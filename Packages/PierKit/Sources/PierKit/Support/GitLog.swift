import Foundation

/// A worktree's history, read through `POST /v1/exec` like every other git command (docs/API.md §8: there is no git
/// API beyond review data): the log a page at a time with what is not pushed yet, one commit's message and files, and
/// one file's patch in a commit. Each command ends with a `# pier-log:` comment so a mock box (and the box's logs) can
/// tell them apart. Fields travel separated by ASCII unit/record separators, which no name or subject contains.
///
/// Every command runs from the worktree's top folder, the root the file routes use: a location can be a folder inside
/// a repository, where `exec` would otherwise run. And git runs without what the box's user may have configured that
/// would change its output: signature checks printed before each commit, an external diff tool.
public enum GitLog {
    static let marker = "# pier-log:"
    static let top = "cd \"$(git rev-parse --show-toplevel 2>/dev/null || pwd)\""
    static let git = "git -c log.showSignature=false"
    static let unpushedMark = "\n--pier-log--\n"
    static let filesMark = "\n--pier-files--\n"
    static let numstatMark = "\n--pier-numstat--\n"
    static let field: Character = "\u{1f}"
    static let record: Character = "\u{1e}"

    /// Commits a page shows at a time.
    public static let pageSize = 60

    public struct Entry: Sendable, Hashable, Identifiable {
        public let sha: String
        public let short: String
        public let parents: [String]
        public let author: String
        public let email: String
        public let date: Date?
        /// Branch and tag names pointing here, as git decorates them in full: "HEAD -> refs/heads/main",
        /// "refs/remotes/origin/main", "tag: refs/tags/v1.2" (`decorations` reads them).
        public let refs: [String]
        public let subject: String
        /// On this branch but not on its upstream yet.
        public var unpushed: Bool

        public var id: String { sha }
        public var isMerge: Bool { parents.count > 1 }
        public var decorations: [Ref] { refs.map(GitLog.ref) }

        public init(sha: String, short: String, parents: [String] = [], author: String = "", email: String = "", date: Date? = nil,
                    refs: [String] = [], subject: String = "", unpushed: Bool = false) {
            self.sha = sha
            self.short = short
            self.parents = parents
            self.author = author
            self.email = email
            self.date = date
            self.refs = refs
            self.subject = subject
            self.unpushed = unpushed
        }
    }

    public struct Page: Sendable, Hashable {
        public var entries: [Entry]
        /// There are older commits after this page.
        public var hasMore: Bool
        /// The branch has no commit yet.
        public var empty: Bool
        /// Every commit the upstream lacks, on this page or not.
        public var unpushed: Set<String>

        public init(entries: [Entry] = [], hasMore: Bool = false, empty: Bool = false, unpushed: Set<String> = []) {
            self.entries = entries
            self.hasMore = hasMore
            self.empty = empty
            self.unpushed = unpushed
        }
    }

    /// The list on screen after reading the first page again (an agent committed, a push): the new first page, then the
    /// older pages already read when the page ends inside them, so a refresh doesn't take away what was scrolled to;
    /// what is pushed now loses its mark. History rewritten under the page (a rebase, a reset) starts over from it.
    public static func refreshed(_ entries: [Entry], hasMore: Bool, with page: Page) -> (entries: [Entry], hasMore: Bool) {
        guard page.hasMore, let last = page.entries.last, let k = entries.firstIndex(where: { $0.sha == last.sha }) else {
            return (page.entries, page.hasMore)
        }
        let older = entries[(k + 1)...].map { e in
            var e = e
            e.unpushed = page.unpushed.contains(e.sha)
            return e
        }
        return (page.entries + older, hasMore)
    }

    /// A name a commit is decorated with.
    public struct Ref: Sendable, Hashable {
        public enum Kind: Sendable, Hashable { case branch, remote, tag, head, other }
        /// As people say it: "main", "origin/main", "v1.2".
        public let name: String
        public let kind: Kind
        /// The branch checked out (HEAD points at it).
        public let current: Bool

        public init(name: String, kind: Kind, current: Bool = false) {
            self.name = name
            self.kind = kind
            self.current = current
        }
    }

    /// One of `%D`'s names. Full ones tell a local branch from a remote one ("refs/heads/fix/x", "refs/remotes/origin/x");
    /// a short one (an older git) is guessed: a slash means a remote.
    public static func ref(_ raw: String) -> Ref {
        var r = raw.trimmingCharacters(in: .whitespaces)
        var current = false
        if r.hasPrefix("HEAD -> ") { r.removeFirst(8); current = true }
        if r == "HEAD" { return Ref(name: r, kind: .head) }
        if r.hasPrefix("tag: ") {
            r.removeFirst(5)
            return Ref(name: r.hasPrefix("refs/tags/") ? String(r.dropFirst(10)) : r, kind: .tag)
        }
        if r.hasPrefix("refs/heads/") { return Ref(name: String(r.dropFirst(11)), kind: .branch, current: current) }
        if r.hasPrefix("refs/remotes/") { return Ref(name: String(r.dropFirst(13)), kind: .remote) }
        if r.hasPrefix("refs/") { return Ref(name: String(r.dropFirst(5)), kind: .other) }
        if current { return Ref(name: r, kind: .branch, current: true) }
        if r == "grafted" { return Ref(name: r, kind: .other) }
        return Ref(name: r, kind: r.contains("/") ? .remote : .branch)
    }

    // MARK: the log

    /// `limit` commits after the first `skip`, newest first (one more than asked, to know whether there are older
    /// ones), after the commits the upstream lacks. `path` narrows it to one file or folder (following renames for
    /// a file).
    public static func command(limit: Int = pageSize, skip: Int = 0, path: String? = nil, follow: Bool = false) -> String {
        let format = "%x1e%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%aI%x1f%D%x1f%s"
        var log = "\(git) log --no-color --decorate=full --format='\(format)' -n \(max(1, limit) + 1) --skip \(max(0, skip))"
        if let path, !path.isEmpty { log += (follow ? " --follow" : "") + " -- \(GitActions.q(path))" }
        return "\(top) && { git rev-list '@{u}..HEAD' 2>/dev/null; true; } && printf '\\n--pier-log--\\n' && \(log) 2>&1 \(marker)log"
    }

    /// Reads `command`'s output; `limit` is the page size it was asked for.
    public static func parse(_ output: String, limit: Int = pageSize) -> Page {
        let parts = output.components(separatedBy: unpushedMark)
        let unpushed = Set((parts.count > 1 ? parts[0] : "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 7 && $0.allSatisfy(\.isHexDigit) })
        let log = parts.count > 1 ? parts[1] : output
        var entries: [Entry] = []
        for rec in log.split(separator: record, omittingEmptySubsequences: true) {
            let f = rec.split(separator: field, maxSplits: 7, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 8, f[0].count >= 7, f[0].allSatisfy(\.isHexDigit) else { continue }
            let subject = f[7].trimmingCharacters(in: .newlines)
            let refs = f[6].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            entries.append(Entry(sha: f[0], short: f[1], parents: f[2].split(separator: " ").map(String.init), author: f[3], email: f[4],
                                 date: RFC3339.parse(f[5].trimmingCharacters(in: .whitespaces)), refs: refs, subject: subject,
                                 unpushed: unpushed.contains(f[0])))
        }
        let more = entries.count > limit
        if more { entries.removeLast(entries.count - limit) }
        let empty = entries.isEmpty && (log.contains("does not have any commits yet") || log.contains("bad default revision 'HEAD'"))
        return Page(entries: entries, hasMore: more, empty: empty, unpushed: unpushed)
    }

    // MARK: one commit

    public struct FileChange: Sendable, Hashable, Identifiable {
        public let path: String
        /// Where a rename or copy came from.
        public let from: String?
        /// git's one-letter status: A, M, D, R, C, T.
        public let status: String
        public var added: Int?
        public var removed: Int?
        public var binary: Bool

        public var id: String { path }

        public init(path: String, from: String? = nil, status: String, added: Int? = nil, removed: Int? = nil, binary: Bool = false) {
            self.path = path
            self.from = from
            self.status = status
            self.added = added
            self.removed = removed
            self.binary = binary
        }
    }

    public struct Detail: Sendable, Hashable {
        public var entry: Entry
        /// The whole message: subject, blank line, body.
        public var message: String
        public var committer: String
        public var committed: Date?
        public var files: [FileChange]
        /// The file list was cut (a very large commit).
        public var truncated: Bool

        /// The message without its first line.
        public var body: String {
            message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        public var added: Int { files.reduce(0) { $0 + ($1.added ?? 0) } }
        public var removed: Int { files.reduce(0) { $0 + ($1.removed ?? 0) } }
    }

    /// What `exec` keeps of its output is the last 64 KB: the commit's header and message, then each of its two file
    /// lists, are cut to fit in it together (a long squash-merge message, a commit of thousands of files).
    static let headerBytes = 16_000
    static let fileListBytes = 22_000

    /// The commit's message and authorship, then its files with their status and line counts (a merge against its
    /// first parent).
    public static func showCommand(sha: String) -> String {
        let s = GitActions.q(sha)
        let format = "%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%aI%x1f%cn%x1f%cI%x1f%D%x1f%B"
        func files(_ what: String) -> String {
            "{ \(git) show --no-color --no-ext-diff --format= \(what) -z --find-renames --diff-merges=first-parent \(s) 2>/dev/null || \(git) show --no-color --no-ext-diff --format= \(what) -z --find-renames \(s); } | head -c \(fileListBytes)"
        }
        return "\(top) && \(git) show -s --no-color --decorate=full --format='\(format)' \(s) | head -c \(headerBytes) && printf '\\n--pier-files--\\n' && \(files("--name-status")) && printf '\\n--pier-numstat--\\n' && \(files("--numstat")) \(marker)show"
    }

    public static func parseShow(_ output: String) -> Detail? {
        let a = output.components(separatedBy: filesMark)
        let head = a[0]
        let rest = a.count > 1 ? a[1] : ""
        let b = rest.components(separatedBy: numstatMark)
        let nameStatus = b[0]
        let numstat = b.count > 1 ? b[1] : ""
        let f = head.split(separator: field, maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
        guard f.count == 10 else { return nil }
        let sha = f[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard sha.count >= 7, sha.allSatisfy(\.isHexDigit) else { return nil }
        // "\r\n" is one Character to Swift: a message written with Windows line ends would never split into lines.
        let message = f[9].replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = Entry(sha: sha, short: f[1], parents: f[2].split(separator: " ").map(String.init), author: f[3], email: f[4],
                          date: RFC3339.parse(f[5]), refs: f[8].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                          subject: message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "")
        var (files, cut) = parseNameStatus(nameStatus)
        let counts = parseNumstat(numstat)
        for i in files.indices {
            if let c = counts[files[i].path] {
                files[i].added = c.added
                files[i].removed = c.removed
                files[i].binary = c.binary
            }
        }
        cut = cut || nameStatus.utf8.count >= fileListBytes
        return Detail(entry: entry, message: message, committer: f[6], committed: RFC3339.parse(f[7]), files: files, truncated: cut)
    }

    /// The NUL-ended fields of a `-z` list, and whether the byte cap cut it: anything after the last NUL is a field cut
    /// in two, and is dropped.
    static func fields(_ s: String) -> (parts: [String], cut: Bool) {
        var parts = s.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        let cut = parts.last?.isEmpty == false
        parts.removeLast()
        return (parts, cut)
    }

    /// `--name-status -z`: "M\0path\0", "R087\0from\0to\0". A record cut at the end (the byte cap) is dropped.
    static func parseNameStatus(_ s: String) -> (files: [FileChange], cut: Bool) {
        let (parts, cutField) = fields(s)
        var out: [FileChange] = []
        var i = 0
        while i < parts.count {
            let code = parts[i].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let letter = code.first, letter.isLetter else { i += 1; continue }
            if letter == "R" || letter == "C" {
                guard i + 2 < parts.count else { return (out, true) }
                out.append(FileChange(path: parts[i + 2], from: parts[i + 1], status: String(letter)))
                i += 3
            } else {
                guard i + 1 < parts.count else { return (out, true) }
                out.append(FileChange(path: parts[i + 1], status: String(letter)))
                i += 2
            }
        }
        return (out, cutField)
    }

    /// `--numstat -z`: "3\t1\tpath\0", a rename "3\t1\t\0from\0to\0", a binary "-\t-\tpath\0". Keyed by the new path.
    static func parseNumstat(_ s: String) -> [String: (added: Int?, removed: Int?, binary: Bool)] {
        let parts = fields(s).parts
        var out: [String: (added: Int?, removed: Int?, binary: Bool)] = [:]
        var i = 0
        while i < parts.count {
            let cols = parts[i].trimmingCharacters(in: .newlines).split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard cols.count == 3 else { i += 1; continue }
            let binary = cols[0] == "-"
            var path = cols[2]
            if path.isEmpty {
                guard i + 2 < parts.count else { break }
                path = parts[i + 2]
                i += 3
            } else {
                i += 1
            }
            out[path] = (Int(cols[0]), Int(cols[1]), binary)
        }
        return out
    }

    /// One file's patch in a commit (a merge against its first parent; the root commit as all added).
    public static func fileDiffCommand(sha: String, path: String, from: String? = nil) -> String {
        let s = GitActions.q(sha)
        let paths = (from.map { GitActions.q($0) + " " } ?? "") + GitActions.q(path)
        let show = "\(git) show --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ --format= --find-renames"
        return "\(top) && { \(show) --diff-merges=first-parent \(s) -- \(paths) 2>/dev/null || \(show) \(s) -- \(paths); } \(marker)diff"
    }
}
