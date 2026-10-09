import XCTest
@testable import PierKit

final class HomeTests: XCTestCase {
    func testParsePullRequests() throws {
        let json = #"{"viewer":"me","review":[{"number":7,"title":"Fix","url":"https://github.com/o/r/pull/7","isDraft":false,"updatedAt":"2026-10-06T15:59:58Z","additions":3,"deletions":1,"reviewDecision":"","repository":{"nameWithOwner":"o/r"},"author":{"login":"bob"},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE"}}}]}}],"mine":[{"number":9,"title":"Mine","url":"https://github.com/o/r/pull/9","isDraft":true,"updatedAt":"2026-10-06T15:59:58Z","additions":0,"deletions":0,"reviewDecision":"APPROVED","repository":{"nameWithOwner":"o/r"},"author":{"login":"me"},"commits":{"nodes":[{"commit":{"statusCheckRollup":null}}]}}],"reviewCount":4,"mineCount":1}"#
        let prs = try HomeCommands.parsePullRequests(exitCode: 0, output: "noise\n" + json + "\n")
        XCTAssertEqual(prs.viewer, "me")
        XCTAssertEqual(prs.reviewCount, 4)
        XCTAssertEqual(prs.review[0].checks, .fail)
        XCTAssertNil(prs.review[0].reviewDecision)
        XCTAssertEqual(prs.review[0].repoName, "r")
        XCTAssertEqual(prs.mine[0].checks, CheckRollup.none)
        XCTAssertEqual(prs.mine[0].reviewDecision, "APPROVED")
        XCTAssertTrue(prs.mine[0].isDraft)
    }

    func testGhProblems() {
        XCTAssertThrowsError(try HomeCommands.parsePullRequests(exitCode: 127, output: "gh: command not found")) {
            XCTAssertEqual(($0 as? HomeError)?.problem, .noGh)
        }
        XCTAssertThrowsError(try HomeCommands.parsePullRequests(exitCode: 4, output: "To get started with GitHub CLI, please run:  gh auth login")) {
            XCTAssertEqual(($0 as? HomeError)?.problem, .noAuth)
        }
    }

    func testParseCI() throws {
        let out = """
        {"repo":"o/r","runs":[{"databaseId":5,"workflowName":"ci","displayTitle":"t","headBranch":"main","createdAt":"2026-10-07T10:00:00Z","url":"https://x/5"}]}
        {"repo":"o/q","runs":[]}
        """
        let f = try HomeCommands.parseCIFailures(exitCode: 0, output: out)
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].branch, "main")
        XCTAssertThrowsError(try HomeCommands.parseCIFailures(exitCode: 0, output: "#ERR gh auth login needed"))
    }

    func testCICommandSkipsBadSlugs() {
        XCTAssertNil(HomeCommands.ciFailures(repos: ["a b/c", "x;rm -rf /"]))
        XCTAssertTrue(HomeCommands.ciFailures(repos: ["o/r"])!.contains("'o/r'"))
    }

    func testGitActivity() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_791_398_519) // 2026-10-07
        let dn = Int(1_791_398_519 / 86400)
        let out = "0 \(dn) 3 100 20\n1 \(dn - 2) 1 5 0\n0 \(dn - 40) 9 1 1\n"
        let a = HomeCommands.parseGitActivity(output: out, projects: [.init(name: "a", path: "/a"), .init(name: "b", path: "/b")], now: now, calendar: cal)
        XCTAssertEqual(a.days.count, 14)
        XCTAssertEqual(a.totalCommits, 4)
        XCTAssertEqual(a.totalAdd, 105)
        XCTAssertEqual(a.days.last?.commits, 3)
        XCTAssertEqual(a.byProject.first?.name, "a")
    }

    func testServicesDecode() throws {
        let s = try JSONDecoder().decode([BoxService].self, from: Data(#"[{"location":"x","worktree":"w","path":"/p","port":3000,"process":"node"}]"#.utf8))
        XCTAssertEqual(s[0].port, 3000)
    }
}
