import Foundation
import Testing

@testable import PierKit

@Suite struct GitActionsTests {
    private func review(files: Bool = true, base: String? = "origin/main", branch: String? = "fix-login", commits: [ReviewCommit] = []) -> ReviewItem {
        ReviewItem(
            location: "shop", worktree: "fix-login", path: "/w", branch: branch, base: base,
            files: files ? [ReviewFile(path: "a.ts", code: " M")] : [], commits: commits, agent: "claude")
    }

    @Test func quoting() {
        #expect(GitActions.q("plain") == "'plain'")
        #expect(GitActions.q("it's") == #"'it'\''s'"#)
        #expect(GitActions.q("") == "''")
        #expect(GitActions.q("$(rm -rf /) `x` \"y\"") == #"'$(rm -rf /) `x` "y"'"#)
        #expect(GitActions.b64("héllo\nworld") == "aMOpbGxvCndvcmxk")
    }

    @Test func approveGeneric() {
        let msg = "Add subtract\n\nBody line"
        #expect(GitActions.approve(hasFiles: true, message: msg, push: false, openPR: nil)
            == "git add -A && printf %s 'QWRkIHN1YnRyYWN0CgpCb2R5IGxpbmU=' | base64 -d | git commit -q -F -")
        #expect(GitActions.approve(hasFiles: false, message: msg, push: true, openPR: nil) == "git push -u origin HEAD 2>&1")
        let full = GitActions.approve(hasFiles: true, message: "m", push: true, openPR: (title: "It's a title", body: "body", base: "main"))
        #expect(full == "git add -A && printf %s 'bQ==' | base64 -d | git commit -q -F - && git push -u origin HEAD 2>&1 && printf %s 'Ym9keQ==' | base64 -d | gh pr create --title 'It'\\''s a title' --body-file - --base 'main' 2>&1")
        #expect(GitActions.approve(hasFiles: false, message: "", push: false, openPR: nil) == "")
    }

    @Test func approveCommandMatchesDesktop() {
        let e = review()
        #expect(GitActions.approveCommand(for: e, mode: .commit, message: "  Fix login\n", openPR: true)
            == "git add -A && printf %s 'Rml4IGxvZ2lu' | base64 -d | git commit -q -F -")
        #expect(GitActions.approveCommand(for: e, mode: .push, message: "Fix login", openPR: true).hasSuffix(" && git push -u origin HEAD 2>&1"))
        // PR: subject = first line, body = rest, base without origin/
        let pr = GitActions.approveCommand(for: e, mode: .pr, message: "Fix login\n\nDetails here", openPR: true)
        #expect(pr.hasSuffix("&& printf %s 'RGV0YWlscyBoZXJl' | base64 -d | gh pr create --title 'Fix login' --body-file - --base 'main' 2>&1"))
        // PR already open: push only
        #expect(!GitActions.approveCommand(for: e, mode: .pr, message: "x", openPR: false).contains("gh pr create"))
        // nothing to commit: no commit part
        let clean = GitActions.approveCommand(for: review(files: false), mode: .pr, message: "Fix login", openPR: true)
        #expect(clean.hasPrefix("git push -u origin HEAD 2>&1 && printf %s '"))
        // empty message falls back to the first commit subject, default body names the agent
        let withCommit = review(files: false, commits: [ReviewCommit(sha: "s", subject: "Earlier commit")])
        let fb = GitActions.approveCommand(for: withCommit, mode: .pr, message: "", openPR: true)
        #expect(fb.contains("--title 'Earlier commit'"))
        #expect(fb.contains(GitActions.b64("Opened from Pier after Claude Code finished in fix-login.")))
        #expect(GitActions.baseBranch(review(base: nil)) == "main")
        #expect(GitActions.baseBranch(review(base: "origin/release/1")) == "release/1")
    }

    @Test func fixedCommands() {
        #expect(GitActions.discard == "git restore --staged . && git checkout -- . && git clean -fd")
        #expect(GitActions.prView == "gh pr view --json number,state,isDraft,url,title,reviewDecision 2>/dev/null")
    }

    @Test func diffCommands() {
        #expect(GitActions.diffUncommitted(ReviewFile(path: "a b.ts", code: " M")) == "git diff --no-color --find-renames HEAD -- 'a b.ts'")
        #expect(GitActions.diffUncommitted(ReviewFile(path: "new.ts", code: "??")) == "git diff --no-color --no-index -- /dev/null 'new.ts'; true")
        #expect(GitActions.diffUncommitted(ReviewFile(path: "n.ts", from: "o.ts", code: "R ")) == "git diff --no-color --find-renames HEAD -- 'o.ts' 'n.ts'")
        #expect(GitActions.diffCommitted(ReviewFile(path: "n.ts", from: "o.ts", code: "R"), base: "origin/main")
            == "git diff --no-color --find-renames 'origin/main...HEAD' -- 'o.ts' 'n.ts'")
        #expect(GitActions.diffUncommitted(ReviewFile(path: "it's.ts", code: " M")).hasSuffix(#"'it'\''s.ts'"#))
    }

    @Test func commandsWeSentToTheRealBoxAreThese() throws {
        // The fixtures were produced by sending exactly these strings (the commit one with the base64 of "Add subtract function\n\nBody line").
        let diff: ExecResult = try Fixture.decode("exec_diff.json")
        #expect(diff.exitCode == 0 && diff.output.hasPrefix("diff --git a/calc.py b/calc.py"))
        let lines = GitActions.parseDiff(diff.output)
        #expect(lines.map(\.kind) == [.hunk, .ctx, .ctx, .add, .add, .add])
        #expect(lines[3].newNo == 3 && lines[1].oldNo == 1 && lines[1].newNo == 1)
        let untracked: ExecResult = try Fixture.decode("exec_diff_untracked.json")
        #expect(GitActions.parseDiff(untracked.output).filter { $0.kind == .add }.count == 3)
        let pr: ExecResult = try Fixture.decode("exec_pr_view.json")
        #expect(pr.exitCode == 1 && GitActions.parsePullRequest(pr.output) == nil)
        let status: ExecResult = try Fixture.decode("exec_status.json")
        let st = GitActions.parseStatus(status.output)
        #expect(st.branch.branch == "subtract")
        #expect(st.files.map(\.code) == [" M", "??", "??"])
        #expect(st.files.map(\.path) == ["calc.py", "probe_dir/", "test_calc.py"])
        #expect(st.files[0].added == 3 && st.files[0].removed == 0)
    }

    @Test func parsePullRequestAndURL() {
        let json = #"{"number":7,"state":"OPEN","isDraft":false,"url":"https://github.com/o/r/pull/7","title":"T","reviewDecision":"APPROVED"}"#
        let pr = GitActions.parsePullRequest(json)
        #expect(pr?.number == 7 && pr?.state == "OPEN" && pr?.reviewDecision == "APPROVED")
        #expect(GitActions.pullRequestURL(in: "Creating...\nhttps://github.com/o/r/pull/42\n") == "https://github.com/o/r/pull/42")
        #expect(GitActions.pullRequestURL(in: "nothing") == nil)
    }

    @Test func statusParsing() {
        let out = "## main...origin/main [ahead 2, behind 1]\0R  new.ts\0old.ts\0 M a.ts\0?? b.ts\0\n--pier-numstat--\n4\t1\ta.ts\n-\t-\tlogo.png\n"
        let s = GitActions.parseStatus(out)
        #expect(s.branch.branch == "main" && s.branch.upstream == "origin/main" && s.branch.ahead == 2 && s.branch.behind == 1)
        #expect(s.files.count == 3)
        #expect(s.files[0].code == "R " && s.files[0].path == "new.ts" && s.files[0].from == "old.ts")
        #expect(s.files[1].added == 4 && s.files[1].removed == 1)
        #expect(GitActions.parseStatus("## No commits yet on main\0?? a\0").branch.branch == "main")
        #expect(GitActions.describeCode("??").label == "New" && GitActions.describeCode("A ").label == "Added" && GitActions.describeCode(" D").label == "Deleted")
    }

    @Test func commitDetail() {
        #expect(GitActions.commitDetail(sha: "abc").hasPrefix("git show -s --format=%B 'abc' && printf '\\n--pier-stat--\\n' && {"))
        let d = GitActions.parseCommitDetail("Subject\n\nBody text\n\n--pier-stat--\n 3 files changed, 10 insertions(+), 2 deletions(-)\n")
        #expect(d.body == "Body text" && d.files == 3 && d.added == 10 && d.removed == 2)
        #expect(GitActions.parseCommitDetail("Only subject").files == nil)
    }

    @Test func sendBack() {
        let r = GitActions.sendBack(note: "Changes requested: rename it ")
        #expect(r.text == "Changes requested: rename it" && r.when == .now && r.force == true && r.enter == true)
    }

    @Test func commitMessageDraft() {
        #expect(GitActions.commitMessage(summary: ["Added the subtract function to calc.py.", "It returns a - b."], branch: "x")
            == "Added the subtract function to calc.py\n\nIt returns a - b.")
        #expect(GitActions.commitMessage(summary: [], branch: "feat/fix-login_flow") == "Fix login flow")
        // wrapped lines are rejoined, questions and options dropped
        let wrapped = GitActions.commitMessage(summary: ["I changed the retry logic so that", "failures back off. Want me to also add jitter?", "❯ 1. Yes", "  2. No"], branch: nil)
        #expect(wrapped.hasPrefix("I changed the retry logic so that failures back off"))
        #expect(!wrapped.contains("jitter") && !wrapped.contains("Yes"))
        // long first sentence is cut at a clause
        let long = "Refactored the webhook retry handler to use exponential backoff, which keeps the queue healthy under sustained load from partners."
        let m = GitActions.commitMessage(summary: [long])
        #expect(m.hasPrefix("Refactored the webhook retry handler to use exponential backoff\n\n"))
        #expect(m.hasSuffix("partners."))
    }
}

@Suite struct AIDraftTests {
    @Test func parsesTheThreeBlocks() {
        let out = """
        Sure.
        <<<COMMIT
        Add retry backoff to the webhook sender

        - exponential backoff, capped at 5 tries
        >>>
        <<<TITLE
        Webhook: exponential retry backoff
        >>>
        <<<BODY
        ## Summary
        - Retries back off exponentially
        >>>
        """
        let d = AIDraft.parse(out)
        #expect(d?.commit.hasPrefix("Add retry backoff to the webhook sender\n\n- exponential") == true)
        #expect(d?.title == "Webhook: exponential retry backoff")
        #expect(d?.body == "## Summary\n- Retries back off exponentially")
    }

    @Test func missingBlocksFallBackOrFail() {
        #expect(AIDraft.parse("claude: command failed") == nil)
        let d = AIDraft.parse("<<<COMMIT\nFix login\n\nBody\n>>>")
        #expect(d?.title == "Fix login")
        #expect(d?.body == "")
    }

    @Test func commandQuotesTheBaseAndEmbedsThePrompt() {
        let c = AIDraft.command(base: "it's", task: "Corrija o login")
        #expect(c.contains("origin/'it'\\''s'"))
        #expect(c.contains("--model haiku"))
        #expect(c.contains("exit 3"))
    }
}
