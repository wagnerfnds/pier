import Foundation

/// Git actions are shell strings run through `POST /v1/exec` in the worktree (docs/API.md §8.4): approving (commit, push,
/// PR), discarding, diffs, commit details, status and diff parsing, `gh pr view` and commit messages. Only send commands
/// built here; quote everything else.
public enum GitActions {
    public enum ApproveMode: String, Sendable, Hashable { case commit, push, pr }

    /// base64 of the UTF-8 text (messages travel as base64 so no quoting can break them).
    public static func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    /// POSIX single-quote a string: `it's` -> `'it'\''s'`.
    public static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Generic form (docs §13.4): commit when there are files, push `-u origin HEAD`, open a PR with a title, body and base
    /// (the base without `origin/`).
    public static func approve(hasFiles: Bool, message: String, push: Bool, openPR: (title: String, body: String, base: String)?) -> String {
        var p: [String] = []
        if hasFiles { p.append("git add -A && printf %s '\(b64(message))' | base64 -d | git commit -q -F -") }
        if push { p.append("git push -u origin HEAD 2>&1") }
        if let pr = openPR {
            p.append("printf %s '\(b64(pr.body))' | base64 -d | gh pr create --title \(q(pr.title)) --body-file - --base \(q(pr.base)) 2>&1")
        }
        return p.joined(separator: " && ")
    }

    /// `approveCommand` for a review entry: the message is trimmed; for a PR the subject is the message's first line
    /// (else the first commit's subject, the branch, the worktree) and the body the rest (else a default line).
    public static func approveCommand(for e: ReviewItem, mode: ApproveMode, message: String, openPR: Bool) -> String {
        var parts: [String] = []
        let msg = message.jsTrimmed
        if !e.files.isEmpty { parts.append("git add -A && printf %s '\(b64(msg))' | base64 -d | git commit -q -F -") }
        if mode != .commit { parts.append("git push -u origin HEAD 2>&1") }
        if mode == .pr && openPR {
            let source = !msg.isEmpty ? msg : (e.commits.first.map(\.subject).flatMap { $0.isEmpty ? nil : $0 } ?? (e.branch.flatMap { $0.isEmpty ? nil : $0 } ?? e.worktree))
            var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let subject = lines.removeFirst()
            let rest = lines.joined(separator: "\n").jsTrimmed
            let body = rest.isEmpty ? "Opened from Pier after \(DisplayNames.agentLabel(e.agent)) finished in \(e.worktree)." : rest
            parts.append("printf %s '\(b64(body))' | base64 -d | gh pr create --title \(q(subject.jsTrimmed)) --body-file - --base \(q(baseBranch(e))) 2>&1")
        }
        return parts.joined(separator: " && ")
    }

    /// `(e.base ?? "main").replace(/^origin\//, "")`
    public static func baseBranch(_ e: ReviewItem) -> String {
        let b = e.base ?? "main"
        return b.hasPrefix("origin/") ? String(b.dropFirst("origin/".count)) : b
    }

    /// Throw away uncommitted work (confirm first).
    public static let discard = "git restore --staged . && git checkout -- . && git clean -fd"

    /// Exit 0 => JSON `PullRequest`; nonzero => no PR for the branch.
    public static let prView = "gh pr view --json number,state,isDraft,url,title,reviewDecision 2>/dev/null"

    /// Uncommitted patch of one file (untracked: against /dev/null).
    public static func diffUncommitted(_ f: ReviewFile) -> String {
        f.code == "??"
            ? "git diff --no-color --no-index -- /dev/null \(q(f.path)); true"
            : "git diff --no-color --find-renames HEAD -- \(f.from.map { q($0) + " " } ?? "")\(q(f.path))"
    }

    /// What the branch's commits changed in a file, from where it left `base`.
    public static func diffCommitted(_ f: ReviewFile, base: String) -> String {
        "git diff --no-color --find-renames \(q(base + "...HEAD")) -- \(f.from.map { q($0) + " " } ?? "")\(q(f.path))"
    }

    public static let detailMark = "\n--pier-stat--\n"

    /// The whole message of a commit and how much it changed (`parseCommitDetail` reads the output).
    public static func commitDetail(sha: String) -> String {
        let s = q(sha)
        return "git show -s --format=%B \(s) && printf '\\n--pier-stat--\\n' && { git show --shortstat --format= --diff-merges=first-parent \(s) 2>/dev/null || git show --shortstat --format= \(s); }"
    }

    public struct CommitDetail: Sendable, Hashable {
        public var body: String
        public var files: Int?
        public var added: Int?
        public var removed: Int?
    }

    public static func parseCommitDetail(_ output: String) -> CommitDetail {
        let parts = output.components(separatedBy: detailMark)
        let message = parts.first ?? ""
        let stat = parts.count > 1 ? parts[1] : ""
        let body = message.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n").jsTrimmed
        func n(_ pattern: String) -> Int? { Rx(pattern).match(stat)?[1].flatMap { Int($0) } }
        let files = n(#"(\d+) files? changed"#)
        return CommitDetail(
            body: body, files: files,
            added: files == nil ? nil : (n(#"(\d+) insertions?\(\+\)"#) ?? 0),
            removed: files == nil ? nil : (n(#"(\d+) deletions?\(-\)"#) ?? 0))
    }

    /// "Send back": a prompt the person writes goes in even at a question, hence `force`.
    public static func sendBack(note: String) -> SendRequest {
        SendRequest(text: note.jsTrimmed, enter: true, when: .now, force: true)
    }

    public static let sendBackPrefix = "Changes requested: "

    /// `/https:\/\/\S+\/pull\/\d+/` over a `gh pr create` output.
    public static func pullRequestURL(in output: String) -> String? {
        Rx(#"https:\/\/\S+\/pull\/\d+"#).match(output)?[0]
    }

    public static func parsePullRequest(_ output: String) -> PullRequest? {
        try? JSONDecoder().decode(PullRequest.self, from: Data(output.utf8))
    }

    // MARK: status

    public static let statusMark = "\n--pier-numstat--\n"
    /// One round trip for status and line counts. A repository without commits has no HEAD to diff against.
    public static let statusCommand = "git status --porcelain=v1 -b -z && printf '\\n--pier-numstat--\\n' && { git diff --numstat HEAD 2>/dev/null; true; }"

    public struct FileChange: Sendable, Hashable {
        public var path: String
        public var from: String?
        /// Two-letter porcelain status (`??` untracked).
        public var code: String
        public var added: Int?
        public var removed: Int?
        public var binary: Bool?
    }

    public struct BranchInfo: Sendable, Hashable {
        public var branch = ""
        public var upstream: String?
        public var ahead = 0
        public var behind = 0
    }

    public static func parseStatus(_ output: String) -> (branch: BranchInfo, files: [FileChange]) {
        let sections = output.components(separatedBy: statusMark)
        let statusPart = sections[0]
        let numstat = sections.count > 1 ? sections[1] : ""
        let entries = statusPart.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var branch = BranchInfo()
        var files: [FileChange] = []
        var i = 0
        let head = Rx(#"^## (?:No commits yet on )?([^.\s]+(?:\.(?!\.)[^.\s]+)*)(?:\.\.\.(\S+))?(?: \[(.+)\])?"#)
        while i < entries.count {
            let e = entries[i]
            defer { i += 1 }
            if e.hasPrefix("## ") {
                if let m = head.match(e) {
                    branch.branch = m[1] ?? ""
                    branch.upstream = m[2]
                    let track = m[3] ?? ""
                    branch.ahead = Rx(#"ahead (\d+)"#).match(track)?[1].flatMap(Int.init) ?? 0
                    branch.behind = Rx(#"behind (\d+)"#).match(track)?[1].flatMap(Int.init) ?? 0
                }
                continue
            }
            guard e.count >= 3 else { continue }
            let code = String(e.prefix(2))
            var change = FileChange(path: String(e.dropFirst(3)), from: nil, code: code)
            // A rename or copy is followed by the path it came from.
            if code.first == "R" || code.first == "C", i + 1 < entries.count {
                i += 1
                change.from = entries[i]
            }
            files.append(change)
        }
        for line in numstat.split(separator: "\n") {
            let cols = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard cols.count == 3 else { continue }
            let path = cols[2]
            guard let k = files.firstIndex(where: { $0.path == path || path.hasSuffix("=> \($0.path)}") || path.hasSuffix("=> \($0.path)") }) else { continue }
            if cols[0] == "-" { files[k].binary = true } else {
                files[k].added = Int(cols[0])
                files[k].removed = Int(cols[1])
            }
        }
        return (branch, files)
    }

    /// "New" / "Added" / "Deleted" / "Renamed" / "Modified" for a porcelain code.
    public static func describeCode(_ code: String) -> (label: String, tone: String) {
        if code == "??" { return ("New", "new") }
        switch code.jsTrimmed.first {
        case "A": return ("Added", "add")
        case "D": return ("Deleted", "del")
        case "R": return ("Renamed", "ren")
        default: return ("Modified", "mod")
        }
    }

    // MARK: unified diff

    public struct DiffLine: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable, Hashable { case add, del, ctx, hunk, meta }
        public var kind: Kind
        public var text: String
        public var oldNo: Int?
        public var newNo: Int?
        public let id: Int
    }

    /// Unified diff output -> lines with their numbers (headers dropped; `Binary files` becomes a meta line).
    public static func parseDiff(_ diff: String) -> [DiffLine] {
        var out: [DiffLine] = []
        var oldNo = 0
        var newNo = 0
        let hunk = Rx(#"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$"#)
        let header = Rx(#"^(diff --git|index |--- |\+\+\+ |new file|deleted file|similarity|rename |old mode|new mode|Binary files)"#)
        func push(_ k: DiffLine.Kind, _ t: String, _ o: Int? = nil, _ n: Int? = nil) {
            out.append(DiffLine(kind: k, text: t, oldNo: o, newNo: n, id: out.count))
        }
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let h = hunk.match(line) {
                oldNo = Int(h[1] ?? "") ?? 0
                newNo = Int(h[2] ?? "") ?? 0
                push(.hunk, line)
                continue
            }
            if header.test(line) {
                if line.hasPrefix("Binary files") { push(.meta, "Binary file") }
                continue
            }
            if line.hasPrefix("+") { push(.add, String(line.dropFirst()), nil, newNo); newNo += 1 }
            else if line.hasPrefix("-") { push(.del, String(line.dropFirst()), oldNo, nil); oldNo += 1 }
            else if line.hasPrefix(" ") { push(.ctx, String(line.dropFirst()), oldNo, newNo); oldNo += 1; newNo += 1 }
            else if line.hasPrefix("\\") { push(.meta, String(line.dropFirst(2))) }
        }
        return out
    }

    // MARK: commit message from the agent's summary

    private static let optionRx = Rx(#"^\s*(?:[❯›>]\s*)?\d[.)]\s"#)
    private static let listRx = Rx(#"^\s*(?:[-*•]|\d+[.)])\s"#)

    /// Draft a commit message from the agent's last message (`MenuParser.lastMessage`): its first sentence as the subject,
    /// the rest as the body, without the questions it asked or the options it offered. Without a summary, the branch name.
    public static func commitMessage(summary: [String], branch: String? = nil) -> String {
        var lines: [String] = []
        for l in summary {
            if optionRx.test(l) || l.isBlank { continue }
            if let prev = lines.last, !listRx.test(l), !prev.hasSuffix(":") {
                lines[lines.count - 1] = "\(prev) \(l.jsTrimmed)"
            } else {
                lines.append(l.jsTrimmed)
            }
        }
        let ws = Rx(#"\s+"#)
        let question = Rx(#"[^.!?]*\?(?=\s|$)"#)
        let text = lines
            .map { ws.replacing(question.replacing($0, with: ""), with: " ").jsTrimmed }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if text.isEmpty { return branch.map(humanize) ?? "" }
        // The first sentence ends at . or ! followed by a space or the end.
        let first: String
        if let m = Rx(#"^(.{8,}?[.!])(?=\s|$)"#, dotAll: true).match(text)?[1] { first = m } else { first = text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? text }
        let sentence = ws.replacing(first, with: " ").jsTrimmed
        var subject = Rx(#"[.!]$"#).replacing(sentence, with: "")
        if subject.count > 72 {
            // Prefer ending at a clause before ellipsising.
            let head = String(subject.prefix(74))
            if let r = head.range(of: ", ", options: .backwards), head.distance(from: head.startIndex, to: r.lowerBound) >= 24 {
                subject = String(head[..<r.lowerBound])
            } else {
                subject = Rx(#"\s+\S*$"#).replacing(String(subject.prefix(71)), with: "") + "…"
            }
        }
        // A shortened subject leaves its whole sentence for the body.
        let rest = String(text.dropFirst(first.count)).jsTrimmed
        let body = subject == Rx(#"[.!]$"#).replacing(sentence, with: "") ? rest : [sentence, rest].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return body.isEmpty ? subject : "\(subject)\n\n\(body)"
    }

    static func humanize(_ branch: String) -> String {
        let leaf = branch.split(separator: "/").last.map(String.init) ?? branch
        let words = Rx(#"[-_]+"#).replacing(leaf, with: " ").jsTrimmed
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
