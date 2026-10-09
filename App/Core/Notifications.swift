import Foundation
import SwiftUI
import UserNotifications
import PierKit

/// Action identifiers of the actionable categories (see docs/PUSH.md).
enum NotificationAction {
    static let allow = "ALLOW"
    static let deny = "DENY"
    /// "Responder" on a permission notification: opens the app on the session.
    static let answer = "ANSWER"
    static let open = "OPEN"
    static let review = "REVIEW"
    static let message = "MESSAGE"
}

/// Local notifications for waiting/finished transitions, with actions (Allow / Deny / Review / Message, and a question's
/// own choices as buttons: `NotificationChoices`).
@MainActor @Observable
final class Notifications: NSObject, UNUserNotificationCenterDelegate {
    var status: UNAuthorizationStatus = .notDetermined
    /// True when the foreground UI already announces this box's transitions (set by the model).
    @ObservationIgnored var isCovered: (@MainActor (String) -> Bool)?
    @ObservationIgnored var onOpen: ((String, String) -> Void)?   // (box, session)
    /// (box, session, "location/worktree")
    @ObservationIgnored var onReview: ((String, String, String?) -> Void)?
    /// A button answered the agent (box, session): the app re-reads that box so the screens show the new state at once.
    @ObservationIgnored var onAnswered: ((String, String) -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        Task { await Self.registerCategories() }
    }

    /// NEEDS_YOU (permission menu), NEEDS_YOU_QUESTION and FINISHED. Also what a push's `aps.category` must name.
    nonisolated static func categories() -> Set<UNNotificationCategory> {
        let allow = UNNotificationAction(identifier: NotificationAction.allow, title: String(localized: "Permitir"),
                                         options: [.authenticationRequired], icon: UNNotificationActionIcon(systemImageName: "checkmark"))
        let deny = UNNotificationAction(identifier: NotificationAction.deny, title: String(localized: "Negar"),
                                        options: [.destructive], icon: UNNotificationActionIcon(systemImageName: "xmark"))
        let answer = UNNotificationAction(identifier: NotificationAction.answer, title: String(localized: "Responder"),
                                          options: [.foreground], icon: UNNotificationActionIcon(systemImageName: "text.bubble"))
        let open = UNNotificationAction(identifier: NotificationAction.open, title: String(localized: "Abrir"),
                                        options: [.foreground], icon: UNNotificationActionIcon(systemImageName: "arrow.up.forward.app"))
        let review = UNNotificationAction(identifier: NotificationAction.review, title: String(localized: "Revisar"),
                                          options: [.foreground], icon: UNNotificationActionIcon(systemImageName: "doc.text.magnifyingglass"))
        let message = UNTextInputNotificationAction(identifier: NotificationAction.message, title: String(localized: "Mandar mensagem"), options: [],
                                                    icon: UNNotificationActionIcon(systemImageName: "paperplane"),
                                                    textInputButtonTitle: String(localized: "Enviar"),
                                                    textInputPlaceholder: String(localized: "Mensagem para o agente"))
        let hidden = String(localized: "Um agente precisa de você")
        var set: Set<UNNotificationCategory> = [
            UNNotificationCategory(identifier: NotificationCategoryID.needsYouPermission, actions: [allow, deny, answer], intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: hidden, options: []),
            UNNotificationCategory(identifier: NotificationCategoryID.needsYouQuestion, actions: [open], intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: hidden, options: []),
            UNNotificationCategory(identifier: NotificationCategoryID.finished, actions: [review, message], intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: String(localized: "Um agente terminou"), options: []),
        ]
        // NEEDS_YOU_CHOICE_n: a question's choices as numbered buttons, the body numbering them the same way. What pierd
        // names when it read the choices; the service extension replaces it with a category whose buttons carry the words.
        for n in NotificationCategoryID.choiceCounts {
            let numbered = (0..<n).map { i in
                UNNotificationAction(identifier: NotificationChoices.actionPrefix + String(i), title: String(i + 1), options: [],
                                     icon: UNNotificationActionIcon(systemImageName: "\(i + 1).circle"))
            }
            set.insert(UNNotificationCategory(identifier: NotificationCategoryID.needsYouChoice(n), actions: numbered + [open], intentIdentifiers: [],
                                              hiddenPreviewsBodyPlaceholder: hidden, options: []))
        }
        return set
    }

    /// Registers the fixed categories next to the ones a question's choices made (`NotificationChoices`): replacing the
    /// whole set would strip the buttons off a question still on the Lock Screen.
    nonisolated static func registerCategories() async {
        await NotificationChoices.merge(fixed: categories())
    }

    /// The words of the choice buttons, from the app's catalog (the extension picks by the device's language).
    nonisolated static var choiceStrings: NotificationChoices.Strings {
        NotificationChoices.Strings(open: String(localized: "Abrir"), hidden: String(localized: "Um agente precisa de você"))
    }

    func refreshStatus() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        let ok = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshStatus()
        return ok
    }

    /// `options`: a waiting agent's choices, shown as the notification's buttons (`ChoiceOptions.fetch`).
    func notifyTransition(box: String, session: Session, to state: AgentState?, boxCount: Int, options: [String]? = nil) async {
        await Self.post(box: box, session: session, to: state, showBox: boxCount > 1, options: options)
    }

    /// Title and body for a waiting/finished transition (`nil` for other states). Shared by local notifications and the in-app banner.
    nonisolated static func text(box: String, session: Session, to state: AgentState?, showBox: Bool) -> (title: String, body: String)? {
        guard state == .waiting || state == .finished else { return nil }
        let agent = (session.agent ?? "agent").capitalized
        let loc = session.chat ? String(localized: "Conversa") : session.location ?? session.name
        let title: String
        var body = session.title ?? loc
        if state == .waiting {
            title = String(localized: "\(agent) precisa de você")
            if let a = session.ask {
                let extra = [a.tool, a.input ?? a.message].compactMap { $0 }.joined(separator: " ")
                if !extra.isEmpty { body += " — " + extra }
            }
        } else {
            title = String(localized: "\(agent) terminou")
        }
        if showBox { body += " · \(box)" }
        return (title, body)
    }

    /// Posts the local notification for a transition. A waiting agent's `options` (its question's or menu's choices) become
    /// the buttons: a category of their own, registered first (docs/PUSH.md 4.3).
    nonisolated static func post(box: String, session: Session, to state: AgentState?, showBox: Bool, options: [String]? = nil) async {
        guard let (title, body) = text(box: box, session: session, to: state, showBox: showBox) else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        var info = userInfo(box: box, session: session)
        c.categoryIdentifier = NotificationCategoryID.category(state: state, ask: session.ask) ?? ""
        if state == .waiting, let options, options.count >= 2 {
            info[NotificationChoices.optionsKey] = options
            c.categoryIdentifier = await NotificationChoices.register(options: options, strings: choiceStrings)
        }
        c.userInfo = info
        c.threadIdentifier = "\(box)/\(session.name)"
        let id = "\(box)/\(session.name)/\(state?.rawValue ?? "")/\(Int(session.stateSince?.timeIntervalSince1970 ?? 0))"
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    /// `box` + `session` (+ `location` "loc/wt" for Review, `hasMenu` for permission prompts); mirrored by the push payload.
    nonisolated static func userInfo(box: String, session: Session) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = ["box": box, "session": session.name,
                                        "hasMenu": session.needsYou && Ask.classify(session.ask) == .permission]
        if let l = session.location { info["location"] = l }
        return info
    }

    enum ActionOutcome: Equatable {
        case opened
        case done
        case failed(String)
    }

    /// Runs a notification action. The app may have been launched in the background just for this: nothing here touches the UI
    /// except routing closures. A failed answer posts a local notification so the person knows to look.
    /// `options` are the choices the notification carried (a `CHOICE_<n>` action picks one of them).
    func handle(action: String, box: String, session: String, location: String?, text: String?, options: [String]? = nil) async -> ActionOutcome {
        let outcome = await run(action: action, box: box, session: session, location: location, text: text, options: options)
        if outcome == .done { onAnswered?(box, session) }
        return outcome
    }

    private func run(action: String, box: String, session: String, location: String?, text: String?, options: [String]?) async -> ActionOutcome {
        switch action {
        case NotificationAction.allow, NotificationAction.deny:
            let isAllow = action == NotificationAction.allow
            let r = await SessionActions.answerPermission(box: box, session: session, isAllow ? .allow : .deny)
            if case .failure(let f) = r {
                Self.postFailure(box: box, session: session,
                                 title: isAllow ? String(localized: "Não consegui permitir") : String(localized: "Não consegui negar"), message: f.message)
                return .failed(f.message)
            }
            return .done
        case NotificationAction.message:
            let r = await SessionActions.send(box: box, session: session, text: text ?? "", when: .idle)
            if case .failure(let f) = r {
                Self.postFailure(box: box, session: session, title: String(localized: "Não consegui enviar a mensagem"), message: f.message)
                return .failed(f.message)
            }
            return .done
        case NotificationAction.review:
            onReview?(box, session, location)
            return .opened
        default:
            // A question's choice ("Three tiers"): answered with the person's words, checked against the box first.
            if let i = NotificationChoices.index(of: action) {
                guard let options, options.indices.contains(i) else { return .failed(SessionActions.Failure.menuChanged.message) }
                let r = await SessionActions.answerChoice(box: box, session: session, label: options[i])
                if case .failure(let f) = r {
                    Self.postFailure(box: box, session: session, title: String(localized: "Não consegui responder"), message: f.message)
                    return .failed(f.message)
                }
                return .done
            }
            // A tap, "Responder", "Abrir".
            onOpen?(box, session)
            return .opened
        }
    }

    /// "Não consegui permitir" etc.; opens the session when tapped.
    nonisolated static func postFailure(box: String, session: String, title: String, message: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = message
        c.sound = .default
        c.userInfo = ["box": box, "session": session]
        c.threadIdentifier = "\(box)/\(session)"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "fail/\(box)/\(session)/\(Int(Date().timeIntervalSince1970))", content: c, trigger: nil))
    }

    // The completion-handler form, called back on the main thread: UIKit asserts on any other (the async form resumes
    // wherever the awaited work ends, which crashed the app after a background button).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        guard let box = info["box"] as? String, let session = info["session"] as? String else { completionHandler(); return }
        let location = info["location"] as? String
        let text = (response as? UNTextInputNotificationResponse)?.userText
        let action = response.actionIdentifier
        let options = NotificationChoices.options(in: info)
        let done = Completion(completionHandler)
        Task { @MainActor in
            let outcome = await self.handle(action: action, box: box, session: session, location: location, text: text, options: options)
            #if DEBUG
            UserDefaults.standard.set("\(action) -> \(outcome)", forKey: "debug.lastNotificationAction")
            #endif
            done.run()
        }
    }

    /// The system's completion handler, carried to the main actor (it is not marked Sendable, but it is only ever called once, there).
    private final class Completion: @unchecked Sendable {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // A banner while the app is open (the in-app banner covers normal transitions; this covers anything delivered by the system).
        // A remote push for a box the open app is already following would only repeat that banner (and the haptic).
        let info = notification.request.content.userInfo
        if notification.request.trigger is UNPushNotificationTrigger, let box = info["box"] as? String {
            let covered = await MainActor.run { self.isCovered?(box) ?? false }
            if covered { return [.list] }
        }
        return [.banner, .list, .sound]
    }
}

/// The choices a waiting agent offers, read the way pierd's push engine reads them (docs/PUSH.md 4.3): the transcript's
/// open single-choice question, else the numbered rows on screen (a question Claude Code only writes to its transcript
/// once answered, a plan approval) without the agent's own "Type something" rows. nil for a permission whose menu was
/// found (Permitir / Negar serve better), when fewer than two choices are readable, and after `timeout`.
enum ChoiceOptions {
    static func fetch(client: any PierBoxClient, session: Session, timeout: Duration = .seconds(3)) async -> [String]? {
        guard session.needsYou else { return nil }
        let name = session.name
        let permission = Ask.classify(session.ask) == .permission
        let found: [String]? = await BoxAccess.withTimeout(timeout) {
            if !permission, let page = try? await client.transcript(session: name, since: 0, gen: nil),
               let q = QuestionHelpers.openQuestion(in: page.items), let qs = q.questions, qs.count == 1, qs[0].multi != true {
                let labels = qs[0].options.map(\.label).filter { !$0.isEmpty }
                if labels.count >= 2 { return labels }
            }
            let screen = try await client.screen(session: name, history: 0)
            if permission, MenuParser.actions(in: screen) != nil { return [] }
            return MenuParser.optionLabels(in: screen)
        } ?? nil
        guard let found, found.count >= 2 else { return nil }
        return Array(found.prefix(NotificationChoices.maxOptions))
    }
}

extension Router {
    /// Review screen of a session's worktree (`location` is the session's "loc/wt"); falls back to the session when it is not a worktree.
    func openReview(box: String, session: String, location: String?) {
        guard let location, let i = location.firstIndex(of: "/") else { return }
        tab = .home
        homePath = NavigationPath()
        homePath.append(ReviewRoute(box: box, location: String(location[..<i]), worktree: String(location[location.index(after: i)...]), session: session))
    }
}
