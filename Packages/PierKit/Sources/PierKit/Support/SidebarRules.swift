import Foundation

/// What the regular-width sidebar lists besides the projects tree: the worktrees with an agent at work right now
/// ("Trabalhando", pinned above everything) and the sessions the person archived or that exited ("Arquivadas").
/// Pure over the sessions plus the phone's marks, with the same columns as the agents board.
public enum SidebarRules {
    /// A worktree (or a chat, which has none) with at least one agent that needs the person or is working.
    public struct ActiveWorktree: Sendable, Hashable, Identifiable {
        public let box: String
        /// "" for a chat.
        public let location: String
        /// nil for the main worktree (and for a chat).
        public let worktree: String?
        /// Its live agents, needs-you first (oldest wait first), then working (newest first).
        public let items: [AgentBoard.Item]
        /// "box/loc" or "box/loc/wt"; a chat is "box/<session>".
        public let id: String

        /// The most urgent state of its agents.
        public var needsYou: Bool { items.contains { $0.session.agentState == .waiting } }
        public var isChat: Bool { location.isEmpty }
    }

    /// Whether a session belongs in the projects tree (and the chats list): an agent, not archived and not exited.
    public static func isListed(_ s: Session, archived: Bool, background: Bool) -> Bool {
        guard let c = AgentBoard.column(s, archived: archived, background: background) else { return false }
        return c != .closed
    }

    /// Worktrees with agents that need the person or are working, needs-you first (longest wait on top), then the
    /// most recently active. Hidden projects are the caller's to leave out.
    public static func working(_ items: [AgentBoard.Item], archived: (AgentBoard.Item) -> Bool,
                               background: Set<String>) -> [ActiveWorktree] {
        var groups: [String: [AgentBoard.Item]] = [:]
        var order: [String] = []
        for it in items {
            guard let c = AgentBoard.column(it.session, archived: archived(it), background: background.contains(it.id)),
                  c == .needsYou || c == .working else { continue }
            let key = it.location.isEmpty ? "\(it.box)/\(it.session.name)" : "\(it.box)/\(it.session.location ?? it.location)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(it)
        }
        let out = order.map { key -> ActiveWorktree in
            let members = groups[key]!.sorted(by: urgency)
            let first = members[0]
            return ActiveWorktree(box: first.box, location: first.location, worktree: first.worktree, items: members, id: key)
        }
        return out.sorted { a, b in
            if a.needsYou != b.needsYou { return a.needsYou }
            return urgency(a.items[0], b.items[0])
        }
    }

    /// Archived (on the phone) or exited (on the box) agent sessions, most recent first.
    public static func archived(_ items: [AgentBoard.Item], archived: (AgentBoard.Item) -> Bool) -> [AgentBoard.Item] {
        items.filter { AgentBoard.column($0.session, archived: archived($0), background: false) == .closed }
            .sorted { a, b in a.since != b.since ? a.since > b.since : a.id < b.id }
    }

    /// Needs-you before working; among waits the oldest first, otherwise the newest first; the id breaks ties.
    static func urgency(_ a: AgentBoard.Item, _ b: AgentBoard.Item) -> Bool {
        let wa = a.session.agentState == .waiting, wb = b.session.agentState == .waiting
        if wa != wb { return wa }
        if a.since != b.since { return wa ? a.since < b.since : a.since > b.since }
        return a.id < b.id
    }
}
