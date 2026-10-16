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
    /// Messages in their undo window or on their way to the box: drawn at once, under the conversation.
    var outgoing: [Outgoing] = []

    struct Outgoing: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let photos: Int
    }

    /// Requests keep failing on the connection itself (not on the box's answers): the screen says so while it redials.
    var linkTrouble = false
    @ObservationIgnored private var link = LinkWatch()

    // View mode
    var mode: SessionViewMode = .conversation
    @ObservationIgnored private var modeChosen = false
    /// The screen comes over a terminal stream (a live shell, LiveTerminal.swift): the loop does not read it.
    @ObservationIgnored var streamsScreen = false

    /// The worktree's uncommitted changes (from the box's review list), for the "Revisar" card when this turn edited nothing itself.
    var uncommitted: TurnChanges?
    @ObservationIgnored private var reviewCheck: (key: String, at: Date)?

    // Needs-you bookkeeping
    /// `stateSince` of the waiting episode already answered (the card hides meanwhile).
    var answeredFor: Date? { didSet { answeredAt = answeredFor == nil ? nil : Date() } }
    @ObservationIgnored private var answeredAt: Date?
    var answering = false

    @ObservationIgnored private var kickFlag = false
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var pendingSentAt: [String: Date] = [:]
    @ObservationIgnored private var waitSince: Date?
    var titleOverride: String?

    /// The session's view model a screen already holds, or a new one: the window, the Mac's side panel and the terminal
    /// tabs share it (one conversation in memory, one loop), and a screen's struct built again by its parent costs a
    /// lookup instead of a new model.
    static func shared(box: String, session: Session, client: any PierBoxClient, model: AppModel) -> SessionViewModel {
        let key = "\(box)/\(session.name)"
        // The same session (a new tmux session can reuse a name), through the same client and app.
        if let v = live[key]?.vm, v.initial.created == session.created, v.client as AnyObject === client as AnyObject,
           v.model === model { return v }
        live = live.filter { $0.value.vm != nil }
        let v = SessionViewModel(box: box, session: session, client: client, model: model)
        live[key] = WeakVM(vm: v)
        return v
    }
    private struct WeakVM { weak var vm: SessionViewModel? }
    private static var live: [String: WeakVM] = [:]

    init(box: String, session: Session, client: any PierBoxClient, model: AppModel) {
        self.box = box
        self.name = session.name
        self.initial = session
        self.client = client
        self.model = model
        // The conversation as it was last shown: drawn at once, then only what is new is read (from disk: `run`).
        if let cached = TranscriptCache.shared.store(box: box, session: session.name) {
            store = cached
            loaded = true
        }
        if let p = StartingPrompts.prompt(box: box, session: session.name) { startingPrompt = p.text; startedHere = p.at }
        if let m = SessionViewPrefs.mode(box: box, name: session.name) {
            mode = m; modeChosen = true
        } else if !session.isAgent {
            mode = .terminal
        }
    }

    // MARK: live session

    var session: Session { model?.connection(for: box)?.sessions.first { $0.name == name } ?? initial }
    var conn: BoxConnection? { model?.connection(for: box) }
    /// The demo's (or a test's) made-up box: what it says is never kept on disk.
    private var isMockBox: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "transcriptDisk") { return false }
        #endif
        return conn?.raw is MockBox
    }

    var isWaiting: Bool { session.needsYou && answeredFor != session.stateSince }
    /// The terminal's lines (ANSI stripped, side panel cut, compacted), computed once per screen.
    @ObservationIgnored private var terminalCache: (screen: String, lines: [String])?
    var terminalLines: [String] {
        let screen = screen
        if let c = terminalCache, c.screen == screen { return c.lines }
        let lines = TerminalText.compact(ANSI.plainGlyphs(TerminalText.clean(screen))).components(separatedBy: "\n")
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
    var transcriptUnavailable: Bool { loaded && store.source == "none" && !recordPending }
    /// Claude Code and Codex write their record once the first prompt goes in, so for the first moments of a task the box
    /// has none to read: the chat shows the person's prompt and the agent starting (a startup question comes up as the
    /// needs-you card), never the terminal. Past a minute and a half with still no record, outside a wait, the record is
    /// one the box cannot read, and the screen takes over.
    var recordPending: Bool {
        guard loaded, store.source == "none", !isClosed, session.isAgent, let agent = session.agent,
              agent == "claude" || agent == "codex" else { return false }
        if session.needsYou { return true }
        // A turn that ended with still no record: the box cannot read this one.
        guard session.agentState != .finished else { return false }
        // Started here: this device's clock says how long ago; started elsewhere: the box's.
        if let startedHere { return Date().timeIntervalSince(startedHere) < 120 }
        return Date().timeIntervalSince(session.created) < 90
    }
    /// The working line's word: the agent's own ("Brewing…"), else what it is doing in Pier's words.
    var liveWord: String {
        if let w = draft?.status?.word, !w.isEmpty { return w.hasSuffix("…") ? w : w + "…" }
        if starting { return S("Iniciando \(session.agentLabel)…") }
        return S("Trabalhando…")
    }
    /// The agent is starting: no record yet, or a task started here whose first read has not answered yet.
    var starting: Bool { recordPending || (!loaded && startingPrompt != nil && !isClosed) }
    /// The first prompt of a task started on this device (`StartingPrompts`), shown until the record has the person's words.
    var startingPrompt: String?
    /// When this device started it (`StartingPrompts`), by this device's clock.
    @ObservationIgnored private var startedHere: Date?
    /// The box listed this session at least once since the screen opened: only then can its absence mean it ended.
    @ObservationIgnored private var listed = false
    private let openedAt = Date()
    var showsStartingPrompt: Bool {
        guard startingPrompt != nil else { return false }
        return !store.items.contains { $0.kind == "user" }
    }
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

    /// How many screens follow this session (the window, the Mac's side panel): one loop serves them all.
    @ObservationIgnored private var followers = 0
    @ObservationIgnored private var loop: Task<Void, Never>?

    /// Follows the session while the calling task lives. Several callers share one loop: the same session open in the
    /// window and in the Mac's side panel used to poll the box twice (the reply draft every 0.6 s, the record, the screen).
    func run() async {
        followers += 1
        if loop == nil { loop = Task { [weak self] in await self?.follow() } }
        defer {
            followers -= 1
            if followers == 0 { loop?.cancel(); loop = nil }
        }
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
    }

    private func follow() async {
        // Not in memory: the kept file, read off the main thread before the first poll (which then asks only for what is new).
        if !loaded, let kept = await TranscriptCache.shared.load(box: box, session: name), !loaded {
            store = kept
            loaded = true
        }
        // Leaving the screen writes what this conversation now holds.
        defer { TranscriptCache.shared.flush() }
        let events = model?.hub.subscribe()
        let listener = Task { [weak self] in
            guard let events else { return }
            for await h in events {
                guard let self else { return }
                if h.box == self.box, Self.isRelevant(h.event, session: self.name) { self.kick() }
            }
        }
        // The reply being written has a clock of its own, so it never waits on a slow transcript or screen read.
        let drafts = Task { [weak self] in await self?.followDraft() }
        defer { listener.cancel(); drafts.cancel() }
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
    @ObservationIgnored private var draftKick = false

    func kick() { kickFlag = true; draftKick = true }

    /// Claude Code's reply as it is written (`GET .../draft`, read from its screen): every 0.6 s while the words keep
    /// changing, every 1.5 s once they stop (a tool runs, the agent thinks), at once on an event or a send.
    private func followDraft() async {
        var unchanged = 0
        while !Task.isCancelled {
            let s = session
            if s.agentState == .running, !s.exited, store.source == "claude" {
                let name = name, client = client
                switch await Self.attempt(.seconds(4), { try await client.draft(session: name) }) {
                case .success(let d):
                    linkAnswered()
                    // The status line's clock ("12s", "7.1k tokens") moves on every read: only new words or a new status
                    // word redraw the row and keep the fast pace.
                    let grew = d.text != draft?.text || d.clipped != draft?.clipped
                    if grew || d.status?.word != draft?.status?.word || d.agent != draft?.agent { draft = d }
                    unchanged = grew ? 0 : unchanged + 1
                case .failure(let e):
                    if LinkWatch.isLinkFailure(e) { await noteLinkFailure() }
                    unchanged += 1
                }
            } else if draft != nil {
                draft = nil
            }
            let steps = unchanged < 3 ? 6 : 15
            var waited = 0
            while waited < steps, !draftKick, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100)); waited += 1
            }
            if draftKick { draftKick = false; unchanged = 0 }
        }
    }

    /// The draft to draw under the conversation: not when the record already has its words (Claude Code writes a block
    /// once it is complete while the screen still shows it, so for a moment both would read the same).
    var visibleDraft: String? {
        guard let t = draft?.text, !t.isEmpty else { return nil }
        if let c = draftCheck, c.text == t, c.items == store.items.count { return c.recorded ? nil : t }
        let recorded = DraftEcho.isRecorded(t, in: store.items)
        draftCheck = (t, store.items.count, recorded)
        return recorded ? nil : t
    }
    @ObservationIgnored private var draftCheck: (text: String, items: Int, recorded: Bool)?

    private func linkAnswered() {
        link.succeeded()
        if linkTrouble { linkTrouble = false }
    }

    /// A request failed on the connection: say so, and after a second one drop the connection so the next request dials
    /// again (address and relay, whichever answers) instead of waiting for the PING watchdog.
    private func noteLinkFailure() async {
        let reset = link.failed()
        if !linkTrouble { linkTrouble = true }
        if reset { await client.reset() }
    }

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
        // Answered, and still the same wait seconds later: the answer did not end it (a key that only moved the agent's
        // form to its next question, an answer the agent never took). The card comes back, read from the screen as it is now.
        if s.needsYou, answeredFor == s.stateSince, let at = answeredAt, Date().timeIntervalSince(at) > 6 { answeredFor = nil }
        // The transcript follows the box's events (`transcript.changed`, `agent.*`); the timer only backs them up: every 3 s
        // while the agent works, every ~7.5 s otherwise. The reply being written follows its own clock (`followDraft`).
        let backup = s.agentState == .running ? tickCount % 2 == 0 : tickCount % 5 == 0
        // An agent still starting has no record yet: ask for it on every tick, so the chat fills the moment it is written.
        let wantTranscript = !loaded || recordPending || (store.source != "none" && (woken || backup)) || tickCount % 10 == 0
        // The screen feeds the terminal, the needs-you card, the fallback conversation and (every few seconds) the "doing" line.
        // Not running: also look for a menu no hook announces (startup dialogs), right after a state change, then every ~9 s.
        let idleLook = s.agentState != .running && !s.exited && (tickCount % 6 == 0 || s.stateSince != screenLookedAt)
        let wantScreen = !streamsScreen
            && (mode == .terminal || s.needsYou || !hasTranscript || (s.agentState == .running && tickCount % 3 == 0) || idleLook)
        if idleLook { screenLookedAt = s.stateSince }
        let wantHeld = (s.queued ?? 0) > 0 || !held.isEmpty
        let since = store.since, gen = store.gen
        let name = name, client = client
        let history = mode == .terminal ? 300 : 0
        // The first read of a long record can take the box a few seconds (docs/API.md 6.3); later polls are small.
        let transcriptLimit: Duration = loaded ? .seconds(6) : .seconds(12)

        // Each request has its own deadline, so one slow answer never stalls the whole loop.
        async let page: Result<TranscriptPage, Error>? = wantTranscript
            ? await Self.attempt(transcriptLimit) { try await client.transcript(session: name, since: since, gen: gen) } : nil
        async let scr: Result<String, Error>? = wantScreen
            ? await Self.attempt(.seconds(6)) { try await client.screen(session: name, history: history) } : nil
        async let hd: Result<[HeldPrompt], Error>? = wantHeld
            ? await Self.attempt(.seconds(6)) { try await client.heldPrompts(session: name) } : nil
        let (p, sc, h) = await (page, scr, hd)

        // A poll whose every request failed on the connection counts toward dropping it; any answer clears that.
        let outcomes: [Error?] = [p.map(Self.failure), sc.map(Self.failure), h.map(Self.failure)].compactMap { $0 }
        if outcomes.contains(where: { $0 == nil }) {
            linkAnswered()
        } else if !outcomes.isEmpty, outcomes.allSatisfy({ $0.map(LinkWatch.isLinkFailure) ?? false }) {
            await noteLinkFailure()
        }

        // Observable state is written only when it changed: every write re-renders the screen, and this runs every 1.5 s.
        if case .success(let p)? = p {
            var next = store
            next.apply(p)
            if next != store {
                store = next
                TranscriptCache.shared.put(next, box: box, session: name, persist: !isMockBox)
            }
            if loadError != nil { loadError = nil }
            if !loaded { loaded = true }
            expirePending()
        } else if wantTranscript, !loaded, tickCount > 3 {
            loadError = S("Não foi possível carregar a conversa.")
        }
        if loaded, store.gapBefore != nil { await fillGap() }
        if case .success(let sc)? = sc {
            if sc != screen { screen = sc }
            if !screenLoaded { screenLoaded = true }
            if s.agentState == .running, let st = StepText.from(screen: sc), st != step { step = st }
        }
        if s.agentState != .running, step != nil { step = nil }
        // Gone with its turn at once: the next turn must never open on the last one's words.
        if s.agentState != .running, draft != nil { draft = nil }
        // The review list can take the box seconds (git over every worktree): never on this loop's clock.
        if !checkingReview {
            checkingReview = true
            Task { await refreshUncommitted(); checkingReview = false }
        }
        if case .success(let h)? = h { if h != held { held = h } } else if (s.queued ?? 0) == 0, !held.isEmpty, !wantHeld { held = [] }
        // Missing from the box's list: gone, once the list had it (a session started a moment ago is listed only at the
        // next refresh, and must not read as closed meanwhile), or when it never shows up.
        if let conn, conn.state.isOnline, conn.hasLoadedSessions {
            if conn.sessions.contains(where: { $0.name == name }) {
                listed = true
                if gone { gone = false }
            } else if !gone, listed || Date().timeIntervalSince(openedAt) > 15 {
                gone = true
            }
        }
    }

    /// `op` with a deadline: `PierError.timeout` when it runs past `d` (one slow answer never stalls a loop).
    static func bounded<T: Sendable>(_ d: Duration, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { g in
            g.addTask { try await op() }
            g.addTask { try await Task.sleep(for: d); throw PierError.timeout }
            defer { g.cancelAll() }
            return try await g.next()!
        }
    }

    /// `bounded`, with the failure kept (a dead connection and an answer of the box are told apart).
    private static func attempt<T: Sendable>(_ d: Duration, _ op: @escaping @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await bounded(d, op)) } catch { return .failure(error) }
    }

    private static func failure<T>(_ r: Result<T, Error>) -> Error? {
        if case .failure(let e) = r { return e }
        return nil
    }

    @ObservationIgnored private var checkingReview = false

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
        TranscriptCache.shared.put(store, box: box, session: name, persist: !isMockBox)
    }

    // MARK: history & detail

    func loadOlder() async {
        guard !loadingOlder, store.hasMoreBefore, let off = store.oldestOffset else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        if let page = try? await client.transcriptBefore(session: name, before: off, limit: 120) {
            store.absorbHistory(page)
            TranscriptCache.shared.put(store, box: box, session: name, persist: !isMockBox)
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

    /// Messages queue (`send` goes one at a time), so the composer takes the next one while the last is on its way.
    var canSend: Bool { !isClosed }

    /// The send in flight or queued last: each `send` waits for it, so messages typed one after the other reach the box
    /// in that order and never trip over each other (the composer, the Inbox, the Mac panel and the next steps all send here).
    @ObservationIgnored private var sendTail: Task<Bool, Never>?

    /// Prompt composer: `idle` while the agent works (held on the box), `now` otherwise. `paths`: photos already taken
    /// out of the composer; nil sends the composer's own. `when` forces one (suggested next steps go with `idle`, so they
    /// never cut into a turn that started meanwhile).
    func send(_ text: String, attachments paths: [String]? = nil, when forced: SendRequest.When? = nil) async -> Bool {
        let atts = paths ?? attachments.compactMap(\.path)
        let previous = sendTail
        let task = Task { [self] in
            // Behind a message that did not go out, the ones queued after it do not either: they would reach the box
            // before it. They come back with it, in order (their senders restore them).
            if let previous, !(await previous.value) { return false }
            return await sendNow(text, attachments: atts, fromComposer: paths == nil, when: forced)
        }
        sendTail = task
        let sent = await task.value
        // The queue that failed is over: the next message starts afresh.
        if !sent, sendTail == task { sendTail = nil }
        return sent
    }

    private func sendNow(_ text: String, attachments atts: [String], fromComposer: Bool, when forced: SendRequest.When?) async -> Bool {
        var full = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !atts.isEmpty { full += (full.isEmpty ? "" : "\n") + atts.joined(separator: "\n") }
        guard !full.isEmpty, canSend else { return false }
        let s = session
        let busy = s.agentState == .running || s.agentState == .waiting
        sending = true
        defer { sending = false }
        // One key for every try: the box types a prompt once per key (docs/API.md 4.3), so a retry after a lost answer
        // gets the first one back (`duplicate`) instead of sending the words twice.
        let request = SendRequest(text: full, enter: true, when: forced ?? (busy ? .idle : .now), force: nil, idemKey: "ios-\(UUID().uuidString)")
        let name = name, client = client
        do {
            let r: SendResult
            do {
                r = try await Self.bounded(.seconds(15)) { try await client.send(session: name, request) }
            } catch where LinkWatch.isLinkFailure(error) {
                // The connection died under the send: dial again (address or relay) and repeat it with the same key.
                await client.reset()
                do {
                    r = try await Self.bounded(.seconds(15)) { try await client.send(session: name, request) }
                } catch where LinkWatch.isLinkFailure(error) {
                    actionError = S("Não deu para confirmar o envio: a box não respondeu. Confira a conversa antes de enviar de novo.")
                    Haptic.warning()
                    return false
                }
            }
            Haptic.impact(.light)
            sendTick += 1
            if fromComposer { attachments.removeAll { $0.path.map(atts.contains) ?? false } }
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

    /// Composer Send: the message shows in the conversation at once, as in any chat, and goes out at once. Typed and sent on
    /// purpose, it skips the undo window, which is for one-tap answers (a slip of the finger); one sent by mistake is
    /// stopped with Interromper, or taken back from the queue while the agent works. Its text and photos come back if it
    /// fails. False when there is nothing to send.
    /// `done`: a sender other than this screen's composer (the Mac panel) hears how it went, with the error, and puts the
    /// text back itself; without it a failed message's text comes back through `composerRestore`.
    /// `withAttachments: false` (the Mac's side panel, which shares this model with the window): the composer's photos
    /// stay where they are.
    func scheduleSend(_ text: String, withAttachments: Bool = true, done: (@MainActor (_ sent: Bool, _ error: String?) -> Void)? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let photos = withAttachments ? attachments.filter { $0.path != nil } : []
        guard canSend, !trimmed.isEmpty || !photos.isEmpty else { return false }
        if withAttachments { attachments.removeAll { $0.path != nil } }
        let out = Outgoing(text: trimmed, photos: photos.count)
        outgoing.append(out)
        sendTick += 1   // the conversation follows the new bubble down now, not after the box answers
        Task { [self] in
            let sent = await send(text, attachments: photos.compactMap(\.path))
            // Sent, `send` put the box's own pending copy in place in the same turn: no gap, no double.
            outgoing.removeAll { $0.id == out.id }
            if sent { done?(true, nil); return }
            attachments = photos + attachments
            if let done {
                done(false, actionError)
                actionError = nil
            } else if !text.isEmpty {
                // Messages that failed together come back in the order they were sent.
                composerRestore = ComposerRestore(text: composerRestore.map { $0.text + "\n" + text } ?? text)
            }
        }
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
