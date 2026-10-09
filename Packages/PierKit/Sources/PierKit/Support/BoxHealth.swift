import Foundation

/// What a box's doctor report (`GET /v1/doctor`, docs/API.md §1.3) means for the person: the checks that need a hand, as
/// the Inbox lists them ("A box precisa de você"). Pure over `[DoctorCheck]`; the app puts the words to each kind.
public enum BoxHealth {
    public enum Severity: Int, Sendable, Hashable, Comparable {
        case warn = 1, fail = 2
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    /// The problems a report can name (`other` carries anything new pierd starts reporting), plus the ones the app sees
    /// on its own side of the connection.
    public enum Kind: Sendable, Hashable {
        /// An agent CLI is signed out on the box (`<agent> sign-in`).
        case agentSignIn(agent: String)
        /// pierd's hooks are not in the agent's settings (`<agent> hooks`).
        case agentHooks(agent: String)
        /// No agent CLI was found at all.
        case noAgents
        /// A tool sessions need (git, tmux) or a feature wants (gh) is missing.
        case tool(name: String)
        /// pierd runs, but not as a service (gone after a reboot).
        case service
        /// pierd stops at logout (no lingering).
        case lingering
        /// pierd answers on every interface, the internet included.
        case listening
        /// A location whose folder no longer exists.
        case location(name: String)
        /// The event journal or a subscriber lost events.
        case events(name: String)
        case other(area: String, name: String)
        /// The app cannot reach the box (network, VPN, pierd down).
        case unreachable
        /// The box revoked this device.
        case revoked
        /// The box answers with another key than the one pinned at pairing.
        case keyChanged
    }

    public struct Issue: Sendable, Hashable, Identifiable {
        /// "<area>/<name>", stable across reports (what a snooze is keyed by).
        public let id: String
        public let kind: Kind
        public let severity: Severity
        public let name: String
        public let detail: String?
        /// The command (or sentence) that fixes it, from pierd.
        public let fix: String?

        public init(id: String, kind: Kind, severity: Severity, name: String, detail: String? = nil, fix: String? = nil) {
            self.id = id
            self.kind = kind
            self.severity = severity
            self.name = name
            self.detail = detail
            self.fix = fix
        }
    }

    /// The checks that need a hand: `fail` and `warn` (and "no agent CLI", which pierd marks as information), most serious
    /// first, in the report's order otherwise. `ok` and other `info` lines are not the person's business, nor is "nobody
    /// paired yet" (the app reading the report is paired).
    public static func issues(in checks: [DoctorCheck]) -> [Issue] {
        var out: [Issue] = []
        for c in checks {
            let kind = kind(of: c)
            let severity: Severity
            switch c.status {
            case "fail": severity = .fail
            case "warn": severity = .warn
            case "info" where kind == .noAgents: severity = .warn
            default: continue
            }
            if c.area == "pierd", c.name.hasPrefix("paired") { continue }
            out.append(Issue(id: "\(c.area)/\(c.name)", kind: kind, severity: severity, name: c.name,
                             detail: c.detail.flatMap { $0.isEmpty ? nil : $0 }, fix: c.fix.flatMap { $0.isEmpty ? nil : $0 }))
        }
        return out.enumerated().sorted { a, b in
            if a.element.severity != b.element.severity { return a.element.severity > b.element.severity }
            return a.offset < b.offset
        }.map(\.element)
    }

    static func kind(of c: DoctorCheck) -> Kind {
        let name = c.name.trimmingCharacters(in: .whitespaces)
        switch c.area {
        case "Agents":
            if name.hasSuffix(" sign-in") { return .agentSignIn(agent: String(name.dropLast(" sign-in".count))) }
            if name.hasSuffix(" hooks") { return .agentHooks(agent: String(name.dropLast(" hooks".count))) }
            if name == "agent CLIs" { return .noAgents }
        case "pierd":
            switch name {
            case "starts at boot", "running": return .service
            case "survives logout": return .lingering
            case "listening": return .listening
            default: break
            }
        case "Worktrees and sessions":
            if ["git", "tmux", "gh", "cloudflared"].contains(name) { return .tool(name: name) }
        case "Locations":
            if name != "locations" { return .location(name: name) }
        case "Events":
            return .events(name: name)
        default:
            break
        }
        return .other(area: c.area, name: name)
    }
}
