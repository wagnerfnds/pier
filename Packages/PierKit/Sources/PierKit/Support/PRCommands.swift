import Foundation

/// Pull request reads and actions are `gh` / `git` shell strings run through `POST /v1/exec` on the box (like `GitActions`).
/// Every command names the PR by number and `--repo owner/name`, so it works from any location; user text (comments, review
/// bodies) travels as base64 and paths and refs are single-quoted. Only send commands built here.
public enum PRCommands {
    /// The JSON fields of `gh pr view` the PR screen reads (decoded by `PRDetail`).
    public static let viewFields = [
        "number", "title", "body", "url", "state", "isDraft", "author", "baseRefName", "headRefName", "headRepository",
        "headRepositoryOwner", "isCrossRepository", "maintainerCanModify", "createdAt", "updatedAt", "mergedAt", "closedAt",
        "additions", "deletions", "changedFiles", "files", "statusCheckRollup", "reviewDecision", "reviews", "reviewRequests",
        "comments", "mergeable", "mergeStateStatus", "labels",
    ].joined(separator: ",")

    static let marker = "# pier-pr:"

    /// `owner/name`, nothing else (it is quoted anyway; this keeps garbage out of the command line).
    public static func isSlug(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    /// `https://github.com/owner/name/pull/12` -> ("owner/name", 12).
    public static func parseURL(_ url: String) -> (repo: String, number: Int)? {
        guard let m = Rx(#"^https?://[^/]+/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)/pull/(\d+)"#).match(url),
              let repo = m[1], let n = m[2].flatMap(Int.init) else { return nil }
        return (repo, n)
    }

    /// The `owner/name` of a git remote URL (https or ssh), lowercased compare is left to the caller.
    public static func slug(fromRemote remote: String) -> String? {
        guard let m = Rx(#"github\.com[:/]+([A-Za-z0-9._-]+/[A-Za-z0-9._-]+?)(?:\.git)?/?$"#).match(remote) else { return nil }
        return m[1]
    }

    private static func pr(_ number: Int, _ repo: String) -> String { "\(number) --repo \(GitActions.q(repo))" }
    private static func bodyFile(_ text: String) -> String { "printf %s '\(GitActions.b64(text))' | base64 -d | " }

    // MARK: reads

    /// One `gh pr view` with everything the screen shows. Exit 0 => one JSON line.
    public static func view(number: Int, repo: String) -> String {
        "gh pr view \(pr(number, repo)) --json \(viewFields) 2>&1 \(marker)view"
    }

    /// The PR's diff of one file (base...head, as GitHub shows it), cut out of `gh pr diff` on the box so only that file travels.
    /// The path goes through the environment, never through the awk program. gh's own failure is printed with its exit code.
    public static func fileDiff(number: Int, repo: String, path: String) -> String {
        let awk = #"BEGIN{ p = ENVIRON["P"] } /^diff --git /{ on = (substr($0, length($0) - length(p) - 2) == " b/" p) } on"#
        return "P=$(printf %s '\(GitActions.b64(path))' | base64 -d) && export P && t=$(mktemp) && { gh pr diff \(pr(number, repo)) --color=never > \"$t\" 2>&1; c=$?; [ $c -eq 0 ] && awk '\(awk)' \"$t\"; [ $c -eq 0 ] || cat \"$t\"; rm -f \"$t\"; exit $c; } \(marker)diff"
    }

    // MARK: actions

    public static func merge(number: Int, repo: String, method: PRMergeMethod, deleteBranch: Bool) -> String {
        // With --repo, gh deletes only the remote branch (never a local one) after merging.
        "gh pr merge \(pr(number, repo)) --\(method.rawValue)\(deleteBranch ? " --delete-branch" : "") 2>&1"
    }

    public static func comment(number: Int, repo: String, body: String) -> String {
        "\(bodyFile(body))gh pr comment \(pr(number, repo)) --body-file - 2>&1"
    }

    /// Approve (body optional), request changes (body required by GitHub) or comment.
    public static func review(number: Int, repo: String, kind: PRReviewKind, body: String) -> String {
        let text = body.jsTrimmed
        if text.isEmpty { return "gh pr review \(pr(number, repo)) --\(kind.rawValue) 2>&1" }
        return "\(bodyFile(text))gh pr review \(pr(number, repo)) --\(kind.rawValue) --body-file - 2>&1"
    }

    public static func close(number: Int, repo: String) -> String {
        "gh pr close \(pr(number, repo)) 2>&1"
    }

    public static func ready(number: Int, repo: String) -> String {
        "gh pr ready \(pr(number, repo)) 2>&1"
    }

    // MARK: bringing a PR into a worktree

    public static let branchMark = "--pier-branch--"

    /// Same-repository PR, in the main checkout before the worktree is created: makes `origin/<head>` current, so pierd
    /// creates the worktree's branch tracking it (docs/API.md §2.4).
    public static func fetchHead(_ head: String) -> String {
        "git fetch origin \(GitActions.q("+refs/heads/\(head):refs/remotes/origin/\(head)")) 2>&1"
    }

    /// Same-repository PR, inside the new worktree: the branch tracks `origin/<head>` (so a plain `git push` updates the PR)
    /// and catches up with it when an older local branch of that name was checked out. Prints the branch at the end.
    public static func trackHead(_ head: String) -> String {
        let up = GitActions.q("origin/\(head)")
        return "git branch --set-upstream-to=\(up) 2>&1 && { git merge --ff-only -q \(up) 2>&1 || echo 'pier: the local branch has commits the PR does not have; left as is'; } && printf '\\n\(branchMark)\\n%s\\n' \"$(git rev-parse --abbrev-ref HEAD)\""
    }

    /// Fork PR, inside the new worktree (created on the throwaway branch `scratch`): `gh pr checkout` fetches the fork's head
    /// and configures the branch to push back to it. When the head's name is taken by another worktree, the PR is checked out
    /// under `scratch` instead. Prints the branch at the end; the throwaway branch is deleted when it is no longer used.
    public static func checkoutFork(number: Int, repo: String, scratch: String) -> String {
        let s = GitActions.q(scratch)
        return "{ gh pr checkout \(pr(number, repo)) --force 2>&1 || gh pr checkout \(pr(number, repo)) --force --branch \(s) 2>&1; } && b=$(git rev-parse --abbrev-ref HEAD) && { [ \"$b\" = \(s) ] || git branch -D \(s) >/dev/null 2>&1; true; } && printf '\\n\(branchMark)\\n%s\\n' \"$b\""
    }

    /// The branch printed by `trackHead` / `checkoutFork`.
    public static func parseBranch(_ output: String) -> String? {
        guard let r = output.range(of: branchMark, options: .backwards) else { return nil }
        let rest = output[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.split(separator: "\n").first.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A free worktree name for the PR: `pr-<n>`, `pr-<n>-2`, …
    public static func worktreeName(number: Int, taken: Set<String>) -> String {
        let base = "pr-\(number)"
        var n = base, i = 2
        while taken.contains(n) { n = "\(base)-\(i)"; i += 1 }
        return n
    }

    // MARK: parsing

    /// Exit 0 + a JSON line => the PR; otherwise a `HomeError` saying why (`gh` missing, not signed in, or gh's message).
    public static func parseView(exitCode: Int, output: String) throws -> PRDetail {
        guard exitCode == 0 else { throw HomeCommands.classify(exitCode: exitCode, output: output) }
        guard let data = HomeCommands.jsonLines(output).first(where: { $0.first == UInt8(ascii: "{") }) else {
            throw HomeError(problem: .other, message: "unexpected gh output")
        }
        do { return try JSONDecoder().decode(PRDetail.self, from: data) } catch { throw HomeError(problem: .other, message: "unexpected gh output") }
    }

    /// PR text for display: without HTML comments (bots hide markers in them) and the `<details>`/`<summary>` wrappers.
    public static func cleanBody(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\r\n", with: "\n")
        t = Rx(#"<!--[\s\S]*?-->"#).replacing(t, with: "")
        t = Rx(#"</?(details|summary|sub|sup)[^>]*>"#).replacing(t, with: "")
        t = Rx(#"<br\s*/?>"#).replacing(t, with: "\n")
        t = Rx(#"\n{3,}"#).replacing(t, with: "\n\n")
        return t.jsTrimmed
    }

    // MARK: the agent's first prompt

    /// The sentences of the agent's first prompt. The app passes localized ones; the defaults are English.
    public struct PromptText: Sendable {
        public var intro: @Sendable (_ number: Int, _ title: String, _ author: String, _ url: String) -> String = { "Continue the work on PR #\($0) (\($1)) by @\($2): \($3)" }
        public var branch: @Sendable (_ branch: String) -> String = { "You are on the PR's branch `\($0)`. Commit and run `git push` when done: it updates the PR." }
        public var forkNoEdit = "The author does not allow maintainers to push to the fork, so pushing will fail: tell me before trying."
        public var requested = "Reviewers asked for changes:"
        public var inline: @Sendable (_ repo: String, _ number: Int) -> String = { "Read the review comments on the code too: `gh api repos/\($0)/pulls/\($1)/comments`." }
        public var task = "Address the requested changes, run the tests, and tell me what you changed."
        public var taskNoReview: @Sendable (_ number: Int, _ repo: String) -> String = { "Read the PR (`gh pr view \($0) --repo \($1) --comments`) and its diff, then tell me what is left to do before changing anything." }
        public init() {}
    }

    /// The prompt "Continuar com um agente" starts from: what the PR is, which branch the agent is on and that a push updates
    /// the PR, and what the reviewers asked for (each reviewer's standing "changes requested" review).
    public static func agentPrompt(_ pr: PRDetail, repo: String, branch: String, text: PromptText = PromptText()) -> String {
        var parts: [String] = []
        parts.append(text.intro(pr.number, pr.title, pr.author?.login ?? "?", pr.url))
        parts.append(text.branch(branch))
        if pr.isCrossRepository && !pr.maintainerCanModify { parts.append(text.forkNoEdit) }
        let asks = pr.requestedChanges
        if !asks.isEmpty {
            var block = text.requested
            for r in asks {
                let body = r.body.jsTrimmed
                block += "\n- @\(r.author)" + (body.isEmpty ? "" : ": " + body.replacingOccurrences(of: "\n", with: "\n  "))
            }
            parts.append(block)
            parts.append(text.inline(repo, pr.number))
            parts.append(text.task)
        } else {
            parts.append(text.taskNoReview(pr.number, repo))
        }
        return parts.joined(separator: "\n\n")
    }
}

