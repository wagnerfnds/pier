// Mac only: the edge surface (the tab at the screen's edge, its toolbar and the Inbox card) is drawn by the AppKit plugin
// (Mac/PierMenuBar); this is its data and its actions on the app's side, reached through `MenuBarBridge`.
#if targetEnvironment(macCatalyst)
import SwiftUI
import PierKit

/// The settings of the Mac surfaces (Ajustes → Mac), in UserDefaults.
enum MacSurfaceSettings {
    static let enabledKey = "macSurface.enabled"
    static let edgeKey = "macSurface.edge"
    static let fractionKey = "macSurface.fraction"
    static let displayKey = "macSurface.display"
    static let sizeKey = "macSurface.size"
    static let fullScreenKey = "macSurface.fullScreen"
    static let optionTapKey = "macSurface.optionTap"
    static let optionLabelsKey = "macSurface.optionLabels"
    /// The menu bar item (the dots in the macOS menu bar): off now that the tab is there; on by itself when the tab is hidden.
    static let menuBarKey = "macSurface.menuBar"

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var edge: String { UserDefaults.standard.string(forKey: edgeKey) ?? "right" }
    static var fraction: Double { UserDefaults.standard.object(forKey: fractionKey) as? Double ?? 0.55 }
    /// "main", "pointer" or a display id.
    static var display: String { UserDefaults.standard.string(forKey: displayKey) ?? "main" }
    static var size: String { UserDefaults.standard.string(forKey: sizeKey) ?? "medium" }
    static var fullScreen: Bool { UserDefaults.standard.bool(forKey: fullScreenKey) }
    /// The ⌥ double tap opens Falar (system-wide with the Input Monitoring permission, in Pier otherwise).
    static var optionTap: Bool { UserDefaults.standard.object(forKey: optionTapKey) as? Bool ?? true }
    static var optionLabels: Bool { UserDefaults.standard.object(forKey: optionLabelsKey) as? Bool ?? true }
    static var menuBar: Bool { UserDefaults.standard.object(forKey: menuBarKey) as? Bool ?? false }

    /// Pier never ends up with no always-present surface: hiding the tab turns the menu bar item on.
    static func enforce() {
        if !enabled, !menuBar { UserDefaults.standard.set(true, forKey: menuBarKey) }
    }

    /// What the plugin gets (`configureSurface:`).
    static var config: [String: Any] {
        enforce()
        return ["enabled": enabled, "edge": edge, "fraction": fraction, "display": display, "size": size, "fullScreen": fullScreen,
                "appearance": UserDefaults.standard.string(forKey: Appearance.key) ?? "system",
                "optionTap": optionTap, "optionLabels": optionLabels, "menuBar": menuBar]
    }
}

/// The Inbox card's data and state on the Mac: which card is shown, the answer waiting in the undo window, the receipt,
/// dictation into the reply field. Builds the plugin's payload from `InboxStore`, `SessionSignals` and `NextStepsStore`
/// (the same sources as the Inbox screen) and answers through `InboxStore.perform`, so the Mac card and the Inbox are one
/// thing seen from two places.
@MainActor final class MacSurfaceStore {
    weak var model: AppModel?
    var cardOpen = false
    private(set) var current: String?
    private var pending: (id: String, option: Int, label: String, token: PendingActions.Token, start: Date, deadline: Date)?
    /// The card an answer left the Inbox for, kept on screen (where it was) while the window runs and for the receipt.
    private var frozen: (card: [String: Any], index: Int)?
    private var receipt: (text: String, until: Date)?
    private var receiptTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var lastNeedsYou: Set<String> = []
    private let store = InboxStore.shared
    private let signals = SessionSignals.shared
    private let steps = NextStepsStore.shared
    /// Something changed that the payload should reflect (set by actions; observation covers the stores).
    var onChange: (() -> Void)?
    /// The side panel's screen, as the plugin reports it ("none" when closed): the agent view and the form refresh only
    /// while they are up.
    private(set) var panelScreen = "none"
    /// The agent the panel shows: its `SessionViewModel` runs (the session screen's own loop: the record, the screen, the
    /// reply being written) while that screen is up, and its conversation goes into the payload, the newest
    /// `conversationLimit` rows of it.
    private var selectedAgent: String?
    private var agentTask: Task<Void, Never>?
    private var agentVMs: [String: SessionViewModel] = [:]
    private var conversationLimit: [String: Int] = [:]
    private static let conversationPage = 40
    /// A task or chat just started from the panel: the panel shows its agent.
    private var started: (id: String, until: Date)?
    /// The new task / chat form (ComposeModel: the app's own rules for projects, agents, models and names).
    private var compose: ComposeModel?
    private var composeImage: TalkImage?
    private var composeError: String?
    private var composeBusy = false
    /// Falar in the panel (TalkModel routes; TalkActions performs).
    private var talk = TalkModel()
    private var talkImage: TalkImage?
    private var talkReceipt: (text: String, until: Date)?
    private var talkClear = false
    /// The receipt's agent (the panel shows it on that agent's screen too).
    private var receiptFor: String?
    private var dictationTarget: String?

    // MARK: payload

    /// Everything the card and the Inbox button show. Read inside the bridge's observation tracking.
    func payload(dots: [AgentDot]) -> [String: Any] {
        guard let model else { return [:] }
        let items = store.items(model: model)
        var cards = items.map { card($0, model: model) }
        // The answered card stays, where it was, while its answer waits and for the receipt.
        if let frozen, let id = frozen.card["id"] as? String, !cards.contains(where: { ($0["id"] as? String) == id }) {
            cards.insert(frozen.card, at: min(frozen.index, cards.count))
        }
        let ids = cards.compactMap { $0["id"] as? String }
        if let c = current, !ids.contains(c) { current = nil }
        if current == nil { current = ids.first }
        // New questions: read their screens now, so the options are there when the card opens.
        let needs = Set(items.filter { $0.kind == .needsYou }.map(\.id))
        if !needs.subtracting(lastNeedsYou).isEmpty { Task { await self.signals.refreshScreensNow(model: model) } }
        lastNeedsYou = needs
        var out: [String: Any] = ["unseen": store.unseenCount(model: model), "cards": cards, "cardOpen": cardOpen]
        if let current { out["current"] = current }
        if let pending {
            out["pending"] = ["card": pending.id, "option": pending.option, "label": pending.label,
                              "start": pending.start.timeIntervalSince1970, "deadline": pending.deadline.timeIntervalSince1970]
        }
        if let receipt, receipt.until > Date() { out["receipt"] = receipt.text; if let receiptFor { out["receiptFor"] = receiptFor } }
        if let target = dictationTarget {
            let d = TalkCenter.shared.dictation
            out["dictation"] = ["target": target, "active": d.isListening, "text": d.transcript]
        }
        // The side panel: the agents, the one shown, the form, Falar.
        out["agents"] = dots.map { agentRow($0, model: model) }
        if let selectedAgent, let detail = agentDetail(selectedAgent, model: model) { out["agentDetail"] = detail }
        if let started, started.until > Date() { out["started"] = started.id }
        out["compose"] = composePayload(model: model)
        out["talk"] = talkPayload(model: model)
        return out
    }

    // MARK: the agents and one agent

    private func agentRow(_ d: AgentDot, model: AppModel) -> [String: Any] {
        guard let conn = model.connection(for: d.box), let s = conn.sessions.first(where: { $0.name == d.session }) else {
            return ["id": d.id, "state": MenuBarBridge.key(d.state), "word": AgentDots.stateWord(d.state), "title": d.title, "project": d.project, "agentLabel": ""]
        }
        var row: [String: Any] = ["id": d.id, "state": MenuBarBridge.key(d.state), "word": AgentDots.stateWord(d.state), "title": d.title,
                                  "project": d.project, "agentLabel": s.agent.map(DisplayNames.agentLabel) ?? S("Terminal"),
                                  "since": (s.stateSince ?? s.created).timeIntervalSince1970]
        if let a = s.agent { row["agent"] = a }
        if let step = signals.steps[d.id] { row["step"] = step }
        return row
    }

    /// Everything the agent's screen shows: the question and its answers (the Inbox's options) while it waits, the step
    /// while it works, the last reply (fetched by `followAgent`), the next steps when its turn ended, and what can be done.
    private func agentDetail(_ id: String, model: AppModel) -> [String: Any]? {
        let dots = AgentDots.make(model)
        guard let d = dots.first(where: { $0.id == id }), let conn = model.connection(for: d.box),
              let s = conn.sessions.first(where: { $0.name == d.session }) else { return nil }
        var out = agentRow(d, model: model)
        let bs = BoxSession(box: d.box, session: s)
        out["replyPlaceholder"] = S("Responder a \(s.agentShortName)…")
        out["canInterrupt"] = s.agentState == .running
        out["canArchive"] = s.agentState == .finished
        out["canReview"] = !bs.location.isEmpty
        if let ch = signals.changes["\(d.box)/\(s.location ?? "")"], ch.added + ch.removed > 0 { out["change"] = "+\(ch.added) −\(ch.removed)" }
        if s.needsYou {
            let wording = PermissionWording.headline(agent: s.agentShortName, tool: s.ask?.tool)
            out["question"] = s.needsYouKind == .question ? (InboxStore.questionText(for: s, id: id) ?? S("\(s.agentShortName) tem uma pergunta")) : wording.text
            if s.needsYouKind != .question, let input = s.ask?.input, !input.isEmpty { out[wording.mono ? "command" : "detail"] = input }
            if s.needsYouKind != .question, let why = s.ask?.why, !why.isEmpty { out["why"] = why }
            out["options"] = InboxStore.options(for: s, id: id, screen: signals.screens[id]).map { o -> [String: Any] in
                var r: [String: Any] = ["number": o.number, "title": o.title, "recommended": o.recommended]
                if let detail = o.detail { r["detail"] = detail }
                r["role"] = switch o.role { case .allow: "allow"; case .always: "always"; case .deny: "deny"; case .plain: "plain" }
                return r
            }
        }
        let vm = agentVMs[id]
        if let vm { out["conversation"] = PanelConversation.payload(vm, limit: conversationLimit[id] ?? Self.conversationPage) }
        if let f = agentFailure, f.id == id { out["failure"] = ["token": f.token, "text": f.text, "error": f.error] }
        if s.agentState == .finished, let since = s.stateSince {
            let key = NextSteps.Key(box: d.box, session: s.name, since: since)
            // This very turn's reply: the board's (read for this turn), else the conversation's once its record was
            // written as the turn ended (a kept or late conversation can still end on the turn before, and the next
            // steps are asked once per turn).
            let written = vm.flatMap { v -> String? in
                guard let last = v.store.last, Double(last) / 1000 >= since.timeIntervalSince1970 - 60 else { return nil }
                return v.store.items.last { $0.type == .text }?.text
            }
            let reply = signals.replies[id]?.since == since ? (signals.replyTexts[id] ?? written) : written
            if panelScreen == "agent:\(id)", let reply { steps.request(key, place: s.execPlace, reply: reply, task: s.title, client: conn.client) }
            switch steps.phase(key) {
            case .ready(let r)?: out["nextSteps"] = r
            case .loading?: out["nextStepsLoading"] = true
            default: break
            }
        }
        return out
    }

    /// The panel shows this agent: its view model runs as the session screen's does (events, the record, the screen, the
    /// reply being written), so the conversation is live and what was read stays for the next time (`TranscriptCache`);
    /// the board's signals (line changes, waiting screens) are refreshed beside it, and a finished turn shown is seen.
    func select(agent id: String?) {
        guard selectedAgent != id else { return }
        selectedAgent = id
        agentTask?.cancel(); agentTask = nil
        onChange?()
        guard let id, model != nil else { return }
        agentTask = Task { [weak self] in
            // A task just started is listed a moment later: wait for it.
            var vm: SessionViewModel?
            while vm == nil, !Task.isCancelled {
                vm = self?.vm(for: id)
                if vm == nil { try? await Task.sleep(for: .milliseconds(500)) }
            }
            guard let vm, !Task.isCancelled else { return }
            self?.onChange?()
            let follow = Task { await vm.run() }
            defer { follow.cancel() }
            while !Task.isCancelled {
                guard let self, let model = self.model else { return }
                // Only once per turn: each mark rewrites the prefs and redraws everything that reads them.
                if vm.session.agentState == .finished, !vm.isClosed, !model.prefs.isSeen(box: vm.box, session: vm.session) {
                    model.prefs.markSeen(box: vm.box, session: vm.name)
                }
                await self.signals.refreshBoard(model: model)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Debug (`-macSurfaceDebug agentsend:<text>`): a message from the agent screen the panel shows.
    func debugAgentSend(_ text: String) -> String {
        guard let id = selectedAgent else { return "no agent shown" }
        agentSend(id, text)
        return "agentsend \(id)"
    }

    /// "Mensagens anteriores" in the panel: more of what is held, then the box's older pages.
    func agentOlder(_ id: String) {
        guard let vm = agentVMs[id] else { return }
        conversationLimit[id] = (conversationLimit[id] ?? Self.conversationPage) + Self.conversationPage
        onChange?()
        Task { [weak self] in
            await vm.loadOlder()
            self?.onChange?()
        }
    }

    private func vm(for id: String) -> SessionViewModel? {
        if let v = agentVMs[id] { return v }
        guard let model, let d = AgentDots.make(model).first(where: { $0.id == id }), let conn = model.connection(for: d.box),
              let s = conn.sessions.first(where: { $0.name == d.session }) else { return nil }
        let v = SessionViewModel.shared(box: d.box, session: s, client: conn.client, model: model)
        // Only the agent on screen is kept (each holds its conversation): the rest went for good with every agent ever
        // shown in the panel. The window's screen shares the same model while it shows that session.
        agentVMs = agentVMs.filter { $0.key == selectedAgent }
        agentVMs[id] = v
        return v
    }

    /// The agent screen's 1–9: an Inbox answer while it waits, a next step when its turn ended.
    func agentPick(_ id: String, _ n: Int) { pick(id, n) }

    /// A message for the agent from its screen: it shows in the conversation at once and goes out at once, as from the
    /// session screen's composer (queued on the box while the agent works). Gone out, it answers the agent's Inbox card
    /// as a reply from the Inbox would; failed, its words come back to the field with the reason (`agentFailure`).
    func agentSend(_ id: String, _ text: String) {
        guard let vm = vm(for: id) else { return }
        stopDictation()
        let card = item(id)
        let started = vm.scheduleSend(text, withAttachments: false) { [weak self] sent, error in
            guard let self else { return }
            if sent {
                if let card, let model = self.model { self.store.markAnswered(card, model: model) }
            } else {
                self.agentFailed(id, text: text, error: error)
            }
        }
        if started { onChange?() }
    }

    /// A message from the panel that did not go out: its words go back into the agent screen's field (one line: several
    /// in a row together, in order) and the reason shows over it for a few seconds.
    private var agentFailure: (id: String, token: String, text: String, error: String)?

    private func agentFailed(_ id: String, text: String, error: String?) {
        let token = UUID().uuidString
        let earlier = agentFailure.flatMap { $0.id == id ? $0.text : nil }
        agentFailure = (id, token, earlier.map { $0 + " " + text } ?? text, error ?? S("A mensagem não foi enviada."))
        onChange?()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.agentFailure?.token == token else { return }
            self.agentFailure = nil
            self.onChange?()
        }
    }

    func agentInterrupt(_ id: String) {
        guard let vm = vm(for: id) else { return }
        Task { await vm.interrupt(); self.onChange?() }
    }

    func agentArchive(_ id: String) {
        if let i = item(id), i.kind == .finished { clear(id); return }
        guard let model, let d = AgentDots.make(model).first(where: { $0.id == id }) else { return }
        model.prefs.setClosed(true, box: d.box, session: d.session)
        onChange?()
    }

    func agentReview(_ id: String) {
        guard let model, let d = AgentDots.make(model).first(where: { $0.id == id }), let conn = model.connection(for: d.box),
              let s = conn.sessions.first(where: { $0.name == d.session }) else { return }
        model.prefs.markSeen(box: d.box, session: d.session)
        model.router.openReview(box: d.box, session: d.session, location: s.location)
    }

    func agentOpen(_ id: String) {
        guard let model, let d = AgentDots.make(model).first(where: { $0.id == id }) else { return }
        model.prefs.markSeen(box: d.box, session: d.session)
        model.openSession(box: d.box, name: d.session)
    }

    /// The plugin's panel changed screen: the agent followed, the form bound, the refresh loops aimed.
    func panelScreen(_ name: String) {
        panelScreen = name
        select(agent: name.hasPrefix("agent:") ? String(name.dropFirst(6)) : nil)
        if name == "task" || name == "chat" { ensureCompose(chat: name == "chat") }
        if name == "none" { stopDictation(); talk.cancelRouting() }
        setOpen(name != "none")
    }

    // MARK: the new task / chat form

    private func ensureCompose(chat: Bool) {
        guard let model else { return }
        if compose == nil {
            let box = model.prefs.lastBox ?? model.boxes.first?.name ?? ""
            compose = ComposeModel(route: ComposeRoute(box: box, chat: chat))
        }
        compose?.bind(model)
        if compose?.chat != chat { compose?.selectChat(chat) }
        onChange?()
    }

    private func composePayload(model: AppModel) -> [String: Any] {
        guard let c = compose else { return ["kind": "task", "projects": []] }
        c.bind(model)
        let recents = Set(model.prefs.recentProjects)
        var projects: [[String: Any]] = []
        for conn in model.boxes {
            for l in conn.locations where l.repo && !model.prefs.isHidden(box: conn.name, location: l.name) {
                let key = LocalPrefs.key(box: conn.name, location: l.name)
                projects.append(["key": key, "box": conn.name, "location": l.name, "name": model.prefs.displayName(box: conn.name, location: l.name),
                                 "recent": recents.contains(key)])
            }
        }
        projects.sort { a, b in
            let ra = a["recent"] as? Bool ?? false, rb = b["recent"] as? Bool ?? false
            if ra != rb { return ra }
            return (a["name"] as? String ?? "") < (b["name"] as? String ?? "")
        }
        let agents = c.agents.map { a -> [String: Any] in
            ["id": a.id, "name": a.name.isEmpty ? DisplayNames.agentLabel(a.id) : a.name, "canModel": a.canPickModel, "canEffort": a.canPickEffort,
             "models": a.models ?? [], "efforts": a.efforts ?? []]
        }
        var out: [String: Any] = ["kind": c.chat ? "chat" : "task", "canChat": c.canChat, "projects": projects,
                                  "worktree": c.isNew ? "new" : "main", "agents": agents, "summary": c.summary,
                                  "busy": composeBusy || c.stage.isBusy, "image": composeImage != nil]
        // The picture itself, so the panel shows what was taken (the panel runs in this process: the bytes go as they are).
        if let d = composeImage?.data { out["imageData"] = d }
        if let l = c.location, !c.chat { out["project"] = LocalPrefs.key(box: c.box, location: l) }
        if let a = c.agentID { out["agent"] = a }
        if let m = c.model { out["model"] = m }
        if let e = c.effort { out["effort"] = e }
        if let error = composeError ?? c.error { out["error"] = error }
        return out
    }

    func composeSet(_ field: String, _ value: String) {
        guard let model else { return }
        ensureCompose(chat: compose?.chat ?? false)
        guard let c = compose else { return }
        switch field {
        case "kind": c.selectChat(value == "chat")
        case "project":
            if let slash = value.firstIndex(of: "/") {
                let box = String(value[..<slash]), loc = String(value[value.index(after: slash)...])
                if box != c.box { c.selectBox(box) }
                c.selectLocation(loc)
            }
        case "worktree":
            if value == "main", let main = c.worktrees.first(where: { $0.main == true }) { c.selectTarget(.existing(main.name)) } else { c.selectTarget(.newWorktree) }
        case "agent": c.selectAgent(value)
        case "model": c.model = value.isEmpty ? nil : value
        case "effort": c.effort = value.isEmpty ? nil : value
        default: break
        }
        composeError = nil
        _ = model
        onChange?()
    }

    func composeImage(_ image: TalkImage?) {
        composeImage = image
        onChange?()
    }

    /// Start: the app's own path (ComposeModel.submit: worktree or main, the picture uploaded first, chats), then the
    /// panel shows the new agent.
    func composeStart(_ text: String) {
        guard let model, let c = compose, !composeBusy else { return }
        c.prompt = text
        c.promptChanged()
        if let image = composeImage, let photo = ComposePhoto.make(from: image.data, index: 1) { c.photos = [photo] }
        guard c.canSubmit else { composeError = c.chat ? S("Escreva o pedido.") : S("Escolha um projeto e escreva o pedido."); onChange?(); return }
        composeBusy = true
        composeError = nil
        onChange?()
        Task { [weak self] in
            let session = await c.submit()
            guard let self else { return }
            self.composeBusy = false
            if let session {
                let id = "\(c.box)/\(session.name)"
                self.started = (id, Date().addingTimeInterval(5))
                self.composeImage = nil
                c.prompt = ""
                c.photos = []
                self.select(agent: id)
                self.panelScreen = "agent:\(id)"
            } else {
                self.composeError = c.error
            }
            self.onChange?()
            _ = model
        }
    }

    // MARK: Falar in the panel

    private func talkPayload(model: AppModel) -> [String: Any] {
        var out: [String: Any] = ["phase": phaseName(talk.phase)]
        if case .asking(let q) = talk.phase { out["question"] = q }
        if case .failed(let m) = talk.phase { out["error"] = m }
        if let plan = talk.plan, talk.phase == .decided {
            var d: [String: Any] = ["text": plan.text]
            switch plan.target {
            case .session(let box, let name):
                let conn = model.boxes.first { $0.name == box }
                let s = conn?.sessions.first { $0.name == name }
                d["kicker"] = S("Mandar para")
                d["title"] = s.map { DisplayNames.sessionName($0, among: conn?.sessions ?? []) } ?? name
                if let s { d["subtitle"] = model.prefs.displayName(box: box, location: BoxSession(box: box, session: s).location) }
                d["isNew"] = false
            case .newTask(let box, let location):
                d["kicker"] = S("Nova tarefa em")
                d["title"] = model.prefs.displayName(box: box, location: location)
                d["subtitle"] = model.boxes.count > 1 ? box : S("Numa worktree nova")
                d["isNew"] = true
            }
            out["decision"] = d
        }
        if let r = talkReceipt, r.until > Date() { out["receipt"] = r.text }
        if talkClear { out["clear"] = true; talkClear = false }
        out["image"] = talkImage != nil
        if let d = talkImage?.data { out["imageData"] = d }
        return out
    }

    private func phaseName(_ p: TalkModel.Phase) -> String {
        switch p {
        case .input: "input"
        case .routing: "routing"
        case .decided: "decided"
        case .asking: "asking"
        case .failed: "failed"
        case .sending: "sending"
        }
    }

    func talkRoute(_ text: String) {
        guard let model else { return }
        stopDictation()
        talk.text = text
        talk.image = talkImage
        talk.route(model: model, sendDirect: UserDefaults.standard.bool(forKey: TalkCenter.sendDirectKey)) { [weak self] plan in self?.talkPerform(plan) }
        onChange?()
    }

    func talkConfirm() {
        guard let plan = talk.plan else { return }
        talkPerform(plan)
    }

    private func talkPerform(_ plan: TalkPlan) {
        guard let model else { return }
        let center = TalkCenter.shared
        talk.phase = .input
        talk.plan = nil
        talkImage = nil
        talkClear = true
        onChange?()
        PendingActions.shared.schedule(label: plan.text, perform: { [weak self] in
            switch await TalkActions.perform(plan, model: model) {
            case .success(let receipt):
                center.show(receipt)
                self?.talkReceipt = (receipt.title, Date().addingTimeInterval(5))
                self?.onChange?()
                Task { try? await Task.sleep(for: .seconds(5)); self?.onChange?() }
            case .failure(let f):
                self?.talk.phase = .failed(f.message)
                self?.onChange?()
            }
        }, onUndo: { [weak self] in
            self?.talk.text = plan.text
            self?.talk.plan = plan
            self?.talk.phase = .decided
            self?.onChange?()
        })
    }

    func talkImage(_ image: TalkImage?) {
        talkImage = image
        onChange?()
    }

    /// "Ajustar no Pier": the app's Falar sheet with the same words (and picture).
    func talkOpen() {
        TalkCenter.shared.open(text: talk.plan?.text ?? talk.text, image: talkImage)
    }

    // MARK: dictation into the panel's fields

    /// A field's microphone (`target`: "inbox", "agent:<id>", "compose", "talk"): the app's own dictation, its transcript
    /// pushed into that field while it listens.
    func toggleDictation(target: String) {
        let d = TalkCenter.shared.dictation
        if d.isListening { stopDictation(); return }
        guard Dictation.isAuthorized else {
            // The permissions are asked in Falar, which explains them; the sheet opens listening.
            TalkCenter.shared.open(listen: true)
            return
        }
        dictationTarget = target
        Task { await d.start() }
        onChange?()
    }

    /// The dots, with the one the card shows marked (its amber dot is the full one on the tab).
    func mark(_ dots: [AgentDot]) -> [[String: String]] {
        dots.map { d in
            ["id": d.id, "state": MenuBarBridge.key(d.state), "title": d.title, "project": d.project,
             "word": AgentDots.stateWord(d.state), "focused": d.id == current || d.state != .needsYou ? "1" : "0"]
        }
    }

    private func card(_ i: InboxItem, model: AppModel) -> [String: Any] {
        let s = i.item.session
        let prefs = model.prefs
        var place = [i.item.placeName(prefs)]
        if let wt = i.item.worktree, wt != s.displayTitle { place.append(wt) }
        if model.boxes.count > 1 { place.append(i.item.box) }
        let agentLabel = s.agent.map(DisplayNames.agentLabel) ?? S("Terminal")
        var c: [String: Any] = ["id": i.id, "kind": i.kind == .needsYou ? "needsYou" : "finished", "title": s.displayTitle,
                                "agentLabel": agentLabel, "place": place.joined(separator: " · "),
                                "replyPlaceholder": S("Responder a \(s.agentShortName)…")]
        if let a = s.agent { c["agent"] = a }
        var signature = "\(i.id)|\(i.since.timeIntervalSince1970)|\(s.displayTitle)"
        if i.kind == .needsYou {
            c["word"] = AgentDots.stateWord(.needsYou)
            let wording = PermissionWording.headline(agent: s.agentShortName, tool: s.ask?.tool)
            let question = s.needsYouKind == .question ? (InboxStore.questionText(for: s, id: i.id) ?? S("\(s.agentShortName) tem uma pergunta")) : wording.text
            c["question"] = question
            // What the agent wants to run or edit, under the headline; a command reads better in monospace.
            if s.needsYouKind != .question, let input = s.ask?.input, !input.isEmpty { c[wording.mono ? "command" : "detail"] = input }
            if s.needsYouKind != .question, let why = s.ask?.why, !why.isEmpty { c["why"] = why }
            let options = InboxStore.options(for: s, id: i.id, screen: signals.screens[i.id])
            c["options"] = options.map { o -> [String: Any] in
                var d: [String: Any] = ["number": o.number, "title": o.title, "recommended": o.recommended]
                if let detail = o.detail { d["detail"] = detail }
                d["role"] = switch o.role { case .allow: "allow"; case .always: "always"; case .deny: "deny"; case .plain: "plain" }
                return d
            }
            signature += "|" + options.map { "\($0.number):\($0.title):\($0.recommended)" }.joined(separator: ",") + "|\(question)|\(s.ask?.input ?? "")|\(s.ask?.why ?? "")"
        } else {
            c["word"] = AgentDots.stateWord(.done)
            let fresh = signals.replies[i.id]?.since == i.since
            let reply = fresh ? (signals.replies[i.id]?.text ?? signals.replyTexts[i.id]) : nil
            c["reply"] = reply.map { SessionActivityAttributes.ContentState.excerpt($0, limit: 600) ?? $0 } ?? (fresh ? S("Terminou a vez.") : S("Lendo a resposta…"))
            var next: [String] = []
            var loading = false
            if let since = s.stateSince, fresh {
                let key = NextSteps.Key(box: i.item.box, session: s.name, since: since)
                // Asked lazily, like the Inbox card does: once per turn, only when the card can show it.
                if cardOpen, current == i.id { steps.request(key, place: s.execPlace, reply: signals.replyTexts[i.id] ?? reply, task: s.title, client: model.client(for: i.item.box)) }
                switch steps.phase(key) {
                case .ready(let r)?: next = r
                case .loading?: loading = true
                default: break
                }
            }
            c["nextSteps"] = next
            c["nextStepsLoading"] = loading
            if let ch = signals.changes["\(i.item.box)/\(s.location ?? "")"], ch.added + ch.removed > 0 { c["change"] = "+\(ch.added) −\(ch.removed)" }
            c["canReview"] = !i.item.location.isEmpty
            signature += "|\(c["reply"] as? String ?? "")|\(next.joined(separator: ","))|\(loading)|\(c["change"] as? String ?? "")"
        }
        c["signature"] = signature
        return c
    }

    // MARK: open, page

    func setOpen(_ open: Bool) {
        guard cardOpen != open else { return }
        cardOpen = open
        if open {
            // The Inbox's own refresh loop while the card is up: screens, replies, line changes.
            tickTask?.cancel()
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, let model = self.model else { return }
                    await self.store.followUp(model: model)
                    await self.signals.refreshBoard(model: model)
                    try? await Task.sleep(for: .seconds(3))
                }
            }
            if let model { Task { await self.signals.refreshBoard(model: model, force: true) } }
        } else {
            tickTask?.cancel(); tickTask = nil
            stopDictation()
        }
        onChange?()
    }

    func page(by delta: Int) {
        guard let model else { return }
        let ids = store.items(model: model).map(\.id)
        current = SurfacePaging.page(from: current, by: delta, in: ids)
        onChange?()
    }

    func page(to index: Int) {
        guard let model else { return }
        let ids = store.items(model: model).map(\.id)
        guard ids.indices.contains(index) else { return }
        current = ids[index]
        onChange?()
    }

    // MARK: answers

    private func item(_ id: String) -> InboxItem? {
        guard let model else { return nil }
        return store.items(model: model).first { $0.id == id }
    }

    /// 1–9 on the card: an answer of a waiting agent, a suggested next step of a finished turn. The card stays, its row
    /// green, while the undo window runs ("Esc desfaz"); then the receipt, and the next card.
    func pick(_ id: String, _ n: Int) {
        guard let model, let i = item(id), pending == nil else { return }
        let action: InboxAction
        let label: String
        switch i.kind {
        case .needsYou:
            guard let o = InboxStore.options(for: i.item.session, id: id, screen: signals.screens[id]).first(where: { $0.number == n }) else { return }
            action = .option(o); label = o.title
        case .finished:
            guard let since = i.item.session.stateSince, case .ready(let replies)? = steps.phase(NextSteps.Key(box: i.item.box, session: i.item.session.name, since: since)),
                  replies.indices.contains(n - 1) else { return }
            action = .send(replies[n - 1]); label = replies[n - 1]
        }
        freeze(i, model: model)
        Task {
            guard let token = await store.perform(action, on: i, model: model) else { frozen = nil; onChange?(); return }
            began(id, option: n, label: label, token: token, title: i.item.session.agentShortName)
        }
    }

    private func freeze(_ i: InboxItem, model: AppModel) {
        let ids = store.items(model: model).map(\.id)
        frozen = (card(i, model: model), ids.firstIndex(of: i.id) ?? 0)
    }

    /// The reply field: a message for the agent, queued until it is idle.
    func reply(_ id: String, _ text: String) {
        guard let model, let i = item(id), pending == nil else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        stopDictation()
        freeze(i, model: model)
        Task {
            guard let token = await store.perform(.send(t), on: i, model: model, typed: true) else { frozen = nil; onChange?(); return }
            // Typed words go out at once: "Enviando…", never an undo that could not take them back.
            began(id, option: 0, label: t, token: token, title: i.item.session.agentShortName, undoable: false)
        }
    }

    private func began(_ id: String, option: Int, label: String, token: PendingActions.Token, title: String, undoable: Bool = true) {
        let now = Date()
        let secs = undoable ? Double(PendingActions.seconds) : 0
        pending = (id, option, label, token, now, now.addingTimeInterval(secs))
        onChange?()
        Task { [weak self] in
            // The window ends (sent) or is undone: wait for the send itself too, then settle.
            while let self, self.pending?.token == token, PendingActions.shared.isPending(token) { try? await Task.sleep(for: .milliseconds(80)) }
            while let self, self.pending?.token == token, self.store.busy.contains(id) { try? await Task.sleep(for: .milliseconds(80)) }
            guard let self, self.pending?.token == token else { return }
            self.pending = nil
            if self.store.handled[id] != nil || self.item(id) == nil {
                self.receiptFor = id
                self.show(receipt: S("Enviado para \(title)"))
                self.frozen = nil
                if let model = self.model {
                    let ids = self.store.items(model: model).map(\.id)
                    self.current = ids.first { $0 != id } ?? ids.first
                }
            } else {
                self.frozen = nil   // undone, or it failed: the card is back in the list by itself
            }
            self.onChange?()
        }
    }

    private func show(receipt text: String) {
        receipt = (text, Date().addingTimeInterval(3.5))
        receiptTask?.cancel()
        receiptTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            self?.receipt = nil
            self?.onChange?()
        }
    }

    /// Esc while an answer waits: "Desfazer" (the card comes back as it was).
    func undo() {
        guard let p = pending else { return }
        PendingActions.shared.undo(p.token)
    }

    /// E: archive a finished turn, dismiss a question (both with the undo window, like the Inbox).
    func clear(_ id: String) {
        guard let model, let i = item(id) else { return }
        if i.kind == .finished { store.archive(i, model: model) } else { store.dismiss(i, model: model) }
        let ids = store.items(model: model).map(\.id)
        current = ids.first { $0 != id } ?? ids.first
        onChange?()
    }

    func open(_ id: String) {
        guard let model, let i = item(id) else { return }
        if i.kind == .finished { model.prefs.markSeen(box: i.item.box, session: i.item.session.name) }
        model.openSession(box: i.item.box, name: i.item.session.name)
    }

    func review(_ id: String) {
        guard let model, let i = item(id) else { return }
        model.prefs.markSeen(box: i.item.box, session: i.item.session.name)
        model.router.openReview(box: i.item.box, session: i.item.session.name, location: i.item.session.location)
    }

    /// The Inbox card's microphone.
    func toggleDictation(_ id: String) { toggleDictation(target: "inbox") }

    func stopDictation() {
        guard dictationTarget != nil else { return }
        let d = TalkCenter.shared.dictation
        if d.isListening { _ = d.stop() }
        // The final words stay in the field: one last payload with the transcript, then the target is forgotten.
        onChange?()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.dictationTarget = nil
            self?.onChange?()
        }
    }
}
#endif
