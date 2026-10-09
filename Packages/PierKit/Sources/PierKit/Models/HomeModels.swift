import Foundation

// Models and shell commands for the Home widgets (pull requests, CI failures, git activity, services).
// What `gh`/`git` would compute on a laptop is computed on the box here, through `POST /v1/exec`.
// Every command is read-only (queries only) and ends in a `# pier-home:*` marker.

/// Why `gh` could not answer.
public enum GhProblem: String, Codable, Sendable, Hashable {
    case noGh, noAuth, other
}

public struct HomeError: Error, Sendable, Hashable, LocalizedError, Codable {
    public let problem: GhProblem
    public let message: String
    public init(problem: GhProblem, message: String) { self.problem = problem; self.message = message }
    public var errorDescription: String? { message }
}

public enum CheckRollup: String, Codable, Sendable, Hashable {
    case pass, fail, pending, none
}

public struct HomePR: Codable, Sendable, Hashable, Identifiable {
    public let number: Int
    public let title: String
    public let url: String
    public let repo: String          // owner/name
    public let author: String?
    public let isDraft: Bool
    public let updatedAt: Date?
    public let additions: Int
    public let deletions: Int
    /// APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED or nil.
    public let reviewDecision: String?
    public let checks: CheckRollup

    public var id: String { url }
    public var repoName: String { repo.split(separator: "/").last.map(String.init) ?? repo }

    public init(number: Int, title: String, url: String, repo: String, author: String? = nil, isDraft: Bool = false, updatedAt: Date? = nil, additions: Int = 0, deletions: Int = 0, reviewDecision: String? = nil, checks: CheckRollup = .none) {
        self.number = number; self.title = title; self.url = url; self.repo = repo; self.author = author
        self.isDraft = isDraft; self.updatedAt = updatedAt; self.additions = additions; self.deletions = deletions
        self.reviewDecision = reviewDecision; self.checks = checks
    }
}

public struct HomePRs: Codable, Sendable, Hashable {
    public var viewer: String
    public var review: [HomePR]
    public var mine: [HomePR]
    public var reviewCount: Int
    public var mineCount: Int
    public init(viewer: String = "", review: [HomePR] = [], mine: [HomePR] = [], reviewCount: Int = 0, mineCount: Int = 0) {
        self.viewer = viewer; self.review = review; self.mine = mine; self.reviewCount = reviewCount; self.mineCount = mineCount
    }
}

/// The latest run of a workflow on a branch, when it failed.
public struct CIFailure: Codable, Sendable, Hashable, Identifiable {
    public let repo: String          // owner/name
    public let runID: Int
    public let workflow: String
    public let title: String
    public let branch: String
    public let createdAt: Date
    public let url: String
    public var id: Int { runID }
    public var repoName: String { repo.split(separator: "/").last.map(String.init) ?? repo }
    public init(repo: String, runID: Int, workflow: String, title: String, branch: String, createdAt: Date, url: String) {
        self.repo = repo; self.runID = runID; self.workflow = workflow; self.title = title
        self.branch = branch; self.createdAt = createdAt; self.url = url
    }
}

public struct GitDay: Codable, Sendable, Hashable, Identifiable {
    /// Local calendar day, `yyyy-MM-dd`.
    public let day: String
    public var commits: Int
    public var add: Int
    public var del: Int
    public var id: String { day }
    public init(day: String, commits: Int = 0, add: Int = 0, del: Int = 0) { self.day = day; self.commits = commits; self.add = add; self.del = del }
}

public struct GitActivity: Codable, Sendable, Hashable {
    public var days: [GitDay]
    public var byProject: [Project]
    public struct Project: Codable, Sendable, Hashable, Identifiable {
        public let name: String
        public let commits: Int
        public var id: String { name }
        public init(name: String, commits: Int) { self.name = name; self.commits = commits }
    }
    public var totalCommits: Int { days.reduce(0) { $0 + $1.commits } }
    public var totalAdd: Int { days.reduce(0) { $0 + $1.add } }
    public var totalDel: Int { days.reduce(0) { $0 + $1.del } }
    public init(days: [GitDay] = [], byProject: [Project] = []) { self.days = days; self.byProject = byProject }
}

/// A dev server listening in a worktree (`GET /v1/services`).
public struct BoxService: Codable, Sendable, Hashable, Identifiable {
    public let location: String
    public let worktree: String?
    public let path: String?
    public let port: Int
    public let process: String?
    public let main: Bool?
    public var id: String { "\(location)/\(worktree ?? "")/\(port)" }
    public init(location: String, worktree: String? = nil, path: String? = nil, port: Int, process: String? = nil, main: Bool? = nil) {
        self.location = location; self.worktree = worktree; self.path = path; self.port = port; self.process = process; self.main = main
    }
    enum CodingKeys: String, CodingKey { case location, worktree, path, port, process, main }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        location = try c.decodeIfPresent(String.self, forKey: .location) ?? ""
        worktree = try c.decodeIfPresent(String.self, forKey: .worktree)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
        process = try c.decodeIfPresent(String.self, forKey: .process)
        main = try c.decodeIfPresent(Bool.self, forKey: .main)
    }
}

/// A repo whose git activity is read (index only in the output, so names never touch the shell).
public struct HomeGitProject: Sendable, Hashable {
    public let name: String
    public let path: String
    public init(name: String, path: String) { self.name = name; self.path = path }
}

public enum HomeCommands {
    public static let gitDays = 14
    static let marker = "# pier-home:"

    /// Single-quotes `s` for a POSIX shell.
    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: pull requests (one GraphQL call across every repo of the user)

    static let prFields = "number title url isDraft updatedAt additions deletions reviewDecision repository { nameWithOwner } author { login } commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }"
    static var prQuery: String {
        """
        query {
          viewer { login }
          review: search(query: "is:pr is:open archived:false review-requested:@me sort:updated-desc", type: ISSUE, first: 15) { issueCount nodes { ... on PullRequest { \(prFields) } } }
          mine: search(query: "is:pr is:open archived:false author:@me sort:updated-desc", type: ISSUE, first: 15) { issueCount nodes { ... on PullRequest { \(prFields) } } }
        }
        """
    }

    public static var pullRequests: String {
        "gh api graphql -f query=\(quote(prQuery)) --jq '{viewer: .data.viewer.login, review: .data.review.nodes, mine: .data.mine.nodes, reviewCount: .data.review.issueCount, mineCount: .data.mine.issueCount}' \(marker)prs"
    }

    // MARK: CI (one shell, one `gh run list` per repo in parallel, reduced to the latest failing run per branch+workflow)

    static let ciJQ = #"[.[]|select(.status=="completed")]|group_by([.headBranch,.workflowName])|map(max_by(.createdAt))|map(select(.conclusion|IN("failure","timed_out","startup_failure")))|tojson"#

    /// `repos` are `owner/name` slugs; anything that is not a plain slug is skipped.
    public static func ciFailures(repos: [String]) -> String? {
        let ok = repos.filter { $0.range(of: #"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil }
        guard !ok.isEmpty else { return nil }
        let list = ok.map(quote).joined(separator: " ")
        // Each repo writes its own file, so parallel answers never interleave.
        return """
        d=$(mktemp -d); i=0; for r in \(list); do i=$((i+1)); ( o=$(gh run list -R "$r" --limit 40 --json databaseId,workflowName,displayTitle,headBranch,status,conclusion,createdAt,url --jq \(quote(ciJQ)) 2>"$d/$i.err") && printf '{"repo":"%s","runs":%s}\\n' "$r" "$o" > "$d/$i.json" ) & done; wait; cat "$d"/*.json 2>/dev/null; for f in "$d"/*.err; do [ -s "$f" ] && { printf '#ERR '; head -c 300 "$f" | tr '\\n' ' '; echo; }; done; rm -rf "$d" \(marker)ci
        """
    }

    // MARK: git activity (one shell over the repos' main checkouts, aggregated by local day on the box)

    /// `utcOffset`: seconds east of UTC of the phone, so a "day" is the phone's day.
    public static func gitActivity(projects: [HomeGitProject], utcOffset: Int) -> String? {
        guard !projects.isEmpty else { return nil }
        let awk = #"""
        /^#P /{p=$2; next}
        /^@/{ if(t!=""){k=p" "int((t+off)/86400); C[k]++; A[k]+=a; D[k]+=d}; t=substr($0,2); a=0; d=0; next }
        /insertion|deletion/{ for(i=2;i<=NF;i++){ if($i ~ /^insertion/) a=$(i-1); if($i ~ /^deletion/) d=$(i-1) } }
        END{ if(t!=""){k=p" "int((t+off)/86400); C[k]++; A[k]+=a; D[k]+=d}; for(k in C) print k, C[k], A[k], D[k] }
        """#
        var body = ""
        for (i, p) in projects.enumerated() {
            body += "echo '#P \(i)'; git -C \(quote(p.path)) log --all --no-merges --since=\(gitDays + 1).days.ago --format=@%ct --shortstat 2>/dev/null; "
        }
        return "( \(body)true ) | awk -v off=\(utcOffset) \(quote(awk)) \(marker)git"
    }

    // MARK: parsing

    public static func classify(exitCode: Int, output: String) -> HomeError {
        let text = output.lowercased()
        if exitCode == 127 || text.contains("command not found") { return HomeError(problem: .noGh, message: "gh not installed") }
        if text.contains("gh auth login") || text.contains("authentication") || text.contains("http 401") || text.contains("bad credentials") {
            return HomeError(problem: .noAuth, message: "gh not authenticated")
        }
        let last = output.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return HomeError(problem: .other, message: last.isEmpty ? "gh exited with \(exitCode)" : last)
    }

    static func iso(_ s: String?) -> Date? { s.flatMap(PierJSON.parseDate) }

    /// The JSON object/array line of an output, ignoring any login-shell noise before it.
    static func jsonLines(_ output: String) -> [Data] {
        output.split(whereSeparator: \.isNewline).compactMap { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            return (t.hasPrefix("{") || t.hasPrefix("[")) ? t.data(using: .utf8) : nil
        }
    }

    public static func parsePullRequests(exitCode: Int, output: String) throws -> HomePRs {
        guard exitCode == 0 else { throw classify(exitCode: exitCode, output: output) }
        guard let data = jsonLines(output).first else { throw HomeError(problem: .other, message: "unexpected gh output") }
        struct Raw: Decodable {
            struct PR: Decodable {
                let number: Int; let title: String; let url: String; let isDraft: Bool?
                let updatedAt: String?; let additions: Int?; let deletions: Int?; let reviewDecision: String?
                struct Repo: Decodable { let nameWithOwner: String }
                struct Author: Decodable { let login: String }
                let repository: Repo?; let author: Author?
                struct Commits: Decodable {
                    struct Node: Decodable { struct C: Decodable { struct R: Decodable { let state: String }; let statusCheckRollup: R? }; let commit: C }
                    let nodes: [Node]
                }
                let commits: Commits?
            }
            let viewer: String?; let review: [PR]?; let mine: [PR]?; let reviewCount: Int?; let mineCount: Int?
        }
        let raw: Raw
        do { raw = try JSONDecoder().decode(Raw.self, from: data) } catch { throw HomeError(problem: .other, message: "unexpected gh output") }
        func map(_ p: Raw.PR) -> HomePR {
            let state = p.commits?.nodes.first?.commit.statusCheckRollup?.state
            let checks: CheckRollup = switch state {
            case nil: .none
            case "SUCCESS": .pass
            case "FAILURE", "ERROR": .fail
            default: .pending
            }
            return HomePR(number: p.number, title: p.title, url: p.url, repo: p.repository?.nameWithOwner ?? "", author: p.author?.login,
                          isDraft: p.isDraft ?? false, updatedAt: iso(p.updatedAt), additions: p.additions ?? 0, deletions: p.deletions ?? 0,
                          reviewDecision: (p.reviewDecision?.isEmpty == false) ? p.reviewDecision : nil, checks: checks)
        }
        let review = (raw.review ?? []).map(map), mine = (raw.mine ?? []).map(map)
        return HomePRs(viewer: raw.viewer ?? "", review: review, mine: mine, reviewCount: raw.reviewCount ?? review.count, mineCount: raw.mineCount ?? mine.count)
    }

    /// Failing latest runs of every repo; repos whose `gh` failed are reported in `failedRepos` (an auth problem is thrown when nothing answered).
    public static func parseCIFailures(exitCode: Int, output: String) throws -> [CIFailure] {
        struct Raw: Decodable {
            let repo: String
            struct Run: Decodable { let databaseId: Int; let workflowName: String?; let displayTitle: String?; let headBranch: String?; let createdAt: String?; let url: String }
            let runs: [Run]
        }
        var out: [CIFailure] = []
        var answered = 0
        var errors: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#ERR") { errors.append(String(t.dropFirst(4))); continue }
            guard t.hasPrefix("{"), let data = t.data(using: .utf8), let r = try? JSONDecoder().decode(Raw.self, from: data) else { continue }
            answered += 1
            for run in r.runs {
                out.append(CIFailure(repo: r.repo, runID: run.databaseId, workflow: run.workflowName ?? "", title: run.displayTitle ?? "",
                                     branch: run.headBranch ?? "", createdAt: iso(run.createdAt) ?? .distantPast, url: run.url))
            }
        }
        if answered == 0 {
            if exitCode == 127 { throw classify(exitCode: 127, output: output) }
            if !errors.isEmpty { throw classify(exitCode: 1, output: errors.joined(separator: "\n")) }
            if exitCode != 0 { throw classify(exitCode: exitCode, output: output) }
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    static func dayString(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The last `gitDays` local days ending today, oldest first.
    public static func lastDays(now: Date, calendar: Calendar) -> [String] {
        (0..<gitDays).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: now) }.map { dayString($0, calendar: calendar) }
    }

    /// Output lines are `projectIndex dayNumber commits add del`, `dayNumber` being days since 1970 in the phone's zone.
    public static func parseGitActivity(output: String, projects: [HomeGitProject], now: Date, calendar: Calendar) -> GitActivity {
        var days = Dictionary(uniqueKeysWithValues: lastDays(now: now, calendar: calendar).map { ($0, GitDay(day: $0)) })
        var perProject: [Int: Int] = [:]
        // dayNumber -> yyyy-MM-dd: the day number counts local days, so format it as UTC.
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        for line in output.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: " ")
            guard f.count == 5, let p = Int(f[0]), let dn = Int(f[1]), let c = Int(f[2]), let a = Int(f[3]), let d = Int(f[4]) else { continue }
            let key = dayString(Date(timeIntervalSince1970: Double(dn) * 86400 + 43200), calendar: utc)
            guard days[key] != nil else { continue }
            days[key]!.commits += c; days[key]!.add += a; days[key]!.del += d
            perProject[p, default: 0] += c
        }
        let by = perProject.compactMap { (i, c) -> GitActivity.Project? in
            projects.indices.contains(i) ? .init(name: projects[i].name, commits: c) : nil
        }.sorted { $0.commits != $1.commits ? $0.commits > $1.commits : $0.name < $1.name }
        return GitActivity(days: days.values.sorted { $0.day < $1.day }, byProject: by)
    }
}
