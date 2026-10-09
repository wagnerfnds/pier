import Foundation

// One pull request as `gh pr view <n> --repo <owner/name> --json …` describes it (see `PRCommands.viewFields`).
// Decoding is tolerant: every list may be missing or `null`, unknown enum values are kept as their raw strings.

public struct PRDetail: Sendable, Hashable {
    public struct Author: Sendable, Hashable {
        public let login: String
        public let name: String?
        public let isBot: Bool
        public init(login: String, name: String? = nil, isBot: Bool = false) { self.login = login; self.name = name; self.isBot = isBot }
    }

    public struct File: Sendable, Hashable, Identifiable {
        public let path: String
        public let additions: Int
        public let deletions: Int
        /// ADDED, MODIFIED, DELETED, RENAMED, COPIED, CHANGED.
        public let changeType: String
        public var id: String { path }
        public init(path: String, additions: Int = 0, deletions: Int = 0, changeType: String = "MODIFIED") {
            self.path = path; self.additions = additions; self.deletions = deletions; self.changeType = changeType
        }
        /// One-letter name-status code, like `git diff --name-status` (what `ReviewFile.code` holds for committed files).
        public var code: String {
            switch changeType {
            case "ADDED": "A"
            case "DELETED": "D"
            case "RENAMED": "R"
            case "COPIED": "C"
            default: "M"
            }
        }
    }

    /// A check run (GitHub Actions job…) or a commit status, folded into one shape.
    public struct Check: Sendable, Hashable, Identifiable {
        public enum State: String, Sendable, Hashable { case pass, fail, pending, skipped, neutral }
        public let name: String
        public let workflow: String?
        public let state: State
        /// The raw conclusion / status (`SUCCESS`, `TIMED_OUT`, `IN_PROGRESS`…).
        public let raw: String
        public let url: String?
        public let completedAt: Date?
        public var id: String { "\(workflow ?? "")/\(name)/\(url ?? "")" }
        public init(name: String, workflow: String? = nil, state: State, raw: String = "", url: String? = nil, completedAt: Date? = nil) {
            self.name = name; self.workflow = workflow; self.state = state; self.raw = raw; self.url = url; self.completedAt = completedAt
        }
    }

    public struct Review: Sendable, Hashable, Identifiable {
        public let id: String
        public let author: String
        /// APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED, PENDING.
        public let state: String
        public let body: String
        public let submittedAt: Date?
        public init(id: String, author: String, state: String, body: String = "", submittedAt: Date? = nil) {
            self.id = id; self.author = author; self.state = state; self.body = body; self.submittedAt = submittedAt
        }
    }

    public struct Comment: Sendable, Hashable, Identifiable {
        public let id: String
        public let author: String
        public let body: String
        public let createdAt: Date?
        public let url: String?
        public init(id: String, author: String, body: String, createdAt: Date? = nil, url: String? = nil) {
            self.id = id; self.author = author; self.body = body; self.createdAt = createdAt; self.url = url
        }
    }

    public struct Label: Sendable, Hashable, Identifiable {
        public let name: String
        /// Hex without `#`.
        public let color: String?
        public var id: String { name }
        public init(name: String, color: String? = nil) { self.name = name; self.color = color }
    }

    public var number: Int
    public var title: String
    public var body: String
    public var url: String
    /// OPEN, CLOSED, MERGED.
    public var state: String
    public var isDraft: Bool
    public var author: Author?
    public var baseRefName: String
    public var headRefName: String
    /// `owner/name` of the head branch's repository (the fork for a cross-repository PR).
    public var headRepository: String?
    public var headOwner: String?
    public var isCrossRepository: Bool
    public var maintainerCanModify: Bool
    public var createdAt: Date?
    public var updatedAt: Date?
    public var mergedAt: Date?
    public var closedAt: Date?
    public var additions: Int
    public var deletions: Int
    public var changedFiles: Int
    public var files: [File]
    public var checks: [Check]
    /// APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED, or nil.
    public var reviewDecision: String?
    public var reviews: [Review]
    /// Logins (or team names) asked to review and not done yet.
    public var reviewRequests: [String]
    public var comments: [Comment]
    /// MERGEABLE, CONFLICTING, UNKNOWN.
    public var mergeable: String?
    /// CLEAN, BLOCKED, BEHIND, DIRTY, UNSTABLE, HAS_HOOKS, DRAFT, UNKNOWN.
    public var mergeStateStatus: String?
    public var labels: [Label]

    public init(number: Int, title: String, body: String = "", url: String = "", state: String = "OPEN", isDraft: Bool = false,
                author: Author? = nil, baseRefName: String = "main", headRefName: String = "", headRepository: String? = nil,
                headOwner: String? = nil, isCrossRepository: Bool = false, maintainerCanModify: Bool = false,
                createdAt: Date? = nil, updatedAt: Date? = nil, mergedAt: Date? = nil, closedAt: Date? = nil,
                additions: Int = 0, deletions: Int = 0, changedFiles: Int = 0, files: [File] = [], checks: [Check] = [],
                reviewDecision: String? = nil, reviews: [Review] = [], reviewRequests: [String] = [], comments: [Comment] = [],
                mergeable: String? = nil, mergeStateStatus: String? = nil, labels: [Label] = []) {
        self.number = number; self.title = title; self.body = body; self.url = url; self.state = state; self.isDraft = isDraft
        self.author = author; self.baseRefName = baseRefName; self.headRefName = headRefName; self.headRepository = headRepository
        self.headOwner = headOwner; self.isCrossRepository = isCrossRepository; self.maintainerCanModify = maintainerCanModify
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.mergedAt = mergedAt; self.closedAt = closedAt
        self.additions = additions; self.deletions = deletions; self.changedFiles = changedFiles; self.files = files; self.checks = checks
        self.reviewDecision = reviewDecision; self.reviews = reviews; self.reviewRequests = reviewRequests; self.comments = comments
        self.mergeable = mergeable; self.mergeStateStatus = mergeStateStatus; self.labels = labels
    }

    // MARK: derived

    public var isOpen: Bool { state == "OPEN" }
    public var isMerged: Bool { state == "MERGED" }

    /// How many checks are in each state.
    public var checkCounts: [Check.State: Int] { checks.reduce(into: [:]) { $0[$1.state, default: 0] += 1 } }

    /// The rollup the Home shows: any failure, else anything running, else passed (nil without checks).
    public var checkRollup: CheckRollup {
        if checks.isEmpty { return .none }
        let c = checkCounts
        if (c[.fail] ?? 0) > 0 { return .fail }
        if (c[.pending] ?? 0) > 0 { return .pending }
        return .pass
    }

    /// Failures first, then running, then the rest; by name inside each group.
    public var sortedChecks: [Check] {
        func rank(_ s: Check.State) -> Int { switch s { case .fail: 0; case .pending: 1; case .pass: 2; case .neutral: 3; case .skipped: 4 } }
        return checks.sorted { rank($0.state) != rank($1.state) ? rank($0.state) < rank($1.state) : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Each reviewer's latest decisive review (approve / request changes / dismissed), else their latest comment-review.
    public var latestReviews: [Review] {
        var out: [String: Review] = [:]
        for r in reviews.sorted(by: { ($0.submittedAt ?? .distantPast) < ($1.submittedAt ?? .distantPast) }) where r.state != "PENDING" {
            if let prev = out[r.author], r.state == "COMMENTED", prev.state != "COMMENTED" { continue }
            out[r.author] = r
        }
        return out.values.sorted { ($0.submittedAt ?? .distantPast) > ($1.submittedAt ?? .distantPast) }
    }

    /// What reviewers asked to change: the body of each reviewer's standing CHANGES_REQUESTED review.
    public var requestedChanges: [Review] { latestReviews.filter { $0.state == "CHANGES_REQUESTED" } }

    /// Comments and reviews that say something, oldest first (the conversation tab).
    public var conversation: [Comment] {
        let fromReviews = reviews.filter { !$0.body.isBlank }.map {
            Comment(id: $0.id, author: $0.author, body: $0.body, createdAt: $0.submittedAt, url: nil)
        }
        return (comments + fromReviews).sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }
}

// MARK: decoding

extension PRDetail: Decodable {
    private struct Login: Decodable {
        let login: String?
        let name: String?
        let is_bot: Bool?
    }
    private struct Repo: Decodable { let nameWithOwner: String?; let name: String? }
    private struct RawFile: Decodable { let path: String; let additions: Int?; let deletions: Int?; let changeType: String? }
    private struct RawCheck: Decodable {
        let __typename: String?
        // CheckRun
        let name: String?; let workflowName: String?; let status: String?; let conclusion: String?; let detailsUrl: String?; let completedAt: String?
        // StatusContext
        let context: String?; let state: String?; let targetUrl: String?
    }
    private struct RawReview: Decodable { let id: String?; let author: Login?; let state: String?; let body: String?; let submittedAt: String? }
    private struct RawComment: Decodable { let id: String?; let author: Login?; let body: String?; let createdAt: String?; let url: String?; let isMinimized: Bool? }
    private struct RawRequest: Decodable { let login: String?; let name: String?; let slug: String? }
    private struct RawLabel: Decodable { let name: String; let color: String? }

    enum CodingKeys: String, CodingKey {
        case number, title, body, url, state, isDraft, author, baseRefName, headRefName, headRepository, headRepositoryOwner
        case isCrossRepository, maintainerCanModify, createdAt, updatedAt, mergedAt, closedAt, additions, deletions, changedFiles
        case files, statusCheckRollup, reviewDecision, reviews, reviewRequests, comments, mergeable, mergeStateStatus, labels
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func date(_ k: CodingKeys) -> Date? { (try? c.decodeIfPresent(String.self, forKey: k)).flatMap { $0 }.flatMap(PierJSON.parseDate) }
        func list<T: Decodable>(_ k: CodingKeys, _ t: T.Type) -> [T] { ((try? c.decodeIfPresent([T].self, forKey: k)) ?? nil) ?? [] }
        func str(_ k: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil }
        func int(_ k: CodingKeys) -> Int { ((try? c.decodeIfPresent(Int.self, forKey: k)) ?? nil) ?? 0 }
        func bool(_ k: CodingKeys) -> Bool { ((try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil) ?? false }

        number = try c.decode(Int.self, forKey: .number)
        title = str(.title) ?? ""
        body = str(.body) ?? ""
        url = str(.url) ?? ""
        state = str(.state) ?? "OPEN"
        isDraft = bool(.isDraft)
        if let a = (try? c.decodeIfPresent(Login.self, forKey: .author)) ?? nil, let login = a.login {
            author = Author(login: login, name: a.name?.nilIfBlank, isBot: a.is_bot ?? false)
        } else { author = nil }
        baseRefName = str(.baseRefName) ?? ""
        headRefName = str(.headRefName) ?? ""
        let repo = (try? c.decodeIfPresent(Repo.self, forKey: .headRepository)) ?? nil
        let owner = (try? c.decodeIfPresent(Login.self, forKey: .headRepositoryOwner)) ?? nil
        headOwner = owner?.login
        headRepository = repo?.nameWithOwner ?? Self.zip2(owner?.login, repo?.name).map { "\($0)/\($1)" }
        isCrossRepository = bool(.isCrossRepository)
        maintainerCanModify = bool(.maintainerCanModify)
        createdAt = date(.createdAt); updatedAt = date(.updatedAt); mergedAt = date(.mergedAt); closedAt = date(.closedAt)
        additions = int(.additions); deletions = int(.deletions); changedFiles = int(.changedFiles)
        files = list(.files, RawFile.self).map { File(path: $0.path, additions: $0.additions ?? 0, deletions: $0.deletions ?? 0, changeType: $0.changeType ?? "MODIFIED") }
        checks = list(.statusCheckRollup, RawCheck.self).compactMap(Self.check)
        reviewDecision = str(.reviewDecision)?.nilIfBlank
        reviews = list(.reviews, RawReview.self).enumerated().map { i, r in
            Review(id: r.id ?? "review-\(i)", author: r.author?.login ?? "?", state: r.state ?? "COMMENTED",
                   body: PRCommands.cleanBody(r.body ?? ""), submittedAt: r.submittedAt.flatMap(PierJSON.parseDate))
        }
        reviewRequests = list(.reviewRequests, RawRequest.self).compactMap { $0.login ?? $0.name ?? $0.slug }
        comments = list(.comments, RawComment.self).enumerated().compactMap { i, r in
            guard r.isMinimized != true else { return nil }
            return Comment(id: r.id ?? "comment-\(i)", author: r.author?.login ?? "?", body: PRCommands.cleanBody(r.body ?? ""),
                           createdAt: r.createdAt.flatMap(PierJSON.parseDate), url: r.url)
        }
        mergeable = str(.mergeable)
        mergeStateStatus = str(.mergeStateStatus)
        labels = list(.labels, RawLabel.self).map { Label(name: $0.name, color: $0.color) }
    }

    private static func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? { if let a, let b { (a, b) } else { nil } }

    private static func check(_ r: RawCheck) -> Check? {
        if r.__typename == "StatusContext" || (r.context != nil && r.name == nil) {
            let s = (r.state ?? "").uppercased()
            let state: Check.State = switch s {
            case "SUCCESS": .pass
            case "FAILURE", "ERROR": .fail
            case "PENDING", "EXPECTED": .pending
            default: .neutral
            }
            return Check(name: r.context ?? "status", workflow: nil, state: state, raw: s, url: r.targetUrl?.nilIfBlank)
        }
        guard let name = r.name else { return nil }
        let status = (r.status ?? "").uppercased()
        let conclusion = (r.conclusion ?? "").uppercased()
        let state: Check.State
        if status != "COMPLETED" && !status.isEmpty { state = .pending }
        else {
            switch conclusion {
            case "SUCCESS": state = .pass
            case "FAILURE", "TIMED_OUT", "CANCELLED", "STARTUP_FAILURE", "ACTION_REQUIRED": state = .fail
            case "SKIPPED": state = .skipped
            case "": state = .pending
            default: state = .neutral   // NEUTRAL, STALE
            }
        }
        return Check(name: name, workflow: r.workflowName?.nilIfBlank, state: state, raw: conclusion.isEmpty ? status : conclusion,
                     url: r.detailsUrl?.nilIfBlank, completedAt: r.completedAt.flatMap(PierJSON.parseDate))
    }
}

/// What `gh pr merge` should do.
public enum PRMergeMethod: String, Sendable, Hashable, CaseIterable {
    case squash, merge, rebase
}

/// `gh pr review` kinds.
public enum PRReviewKind: String, Sendable, Hashable, CaseIterable {
    case approve, requestChanges = "request-changes", comment
}

private extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
