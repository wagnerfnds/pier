// Codable models of pierd's project routes (docs/API.md §2.8): the GitHub account's repositories, clones, and a
// project's footprint on the disk. Checked against Server/pierd/internal/box/github.go and projects.go.
import Foundation

/// One repository of `GET /v1/github/repos`.
public struct GitHubRepo: Codable, Sendable, Hashable, Identifiable {
    public let slug: String
    public let name: String
    public let description: String?
    public let url: String
    public let isPrivate: Bool
    public let fork: Bool
    public let archived: Bool
    public let language: String?
    public let updatedAt: Date?
    /// The location this repository already is on the box, if it is.
    public let location: String?
    public var id: String { slug }

    public init(slug: String, name: String, description: String? = nil, url: String = "", isPrivate: Bool = false, fork: Bool = false,
                archived: Bool = false, language: String? = nil, updatedAt: Date? = nil, location: String? = nil) {
        self.slug = slug; self.name = name; self.description = description; self.url = url; self.isPrivate = isPrivate
        self.fork = fork; self.archived = archived; self.language = language; self.updatedAt = updatedAt; self.location = location
    }

    enum CodingKeys: String, CodingKey {
        case slug, name, description, url, fork, archived, language, location
        case isPrivate = "private"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? slug.split(separator: "/").last.map(String.init) ?? slug
        description = try c.decodeIfPresent(String.self, forKey: .description)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        fork = try c.decodeIfPresent(Bool.self, forKey: .fork) ?? false
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        language = try c.decodeIfPresent(String.self, forKey: .language)
        updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
        location = try c.decodeIfPresent(String.self, forKey: .location)
    }
}

/// `GET /v1/github/repos[?owner=]`: the repositories of the account gh is signed in to on the box (or of one of its organisations).
public struct GitHubRepos: Codable, Sendable, Hashable {
    public let login: String
    public let owner: String
    public let owners: [String]
    public let repos: [GitHubRepo]

    public init(login: String, owner: String? = nil, owners: [String] = [], repos: [GitHubRepo] = []) {
        self.login = login; self.owner = owner ?? login; self.owners = owners.isEmpty ? [login] : owners; self.repos = repos
    }

    enum CodingKeys: String, CodingKey { case login, owner, owners, repos }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        login = try c.decodeIfPresent(String.self, forKey: .login) ?? ""
        owner = try c.decodeIfPresent(String.self, forKey: .owner) ?? login
        owners = try c.decodeIfPresent([String].self, forKey: .owners) ?? [login]
        repos = try c.decodeIfPresent([GitHubRepo].self, forKey: .repos) ?? []
    }
}

/// `POST /v1/clones`.
public struct CloneRequest: Codable, Sendable, Hashable {
    /// `owner/repo`, a GitHub page of it, or a clone URL (https or ssh).
    public var repo: String
    public var name: String?
    public var dir: String?
    /// The space of the box's projects folder to clone into (made if new).
    public var space: String?
    /// Make it ready: trust the repository's config or work one out, run setup, start its services.
    public var setup: Bool
    public init(repo: String, name: String? = nil, dir: String? = nil, space: String? = nil, setup: Bool = true) {
        self.repo = repo; self.name = name; self.dir = dir; self.space = space; self.setup = setup
    }
}

/// A repository being brought onto the box (`GET /v1/clones`, the answer of `POST /v1/clones`).
public struct ProjectClone: Codable, Sendable, Hashable, Identifiable {
    public enum State: String, Codable, Sendable {
        case cloning, settingUp = "setting_up", ready, failed
        public init(from decoder: Decoder) throws {
            self = State(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .cloning
        }
    }
    public let id: String
    public let repo: String
    public let slug: String?
    public let location: String
    public let path: String
    public let state: State
    /// "repo", "detected" or "none": what made the project ready.
    public let setup: String?
    public let services: [String]
    public let error: String?
    public let log: String?
    public let started: Date?
    public let finished: Date?

    public var isRunning: Bool { state == .cloning || state == .settingUp }

    public init(id: String, repo: String, slug: String? = nil, location: String, path: String = "", state: State, setup: String? = nil,
                services: [String] = [], error: String? = nil, log: String? = nil, started: Date? = nil, finished: Date? = nil) {
        self.id = id; self.repo = repo; self.slug = slug; self.location = location; self.path = path; self.state = state
        self.setup = setup; self.services = services; self.error = error; self.log = log; self.started = started; self.finished = finished
    }

    enum CodingKeys: String, CodingKey { case id, repo, slug, location, path, state, setup, services, error, log, started, finished }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        repo = try c.decodeIfPresent(String.self, forKey: .repo) ?? ""
        slug = try c.decodeIfPresent(String.self, forKey: .slug)
        location = try c.decodeIfPresent(String.self, forKey: .location) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        state = try c.decodeIfPresent(State.self, forKey: .state) ?? .cloning
        setup = try c.decodeIfPresent(String.self, forKey: .setup)
        services = try c.decodeIfPresent([String].self, forKey: .services) ?? []
        error = try c.decodeIfPresent(String.self, forKey: .error)
        log = try c.decodeIfPresent(String.self, forKey: .log)
        started = try? c.decodeIfPresent(Date.self, forKey: .started)
        finished = try? c.decodeIfPresent(Date.self, forKey: .finished)
    }
}

/// `GET /v1/locations/{l}/disk`: what a project takes on the disk and what removing it would lose.
public struct ProjectDisk: Codable, Sendable, Hashable {
    public struct Uncommitted: Codable, Sendable, Hashable {
        public let worktree: String
        public let files: Int
        public init(worktree: String, files: Int) { self.worktree = worktree; self.files = files }
    }
    public struct Unpushed: Codable, Sendable, Hashable {
        public let branch: String
        public let commits: Int
        public init(branch: String, commits: Int) { self.branch = branch; self.commits = commits }
    }
    public let bytes: Int64
    public let paths: [String]
    public let uncommitted: [Uncommitted]
    public let unpushed: [Unpushed]
    public let stashes: Int
    public let sessions: Int
    public let removable: Bool
    public let reason: String?
    public let remote: String?
    /// Worktrees git could not read: what they hold is unknown, so it counts as work that would be lost.
    public let unreadable: [String]

    /// Removing it loses work that exists nowhere else.
    public var hasUnsavedWork: Bool { !uncommitted.isEmpty || !unpushed.isEmpty || stashes > 0 || !unreadable.isEmpty }

    public init(bytes: Int64 = 0, paths: [String] = [], uncommitted: [Uncommitted] = [], unpushed: [Unpushed] = [], stashes: Int = 0,
                sessions: Int = 0, removable: Bool = true, reason: String? = nil, remote: String? = nil, unreadable: [String] = []) {
        self.bytes = bytes; self.paths = paths; self.uncommitted = uncommitted; self.unpushed = unpushed; self.stashes = stashes
        self.sessions = sessions; self.removable = removable; self.reason = reason; self.remote = remote; self.unreadable = unreadable
    }

    enum CodingKeys: String, CodingKey { case bytes, paths, uncommitted, unpushed, stashes, sessions, removable, reason, remote, unreadable }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
        uncommitted = try c.decodeIfPresent([Uncommitted].self, forKey: .uncommitted) ?? []
        unpushed = try c.decodeIfPresent([Unpushed].self, forKey: .unpushed) ?? []
        stashes = try c.decodeIfPresent(Int.self, forKey: .stashes) ?? 0
        sessions = try c.decodeIfPresent(Int.self, forKey: .sessions) ?? 0
        removable = try c.decodeIfPresent(Bool.self, forKey: .removable) ?? false
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        remote = try c.decodeIfPresent(String.self, forKey: .remote)
        unreadable = try c.decodeIfPresent([String].self, forKey: .unreadable) ?? []
    }
}

/// `DELETE /v1/locations/{l}?purge=1`.
public struct ProjectPurge: Codable, Sendable, Hashable {
    public let removed: String
    public let freed: Int64
    public init(removed: String, freed: Int64) { self.removed = removed; self.freed = freed }
}

/// One of a worktree's own services as `GET …/worktrees/{w}/services` lists it, with its command.
public struct WorktreeServiceDetail: Codable, Sendable, Hashable, Identifiable {
    public let name: String
    public let run: String
    public let autostart: Bool
    public let state: String
    public let unit: String
    public let port: Int?
    /// "mysql" or "redis" for the worktree's own servers that pierd runs from the project's base (capability `base.db`);
    /// nil for the project's services.
    public let kind: String?
    public var id: String { name }
    public var isRunning: Bool { state == "running" }
    /// One of the worktree's own servers.
    public var isServer: Bool { kind != nil }

    public init(name: String, run: String = "", autostart: Bool = false, state: String = "stopped", unit: String = "", port: Int? = nil,
                kind: String? = nil) {
        self.name = name; self.run = run; self.autostart = autostart; self.state = state; self.unit = unit; self.port = port; self.kind = kind
    }

    enum CodingKeys: String, CodingKey { case name, run, autostart, state, unit, port, kind }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        run = try c.decodeIfPresent(String.self, forKey: .run) ?? ""
        autostart = try c.decodeIfPresent(Bool.self, forKey: .autostart) ?? false
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "stopped"
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        kind = try c.decodeIfPresent(String.self, forKey: .kind).flatMap { $0.isEmpty ? nil : $0 }
    }
}
