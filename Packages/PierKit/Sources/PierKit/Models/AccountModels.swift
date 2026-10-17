// Codable models of the box's agent accounts and their limits, its variables and skills, and its public links
// (docs/API.md §2.10–2.12). Checked against Server/pierd/internal/box/accounts.go, skills.go, shares.go and
// internal/integrations/statusline.go.
import Foundation

/// One usage window of a subscription: Claude Code's 5-hour and weekly ("five_hour", "seven_day"), Codex's
/// "primary" / "secondary" (their length in `minutes`).
public struct LimitWindow: Codable, Sendable, Hashable, Identifiable {
    public let kind: String
    public let minutes: Int?
    public let usedPercent: Double
    public let resetsAt: Date?
    public var id: String { kind }
    public init(kind: String, minutes: Int? = nil, usedPercent: Double, resetsAt: Date? = nil) {
        self.kind = kind; self.minutes = minutes; self.usedPercent = usedPercent; self.resetsAt = resetsAt
    }
    enum CodingKeys: String, CodingKey { case kind, minutes, usedPercent = "used_percent", resetsAt = "resets_at" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        minutes = try c.decodeIfPresent(Int.self, forKey: .minutes)
        usedPercent = try c.decodeIfPresent(Double.self, forKey: .usedPercent) ?? 0
        let r = try? c.decodeIfPresent(Date.self, forKey: .resetsAt)
        resetsAt = r.flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
    }
}

public struct AccountLimits: Codable, Sendable, Hashable {
    public let windows: [LimitWindow]
    public let updated: Date?
    /// "statusline" (Claude Code) or "session_log" (Codex).
    public let source: String?
    public init(windows: [LimitWindow] = [], updated: Date? = nil, source: String? = nil) {
        self.windows = windows; self.updated = updated; self.source = source
    }
    enum CodingKeys: String, CodingKey { case windows, updated, source }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windows = try c.decodeIfPresent([LimitWindow].self, forKey: .windows) ?? []
        updated = try? c.decodeIfPresent(Date.self, forKey: .updated)
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }
}

/// `GET /v1/accounts`: a Claude Code or Codex account on the box (its own folder: CLAUDE_CONFIG_DIR / CODEX_HOME).
public struct AgentAccount: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let agent: String
    public let name: String
    public let dir: String
    public let builtin: Bool
    public let signedIn: Bool
    public let signedInKnown: Bool
    public let isDefault: Bool
    public let projects: [String]
    public let limits: AccountLimits?
    /// False for a Claude account whose status line is not pierd's yet (`POST /v1/limits/enable`).
    public let limitsReady: Bool

    public init(id: String, agent: String, name: String, dir: String = "", builtin: Bool = false, signedIn: Bool = true, signedInKnown: Bool = true,
                isDefault: Bool = false, projects: [String] = [], limits: AccountLimits? = nil, limitsReady: Bool = true) {
        self.id = id; self.agent = agent; self.name = name; self.dir = dir; self.builtin = builtin; self.signedIn = signedIn
        self.signedInKnown = signedInKnown; self.isDefault = isDefault; self.projects = projects; self.limits = limits; self.limitsReady = limitsReady
    }
    enum CodingKeys: String, CodingKey {
        case id, agent, name, dir, builtin, projects, limits
        case signedIn = "signed_in", signedInKnown = "signed_in_known", isDefault = "default", limitsReady = "limits_ready"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        dir = try c.decodeIfPresent(String.self, forKey: .dir) ?? ""
        builtin = try c.decodeIfPresent(Bool.self, forKey: .builtin) ?? false
        signedIn = try c.decodeIfPresent(Bool.self, forKey: .signedIn) ?? false
        signedInKnown = try c.decodeIfPresent(Bool.self, forKey: .signedInKnown) ?? false
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        projects = try c.decodeIfPresent([String].self, forKey: .projects) ?? []
        limits = try c.decodeIfPresent(AccountLimits.self, forKey: .limits)
        limitsReady = try c.decodeIfPresent(Bool.self, forKey: .limitsReady) ?? true
    }
}

/// `GET`/`PUT /v1/env`: the box's own variables (every project gets them) and what each is for.
public struct BoxVariables: Codable, Sendable, Hashable {
    public var env: [String: String]
    public var notes: [String: String]
    public init(env: [String: String] = [:], notes: [String: String] = [:]) { self.env = env; self.notes = notes }
    enum CodingKeys: String, CodingKey { case env, notes }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        notes = try c.decodeIfPresent([String: String].self, forKey: .notes) ?? [:]
    }
}

/// `GET /v1/skills`: a skill pierd can install for Claude Code and Codex.
public struct BoxSkill: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let description: String
    public let installed: Bool
    public let paths: [String]
    public init(id: String, name: String = "", description: String = "", installed: Bool = false, paths: [String] = []) {
        self.id = id; self.name = name; self.description = description; self.installed = installed; self.paths = paths
    }
    enum CodingKeys: String, CodingKey { case id, name, description, installed, paths }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        installed = try c.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
    }
}

/// `GET`/`POST /v1/shares`: a public link to one of a worktree's dev servers, through the box's relay.
public struct PublicLink: Codable, Sendable, Hashable, Identifiable {
    public let name: String
    public let url: String
    public let location: String
    public let worktree: String
    public let port: Int
    public let created: Date?
    public let expires: Date?
    /// The link the box made for the worktree's preview, renewed while the worktree is there (docs/API.md §2.12.1).
    public let auto: Bool?
    public var id: String { name }
    public init(name: String, url: String, location: String, worktree: String, port: Int, created: Date? = nil, expires: Date? = nil, auto: Bool? = nil) {
        self.name = name; self.url = url; self.location = location; self.worktree = worktree; self.port = port; self.created = created; self.expires = expires
        self.auto = auto
    }
}
