import XCTest

/// The projects' pull requests, anyone's, against the mock box (`-uiTestPRs 1`): the Home's "PRs dos projetos" opens one;
/// on the iPhone the Projetos list folds like the sidebar (sections, a project's worktrees) and a project lists its pull
/// requests, which open the PR screen (where one is brought into a worktree).
final class ProjectPRsUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func element(prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }
    private func text(_ s: String) -> XCUIElement { app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch }
    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["KBD_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
    private func reveal(_ e: XCUIElement, tries: Int = 8) {
        var n = 0
        while !(e.exists && e.isHittable), n < tries { app.swipeUp(); n += 1 }
    }

    func testTheHomeListsEveryProjectsPullRequests() {
        app.launchArguments = ["-uiTestMock", "1", "-uiTestPRs", "1", "-homeScrollTo", "projectPRs", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        XCTAssertTrue(text("PRs dos projetos").waitForExistence(timeout: 20), "no PRs dos projetos widget")
        let row = element(prefix: "project-pr-row-")
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no pull request in the widget")
        XCTAssertTrue(text("@mara").exists || text("@dev-luiz").exists || text("@ana-qa").exists, "other people's pull requests are not listed")
        shot("project-prs-home")
        reveal(row)
        row.tap()
        XCTAssertTrue(element("pr-title").waitForExistence(timeout: 10), "the PR screen did not open")
    }

    func testTheIPhoneProjectsFoldLikeTheSidebarAndAProjectListsItsPullRequests() throws {
        app.launchArguments = ["-uiTestMock", "1", "-uiTestPRs", "1", "-startTab", "projects", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Projetos"].waitForExistence(timeout: 15), "Projetos did not open")
        if element("sidebar-home").exists { throw XCTSkip("regular width: the sidebar itself") }
        let project = app.staticTexts["sandbox"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10))

        // A project opens into its worktrees, and closes again.
        let disclosure = element("projects-disclosure-sandbox")
        XCTAssertTrue(disclosure.exists, "no disclosure on a project with worktrees")
        let worktree = element("projects-worktree-sandbox/subtract")
        if !worktree.exists { disclosure.tap() }
        XCTAssertTrue(worktree.waitForExistence(timeout: 5), "the project's worktrees did not show")
        shot("projects-tree")
        disclosure.tap()
        XCTAssertTrue(worktree.waitForNonExistence(timeout: 5), "the worktrees stayed")

        // A section folds (and stays folded, as in the sidebar).
        let header = element(prefix: "projects-section-")
        XCTAssertTrue(header.exists, "no section header")
        header.tap()
        XCTAssertTrue(project.waitForNonExistence(timeout: 5), "the section did not fold")
        header.tap()
        XCTAssertTrue(project.waitForExistence(timeout: 5), "the section did not open again")

        // A project's pull requests, anyone's.
        let withRemote = app.staticTexts["acme-web"].firstMatch
        reveal(withRemote)
        withRemote.tap()
        let prs = element("project-prs")
        XCTAssertTrue(prs.waitForExistence(timeout: 10), "no Pull requests on the project")
        prs.tap()
        let row = element(prefix: "project-pr-")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the project's pull requests did not load")
        XCTAssertTrue(text("de qualquer pessoa").exists)
        shot("project-prs-list")
        row.tap()
        XCTAssertTrue(element("pr-title").waitForExistence(timeout: 10), "the PR screen did not open")
        XCTAssertTrue(element("pr-bring").waitForExistence(timeout: 10) || app.buttons.matching(NSPredicate(format: "label CONTAINS 'worktree'")).firstMatch.exists,
                      "the PR cannot be brought into a worktree")
        shot("project-pr-opened")
    }

    /// Where there is room (iPad, Mac): the project's workspace has a Pull requests tab.
    func testTheWorkspaceHasAPullRequestsTab() throws {
        app.launchArguments = ["-uiTestMock", "1", "-uiTestPRs", "1", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        let project = element("sidebar-project-acme-web")
        guard project.waitForExistence(timeout: 15) else { throw XCTSkip("compact width: the iPhone's project screen") }
        project.tap()
        let tab = element("workspace-tab-pullRequests")
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "no Pull requests tab")
        tab.tap()
        let row = element(prefix: "project-pr-")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the project's pull requests did not load")
        shot("workspace-prs")
        row.tap()
        XCTAssertTrue(element("pr-title").waitForExistence(timeout: 10), "the PR screen did not open")
    }
}
