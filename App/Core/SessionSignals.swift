import Foundation
import PierKit

/// The live bits of sessions the event stream does not carry, shared by the Home widgets and the agents board so the two
/// never poll twice: each working agent's current step (its screen, 12 s), which finished turns still run background work
/// (transcript signals, 15 s), the line changes per worktree (`GET /v1/review?all=1`, 30 s), and for the board the last
/// reply of a finished turn (once per turn) and whether a waiting agent shows an Allow/Deny menu (12 s).
///
/// Every refresh is throttled by its own clock, so any number of screens can tick it; events (`agent.*`, `session.*`) make
/// the next tick fetch again.
@MainActor @Observable
final class SessionSignals {
    static let shared = SessionSignals()

    struct LineChange: Hashable { var added: Int; var removed: Int }

    /// "box/session" -> what the agent is doing ("Bash(pnpm test)").
    private(set) var steps: [String: String] = [:]
    /// Finished turns that still run work in the background ("box/session" -> what runs), so they read as working, not done.
    private(set) var background: [String: [BackgroundItem]] = [:]
    /// "box/locref" (a session's `location`) -> lines changed in that worktree.
    private(set) var changes: [String: LineChange] = [:]
    /// "box/session" -> the agent's last plain reply of the turn that ended at `since`.
    private(set) var replies: [String: (since: Date, text: String?)] = [:]
    /// "box/session" of waiting agents whose screen shows an Allow/Deny menu.
    private(set) var menus: Set<String> = []
    // --- Inbox: read in the same fetches as `menus` / `replies` (no extra polling). ---
    /// "box/session" -> the waiting agent's screen (the Inbox reads its options from it; answers re-read it first).
    private(set) var screens: [String: String] = [:]
    /// "box/session" -> the full Markdown of the last reply of the finished turn in `replies`.
    private(set) var replyTexts: [String: String] = [:]
    // --- end Inbox ---

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var stepsAt = Date.distantPast
    @ObservationIgnored private var changesAt = Date.distantPast
    @ObservationIgnored private var backgroundAt = Date.distantPast
    @ObservationIgnored private var menusAt = Date.distantPast
    @ObservationIgnored private var busy: Set<String> = []

    /// An agent or session event: the next tick reads steps, background work and menus again (changes a bit later).
    func invalidate() {
        stepsAt = .distantPast; backgroundAt = .distantPast; menusAt = .distantPast
        changesAt = min(changesAt, Date().addingTimeInterval(-20))
    }

    /// What the Home needs.
    func refreshStale(model: AppModel, force: Bool = false) async {
        self.model = model
        async let a: Void = refreshSteps(force: force)
        async let b: Void = refreshBackground(force: force)
        async let c: Void = refreshChanges(force: force)
        _ = await (a, b, c)
    }

    /// What the board needs: the Home's set plus replies and menus.
    func refreshBoard(model: AppModel, force: Bool = false) async {
        self.model = model
        async let a: Void = refreshStale(model: model, force: force)
        async let b: Void = refreshReplies()
        async let c: Void = refreshMenus(force: force)
        _ = await (a, b, c)
    }

    private func begin(_ k: String) -> Bool { busy.insert(k).inserted }
    private func end(_ k: String) { busy.remove(k) }
    private var clients: [String: any PierBoxClient] {
        Dictionary(model?.boxes.map { ($0.name, $0.client) } ?? [], uniquingKeysWith: { a, _ in a })
    }

    /// Each working agent's current step, from the tail of its screen (12 s).
    func refreshSteps(force: Bool = false) async {
        guard let model, force || Date().timeIntervalSince(stepsAt) >= 12, begin("steps") else { return }
        defer { end("steps") }
        let working = model.sessionsStore.group(.working).prefix(12)
        let clients = clients
        let found: [(String, String?)] = await withTaskGroup(of: (String, String?).self) { g in
            for w in working {
                guard let c = clients[w.box] else { continue }
                let (id, name) = (w.id, w.session.name)
                g.addTask { (id, (try? await c.screen(session: name, history: 0)).flatMap { StepText.from(screen: $0) }) }
            }
            return await collect(&g)
        }
        stepsAt = Date()
        var next: [String: String] = [:]
        for (id, s) in found { if let s { next[id] = s } }
        if next != steps { steps = next }
    }

    /// Background shells / subagents of finished turns: the transcript's signals only (`since` past the end: no items), 15 s.
    func refreshBackground(force: Bool = false) async {
        guard let model, force || Date().timeIntervalSince(backgroundAt) >= 15 else { return }
        let done = model.sessionsStore.group(.done).prefix(12)
        guard !done.isEmpty else { if !background.isEmpty { background = [:] }; return }
        guard begin("background") else { return }
        defer { end("background") }
        let clients = clients
        let found: [(String, [BackgroundItem])] = await withTaskGroup(of: (String, [BackgroundItem]).self) { g in
            for s in done {
                guard let c = clients[s.box] else { continue }
                let (id, name) = (s.id, s.session.name)
                g.addTask {
                    guard let p = try? await c.transcript(session: name, since: 2_000_000_000, gen: nil) else { return (id, []) }
                    return (id, BackgroundWork.running(signals: p.signals, crew: p.crew ?? []))
                }
            }
            return await collect(&g)
        }
        backgroundAt = Date()
        var next: [String: [BackgroundItem]] = [:]
        for (id, items) in found where !items.isEmpty { next[id] = items }
        if next != background { background = next }
    }

    /// Lines changed per worktree, from the box's review (30 s, only while some turn is finished).
    func refreshChanges(force: Bool = false) async {
        guard let model, force || Date().timeIntervalSince(changesAt) >= 30 else { return }
        guard !model.sessionsStore.group(.done).isEmpty, begin("changes") else { return }
        defer { end("changes") }
        let conns = model.boxes.filter { $0.state.isOnline }.map { ($0.name, $0.client) }
        let items: [(String, [ReviewItem])] = await withTaskGroup(of: (String, [ReviewItem]).self) { g in
            for (name, c) in conns { g.addTask { (name, (try? await c.review(all: true)) ?? []) } }
            return await collect(&g)
        }
        changesAt = Date()
        var next: [String: LineChange] = [:]
        for (box, list) in items {
            for r in list {
                // A session's location is "loc/wt", or just "loc" for the main checkout.
                let ref = r.main == true ? r.location : "\(r.location)/\(r.worktree)"
                next["\(box)/\(ref)"] = LineChange(added: r.added, removed: r.removed)
            }
        }
        if next != changes { changes = next }
    }

    /// The last reply of each finished turn (the transcript's tail, `before=0`), read once per turn.
    func refreshReplies() async {
        guard let model else { return }
        let todo = model.sessionsStore.group(.done).filter { replies[$0.id]?.since != ($0.session.stateSince ?? $0.session.created) }.prefix(12)
        guard !todo.isEmpty, begin("replies") else { return }
        defer { end("replies") }
        let clients = clients
        let found: [(String, Date, String?, String?, Bool)] = await withTaskGroup(of: (String, Date, String?, String?, Bool).self) { g in
            for s in todo {
                guard let c = clients[s.box] else { continue }
                let (id, name, since) = (s.id, s.session.name, s.session.stateSince ?? s.session.created)
                g.addTask {
                    guard let tail = try? await c.transcriptBefore(session: name, before: 0, limit: 40) else { return (id, since, nil, nil, false) }
                    return (id, since, LiveActivitySync.lastReply(tail), Self.lastReplyMarkdown(tail), true)
                }
            }
            return await collect(&g)
        }
        // A failed read is tried again on the next tick; an answer (even "no reply") is kept for the turn.
        for (id, since, text, full, ok) in found where ok { replies[id] = (since, text); replyTexts[id] = full }
    }

    /// Which waiting agents show an Allow/Deny menu on screen (12 s), so the board offers to answer it. Oldest first, the
    /// order the Inbox lists them in: with more agents waiting than fit, the cards at the top are the ones with options.
    func refreshMenus(force: Bool = false) async {
        guard let model, force || Date().timeIntervalSince(menusAt) >= 12 else { return }
        let waiting = model.sessionsStore.group(.needsYou).reversed().prefix(12)
        guard !waiting.isEmpty else { if !menus.isEmpty { menus = [] }; if !screens.isEmpty { screens = [:] }; return }
        guard begin("menus") else { return }
        defer { end("menus") }
        let clients = clients
        let found: [(String, String?)] = await withTaskGroup(of: (String, String?).self) { g in
            for w in waiting {
                guard let c = clients[w.box] else { continue }
                let (id, name) = (w.id, w.session.name)
                g.addTask { (id, try? await c.screen(session: name, history: 0)) }
            }
            return await collect(&g)
        }
        menusAt = Date()
        let next = Set(found.filter { $0.1.map { MenuParser.actions(in: $0) != nil } ?? false }.map(\.0))
        if next != menus { menus = next }
        var shown: [String: String] = [:]
        for (id, screen) in found { if let screen { shown[id] = screen } else if let old = screens[id] { shown[id] = old } }
        if shown != screens { screens = shown }
    }

    /// The agent's last reply of the turn as written (Markdown), for the Inbox card; nil when the turn ended without one.
    nonisolated static func lastReplyMarkdown(_ page: TranscriptPage) -> String? {
        for item in page.items.reversed() {
            if item.kind == "user" { return nil }
            if item.kind == "text", let t = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        }
        return nil
    }

    /// Reads the waiting agents' screens now (the Inbox, right after an event or an answer).
    func refreshScreensNow(model: AppModel) async {
        self.model = model
        await refreshMenus(force: true)
    }

    /// "Em segundo plano · tests" for a finished turn with work still running, else the agent's current step.
    func workingDetail(_ item: BoxSession) -> String? {
        if let bg = background[item.id], item.session.agentState != .running {
            let what = bg.first.map { " · \($0.title)" } ?? ""
            return (bg.count == 1 ? S("Em segundo plano") : S("\(bg.count) em segundo plano")) + what
        }
        return steps[item.id]
    }
}

/// Collects a task group's results.
@MainActor private func collect<T: Sendable>(_ g: inout TaskGroup<T>) async -> [T] {
    var out: [T] = []
    for await r in g { out.append(r) }
    return out
}
