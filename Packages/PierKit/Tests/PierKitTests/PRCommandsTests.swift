import XCTest
@testable import PierKit

final class PRCommandsTests: XCTestCase {
    private func view(_ fixture: String) throws -> PRDetail {
        let r = try JSONDecoder.pier.decode(ExecResult.self, from: Fixture.data(fixture))
        return try PRCommands.parseView(exitCode: r.exitCode, output: r.output)
    }

    // MARK: parsing real `gh pr view --json` output

    func testParsesAMergedPRWithoutChecksOrReviews() throws {
        let pr = try view("exec_gh_pr_view_merged.json")
        XCTAssertEqual(pr.number, 151)
        XCTAssertEqual(pr.state, "MERGED")
        XCTAssertTrue(pr.isMerged)
        XCTAssertFalse(pr.isOpen)
        XCTAssertEqual(pr.author?.login, "octocat")
        XCTAssertEqual(pr.author?.name, "Mona Octocat")
        XCTAssertEqual(pr.baseRefName, "main")
        XCTAssertEqual(pr.headRefName, "chore/remove-exports")
        XCTAssertEqual(pr.headRepository, "octocat/acme-web")
        XCTAssertFalse(pr.isCrossRepository)
        XCTAssertEqual(pr.additions, 183)
        XCTAssertEqual(pr.deletions, 838)
        XCTAssertEqual(pr.changedFiles, 87)
        XCTAssertEqual(pr.files.count, 87)
        XCTAssertEqual(pr.files[0].path, ".claude/skills/release-notes/SKILL.md")
        XCTAssertEqual(pr.files[0].code, "M")
        XCTAssertNil(pr.reviewDecision, "an empty reviewDecision is no decision")
        XCTAssertTrue(pr.checks.isEmpty)
        XCTAssertEqual(pr.checkRollup, CheckRollup.none)
        XCTAssertTrue(pr.body.contains("**Exports**"))
        XCTAssertNotNil(pr.mergedAt)
        XCTAssertEqual(pr.url, "https://github.com/octocat/acme-web/pull/151")
    }

    func testParsesAForkPRWithChecksAndRequestedReviewers() throws {
        let pr = try view("exec_gh_pr_view_fork.json")
        XCTAssertEqual(pr.number, 14617)
        XCTAssertTrue(pr.isOpen)
        XCTAssertTrue(pr.isCrossRepository)
        XCTAssertTrue(pr.maintainerCanModify)
        XCTAssertEqual(pr.headRepository, "bingtang9/cli")
        XCTAssertEqual(pr.headOwner, "bingtang9")
        XCTAssertEqual(pr.reviewDecision, "REVIEW_REQUIRED")
        XCTAssertEqual(pr.reviewRequests, ["tidy-dev"])
        XCTAssertEqual(pr.mergeable, "MERGEABLE")
        XCTAssertEqual(pr.mergeStateStatus, "BLOCKED")
        XCTAssertEqual(pr.labels.map(\.name), ["needs-triage", "external"])
        XCTAssertEqual(pr.labels[0].color, "D6393F")
        XCTAssertFalse(pr.checks.isEmpty)
        let triage = try XCTUnwrap(pr.checks.first { $0.name == "label-external / label_issues" })
        XCTAssertEqual(triage.state, .pass)
        XCTAssertEqual(triage.workflow, "PR Triaging")
        XCTAssertTrue(triage.url?.hasPrefix("https://github.com/cli/cli/actions/runs/") == true)
        XCTAssertEqual(pr.checks.first { $0.name.hasPrefix("close-from-default-branch") }?.state, .skipped)
    }

    func testParsesReviewsAndHidesBotMarkup() throws {
        let pr = try view("exec_gh_pr_view_approved.json")
        XCTAssertEqual(pr.reviewDecision, "APPROVED")
        XCTAssertEqual(pr.reviews.count, 2)
        XCTAssertEqual(pr.reviews[1].author, "tidy-dev")
        XCTAssertEqual(pr.reviews[1].state, "APPROVED")
        let copilot = pr.reviews[0]
        XCTAssertFalse(copilot.body.contains("<!--"), "HTML comments are dropped")
        XCTAssertFalse(copilot.body.contains("<details>"))
        XCTAssertTrue(copilot.body.hasPrefix("## Copilot review overview"))
        // The latest decisive review per person; the comment-only one stays because it is that person's only review.
        XCTAssertEqual(Set(pr.latestReviews.map(\.author)), ["tidy-dev", "copilot-pull-request-reviewer"])
        XCTAssertTrue(pr.requestedChanges.isEmpty)
        // The conversation holds reviews with a body, not the empty approval.
        XCTAssertEqual(pr.conversation.map(\.author), ["copilot-pull-request-reviewer"])
        XCTAssertEqual(pr.checkRollup, .pass)
    }

    func testParsesChangesRequestedAndComments() throws {
        let pr = try view("exec_gh_pr_view_changes.json")
        XCTAssertEqual(pr.state, "CLOSED")
        XCTAssertEqual(pr.reviewDecision, "CHANGES_REQUESTED")
        XCTAssertEqual(pr.requestedChanges.map(\.author), ["BagToad"])
        XCTAssertEqual(pr.comments.count, 2)
        XCTAssertEqual(pr.comments[1].author, "tidy-dev")
        XCTAssertEqual(pr.comments[1].body, "Closing as stale.")
        XCTAssertEqual(pr.conversation.first?.author, "github-actions")
        // Failures first, then running, passed, neutral, skipped.
        let order = pr.sortedChecks.map(\.state)
        XCTAssertEqual(order, order.sorted { rank($0) < rank($1) })
    }

    private func rank(_ s: PRDetail.Check.State) -> Int { [.fail, .pending, .pass, .neutral, .skipped].firstIndex(of: s)! }

    func testCheckStatesAndStatusContexts() throws {
        let json = #"""
        {"number":3,"title":"t","state":"OPEN","statusCheckRollup":[
          {"__typename":"CheckRun","name":"build","status":"IN_PROGRESS","conclusion":"","workflowName":"CI"},
          {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"TIMED_OUT"},
          {"__typename":"CheckRun","name":"docs","status":"COMPLETED","conclusion":"NEUTRAL"},
          {"__typename":"StatusContext","context":"ci/circleci","state":"FAILURE","targetUrl":"https://circleci.com/x"},
          {"__typename":"StatusContext","context":"vercel","state":"PENDING","targetUrl":""}
        ],"reviews":null,"comments":null,"files":null,"labels":null}
        """#
        let pr = try PRCommands.parseView(exitCode: 0, output: "Welcome!\n" + json.replacingOccurrences(of: "\n", with: "") + "\n")
        XCTAssertEqual(pr.checks.map(\.state), [.pending, .fail, .neutral, .fail, .pending])
        XCTAssertEqual(pr.checks[3].name, "ci/circleci")
        XCTAssertEqual(pr.checks[3].url, "https://circleci.com/x")
        XCTAssertNil(pr.checks[4].url)
        XCTAssertEqual(pr.checkRollup, .fail)
        XCTAssertEqual(pr.checkCounts[.fail], 2)
        XCTAssertTrue(pr.reviews.isEmpty && pr.comments.isEmpty && pr.files.isEmpty)
    }

    func testViewErrors() {
        XCTAssertThrowsError(try PRCommands.parseView(exitCode: 1, output: "GraphQL: Could not resolve to a PullRequest with the number of 999. (repository.pullRequest)")) {
            XCTAssertEqual(($0 as? HomeError)?.problem, .other)
            XCTAssertTrue(($0 as? HomeError)?.message.contains("Could not resolve") == true)
        }
        XCTAssertThrowsError(try PRCommands.parseView(exitCode: 4, output: "To get started with GitHub CLI, please run:  gh auth login")) {
            XCTAssertEqual(($0 as? HomeError)?.problem, .noAuth)
        }
        XCTAssertThrowsError(try PRCommands.parseView(exitCode: 0, output: "nothing"))
    }

    // MARK: commands

    func testReadCommandsNameThePRAndRepo() {
        let v = PRCommands.view(number: 151, repo: "octocat/acme-web")
        XCTAssertTrue(v.hasPrefix("gh pr view 151 --repo 'octocat/acme-web' --json number,title,body,"))
        XCTAssertTrue(v.contains("statusCheckRollup") && v.contains("reviews") && v.contains("comments") && v.contains("files"))
        XCTAssertEqual(PRCommands.parseURL("https://github.com/cli/cli/pull/14617")?.repo, "cli/cli")
        XCTAssertEqual(PRCommands.parseURL("https://github.com/cli/cli/pull/14617")?.number, 14617)
        XCTAssertNil(PRCommands.parseURL("https://github.com/cli/cli/issues/3"))
        XCTAssertEqual(PRCommands.slug(fromRemote: "https://github.com/octocat/acme-web.git"), "octocat/acme-web")
        XCTAssertEqual(PRCommands.slug(fromRemote: "git@github.com:octocat/hello.world.git"), "octocat/hello.world")
        XCTAssertTrue(PRCommands.isSlug("o/r.x"))
        XCTAssertFalse(PRCommands.isSlug("o/r; rm -rf /"))
    }

    func testActionCommands() {
        XCTAssertEqual(PRCommands.merge(number: 7, repo: "o/r", method: .squash, deleteBranch: true),
                       "gh pr merge 7 --repo 'o/r' --squash --delete-branch 2>&1")
        XCTAssertEqual(PRCommands.merge(number: 7, repo: "o/r", method: .rebase, deleteBranch: false), "gh pr merge 7 --repo 'o/r' --rebase 2>&1")
        XCTAssertEqual(PRCommands.close(number: 7, repo: "o/r"), "gh pr close 7 --repo 'o/r' 2>&1")
        XCTAssertEqual(PRCommands.ready(number: 7, repo: "o/r"), "gh pr ready 7 --repo 'o/r' 2>&1")
        XCTAssertEqual(PRCommands.review(number: 7, repo: "o/r", kind: .approve, body: "  "), "gh pr review 7 --repo 'o/r' --approve 2>&1")
        let text = "Don't merge yet; run `rm -rf /` $(whoami) \"quoted\""
        let c = PRCommands.comment(number: 7, repo: "o/r", body: text)
        XCTAssertEqual(c, "printf %s '\(GitActions.b64(text))' | base64 -d | gh pr comment 7 --repo 'o/r' --body-file - 2>&1")
        XCTAssertFalse(c.contains("whoami"), "user text never appears in the shell line")
        let r = PRCommands.review(number: 7, repo: "o/r", kind: .requestChanges, body: text)
        XCTAssertTrue(r.hasSuffix("gh pr review 7 --repo 'o/r' --request-changes --body-file - 2>&1"))
        XCTAssertFalse(r.contains("whoami"))
    }

    func testWorktreeHelpers() {
        XCTAssertEqual(PRCommands.worktreeName(number: 12, taken: ["pr-12", "pr-12-2"]), "pr-12-3")
        XCTAssertEqual(PRCommands.worktreeName(number: 12, taken: []), "pr-12")
        XCTAssertEqual(PRCommands.fetchHead("feat/x"), "git fetch origin '+refs/heads/feat/x:refs/remotes/origin/feat/x' 2>&1")
        let fork = PRCommands.checkoutFork(number: 9, repo: "o/r", scratch: "pr-9")
        XCTAssertTrue(fork.hasPrefix("{ gh pr checkout 9 --repo 'o/r' --force 2>&1 || gh pr checkout 9 --repo 'o/r' --force --branch 'pr-9' 2>&1; }"))
        XCTAssertEqual(PRCommands.parseBranch("Switched to branch 'fix'\n\n--pier-branch--\nfix\n"), "fix")
        XCTAssertNil(PRCommands.parseBranch("fatal: no"))
    }

    func testAgentPrompt() throws {
        let changes = try view("exec_gh_pr_view_changes.json")
        let p = PRCommands.agentPrompt(changes, repo: "cli/cli", branch: changes.headRefName)
        XCTAssertTrue(p.hasPrefix("Continue the work on PR #14057 (docs: recommend nix-shell over nix-env for Nix/NixOS) by @"))
        XCTAssertTrue(p.contains("`\(changes.headRefName)`"))
        XCTAssertTrue(p.contains("Reviewers asked for changes:\n- @BagToad"))
        XCTAssertTrue(p.contains("gh api repos/cli/cli/pulls/14057/comments"))
        var text = PRCommands.PromptText()
        text.intro = { n, _, a, _ in "PR \(n) de @\(a)" }
        let approved = try view("exec_gh_pr_view_approved.json")
        let q = PRCommands.agentPrompt(approved, repo: "cli/cli", branch: "b", text: text)
        XCTAssertTrue(q.hasPrefix("PR 14620 de @"))
        XCTAssertFalse(q.contains("Reviewers asked"))
        XCTAssertTrue(q.contains("gh pr view 14620 --repo cli/cli --comments"))
    }

    func testCleanBody() {
        XCTAssertEqual(PRCommands.cleanBody("a<!-- x\ny -->b\r\n<details><summary>S</summary>\n\n\n\nc</details>"), "ab\nS\n\nc")
    }

    // MARK: the shell, run for real (macOS sh / awk / git)

    #if os(macOS)
    private func sh(_ script: String, cwd: URL? = nil, env: [String: String] = [:]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script]
        if let cwd { p.currentDirectoryURL = cwd }
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let out = Pipe()
        p.standardOutput = out; p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// `fileDiff` cuts one file out of a real `gh pr diff` (gh is a function that prints the captured output).
    func testFileDiffCutsOneFileOutOfTheWholeDiff() throws {
        let r = try JSONDecoder.pier.decode(ExecResult.self, from: Fixture.data("exec_gh_pr_diff.json"))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("prdiff-\(UUID().uuidString)")
        try r.output.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let gh = "gh() { [ \"$4\" = --repo ] && [ \"$5\" = cli/cli ] || { echo bad args >&2; return 9; }; cat \"$DIFF\"; }; "
        let cmd = PRCommands.fileDiff(number: 14620, repo: "cli/cli", path: "pkg/extensions/official.go")
        let (code, out) = try sh(gh + cmd, env: ["DIFF": tmp.path])
        XCTAssertEqual(code, 0, out)
        XCTAssertTrue(out.hasPrefix("diff --git a/pkg/extensions/official.go b/pkg/extensions/official.go\n"), out)
        XCTAssertFalse(out.contains("official_test.go"), "the file whose name extends the path is not included")
        XCTAssertFalse(out.contains("extension.go b/"))
        let lines = GitActions.parseDiff(out)
        XCTAssertTrue(lines.contains { $0.kind == .add })
        XCTAssertEqual(lines.first?.kind, .hunk)
        // gh failing: its message and exit code come back.
        let failing = "gh() { echo 'GraphQL: Could not resolve to a PullRequest' >&2; return 1; }; "
        let (c2, o2) = try sh(failing + cmd)
        XCTAssertEqual(c2, 1)
        XCTAssertTrue(o2.contains("Could not resolve"))
    }

    /// Same-repository flow against real git: fetch the head in the main checkout, make a worktree on that branch the way pierd
    /// does (tracking `origin/<head>`), then `trackHead` leaves it tracking the PR's branch so `git push` goes there.
    func testSameRepoFlowTracksThePRBranch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("prflow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = "git -c user.email=t@t -c user.name=t -c init.defaultBranch=main"
        let setup = """
        set -e
        \(git) init -q --bare origin.git
        \(git) clone -q origin.git seed 2>/dev/null; cd seed
        echo a > a; git add a; \(git) commit -qm a; git push -q origin HEAD:main
        git checkout -qb feat/x; echo b > b; git add b; \(git) commit -qm b; git push -q origin feat/x
        cd ..; \(git) clone -q origin.git repo
        """
        let (c0, o0) = try sh(setup, cwd: root)
        XCTAssertEqual(c0, 0, o0)
        let repo = root.appendingPathComponent("repo")
        // The clone predates nothing here, so drop the remote ref to mimic a branch pushed after cloning.
        _ = try sh("git update-ref -d refs/remotes/origin/feat/x", cwd: repo)
        let (c1, o1) = try sh(PRCommands.fetchHead("feat/x"), cwd: repo)
        XCTAssertEqual(c1, 0, o1)
        let (c2, o2) = try sh("git worktree add -q --track -b feat/x ../repo-pr-1 origin/feat/x", cwd: repo)
        XCTAssertEqual(c2, 0, o2)
        let wt = root.appendingPathComponent("repo-pr-1")
        let (c3, o3) = try sh(PRCommands.trackHead("feat/x"), cwd: wt)
        XCTAssertEqual(c3, 0, o3)
        XCTAssertEqual(PRCommands.parseBranch(o3), "feat/x")
        let (_, up) = try sh("git rev-parse --abbrev-ref @{upstream}", cwd: wt)
        XCTAssertEqual(up.trimmingCharacters(in: .whitespacesAndNewlines), "origin/feat/x")
    }
    #endif
}
