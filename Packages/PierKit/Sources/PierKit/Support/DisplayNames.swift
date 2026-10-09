import Foundation

/// Names for agents, sessions and places, as the app shows them.
public enum DisplayNames {
    private static let labels = [
        "claude": "Claude Code", "codex": "Codex", "opencode": "OpenCode", "gemini": "Gemini", "pi": "Pi",
        "cursor-agent": "Cursor Agent", "cursor": "Cursor Agent",
    ]
    private static let known = ["claude", "codex", "opencode", "gemini", "pi", "cursor-agent"]

    /// "claude" -> "Claude Code".
    public static func agentLabel(_ a: String) -> String {
        labels[a] ?? (a.prefix(1).uppercased() + a.dropFirst())
    }

    /// The session's agent id, also recognising a bare command (`/usr/bin/claude ...`); nil for shells and service terminals.
    public static func agent(of s: Session) -> String? {
        if s.service != nil { return nil }
        if let a = s.agent, !a.isEmpty { return a }
        let program = s.command?.split(separator: " ").first.map { String($0.split(separator: "/").last ?? "") }
        if let program, known.contains(program) { return program }
        return nil
    }

    /// Title, else the agent's name, else the service or "Shell"; untitled twins in one folder get " 2", " 3".
    public static func sessionName(_ s: Session, among sessions: [Session] = []) -> String {
        let title = s.title?.jsTrimmed ?? ""
        let agent = agent(of: s)
        var name = !title.isEmpty ? title : (agent.map(agentLabel) ?? s.service ?? "Shell")
        if title.isEmpty {
            let same = sessions.filter { $0.dir == s.dir && self.agent(of: $0) == agent && !$0.exited && ($0.title?.jsTrimmed ?? "").isEmpty }
            if same.count > 1 {
                let order = same.sorted { ($0.created, $0.name) < ($1.created, $1.name) }
                if let n = order.firstIndex(where: { $0.name == s.name }), n > 0 { name += " \(n + 1)" }
            }
        }
        return name
    }

    /// Secondary text beside a titled session's name: the agent ("Claude Code") or "Shell"; empty for untitled ones.
    public static func sessionAgent(_ s: Session) -> String {
        if s.service != nil { return "Service" }
        if (s.title?.jsTrimmed ?? "").isEmpty { return "" }
        return agent(of: s).map(agentLabel) ?? "Shell"
    }

    /// Where a chat runs (it belongs to no project), rather than its folder's generated name.
    public static let chatPlace = "Chat"

    /// "repo" for a main checkout, else "repo / worktree"; falls back to the folder name.
    public static func place(forPath path: String?, in locations: [Location]) -> String {
        guard let path else { return "" }
        for loc in locations {
            if let wt = loc.worktrees?.first(where: { $0.path == path }) {
                return wt.main == true ? loc.name : "\(loc.name) / \(wt.name)"
            }
        }
        return path.split(separator: "/").last.map(String.init) ?? ""
    }
}
