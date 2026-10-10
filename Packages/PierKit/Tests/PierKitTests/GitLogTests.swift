import Foundation
import Testing

@testable import PierKit

/// The history commands and their parsers, over output captured from git on a small repository (Fixtures/exec_git_*).
@Suite struct GitLogTests {
    private func output(_ fixture: String) throws -> String { try Fixture.decode(fixture, as: ExecResult.self).output }

    @Test func logCommand() {
        let c = GitLog.command(limit: 60, skip: 120)
        #expect(c.hasPrefix("{ git rev-list '@{u}..HEAD' 2>/dev/null; true; } && printf '\\n--pier-log--\\n' && git log --no-color"))
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
        #expect(head.refs == ["HEAD -> subtract"])
        #expect(head.parents == ["44bc2ec48838211a2b203533be378ee8a467b355"])
        #expect(head.author == "Mona Octocat" && head.email == "mona@example.com")
        let pushed = page.entries[1]
        #expect(!pushed.unpushed)
        #expect(pushed.refs == ["origin/subtract"])
        #expect(pushed.date == RFC3339.parse("2026-10-08T09:00:00-03:00"))
        #expect(page.entries[2].subject == "Add subtract function")
        let root = page.entries[3]
        #expect(root.parents.isEmpty && root.refs == ["origin/main", "main"])
    }

    @Test func pagesKnowWhetherThereIsMore() throws {
        let page = GitLog.parse(try output("exec_git_log.json"), limit: 3)
        #expect(page.entries.count == 3 && page.hasMore)
    }

    @Test func emptyRepository() {
        let out = "\n--pier-log--\nfatal: your current branch 'main' does not have any commits yet\n"
        let page = GitLog.parse(out)
        #expect(page.entries.isEmpty && page.empty && !page.hasMore)
        #expect(!GitLog.parse("\n--pier-log--\n").empty)
    }

    @Test func showCommandQuotesTheSha() {
        let c = GitLog.showCommand(sha: "abc1234")
        #expect(c.hasPrefix("git show -s --no-color --format='%H%x1f"))
        #expect(c.contains("--name-status -z --find-renames --diff-merges=first-parent 'abc1234'"))
        #expect(c.contains("| head -c 26000 && printf '\\n--pier-numstat--\\n'"))
        #expect(c.hasSuffix("# pier-log:show"))
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
        #expect(d.entry.refs == ["origin/subtract"])
        #expect(d.body.isEmpty)
        #expect(d.files == [
            GitLog.FileChange(path: "DOCS.md", from: "README.md", status: "R", added: 0, removed: 0),
            GitLog.FileChange(path: "logo.bin", status: "A", binary: true),
        ])
    }

    @Test func cutFileListsKeepWholeRecords() {
        let (files, cut) = GitLog.parseNameStatus("M\0a.go\0R090\0old.go\0")
        #expect(files == [GitLog.FileChange(path: "a.go", status: "M")] && cut)
        let counts = GitLog.parseNumstat("1\t2\ta.go\0" + "5\t0\t\0old.go\0")
        #expect(counts["a.go"]?.added == 1 && counts["a.go"]?.removed == 2 && counts.count == 1)
        #expect(GitLog.parseShow("garbage") == nil)
    }

    @Test func commitFileDiff() throws {
        #expect(GitLog.fileDiffCommand(sha: "aa1ffb5", path: "calc.py")
            == "{ git show --no-color --format= --find-renames --diff-merges=first-parent 'aa1ffb5' -- 'calc.py' 2>/dev/null || git show --no-color --format= --find-renames 'aa1ffb5' -- 'calc.py'; } # pier-log:diff")
        #expect(GitLog.fileDiffCommand(sha: "s", path: "new.md", from: "old.md").contains("-- 'old.md' 'new.md'"))
        let lines = GitActions.parseDiff(try output("exec_git_commit_diff.json"))
        #expect(lines.filter { $0.kind == .add }.map(\.text) == ["", "def subtract(a, b):", "    return a - b"])
        #expect(lines.first?.kind == .hunk)
    }
}
