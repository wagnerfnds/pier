import Foundation
import Testing

@testable import PierKit

/// The history commands and their parsers, over output captured from git on a small repository (Fixtures/exec_git_*).
@Suite struct GitLogTests {
    private func output(_ fixture: String) throws -> String { try Fixture.decode(fixture, as: ExecResult.self).output }

    @Test func logCommand() {
        let c = GitLog.command(limit: 60, skip: 120)
        // From the worktree's top (a location can be a folder inside the repository), whatever git config says.
        #expect(c.hasPrefix(#"cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" && { git rev-list '@{u}..HEAD' 2>/dev/null; true; } && printf '\n--pier-log--\n' && git -c log.showSignature=false log --no-color --decorate=full"#))
        #expect(c.contains("-n 61 --skip 120"))
        #expect(c.hasSuffix(" 2>&1 # pier-log:log"))
        #expect(!c.contains(" -- "))
        let file = GitLog.command(limit: 10, path: "src/it's.go", follow: true)
        #expect(file.contains("-n 11 --skip 0 --follow -- 'src/it'\\''s.go' 2>&1"))
    }

    @Test func parsesLogWithUnpushedAndRefs() throws {
        let page = GitLog.parse(try output("exec_git_log.json"))
        #expect(page.entries.map(\.short) == ["ea9eb4b", "44bc2ec", "aa1ffb5", "6ecbc6f"])
        #expect(!page.hasMore && !page.empty)
        let head = page.entries[0]
        #expect(head.subject == "Unpushed tweak")
        #expect(head.unpushed)
        #expect(head.refs == ["HEAD -> refs/heads/subtract"])
        #expect(head.decorations == [GitLog.Ref(name: "subtract", kind: .branch, current: true)])
        #expect(head.parents == ["44bc2ec48838211a2b203533be378ee8a467b355"])
        #expect(head.author == "Mona Octocat" && head.email == "mona@example.com")
        let pushed = page.entries[1]
        #expect(!pushed.unpushed)
        #expect(pushed.decorations == [GitLog.Ref(name: "origin/subtract", kind: .remote)])
        #expect(pushed.date == RFC3339.parse("2026-10-08T09:00:00-03:00"))
        #expect(page.entries[2].subject == "Add subtract function")
        let root = page.entries[3]
        #expect(root.parents.isEmpty)
        #expect(root.decorations == [GitLog.Ref(name: "origin/main", kind: .remote), GitLog.Ref(name: "main", kind: .branch)])
    }

    @Test func pagesKnowWhetherThereIsMore() throws {
        let page = GitLog.parse(try output("exec_git_log.json"), limit: 3)
        #expect(page.entries.count == 3 && page.hasMore)
        #expect(page.unpushed == ["ea9eb4b534b1b8d7c2c793520d940d554cc732d1"])
    }

    /// Reading the first page again keeps the older pages already read, and what is pushed loses its mark.
    @Test func refreshKeepsOlderPages() {
        func e(_ sha: String, unpushed: Bool = false) -> GitLog.Entry { GitLog.Entry(sha: sha, short: sha, unpushed: unpushed) }
        let shown = [e("c3", unpushed: true), e("c2", unpushed: true), e("c1", unpushed: true), e("c0", unpushed: true)]
        // A new commit on top; the page (2 commits) ends at c3, inside what is shown; everything was pushed.
        let page = GitLog.Page(entries: [e("c4"), e("c3")], hasMore: true, unpushed: [])
        let (entries, more) = GitLog.refreshed(shown, hasMore: true, with: page)
        #expect(entries.map(\.sha) == ["c4", "c3", "c2", "c1", "c0"] && more)
        #expect(entries.allSatisfy { !$0.unpushed })
        // Rewritten history (the page's last commit is not on screen): start over from the page.
        let rewritten = GitLog.Page(entries: [e("x2"), e("x1")], hasMore: true)
        #expect(GitLog.refreshed(shown, hasMore: true, with: rewritten).entries.map(\.sha) == ["x2", "x1"])
        // The whole history fits in the page: it is the list.
        let all = GitLog.Page(entries: [e("c4"), e("c3"), e("c2"), e("c1"), e("c0")], hasMore: false)
        #expect(GitLog.refreshed(shown, hasMore: true, with: all) == (all.entries, false))
    }

    @Test func emptyRepository() {
        let out = "\n--pier-log--\nfatal: your current branch 'main' does not have any commits yet\n"
        let page = GitLog.parse(out)
        #expect(page.entries.isEmpty && page.empty && !page.hasMore)
        #expect(!GitLog.parse("\n--pier-log--\n").empty)
    }

    @Test func showCommandQuotesTheSha() {
        let c = GitLog.showCommand(sha: "abc1234")
        #expect(c.hasPrefix(#"cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" && git -c log.showSignature=false show -s --no-color --decorate=full --format='%H%x1f"#))
        // The header and both lists are cut to fit exec's 64 KB together.
        #expect(c.contains("'abc1234' | head -c 16000 && printf '\\n--pier-files--\\n'"))
        #expect(c.contains("--no-ext-diff --format= --name-status -z --find-renames --diff-merges=first-parent 'abc1234'"))
        #expect(c.contains("| head -c 22000 && printf '\\n--pier-numstat--\\n'"))
        #expect(c.hasSuffix("| head -c 22000 # pier-log:show"))
        #expect(GitLog.headerBytes + 2 * GitLog.fileListBytes + 64 < 64 << 10)
    }

    @Test func parsesACommit() throws {
        let d = try #require(GitLog.parseShow(try output("exec_git_show.json")))
        #expect(d.entry.short == "aa1ffb5" && d.entry.subject == "Add subtract function")
        #expect(d.message == "Add subtract function\n\nWith a test for it.")
        #expect(d.body == "With a test for it.")
        #expect(d.committer == "Mona Octocat")
        #expect(d.committed == RFC3339.parse("2026-10-07T21:36:28Z"))
        #expect(d.files == [
            GitLog.FileChange(path: "calc.py", status: "M", added: 3, removed: 0),
            GitLog.FileChange(path: "test_calc.py", status: "A", added: 4, removed: 0),
        ])
        #expect(d.added == 7 && d.removed == 0 && !d.truncated)
    }

    @Test func parsesRenamesAndBinaries() throws {
        let d = try #require(GitLog.parseShow(try output("exec_git_show_rename.json")))
        #expect(d.entry.decorations == [GitLog.Ref(name: "origin/subtract", kind: .remote)])
        #expect(d.body.isEmpty)
        #expect(d.files == [
            GitLog.FileChange(path: "DOCS.md", from: "README.md", status: "R", added: 0, removed: 0),
            GitLog.FileChange(path: "logo.bin", status: "A", binary: true),
        ])
    }

    @Test func cutFileListsKeepWholeRecords() {
        let (files, cut) = GitLog.parseNameStatus("M\0a.go\0R090\0old.go\0")
        #expect(files == [GitLog.FileChange(path: "a.go", status: "M")] && cut)
        // Cut inside a path: the piece after the last NUL is not a file.
        let (some, cutPath) = GitLog.parseNameStatus("M\0a.go\0A\0src/lo")
        #expect(some == [GitLog.FileChange(path: "a.go", status: "M")] && cutPath)
        let (whole, uncut) = GitLog.parseNameStatus("M\0a.go\0")
        #expect(whole.count == 1 && !uncut)
        #expect(GitLog.parseNameStatus("") == ([], false))
        let counts = GitLog.parseNumstat("1\t2\ta.go\0" + "5\t0\t\0old.go\0")
        #expect(counts["a.go"]?.added == 1 && counts["a.go"]?.removed == 2 && counts.count == 1)
        #expect(GitLog.parseNumstat("1\t2\ta.go\0" + "3\t4\tb.g").keys.sorted() == ["a.go"])
        #expect(GitLog.parseShow("garbage") == nil)
    }

    @Test func commitFileDiff() throws {
        let show = "git -c log.showSignature=false show --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ --format= --find-renames"
        #expect(GitLog.fileDiffCommand(sha: "aa1ffb5", path: "calc.py")
            == #"cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" && { "# + show + " --diff-merges=first-parent 'aa1ffb5' -- 'calc.py' 2>/dev/null || " + show + " 'aa1ffb5' -- 'calc.py'; } # pier-log:diff")
        #expect(GitLog.fileDiffCommand(sha: "s", path: "new.md", from: "old.md").contains("-- 'old.md' 'new.md'"))
        let lines = GitActions.parseDiff(try output("exec_git_commit_diff.json"))
        #expect(lines.filter { $0.kind == .add }.map(\.text) == ["", "def subtract(a, b):", "    return a - b"])
        #expect(lines.first?.kind == .hunk)
    }

    @Test func decorations() {
        #expect(GitLog.ref("HEAD -> refs/heads/fix/login") == GitLog.Ref(name: "fix/login", kind: .branch, current: true))
        // A local branch with a slash is still local: only refs/remotes/ is a remote.
        #expect(GitLog.ref("refs/heads/feature/x") == GitLog.Ref(name: "feature/x", kind: .branch))
        #expect(GitLog.ref("refs/remotes/origin/HEAD") == GitLog.Ref(name: "origin/HEAD", kind: .remote))
        #expect(GitLog.ref("tag: refs/tags/v1.2") == GitLog.Ref(name: "v1.2", kind: .tag))
        #expect(GitLog.ref("HEAD") == GitLog.Ref(name: "HEAD", kind: .head))
        #expect(GitLog.ref("refs/stash") == GitLog.Ref(name: "stash", kind: .other))
        #expect(GitLog.ref("grafted") == GitLog.Ref(name: "grafted", kind: .other))
        // An older git's short names.
        #expect(GitLog.ref("HEAD -> main") == GitLog.Ref(name: "main", kind: .branch, current: true))
        #expect(GitLog.ref("tag: v1") == GitLog.Ref(name: "v1", kind: .tag))
        #expect(GitLog.ref("origin/main").kind == .remote && GitLog.ref("main").kind == .branch)
    }

    /// A message written with Windows line ends still has a subject and a body.
    @Test func crlfMessage() throws {
        let head = ["abc1234def", "abc1234", "", "A", "a@x", "2026-10-07T21:36:28Z", "A", "2026-10-07T21:36:28Z", "", "Fix it\r\n\r\nWhy it broke.\r\n"]
        let d = try #require(GitLog.parseShow(head.joined(separator: "\u{1f}") + "\n--pier-files--\nM\0a.go\0\n--pier-numstat--\n1\t0\ta.go\0"))
        #expect(d.entry.subject == "Fix it")
        #expect(d.body == "Why it broke.")
    }

    /// A message cut at the header's cap still reads: the fields come before it.
    @Test func longMessageIsCutNotLost() throws {
        let long = "Squash\n\n" + String(repeating: "* a change\n", count: 3000)
        let head = ["abc1234def", "abc1234", "", "A", "a@x", "2026-10-07T21:36:28Z", "A", "2026-10-07T21:36:28Z", "", long]
        let cut = String(head.joined(separator: "\u{1f}").utf8.prefix(GitLog.headerBytes))!
        let d = try #require(GitLog.parseShow(cut + "\n--pier-files--\nM\0a.go\0\n--pier-numstat--\n1\t0\ta.go\0"))
        #expect(d.entry.subject == "Squash" && d.files.count == 1)
    }
}
