import SwiftUI
import PierKit

/// Opens Falar (sheet), keeps the hold-to-talk state of the Home mic and the receipt shown after a request went out.
/// One per app, like `SessionSignals.shared`: the Home, the palette, the menu bar and the sheet all reach it.
@MainActor @Observable
final class TalkCenter {
    static let shared = TalkCenter()

    struct Request: Identifiable {
        let id = UUID()
        var text: String = ""
        /// Start dictating as the sheet opens (the mic was tapped, not held).
        var listen = false
        /// Route `text` at once (it came from a hold or the palette).
        var autoRoute = false
        /// A picture to send with the words ("point at it" on the Mac: a part of the screen).
        var image: TalkImage?
    }

    struct Receipt: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let detail: String
        let box: String
        let session: String
        let symbol: String
    }

    var request: Request?
    private(set) var receipt: Receipt?
    let dictation = Dictation()
    /// The Home mic is held down: the overlay shows the live transcript.
    private(set) var holding = false

    /// "Enviar direto" (Ajustes): act on the router's decision without the confirmation card. Off by default.
    static let sendDirectKey = "talkSendDirect"

    func open(text: String = "", listen: Bool = false, autoRoute: Bool = false, image: TalkImage? = nil) {
        request = Request(text: text, listen: listen, autoRoute: autoRoute && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, image: image)
    }

    // MARK: hold to talk (Home mic)

    func beginHold() {
        guard !holding else { return }
        holding = true
        Haptic.impact(.medium)
        // Without both permissions a system alert would interrupt the gesture: the sheet asks for them instead.
        guard Dictation.isAuthorized else { return }
        Task { await dictation.start() }
    }

    /// `tap`: a short press opens the sheet already listening; a hold sends what was heard to the router.
    func endHold(tap: Bool) {
        guard holding else { return }
        holding = false
        if tap || !Dictation.isAuthorized {
            dictation.cancel()
            open(listen: true)
            return
        }
        let text = dictation.stop().trimmingCharacters(in: .whitespacesAndNewlines)
        Haptic.impact(.light)
        if !text.isEmpty { open(text: text, autoRoute: true) }
    }

    // MARK: receipt

    func show(_ r: Receipt) {
        receipt = r
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(7))
            if self?.receipt?.id == r.id { self?.receipt = nil }
        }
    }

    func dismissReceipt() { receipt = nil }
}

/// A picture that goes with a Falar request (a part of the screen the person pointed at), already downscaled to JPEG.
struct TalkImage: Equatable {
    let name: String
    let data: Data
    let thumb: UIImage

    static func == (a: TalkImage, b: TalkImage) -> Bool { a.name == b.name && a.data == b.data }

    /// Like Compose's photos: at most 2048 px on the long side, JPEG, with a small thumbnail for the chip.
    static func make(from raw: Data, name: String = "tela.jpg") -> TalkImage? {
        guard let photo = ComposePhoto.make(from: raw, index: 1) else { return nil }
        return TalkImage(name: name, data: photo.data, thumb: photo.thumb)
    }
}

/// What will be done, as the person confirms it: the router's decision, possibly edited or pointed at another agent.
struct TalkPlan: Equatable {
    enum Target: Hashable {
        case session(box: String, name: String)
        case newTask(box: String, location: String)
        var box: String { switch self { case .session(let b, _), .newTask(let b, _): b } }
    }
    var target: Target
    var text: String
    var title: String?
    /// Sent with the words: uploaded to the session (or the new worktree), its path under the message.
    var image: TalkImage?
}

/// The sheet's state: input, routing through the box, the decision (or the router's question), sending.
@MainActor @Observable
final class TalkModel {
    enum Phase: Equatable {
        case input
        case routing
        case decided
        case asking(String)
        case failed(String)
        case sending
    }

    var text = ""
    var phase: Phase = .input
    var plan: TalkPlan?
    /// The picture to send with the request (removable in the sheet).
    var image: TalkImage?
    /// What was last sent to the router (with an earlier question and its answer folded in).
    @ObservationIgnored private var lastRequest: String?
    @ObservationIgnored private var routeTask: Task<Void, Never>?

    var canRoute: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && phase != .routing && phase != .sending }

    /// The live sessions and projects, in the router's words. `signals` adds the first line of each finished turn's reply.
    static func context(model: AppModel) -> TalkRouter.Context {
        var sessions: [TalkRouter.SessionInfo] = []
        var projects: [TalkRouter.ProjectInfo] = []
        for c in model.boxes {
            for s in c.sessions where s.isAgent && !s.exited {
                guard let st = DashState(s) else { continue }
                let bs = BoxSession(box: c.name, session: s)
                if model.prefs.isHidden(box: c.name, location: bs.location) { continue }
                let state = switch st { case .needsYou: "needs_you"; case .working: "working"; case .done: "your_turn"; case .ready: "ready" }
                sessions.append(.init(box: c.name, name: s.name, title: DisplayNames.sessionName(s, among: c.sessions),
                                      location: s.location ?? "", state: state, agent: s.agent,
                                      lastReply: SessionSignals.shared.replies[bs.id]?.text))
            }
            for l in c.locations where l.repo && !model.prefs.isHidden(box: c.name, location: l.name) {
                let name = model.prefs.displayName(box: c.name, location: l.name)
                projects.append(.init(box: c.name, location: l.name, displayName: name == l.name ? nil : name,
                                      worktrees: (l.worktrees ?? []).filter { $0.main != true }.map(\.name)))
            }
        }
        // Needs-you and finished turns first: those are what a person most often talks about.
        let order = ["needs_you": 0, "your_turn": 1, "working": 2, "ready": 3]
        sessions.sort { (order[$0.state] ?? 9) < (order[$1.state] ?? 9) }
        return .init(sessions: sessions, projects: projects)
    }

    /// The box that runs the router: the last used one when online, else any online box.
    static func routerBox(model: AppModel) -> BoxConnection? {
        let online = model.boxes.filter { $0.state.isOnline }
        return online.first { $0.name == model.prefs.lastBox } ?? online.first ?? model.boxes.first
    }

    func route(model: AppModel, sendDirect: Bool, onDirect: @escaping @MainActor (TalkPlan) -> Void) {
        var request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        // Answering the router's question: it sees the first request, its question and the answer together.
        if case .asking(let q) = phase, let prev = lastRequest, request != prev {
            request = "\(prev)\n\n(You asked: \(q))\nAnswer: \(request)"
        }
        lastRequest = request
        routeTask?.cancel()
        phase = .routing
        plan = nil
        let context = Self.context(model: model)
        guard let conn = Self.routerBox(model: model), let loc = conn.locations.first(where: \.repo) ?? conn.locations.first else {
            phase = .failed(S("Nenhuma box online para entender o pedido."))
            return
        }
        let language = (Bundle.main.preferredLocalizations.first ?? "pt-BR").hasPrefix("en") ? "English" : "Brazilian Portuguese"
        let cmd = TalkRouter.command(prompt: TalkRouter.prompt(request: request, context: context, language: language))
        let client = conn.client
        routeTask = Task {
            let outcome: Phase
            var decided: TalkPlan?
            do {
                let r = try await client.exec(location: loc.name, command: cmd, timeout: "90s")
                if Task.isCancelled { return }
                if r.exitCode == TalkRouter.noCLIExit {
                    outcome = .failed(S("O Claude Code não foi encontrado na box."))
                } else if r.exitCode != 0 {
                    outcome = .failed(S("Não consegui entender o pedido agora. Tente de novo ou escolha o agente."))
                } else {
                    switch TalkRouter.parse(r.output, context: context) {
                    case .success(.send(let box, let session, let text)):
                        decided = TalkPlan(target: .session(box: box, name: session), text: text)
                        outcome = .decided
                    case .success(.newTask(let box, let location, let prompt, let title)):
                        decided = TalkPlan(target: .newTask(box: box, location: location), text: prompt, title: title)
                        outcome = .decided
                    case .success(.ask(let q)):
                        outcome = .asking(q)
                        text = ""   // the field takes the answer
                    case .failure(.unknownSession), .failure(.unknownProject):
                        outcome = .failed(S("O roteador apontou para um agente que não existe. Escolha o agente."))
                    case .failure:
                        outcome = .failed(S("Não consegui entender o pedido agora. Tente de novo ou escolha o agente."))
                    }
                }
            } catch {
                if Task.isCancelled { return }
                outcome = .failed(SessionActions.describe(error))
            }
            decided?.image = image
            plan = decided
            phase = outcome
            if let decided, sendDirect { onDirect(decided) }
        }
    }

    /// The person picked the agent themselves (no router, or another one than it chose).
    func choose(_ target: TalkPlan.Target) {
        routeTask?.cancel()
        let base = plan?.text ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        var title = plan?.title
        if case .newTask = target, title == nil { title = nil }
        plan = TalkPlan(target: target, text: base, title: title, image: image)
        phase = .decided
    }

    /// Stops a pending route; the sheet can route again (a sheet can disappear and reappear, e.g. while another closes).
    func cancelRouting() {
        routeTask?.cancel()
        routeTask = nil
        if phase == .routing { phase = .input }
    }
}

/// Carries out a confirmed plan. Every Falar action goes through `perform`, so an undo window (a `PendingActions`-style
/// "Desfazer" for 2 s) can wrap this one call later.
@MainActor
enum TalkActions {
    struct Failure: Error { let message: String }

    static func perform(_ plan: TalkPlan, model: AppModel) async -> Result<TalkCenter.Receipt, Failure> {
        guard let conn = model.boxes.first(where: { $0.name == plan.target.box }) else {
            return .failure(Failure(message: S("Essa box não está mais pareada.")))
        }
        let text = plan.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(Failure(message: S("A mensagem está vazia."))) }
        do {
            switch plan.target {
            case .session(let box, let name):
                // The picture first (docs/API.md §4.9), its path under the words, like the composer's photos.
                var full = text
                if let image = plan.image {
                    let a = try await conn.client.uploadAttachment(session: name, name: image.name, data: image.data)
                    full += "\n" + a.path
                }
                let r = try await conn.client.send(session: name, SendRequest(text: full, enter: true, when: .idle, idemKey: "ios-talk-\(UUID().uuidString)"))
                conn.scheduleRefresh(sessions: true)
                Haptic.success()
                let title = conn.sessions.first { $0.name == name }.map { DisplayNames.sessionName($0, among: conn.sessions) } ?? name
                return .success(.init(title: r.queued == true ? S("Na fila de \(title)") : S("Enviado para \(title)"),
                                      detail: text, box: box, session: name, symbol: r.queued == true ? "tray.and.arrow.down.fill" : "paperplane.fill"))
            case .newTask(let box, let location):
                guard let loc = conn.location(named: location) else { return .failure(Failure(message: S("Esse projeto não está mais na box."))) }
                let created = try await TaskCreator.create(box: HeadlessBox(name: box, client: conn.client), info: conn.info, location: loc,
                                                           prompt: text, agent: nil, model: nil, prefs: model.prefs, title: plan.title,
                                                           attachments: plan.image.map { [(name: $0.name, data: $0.data)] } ?? [])
                conn.scheduleRefresh(sessions: true, locations: true)
                NotificationCenter.default.post(name: .pierTaskCreated, object: nil, userInfo: ["box": box, "session": created.session.name])
                Haptic.success()
                let name = model.prefs.displayName(box: box, location: location)
                return .success(.init(title: S("Nova tarefa em \(name)"), detail: plan.title ?? text, box: box,
                                      session: created.session.name, symbol: "plus.bubble.fill"))
            }
        } catch {
            return .failure(Failure(message: ComposeErrorText.message(error)))
        }
    }
}
