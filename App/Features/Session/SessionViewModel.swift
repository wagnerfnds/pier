import SwiftUI
import PierKit

enum DetailState {
    case loading
    case loaded(ToolDetail)
    case failed(String)
}

/// A photo uploaded to the session's worktree, waiting to be sent with the next prompt.
struct ComposerAttachment: Identifiable {
    let id = UUID()
    let name: String
    var path: String?
    var thumbnail: UIImage?
    var failed = false
}

@MainActor @Observable
final class SessionViewModel {
    let box: String
    let name: String
    let initial: Session
    let client: any PierBoxClient
    @ObservationIgnored weak var model: AppModel?

    // Conversation
    var store = TranscriptStore()
    var draft: Draft?
    var loaded = false
    var loadError: String?
    var loadingOlder = false
    /// The session left the box's list while this screen was open (killed elsewhere).
    var gone = false
    var expanded: Set<String> = []
    var details: [String: DetailState] = [:]
    /// "Rodando pnpm test…": what the agent is doing right now, read from its screen while it works.
    var step: String?

    // Terminal / needs you
    var screen = ""
    var screenLoaded = false

    // Composer
    var held: [HeldPrompt] = []
    var sending = false
    var sendTick = 0
    var attachments: [ComposerAttachment] = []
    var actionError: String?
    var interrupting = false

    // View mode
    var mode: SessionViewMode = .conversation
    @ObservationIgnored private var modeChosen = false

    /// The worktree's uncommitted changes (from the box's review list), for the "Revisar" card when this turn edited nothing itself.
    var uncommitted: TurnChanges?
    @ObservationIgnored private var reviewCheck: (key: String, at: Date)?

    // Needs-you bookkeeping
    var answeredFor: Date?          // `stateSince` of the waiting episode already answered
    var answering = false

    @ObservationIgnored private var kickFlag = false
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var pendingSentAt: [String: Date] = [:]
    @ObservationIgnored private var waitSince: Date?
    var titleOverride: String?

    init(box: String, session: Session, client: any PierBoxClient, model: AppModel) {
        self.box = box
        self.name = session.name
        self.initial = session
        self.client = client
        self.model = model
        if let m = SessionViewPrefs.mode(box: box, name: session.name) {
            mode = m; modeChosen = true
        } else if !session.isAgent {
            mode = .terminal
        }
    }

    // MARK: live session

    var session: Session { model?.connection(for: box)?.sessions.first { $0.name == name } ?? initial }
    var conn: BoxConnection? { model?.connection(for: box) }

    var isWaiting: Bool { session.needsYou && answeredFor != session.stateSince }
    /// The terminal's lines (ANSI stripped, side panel cut, compacted), computed once per screen.
    @ObservationIgnored private var terminalCache: (screen: String, lines: [String])?
    var terminalLines: [String] {
        let screen = screen
        if let c = terminalCache, c.screen == screen { return c.lines }
        let lines = TerminalText.compact(TerminalText.clean(screen)).components(separatedBy: "\n")
        terminalCache = (screen, lines)
        return lines
    }

    /// The screen parsed once per screen (menu, form, tail), not once per view body.
    struct ScreenAnalysis {
        let kind: ScreenKind
        let choices: [MenuChoice]
        /// An unnumbered menu (arrows + Enter), e.g. Claude Code's "New MCP server found" dialog.
        let cursor: CursorMenu?
        let keysOnly: Bool
        let tail: [String]
    }
    @ObservationIgnored private var analysisCache: (screen: String, agent: String?, value: ScreenAnalysis)?
    var analysis: ScreenAnalysis {
        let screen = screen, agent = session.agent
        if let c = analysisCache, c.agent == agent, c.screen == screen { return c.value }
        let choices = MenuParser.choices(in: screen)
        let cursor = choices.isEmpty ? MenuParser.cursorMenu(in: screen) : nil
        let v = ScreenAnalysis(kind: MenuParser.screenAt(agent: agent, screen), choices: choices, cursor: cursor,
                               keysOnly: choices.isEmpty && MenuParser.keysOnly(screen), tail: MenuParser.meaningfulTail(screen, 14))
        analysisCache = (screen, agent, v)
        return v
    }

    /// A menu of the agent's own on screen that no hook announced (Claude Code's startup dialogs: MCP servers, trust...).
    /// These dialogs come up while the box still reports the agent as running (no hook fired yet), so a running agent counts
    /// too, but only for a menu with a key hint under it (`Enter to confirm`), never for numbers in its output.
    var screenMenu: Bool {
        guard !session.needsYou, !isClosed, session.isAgent, screenLoaded, screen != answeredScreen else { return false }
        let a = analysis
        guard a.kind == .interactive else { return false }
        if a.cursor != nil { return true }
        return session.agentState != .running && (!a.choices.isEmpty || a.keysOnly)
    }
    /// Shells, monitors and subagents still running for this session (from the transcript's signals and crew).
    var background: [BackgroundItem] { isClosed ? [] : BackgroundWork.running(signals: store.signals, crew: store.crew) }
    /// The needs-you card is up: a wait the box announced, or a menu found on screen.
    var showsCard: Bool { (isWaiting || screenMenu) && pendingAnswer == nil }
    /// The screen the last answer was given against (the card hides until the screen changes).
    private var answeredScreen: String?
    /// The state (by its start) the idle screen check last ran for.
    @ObservationIgnored private var screenLookedAt: Date?
    var isRunning: Bool { session.agentState == .running && !session.exited }
    var hasTranscript: Bool { store.source == "claude" || store.source == "codex" }
    /// The transcript answered and this agent keeps no record the box can read: the conversation shows the screen instead.
    var transcriptUnavailable: Bool { loaded && store.source == "none" }
    /// No input possible: the program ended or the session is gone.
    var isClosed: Bool { session.exited || gone }

    /// (location, worktree) this session works in; a main-worktree session maps to the location's main worktree.
    var reviewTarget: (String, String)? {
        let bs = BoxSession(box: box, session: session)
        let loc = bs.location
        guard !loc.isEmpty else { return nil }
        if let wt = bs.worktree { return (loc, wt) }
        let main = conn?.location(named: loc)?.worktrees?.first { $0.main == true }?.name
        return (loc, main ?? loc)
    }

    /// What to offer in the "Revisar" card at the end of a finished turn: this turn's edits, else uncommitted changes.
    var reviewCard: (changes: TurnChanges, uncommittedOnly: Bool)? {
        guard !isRunning, !isWaiting, reviewTarget != nil else { return nil }
        if let t = TurnChanges.lastTurn(store.displayItems) { return (t, false) }
        if let u = uncommitted { return (u, true) }
        return nil
    }

    private func refreshUncommitted() async {
        let s = session
        guard s.agentState != .running, !s.needsYou, let (loc, wt) = reviewTarget else { return }
        let key = "\(s.agentState?.rawValue ?? "-")|\(s.stateSince?.timeIntervalSince1970 ?? 0)"
        if let c = reviewCheck, c.key == key, Date().timeIntervalSince(c.at) < 40 { return }
        reviewCheck = (key, Date())
        let client = client
        if let items = try? await Self.bounded(.seconds(8), { try await client.review(all: true) }) {
            uncommitted = items.first { $0.location == loc && $0.worktree == wt }.flatMap(TurnChanges.uncommitted)
        }
    }

    func setMode(_ m: SessionViewMode) {
        modeChosen = true
        mode = m
        SessionViewPrefs.set(m, box: box, name: name)
        kick()
    }

    // MARK: polling loop

    func run() async {
        let events = model?.hub.subscribe()
        let listener = Task { [weak self] in
            guard let events else { return }
            for await h in events {
                guard let self else { return }
                if h.box == self.box, Self.isRelevant(h.event, session: self.name) { self.kick() }
            }
        }
        defer { listener.cancel() }
        while !Task.isCancelled {
            await tick()
            var waited = 0
            while waited < 15, !kickFlag, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100)); waited += 1
            }
            woken = kickFlag
            kickFlag = false
        }
    }

    /// The current tick was started by an event or an action (not the 1.5 s timer).
    @ObservationIgnored private var woken = true

    func kick() { kickFlag = true }

    private static func isRelevant(_ e: PierEvent, session: String) -> Bool {
        let t = e.type
        guard t.hasPrefix("agent.") || t.hasPrefix("session.") || t.hasPrefix("transcript.") else { return false }
        let s = e.data?["session"]?.stringValue ?? e.data?["name"]?.stringValue
        return s == nil || s == session
    }

    func tick() async {
        tickCount += 1
        let s = session
        // A new wait (another permission, another question) must not be answered against the previous one's screen.
        if s.needsYou, s.stateSince != waitSince { waitSince = s.stateSince; screen = ""; screenLoaded = false }
        // The transcript follows the box's events (`transcript.changed`, `agent.*`); the timer only backs them up: every 3 s
        // while the agent works, every ~7.5 s otherwise. The live draft below still polls every tick while running.
        let backup = s.agentState == .running ? tickCount % 2 == 0 : tickCount % 5 == 0
        let wantTranscript = !loaded || (store.source != "none" && (woken || backup)) || tickCount % 10 == 0
        let wantDraft = s.agentState == .running && hasTranscript
        // The screen feeds the terminal, the needs-you card, the fallback conversation and (every few seconds) the "doing" line.
        // Not running: also look for a menu no hook announces (startup dialogs), right after a state change, then every ~9 s.
        let idleLook = s.agentState != .running && !s.exited && (tickCount % 6 == 0 || s.stateSince != screenLookedAt)
        let wantScreen = mode == .terminal || s.needsYou || !hasTranscript || (s.agentState == .running && tickCount % 3 == 0) || idleLook
        if idleLook { screenLookedAt = s.stateSince }
        let wantHeld = (s.queued ?? 0) > 0 || !held.isEmpty
        let since = store.since, gen = store.gen
        let name = name, client = client
        let history = mode == .terminal ? 300 : 0

        // Each request has its own deadline, so one slow answer never stalls the whole loop.
        async let page: TranscriptPage? = wantTranscript ? (try? await Self.bounded(.seconds(12)) { try await client.transcript(session: name, since: since, gen: gen) }) : nil
        async let dr: Draft? = wantDraft ? (try? await Self.bounded(.seconds(6)) { try await client.draft(session: name) }) : nil
        async let scr: String? = wantScreen ? (try? await Self.bounded(.seconds(6)) { try await client.screen(session: name, history: history) }) : nil
        async let hd: [HeldPrompt]? = wantHeld ? (try? await Self.bounded(.seconds(6)) { try await client.heldPrompts(session: name) }) : nil
        let (p, d, sc, h) = await (page, dr, scr, hd)

        // Observable state is written only when it changed: every write re-renders the screen, and this runs every 1.5 s.
        if let p {
            var next = store
            next.apply(p)
            if next != store { store = next }
            if loadError != nil { loadError = nil }
            if !loaded { loaded = true }
            expirePending()
        } else if wantTranscript, !loaded, tickCount > 3 {
            loadError = S("Não foi possível carregar a conversa.")
        }
        if loaded, store.gapBefore != nil { await fillGap() }
        if wantDraft { if let d, d != draft { draft = d } } else if s.agentState != .running, draft != nil { draft = nil }
        if let sc {
            if sc != screen { screen = sc }
            if !screenLoaded { screenLoaded = true }
            if s.agentState == .running, let st = StepText.from(screen: sc), st != step { step = st }
        }
        if s.agentState != .running, step != nil { step = nil }
        await refreshUncommitted()
        if let h { if h != held { held = h } } else if (s.queued ?? 0) == 0, !held.isEmpty, !wantHeld { held = [] }
        if conn?.state.isOnline == true, conn?.hasLoadedSessions == true,
           conn?.sessions.contains(where: { $0.name == name }) == false { gone = true } else if gone, conn?.sessions.contains(where: { $0.name == name }) == true { gone = false }
    }

    private static func bounded<T: Sendable>(_ d: Duration, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { g in
            g.addTask { try await op() }
            g.addTask { try await Task.sleep(for: d); throw PierError.timeout }
            defer { g.cancelAll() }
            return try await g.next()!
        }
    }

    /// A prompt the record never echoed (sent with attachments, a slash command, a lost turn) must not linger forever.
    private func expirePending() {
        let now = Date()
        for item in store.pending {
            if let at = pendingSentAt[item.id], now.timeIntervalSince(at) > 90 {
                store.removePending(id: item.id); pendingSentAt[item.id] = nil
            }
        }
        for id in pendingSentAt.keys where !store.pending.contains(where: { $0.id == id }) { pendingSentAt[id] = nil }
    }

    private func fillGap() async {
        var guardN = 0
        while let before = store.gapBefore, guardN < TranscriptStore.maxGapPages {
            guardN += 1
            guard let page = try? await client.transcriptBefore(session: name, before: before, limit: 300) else { break }
            store.absorbHistory(page)
        }
    }

    // MARK: history & detail

    func loadOlder() async {
        guard !loadingOlder, store.hasMoreBefore, let off = store.oldestOffset else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        if let page = try? await client.transcriptBefore(session: name, before: off, limit: 120) {
            store.absorbHistory(page)
        }
    }

    func toggle(_ id: String, detailID: String?) {
        withAnimation(.snappy(duration: 0.25)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
        if expanded.contains(id), let detailID { loadDetail(detailID) }
    }

    func loadDetail(_ id: String, force: Bool = false) {
        if !force, case .loaded(let d)? = details[id], d.pending != true { return }
        if case .loading? = details[id] { return }
        details[id] = .loading
        Task {
            do { details[id] = .loaded(try await client.toolDetail(session: name, id: id)) }
            catch { details[id] = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
        }
    }

    // MARK: sending

    var canSend: Bool { !isClosed && !sending }

    /// Prompt composer: `idle` while the agent works (held on the box), `now` otherwise. `paths`: photos already taken
    /// out of the composer (a send that waited the undo window); nil sends the composer's own. `when` forces one
    /// (suggested next steps go with `idle`, so they never cut into a turn that started meanwhile).
    func send(_ text: String, attachments paths: [String]? = nil, when forced: SendRequest.When? = nil) async -> Bool {
        let atts = paths ?? attachments.compactMap(\.path)
        var full = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !atts.isEmpty { full += (full.isEmpty ? "" : "\n") + atts.joined(separator: "\n") }
        guard !full.isEmpty, canSend else { return false }
        let s = session
        let busy = s.agentState == .running || s.agentState == .waiting
        sending = true
        defer { sending = false }
        do {
            let r = try await client.send(session: name, SendRequest(text: full, enter: true, when: forced ?? (busy ? .idle : .now), force: nil,
                                                                      idemKey: "ios-\(UUID().uuidString)"))
            Haptic.impact(.light)
            sendTick += 1
            if paths == nil { attachments = [] }
            if r.queued == true {
                held = (try? await client.heldPrompts(session: name)) ?? held
            } else {
                let item = store.addPendingUser(full)
                pendingSentAt[item.id] = Date()
            }
            conn?.scheduleRefresh(sessions: true)
            kick()
            return true
        } catch let e as BoxError where e.kind == .agentWaiting {
            actionError = S("O agente está esperando por você. Responda ao pedido antes de enviar.")
        } catch let e as BoxError where e.kind == .sessionExited {
            actionError = S("A sessão foi encerrada e não aceita mais mensagens.")
        } catch {
            actionError = describe(error)
        }
        Haptic.warning()
        return false
    }

    func cancelHeld(_ h: HeldPrompt) async {
        do { try await client.cancelHeld(session: name, turn: h.turn); held.removeAll { $0.turn == h.turn } }
        catch { actionError = describe(error) }
        conn?.scheduleRefresh(sessions: true)
    }

    func sendHeldNow(_ h: HeldPrompt) async {
        do {
            _ = try await client.sendHeldNow(session: name, turn: h.turn, force: false)
            held.removeAll { $0.turn == h.turn }
            Haptic.impact(.light)
        } catch let e as BoxError where e.kind == .agentWaiting {
            actionError = S("O agente está esperando por você. Responda ao pedido antes de enviar.")
        } catch { actionError = describe(error) }
        conn?.scheduleRefresh(sessions: true); kick()
    }

    func attach(data: Data, name filename: String, thumbnail: UIImage?) async {
        var a = ComposerAttachment(name: filename, thumbnail: thumbnail)
        let id = a.id
        attachments.append(a)
        do {
            let r = try await client.uploadAttachment(session: name, name: filename, data: data)
            if let i = attachments.firstIndex(where: { $0.id == id }) { a = attachments[i]; a.path = r.path; attachments[i] = a }
        } catch {
            if let i = attachments.firstIndex(where: { $0.id == id }) { attachments[i].failed = true }
            actionError = describe(error)
        }
    }

    // MARK: controls

    func press(_ keys: [ControlKey]) async {
        Haptic.impact(.light)
        do { try await client.keys(session: name, keys) } catch { actionError = describe(error) }
        kick()
    }

    /// Stop the current turn (Esc, then the ledger closes it). The button shows a spinner until the state changes.
    func interrupt() async {
        guard !interrupting else { return }
        interrupting = true
        Haptic.impact()
        defer { interrupting = false }
        do { _ = try await client.interrupt(session: name) } catch { actionError = describe(error) }
        conn?.scheduleRefresh(sessions: true); kick()
    }

    func kill() async -> Bool {
        do {
            try await client.kill(session: name)
            Haptic.success()
            conn?.scheduleRefresh(sessions: true, locations: true)
            return true
        } catch { actionError = describe(error); return false }
    }

    func rename(_ title: String) async {
        do {
            let s = try await client.rename(session: name, title: title)
            titleOverride = s.title ?? ""
            conn?.scheduleRefresh(sessions: true)
        } catch { actionError = describe(error) }
    }

    /// The ⋯ menu's "Gerar título com IA" is running.
    var titling = false

    /// A title written by Haiku on the box from the session's first message (`AITitler`), saved on the box.
    func generateTitle() async {
        guard !titling else { return }
        let first = store.items.first { $0.kind == "user" && !($0.text ?? "").isEmpty }?.text
        guard let prompt = first ?? session.title, !prompt.isEmpty, let place = session.execPlace else {
            actionError = S("Não há uma mensagem para resumir em um título.")
            return
        }
        titling = true
        defer { titling = false }
        do {
            titleOverride = try await AITitler.generate(client: client, at: place, session: name, prompt: prompt)
            Haptic.success()
            conn?.scheduleRefresh(sessions: true)
        } catch { actionError = describe(error) }
    }

    // MARK: needs you

    /// A menu digit with the person's authority (docs/API.md §5.3).
    func answer(key: String) async {
        let episode = session.stateSince   // the wait being answered, not one that may start meanwhile
        answering = true
        Haptic.impact()
        do {
            _ = try await client.send(session: name, .key(key))
            answeredFor = episode; answeredScreen = screen
        } catch { actionError = describe(error) }
        answering = false
        conn?.scheduleRefresh(sessions: true); kick()
    }

    func answer(keys: [ControlKey]) async {
        let episode = session.stateSince
        answering = true
        Haptic.impact()
        do {
            try await client.keys(session: name, keys)
            answeredFor = episode; answeredScreen = screen
        } catch { actionError = describe(error) }
        answering = false
        conn?.scheduleRefresh(sessions: true); kick()
    }

    /// Structured answer first, digit keys when the box can't drive the form (§14).
    func answerQuestion(item: TranscriptItem, answers: [QuestionAnswer]) async {
        let qs = item.questions ?? []
        let episode = session.stateSince
        answering = true
        defer { answering = false }
        Haptic.impact()
        if let problem = QuestionHelpers.validate(answers, for: qs) { actionError = problem.description; return }
        do {
            _ = try await client.answerQuestions(session: name, tool: item.tool ?? "AskUserQuestion", answers: answers)
            answeredFor = episode
            Haptic.success()
        } catch {
            // Fallback: type the option digits, but only while the box still reports the same wait. The box answers 409
            // also when the question was answered meanwhile (terminal, another device) or the agent moved on, and digits
            // typed then land on whatever is on screen now (a different menu, or a new turn once it finished).
            await conn?.refreshSessions()
            guard session.needsYou, session.stateSince == episode else {
                actionError = S("O pedido mudou antes do envio. Nada foi enviado.")
                conn?.scheduleRefresh(sessions: true); kick()
                return
            }
            var ok = true
            for (q, a) in zip(qs, answers) {
                guard let pick = a.picks?.first, let digit = QuestionHelpers.menuKey(forPick: pick, in: q) else { ok = false; break }
                do { _ = try await client.send(session: name, .key(digit)) } catch { ok = false; actionError = describe(error); break }
                try? await Task.sleep(for: .milliseconds(350))
            }
            if ok { answeredFor = episode; Haptic.success() }
            else if actionError == nil { actionError = S("Não consegui responder daqui. Termine no terminal.") }
        }
        conn?.scheduleRefresh(sessions: true); kick()
    }

    // MARK: undo window (PendingActions)
    // Answers and composer messages wait the person's "Tempo para desfazer" before they go out. Meanwhile the card is
    // hidden (it comes back on Desfazer) and the composer is empty (its text and photos come back on Desfazer or failure).

    /// An answer waiting to go out; the needs-you card hides meanwhile.
    var pendingAnswer: PendingActions.Token?
    /// Text the composer gets back (an undone or failed send); ComposerBar takes it and clears this.
    var composerRestore: ComposerRestore?

    struct ComposerRestore: Equatable {
        let id = UUID()
        let text: String
    }

    /// Composer Send: the message waits the undo window. False when there is nothing to send.
    func scheduleSend(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let photos = attachments.filter { $0.path != nil }
        guard canSend, !trimmed.isEmpty || !photos.isEmpty else { return false }
        attachments.removeAll { $0.path != nil }
        let restore: @MainActor () -> Void = { [self] in
            if !text.isEmpty { composerRestore = ComposerRestore(text: text) }
            attachments = photos + attachments
        }
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let label = !firstLine.isEmpty ? String(firstLine.prefix(80))
            : photos.count == 1 ? S("1 foto") : S("\(photos.count) fotos")
        PendingActions.shared.schedule(label: label, symbol: "paperplane.fill", perform: { [self] in
            if await !send(text, attachments: photos.compactMap(\.path)) { restore() }
        }, onUndo: restore)
        return true
    }

    /// A menu digit, after the undo window.
    func scheduleAnswer(key: String, label: String) {
        deferAnswer(label) { vm in await vm.answer(key: key) }
    }

    /// Arrow keys + Enter (an unnumbered menu, the trust dialog), after the undo window.
    func scheduleAnswer(keys: [ControlKey], label: String) {
        deferAnswer(label) { vm in await vm.answer(keys: keys) }
    }

    /// Question answers, after the undo window (checked first, so a missing answer says so at once).
    func scheduleAnswerQuestion(item: TranscriptItem, answers: [QuestionAnswer]) {
        if let problem = QuestionHelpers.validate(answers, for: item.questions ?? []) { actionError = problem.description; return }
        let label = answers.map { a in ((a.picks ?? []) + [a.other].compactMap { $0 }).joined(separator: ", ") }
            .filter { !$0.isEmpty }.joined(separator: " · ")
        deferAnswer(label.isEmpty ? S("Resposta") : label) { vm in await vm.answerQuestion(item: item, answers: answers) }
    }

    private func deferAnswer(_ label: String, _ run: @escaping @MainActor (SessionViewModel) async -> Void) {
        guard pendingAnswer == nil, !answering else { return }
        // A wait the box announced is answered only while it is still the same wait (not one that started meanwhile).
        let episode = session.stateSince, announced = session.needsYou
        Haptic.impact()
        pendingAnswer = PendingActions.shared.schedule(label: label, symbol: "hand.tap.fill", perform: { [self] in
            defer { pendingAnswer = nil }
            if announced, !session.needsYou || session.stateSince != episode {
                actionError = S("O pedido mudou antes do envio. Nada foi enviado.")
                return
            }
            await run(self)
        }, onUndo: { [self] in pendingAnswer = nil })
    }

    func describe(_ error: Error) -> String {
        if let e = error as? BoxError { return e.error }
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return error.localizedDescription
    }
}
