import AppIntents
#if !targetEnvironment(macCatalyst)
import ActivityKit
#endif
import Foundation
import PierKit

// Intents for Live Activity buttons and Shortcuts. Compiled into the app AND the widget extension (App/Shared).
// Names and parameters are stable: other code (App/Intents) reuses them.

/// Answers a permission prompt of an agent session: sends the option digit the screen's menu assigns to Allow / Deny.
enum PermissionAnswer: Sendable {
    case allow, deny

    /// Reads the session's screen, maps the menu (docs/API.md §5.3) and sends the option's own digit.
    /// Returns the key sent, or throws a user-facing error.
    static func send(_ answer: PermissionAnswer, box: String, session: String) async throws -> String {
        guard let access = BoxAccess.load(), let client = access.client(box: box) else { throw SessionIntentError.notPaired }
        let screen: String
        do { screen = try await client.screen(session: session, history: 0) } catch { throw SessionIntentError.unreachable }
        guard let actions = MenuParser.actions(in: screen) else { throw SessionIntentError.noMenu }
        let key: String? = actions.compactMap { a -> String? in
            switch (answer, a) {
            case (.allow, .allow(let k)): k
            case (.deny, .deny(let k)): k
            default: nil
            }
        }.first
        guard let key else { throw SessionIntentError.noMenu }
        do { _ = try await client.send(session: session, .key(key)) } catch { throw SessionIntentError.unreachable }
        await SessionActivityBridge.answered(box: box, session: session)
        return key
    }
}

enum SessionIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notPaired, unreachable, noMenu, noQuestion

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notPaired: "Nenhuma box pareada."
        case .unreachable: "Não foi possível alcançar a box."
        case .noMenu: "O agente não está mais pedindo permissão."
        case .noQuestion: "A pergunta mudou ou já foi respondida."
        }
    }
}

struct AllowPermissionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Permitir"
    static let description = IntentDescription("Permite a ação que o agente está pedindo.")
    /// Allowing runs code on the box: the lock-screen button asks to unlock first, like the push action (`.authenticationRequired`).
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Box") var box: String
    @Parameter(title: "Sessão") var session: String

    init() {}
    init(box: String, session: String) { self.box = box; self.session = session }

    func perform() async throws -> some IntentResult {
        _ = try await PermissionAnswer.send(.allow, box: box, session: session)
        return .result()
    }
}

struct DenyPermissionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Negar"
    static let description = IntentDescription("Nega a ação que o agente está pedindo.")

    @Parameter(title: "Box") var box: String
    @Parameter(title: "Sessão") var session: String

    init() {}
    init(box: String, session: String) { self.box = box; self.session = session }

    func perform() async throws -> some IntentResult {
        _ = try await PermissionAnswer.send(.deny, box: box, session: session)
        return .result()
    }
}

/// Answers a waiting question with one of its choices, by its words: the question's own form when the box has it (the
/// hook's `ask.questions`, `POST .../answer`), else the numbered row on screen that reads so (a plan approval, a menu).
enum ChoiceAnswer {
    static func send(_ label: String, box: String, session: String) async throws {
        guard let access = BoxAccess.load(), let client = access.client(box: box) else { throw SessionIntentError.notPaired }
        let s: Session?
        do { s = try await client.sessions().first { $0.name == session } } catch { throw SessionIntentError.unreachable }
        guard let s, s.needsYou else { throw SessionIntentError.noQuestion }
        if let q = s.ask?.questionItem?.questions, q.count == 1, q[0].multi != true, q[0].options.contains(where: { $0.label == label }) {
            do {
                _ = try await client.answerQuestions(session: session, tool: "AskUserQuestion", answers: [.pick(label)])
                await SessionActivityBridge.answered(box: box, session: session)
                return
            } catch {
                // The box could not drive the form: the row on screen, below.
            }
        }
        let screen: String
        do { screen = try await client.screen(session: session, history: 0) } catch { throw SessionIntentError.unreachable }
        guard let c = MenuParser.choices(in: screen).first(where: { $0.label == label || $0.label.hasPrefix(label) }) else {
            throw SessionIntentError.noQuestion
        }
        do { _ = try await client.send(session: session, .key(c.key)) } catch { throw SessionIntentError.unreachable }
        await SessionActivityBridge.answered(box: box, session: session)
    }
}

/// One of a question's choices, as a Live Activity button (the Dynamic Island, the Lock Screen).
struct AnswerChoiceIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Responder"
    static let description = IntentDescription("Responde a pergunta do agente com uma das opções.")

    @Parameter(title: "Box") var box: String
    @Parameter(title: "Sessão") var session: String
    @Parameter(title: "Opção") var choice: String

    init() {}
    init(box: String, session: String, choice: String) { self.box = box; self.session = session; self.choice = choice }

    func perform() async throws -> some IntentResult {
        try await ChoiceAnswer.send(choice, box: box, session: session)
        return .result()
    }
}

/// Opens the app on a session (deep link `pier://session?box=&name=`).
struct OpenSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Abrir sessão"
    static let description = IntentDescription("Abre uma sessão de agente no Pier.")
    static let openAppWhenRun = true

    @Parameter(title: "Box") var box: String
    @Parameter(title: "Sessão") var session: String

    init() {}
    init(box: String, session: String) { self.box = box; self.session = session }

    func perform() async throws -> some IntentResult {
        PendingDeepLink.set(Shared.sessionURL(box: box, name: session))
        return .result()
    }
}

/// A deep link left in the App Group by an intent; the app opens it when it becomes active.
enum PendingDeepLink {
    private static let key = "pendingDeepLink"
    static func set(_ url: URL) { Shared.defaults.set(url.absoluteString, forKey: key) }
    static func take() -> URL? {
        let d = Shared.defaults
        guard let s = d.string(forKey: key) else { return nil }
        d.removeObject(forKey: key)
        return URL(string: s)
    }
}

/// After a button answered the prompt, flip the running activity out of "waiting" right away (the box will confirm on the
/// next refresh). No Live Activities on the Mac.
enum SessionActivityBridge {
    static func answered(box: String, session: String) async {
        #if !targetEnvironment(macCatalyst)
        for a in Activity<SessionActivityAttributes>.activities where a.attributes.box == box && a.attributes.session == session {
            var s = a.content.state
            guard s.phase == .waiting else { continue }
            s.phase = .running; s.since = Date(); s.ask = nil; s.hasMenu = false; s.step = nil
            s.options = nil; s.steps = nil; s.choices = nil
            await a.update(ActivityContent(state: s, staleDate: nil))
        }
        #endif
    }
}
