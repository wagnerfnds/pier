// Codable models of pierd's JSON (docs/API.md §13.3), checked against the Go structs in Server/pierd.
import Foundation

public struct Worktree: Codable, Sendable, Hashable, Identifiable {
    public let name: String
    public let path: String
    public let branch: String?
    public let head: String?
    public let main: Bool?
    public let settingUp: Bool?
    public let port: Int?
    public let locked: Bool?
    public let lockReason: String?

    public init(name: String, path: String, branch: String? = nil, head: String? = nil, main: Bool? = nil, settingUp: Bool? = nil, port: Int? = nil, locked: Bool? = nil, lockReason: String? = nil) {
        self.name = name
        self.path = path
        self.branch = branch
        self.head = head
        self.main = main
        self.settingUp = settingUp
        self.port = port
        self.locked = locked
        self.lockReason = lockReason
    }

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case branch
        case head
        case main
        case settingUp = "setting_up"
        case port
        case locked
        case lockReason = "lock_reason"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.path = try c.decode(String.self, forKey: .path)
        self.branch = try c.decodeIfPresent(String.self, forKey: .branch)
        self.head = try c.decodeIfPresent(String.self, forKey: .head)
        self.main = try c.decodeIfPresent(Bool.self, forKey: .main)
        self.settingUp = try c.decodeIfPresent(Bool.self, forKey: .settingUp)
        self.port = try c.decodeIfPresent(Int.self, forKey: .port)
        self.locked = try c.decodeIfPresent(Bool.self, forKey: .locked)
        self.lockReason = try c.decodeIfPresent(String.self, forKey: .lockReason)
    }

    public var id: String { path }
}

public struct Scripts: Codable, Sendable, Hashable {
    public let setup: String?
    public let archive: String?
    public let from: String?

    public init(setup: String? = nil, archive: String? = nil, from: String? = nil) {
        self.setup = setup
        self.archive = archive
        self.from = from
    }

    enum CodingKeys: String, CodingKey {
        case setup
        case archive
        case from
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.setup = try c.decodeIfPresent(String.self, forKey: .setup)
        self.archive = try c.decodeIfPresent(String.self, forKey: .archive)
        self.from = try c.decodeIfPresent(String.self, forKey: .from)
    }
}

/// A registered repo and its worktrees.
public struct Location: Codable, Sendable, Hashable, Identifiable {
    public let name: String
    public let path: String
    public let repo: Bool
    public let worktrees: [Worktree]?
    public let remote: String?
    public let slug: String?
    public let defaultBranch: String?
    public let repoTrust: String?
    public let check: String?
    public let checkFrom: String?
    public let agents: [AgentPreset]?
    public let scripts: Scripts?

    public init(name: String, path: String = "", repo: Bool = false, worktrees: [Worktree]? = nil, remote: String? = nil, slug: String? = nil, defaultBranch: String? = nil, repoTrust: String? = nil, check: String? = nil, checkFrom: String? = nil, agents: [AgentPreset]? = nil, scripts: Scripts? = nil) {
        self.name = name
        self.path = path
        self.repo = repo
        self.worktrees = worktrees
        self.remote = remote
        self.slug = slug
        self.defaultBranch = defaultBranch
        self.repoTrust = repoTrust
        self.check = check
        self.checkFrom = checkFrom
        self.agents = agents
        self.scripts = scripts
    }

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case repo
        case worktrees
        case remote
        case slug
        case defaultBranch = "default_branch"
        case repoTrust = "repo_trust"
        case check
        case checkFrom = "check_from"
        case agents
        case scripts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        self.repo = try c.decodeIfPresent(Bool.self, forKey: .repo) ?? false
        self.worktrees = try c.decodeIfPresent([Worktree].self, forKey: .worktrees)
        self.remote = try c.decodeIfPresent(String.self, forKey: .remote)
        self.slug = try c.decodeIfPresent(String.self, forKey: .slug)
        self.defaultBranch = try c.decodeIfPresent(String.self, forKey: .defaultBranch)
        self.repoTrust = try c.decodeIfPresent(String.self, forKey: .repoTrust)
        self.check = try c.decodeIfPresent(String.self, forKey: .check)
        self.checkFrom = try c.decodeIfPresent(String.self, forKey: .checkFrom)
        self.agents = try c.decodeIfPresent([AgentPreset].self, forKey: .agents)
        self.scripts = try c.decodeIfPresent(Scripts.self, forKey: .scripts)
    }

    public var id: String { name }
    /// API ref of a worktree (`exec` / session `location`): the bare name for the main checkout.
    public func ref(_ wt: Worktree) -> String { wt.main == true ? name : "\(name)/\(wt.name)" }
}

public struct Commit: Codable, Sendable, Hashable, Identifiable {
    public let sha: String
    public let short: String?
    public let subject: String
    public let author: String?
    public let time: Date?
    public let refs: String?
    public let parents: [String]
    public let onBase: Bool

    public init(sha: String, short: String? = nil, subject: String = "", author: String? = nil, time: Date? = nil, refs: String? = nil, parents: [String] = [], onBase: Bool = false) {
        self.sha = sha
        self.short = short
        self.subject = subject
        self.author = author
        self.time = time
        self.refs = refs
        self.parents = parents
        self.onBase = onBase
    }

    enum CodingKeys: String, CodingKey {
        case sha
        case short
        case subject
        case author
        case time
        case refs
        case parents
        case onBase = "on_base"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sha = try c.decode(String.self, forKey: .sha)
        self.short = try c.decodeIfPresent(String.self, forKey: .short)
        self.subject = try c.decodeIfPresent(String.self, forKey: .subject) ?? ""
        self.author = try c.decodeIfPresent(String.self, forKey: .author)
        self.time = try c.decodeIfPresent(Date.self, forKey: .time)
        self.refs = try c.decodeIfPresent(String.self, forKey: .refs)
        self.parents = try c.decodeIfPresent([String].self, forKey: .parents) ?? []
        self.onBase = try c.decodeIfPresent(Bool.self, forKey: .onBase) ?? false
    }

    public var id: String { sha }
}

public struct WorktreeStatus: Codable, Sendable, Hashable, Identifiable {
    public let location: String
    public let name: String
    public let path: String
    public let branch: String?
    public let main: Bool?
    public let port: Int?
    public let base: String?
    public let ahead: Int
    public let behind: Int
    public let changed: Int
    public let untracked: Int
    public let lastCommit: Commit?
    public let paused: Bool?
    public let sessions: Int
    public let error: String?

    public init(location: String, name: String, path: String = "", branch: String? = nil, main: Bool? = nil, port: Int? = nil, base: String? = nil, ahead: Int = 0, behind: Int = 0, changed: Int = 0, untracked: Int = 0, lastCommit: Commit? = nil, paused: Bool? = nil, sessions: Int = 0, error: String? = nil) {
        self.location = location
        self.name = name
        self.path = path
        self.branch = branch
        self.main = main
        self.port = port
        self.base = base
        self.ahead = ahead
        self.behind = behind
        self.changed = changed
        self.untracked = untracked
        self.lastCommit = lastCommit
        self.paused = paused
        self.sessions = sessions
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case location
        case name
        case path
        case branch
        case main
        case port
        case base
        case ahead
        case behind
        case changed
        case untracked
        case lastCommit = "last_commit"
        case paused
        case sessions
        case error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.location = try c.decode(String.self, forKey: .location)
        self.name = try c.decode(String.self, forKey: .name)
        self.path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        self.branch = try c.decodeIfPresent(String.self, forKey: .branch)
        self.main = try c.decodeIfPresent(Bool.self, forKey: .main)
        self.port = try c.decodeIfPresent(Int.self, forKey: .port)
        self.base = try c.decodeIfPresent(String.self, forKey: .base)
        self.ahead = try c.decodeIfPresent(Int.self, forKey: .ahead) ?? 0
        self.behind = try c.decodeIfPresent(Int.self, forKey: .behind) ?? 0
        self.changed = try c.decodeIfPresent(Int.self, forKey: .changed) ?? 0
        self.untracked = try c.decodeIfPresent(Int.self, forKey: .untracked) ?? 0
        self.lastCommit = try c.decodeIfPresent(Commit.self, forKey: .lastCommit)
        self.paused = try c.decodeIfPresent(Bool.self, forKey: .paused)
        self.sessions = try c.decodeIfPresent(Int.self, forKey: .sessions) ?? 0
        self.error = try c.decodeIfPresent(String.self, forKey: .error)
    }

    public var id: String { path }
}

extension BranchList {
    public struct B: Codable, Sendable, Hashable, Identifiable {
        public let name: String
        public let remote: Bool
        public let current: Bool?

        public init(name: String, remote: Bool = false, current: Bool? = nil) {
            self.name = name
            self.remote = remote
            self.current = current
        }

        enum CodingKeys: String, CodingKey {
            case name
            case remote
            case current
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try c.decode(String.self, forKey: .name)
            self.remote = try c.decodeIfPresent(Bool.self, forKey: .remote) ?? false
            self.current = try c.decodeIfPresent(Bool.self, forKey: .current)
        }

        public var id: String { (remote ? "remote:" : "local:") + name }
    }
}

public struct BranchList: Codable, Sendable, Hashable {
    public let `default`: String?
    public let branches: [BranchList.B]?

    public init(`default`: String? = nil, branches: [BranchList.B]? = nil) {
        self.`default` = `default`
        self.branches = branches
    }

    enum CodingKeys: String, CodingKey {
        case `default`
        case branches
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`default` = try c.decodeIfPresent(String.self, forKey: .`default`)
        self.branches = try c.decodeIfPresent([BranchList.B].self, forKey: .branches)
    }
}

public struct WorktreeRequest: Codable, Sendable, Hashable {
    public var name: String
    public var branch: String?
    public var base: String?
    public var pr: Int?
    public var ref: String?

    public init(name: String, branch: String? = nil, base: String? = nil, pr: Int? = nil, ref: String? = nil) {
        self.name = name
        self.branch = branch
        self.base = base
        self.pr = pr
        self.ref = ref
    }

    enum CodingKeys: String, CodingKey {
        case name
        case branch
        case base
        case pr
        case ref
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.branch = try c.decodeIfPresent(String.self, forKey: .branch)
        self.base = try c.decodeIfPresent(String.self, forKey: .base)
        self.pr = try c.decodeIfPresent(Int.self, forKey: .pr)
        self.ref = try c.decodeIfPresent(String.self, forKey: .ref)
    }
}
