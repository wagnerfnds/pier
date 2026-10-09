import Foundation

/// The agents board (kanban): every agent session of every box in a column by state.
/// Pure over the sessions plus the phone's own marks, so the screen and its tests share the rules.
public enum AgentBoard {
    public enum Column: String, CaseIterable, Sendable, Hashable, Identifiable {
        /// Waiting on a permission or a question.
        case needsYou
        /// Running, or a finished turn whose background work (shells, subagents) still runs.
        case working
        /// A finished turn the person has not archived: the agent waits for them to carry on.
        case yourTurn
        /// Idle / ready, no turn to look at.
        case ready
        /// Archived on the phone, or exited on the box.
        case closed

        public var id: String { rawValue }
    }

    /// One session on the board. `id` is "box/session", the same key the app uses everywhere else.
    public struct Item: Sendable, Hashable, Identifiable {
        public let box: String
        public let session: Session
        public init(box: String, session: Session) { self.box = box; self.session = session }
        public var id: String { "\(box)/\(session.name)" }
        /// "loc/wt" -> "loc"; a main-worktree session is just "loc".
        public var location: String { session.location.map { String($0.split(separator: "/", maxSplits: 1).first ?? "") } ?? "" }
        public var worktree: String? {
            guard let l = session.location, let i = l.firstIndex(of: "/") else { return nil }
            return String(l[l.index(after: i)...])
        }
        /// "box/location", the key of the project filter.
        public var projectKey: String { "\(box)/\(location)" }
        var since: Date { session.stateSince ?? session.created }
    }

    public struct Filter: Sendable, Hashable {
        public var box: String?
        /// "box/location".
        public var project: String?
        public var text: String
        public init(box: String? = nil, project: String? = nil, text: String = "") { self.box = box; self.project = project; self.text = text }
        public var isActive: Bool { box != nil || project != nil || !text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// What a drop of a card on a column does.
    public enum Move: Sendable, Hashable { case archive, unarchive }

    /// The column of one session, or nil when it is not an agent (plain terminals, services).
    /// - Parameters:
    ///   - archived: the person marked it as over (`LocalPrefs.isClosed`; a newer turn already cleared that).
    ///   - background: a finished turn with work still running in the background.
    public static func column(_ s: Session, archived: Bool, background: Bool) -> Column? {
        guard s.isAgent else { return nil }
        if s.exited { return .closed }
        switch s.agentState {
        case .waiting: return .needsYou
        case .running: return .working
        case .finished:
            // An explicit archive wins over background work: the agent's next turn brings the card back by itself.
            if archived { return .closed }
            return background ? .working : .yourTurn
        case .idle, .none, .unknown: return archived ? .closed : .ready
        }
    }

    /// Whether `item` passes the filter. `names` gives what the text search also looks at (display names of the project).
    public static func matches(_ item: Item, _ f: Filter, names: [String] = []) -> Bool {
        if let b = f.box, item.box != b { return false }
        if let p = f.project, item.projectKey != p { return false }
        let words = f.text.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let hay = ([item.session.title, item.session.name, item.location, item.worktree, item.box, item.session.agent] + names.map(Optional.some))
            .compactMap { $0?.lowercased() }.joined(separator: " ")
        return words.allSatisfy { hay.contains($0) }
    }

    /// The board: each column's items, sorted. Needs-you is oldest first (the longest wait on top); the
    /// others newest first. Ties fall back to the id, so a refresh never reorders equal cards.
    public static func build(_ items: [Item], filter: Filter = Filter(), archived: (Item) -> Bool, background: Set<String>,
                             names: (Item) -> [String] = { _ in [] }) -> [Column: [Item]] {
        var out: [Column: [Item]] = Dictionary(uniqueKeysWithValues: Column.allCases.map { ($0, []) })
        for it in items {
            guard let c = column(it.session, archived: archived(it), background: background.contains(it.id)),
                  matches(it, filter, names: names(it)) else { continue }
            out[c, default: []].append(it)
        }
        for c in Column.allCases {
            out[c]?.sort { a, b in
                if a.since != b.since { return c == .needsYou ? a.since < b.since : a.since > b.since }
                return a.id < b.id
            }
        }
        return out
    }

    /// Dropping a card from `from` on `to`: to Encerradas archives a finished or idle session; out of Encerradas brings an
    /// archived one back. Exited sessions stay closed; moves between active columns mean nothing (the agent decides those).
    public static func move(_ s: Session, from: Column, to: Column) -> Move? {
        guard from != to, !s.exited else { return nil }
        if to == .closed { return from == .yourTurn || from == .ready || (from == .working && s.agentState == .finished) ? .archive : nil }
        if from == .closed { return to == .yourTurn || to == .ready ? .unarchive : nil }
        return nil
    }

    /// Projects with at least one session, for the filter menu: (box, location) sorted by box then location.
    public static func projects(_ items: [Item]) -> [(box: String, location: String)] {
        var seen = Set<String>()
        return items.filter { $0.session.isAgent && !$0.location.isEmpty && seen.insert($0.projectKey).inserted }
            .map { ($0.box, $0.location) }
            .sorted { ($0.box, $0.location) < ($1.box, $1.location) }
    }
}
