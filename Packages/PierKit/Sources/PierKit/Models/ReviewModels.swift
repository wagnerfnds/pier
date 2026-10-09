// Codable models of pierd's JSON (docs/API.md §13.3), checked against the Go structs in Server/pierd.
import Foundation

public struct ReviewFile: Codable, Sendable, Hashable, Identifiable {
    public let path: String
    public let from: String?
    public let code: String
    public let added: Int
    public let removed: Int
    public let binary: Bool?

    public init(path: String, from: String? = nil, code: String = "", added: Int = 0, removed: Int = 0, binary: Bool? = nil) {
        self.path = path
        self.from = from
        self.code = code
        self.added = added
        self.removed = removed
        self.binary = binary
    }

    enum CodingKeys: String, CodingKey {
        case path
        case from
        case code
        case added
        case removed
        case binary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try c.decode(String.self, forKey: .path)
        self.from = try c.decodeIfPresent(String.self, forKey: .from)
        self.code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
        self.added = try c.decodeIfPresent(Int.self, forKey: .added) ?? 0
        self.removed = try c.decodeIfPresent(Int.self, forKey: .removed) ?? 0
        self.binary = try c.decodeIfPresent(Bool.self, forKey: .binary)
    }

    public var id: String { (from.map { $0 + "->" } ?? "") + path + "|" + code }
}

public struct ReviewCommit: Codable, Sendable, Hashable, Identifiable {
    public let sha: String
    public let subject: String
    public let author: String
    public let when: Date

    public init(sha: String, subject: String = "", author: String = "", when: Date = Date(timeIntervalSince1970: 0)) {
        self.sha = sha
        self.subject = subject
        self.author = author
        self.when = when
    }

    enum CodingKeys: String, CodingKey {
        case sha
        case subject
        case author
        case when
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sha = try c.decode(String.self, forKey: .sha)
        self.subject = try c.decodeIfPresent(String.self, forKey: .subject) ?? ""
        self.author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        self.when = try c.decodeIfPresent(Date.self, forKey: .when) ?? Date(timeIntervalSince1970: 0)
    }

    public var id: String { sha }
}

public struct ReviewItem: Codable, Sendable, Identifiable, Hashable {
    public let location: String
    public let worktree: String
    public let path: String
    public let branch: String?
    public let head: String?
    public let base: String?
    public let upstream: String?
    public let main: Bool?
    public let ahead: Int
    public let behind: Int
    public let files: [ReviewFile]
    public let added: Int
    public let removed: Int
    public let commits: [ReviewCommit]
    public let baseAhead: Int
    public let committed: [ReviewFile]
    public let session: String
    public let agent: String
    public let agentState: String
    public let stateSince: Date?
    public let browser: JSONValue?

    public init(location: String, worktree: String, path: String, branch: String? = nil, head: String? = nil, base: String? = nil, upstream: String? = nil, main: Bool? = nil, ahead: Int = 0, behind: Int = 0, files: [ReviewFile] = [], added: Int = 0, removed: Int = 0, commits: [ReviewCommit] = [], baseAhead: Int = 0, committed: [ReviewFile] = [], session: String = "", agent: String = "", agentState: String = "", stateSince: Date? = nil, browser: JSONValue? = nil) {
        self.location = location
        self.worktree = worktree
        self.path = path
        self.branch = branch
        self.head = head
        self.base = base
        self.upstream = upstream
        self.main = main
        self.ahead = ahead
        self.behind = behind
        self.files = files
        self.added = added
        self.removed = removed
        self.commits = commits
        self.baseAhead = baseAhead
        self.committed = committed
        self.session = session
        self.agent = agent
        self.agentState = agentState
        self.stateSince = stateSince
        self.browser = browser
    }

    enum CodingKeys: String, CodingKey {
        case location
        case worktree
        case path
        case branch
        case head
        case base
        case upstream
        case main
        case ahead
        case behind
        case files
        case added
        case removed
        case commits
        case baseAhead = "base_ahead"
        case committed
        case session
        case agent
        case agentState = "agent_state"
        case stateSince = "state_since"
        case browser
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.location = try c.decode(String.self, forKey: .location)
        self.worktree = try c.decode(String.self, forKey: .worktree)
        self.path = try c.decode(String.self, forKey: .path)
        self.branch = try c.decodeIfPresent(String.self, forKey: .branch)
        self.head = try c.decodeIfPresent(String.self, forKey: .head)
        self.base = try c.decodeIfPresent(String.self, forKey: .base)
        self.upstream = try c.decodeIfPresent(String.self, forKey: .upstream)
        self.main = try c.decodeIfPresent(Bool.self, forKey: .main)
        self.ahead = try c.decodeIfPresent(Int.self, forKey: .ahead) ?? 0
        self.behind = try c.decodeIfPresent(Int.self, forKey: .behind) ?? 0
        self.files = try c.decodeIfPresent([ReviewFile].self, forKey: .files) ?? []
        self.added = try c.decodeIfPresent(Int.self, forKey: .added) ?? 0
        self.removed = try c.decodeIfPresent(Int.self, forKey: .removed) ?? 0
        self.commits = try c.decodeIfPresent([ReviewCommit].self, forKey: .commits) ?? []
        self.baseAhead = try c.decodeIfPresent(Int.self, forKey: .baseAhead) ?? 0
        self.committed = try c.decodeIfPresent([ReviewFile].self, forKey: .committed) ?? []
        self.session = try c.decodeIfPresent(String.self, forKey: .session) ?? ""
        self.agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? ""
        self.agentState = try c.decodeIfPresent(String.self, forKey: .agentState) ?? ""
        self.stateSince = try c.decodeIfPresent(Date.self, forKey: .stateSince)
        self.browser = try c.decodeIfPresent(JSONValue.self, forKey: .browser)
    }

    public var id: String { path }
    /// `location` for `exec`: the bare repo name for the main checkout.
    public var execLocation: String { main == true ? location : "\(location)/\(worktree)" }
    public var state: AgentState { AgentState(rawValue: agentState) }
}

public struct TouchedFile: Codable, Sendable, Hashable, Identifiable {
    public let path: String
    public let added: Int
    public let removed: Int
    public let created: Bool?
    public let deleted: Bool?
    public let live: Bool?
    public let at: Int64?
    public let session: String
    public let agent: String
    public let base: String

    public init(path: String, added: Int = 0, removed: Int = 0, created: Bool? = nil, deleted: Bool? = nil, live: Bool? = nil, at: Int64? = nil, session: String = "", agent: String = "", base: String = "") {
        self.path = path
        self.added = added
        self.removed = removed
        self.created = created
        self.deleted = deleted
        self.live = live
        self.at = at
        self.session = session
        self.agent = agent
        self.base = base
    }

    enum CodingKeys: String, CodingKey {
        case path
        case added
        case removed
        case created
        case deleted
        case live
        case at
        case session
        case agent
        case base
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try c.decode(String.self, forKey: .path)
        self.added = try c.decodeIfPresent(Int.self, forKey: .added) ?? 0
        self.removed = try c.decodeIfPresent(Int.self, forKey: .removed) ?? 0
        self.created = try c.decodeIfPresent(Bool.self, forKey: .created)
        self.deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted)
        self.live = try c.decodeIfPresent(Bool.self, forKey: .live)
        self.at = try c.decodeIfPresent(Int64.self, forKey: .at)
        self.session = try c.decodeIfPresent(String.self, forKey: .session) ?? ""
        self.agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? ""
        self.base = try c.decodeIfPresent(String.self, forKey: .base) ?? ""
    }

    public var id: String { path }
}

public struct FileDiff: Codable, Sendable, Hashable {
    public let file: String
    public let diff: String
    public let untracked: Bool?
    public let truncated: Bool?

    public init(file: String = "", diff: String = "", untracked: Bool? = nil, truncated: Bool? = nil) {
        self.file = file
        self.diff = diff
        self.untracked = untracked
        self.truncated = truncated
    }

    enum CodingKeys: String, CodingKey {
        case file
        case diff
        case untracked
        case truncated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.file = try c.decodeIfPresent(String.self, forKey: .file) ?? ""
        self.diff = try c.decodeIfPresent(String.self, forKey: .diff) ?? ""
        self.untracked = try c.decodeIfPresent(Bool.self, forKey: .untracked)
        self.truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated)
    }
}

public struct ExecResult: Codable, Sendable, Hashable {
    public let exitCode: Int
    public let output: String
    public let truncated: Bool?

    public init(exitCode: Int = 0, output: String = "", truncated: Bool? = nil) {
        self.exitCode = exitCode
        self.output = output
        self.truncated = truncated
    }

    enum CodingKeys: String, CodingKey {
        case exitCode = "exit_code"
        case output
        case truncated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode) ?? 0
        self.output = try c.decodeIfPresent(String.self, forKey: .output) ?? ""
        self.truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated)
    }
}

/// `gh pr view --json number,state,isDraft,url,title,reviewDecision`.
public struct PullRequest: Codable, Sendable, Hashable {
    public let number: Int
    public let state: String
    public let isDraft: Bool?
    public let url: String?
    public let title: String?
    public let reviewDecision: String?

    public init(number: Int = 0, state: String = "", isDraft: Bool? = nil, url: String? = nil, title: String? = nil, reviewDecision: String? = nil) {
        self.number = number
        self.state = state
        self.isDraft = isDraft
        self.url = url
        self.title = title
        self.reviewDecision = reviewDecision
    }

    enum CodingKeys: String, CodingKey {
        case number
        case state
        case isDraft
        case url
        case title
        case reviewDecision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.number = try c.decodeIfPresent(Int.self, forKey: .number) ?? 0
        self.state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        self.isDraft = try c.decodeIfPresent(Bool.self, forKey: .isDraft)
        self.url = try c.decodeIfPresent(String.self, forKey: .url)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.reviewDecision = try c.decodeIfPresent(String.self, forKey: .reviewDecision)
    }
}
