import Foundation
import PierKit

/// What an agent still runs after (or during) its turn: background shells, monitors and subagents. A finished turn with
/// work in the background is not done yet: the agent will speak again when it ends.
struct BackgroundItem: Identifiable, Hashable {
    let id: String
    let symbol: String
    let title: String
    let since: Date
}

enum BackgroundWork {
    static func running(signals: Signals?, crew: [CrewMember]) -> [BackgroundItem] {
        let jobs = (signals?.background ?? []).filter { $0.state == "running" }.map { j in
            BackgroundItem(id: j.tool, symbol: j.kind == "monitor" ? "eye" : "terminal", title: title(j), since: date(j.since))
        }
        let helpers = crew.filter { $0.state == "running" }.map { c in
            BackgroundItem(id: c.id, symbol: "person.2", title: c.doing.isEmpty ? c.name : "\(c.name) · \(c.doing)", since: date(c.since))
        }
        return (helpers + jobs).sorted { $0.since < $1.since }
    }

    /// A job's label, else its command without the `cd <dir>;` prefix and output redirections, first line, short.
    static func title(_ j: Signals.Job) -> String {
        if let l = j.label?.trimmingCharacters(in: .whitespacesAndNewlines), !l.isEmpty { return clip(l) }
        var c = j.command.split(separator: "\n").first.map(String.init) ?? j.command
        if let r = c.range(of: #"^\s*cd\s+\S+\s*(;|&&)\s*"#, options: .regularExpression) { c.removeSubrange(r) }
        if let r = c.range(of: #"\s+(\d?>|\|)\s.*$"#, options: .regularExpression) { c.removeSubrange(r) }
        return clip(c.trimmingCharacters(in: .whitespaces))
    }

    private static func clip(_ s: String) -> String { s.count > 60 ? String(s.prefix(59)) + "…" : s }
    private static func date(_ ms: Int64) -> Date { ms > 0 ? Date(timeIntervalSince1970: Double(ms) / 1000) : Date() }
}
