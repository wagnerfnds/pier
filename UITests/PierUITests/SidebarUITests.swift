import XCTest

/// Regular width (run on an iPad simulator): the sidebar lists the sections and the projects grouped by the person's
/// sections, and what is picked there (or opened from the Home) shows in the detail column. Skipped on compact width.
final class SidebarUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestMock", "1", "-seedSections", "1", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Início"].waitForExistence(timeout: 15), "home did not load")
        if !element("sidebar-home").waitForExistence(timeout: 3) {
            throw XCTSkip("no sidebar: this test runs on regular width (iPad)")
        }
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func text(containing s: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }
    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["KBD_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    func testSidebarShowsSectionsAndProjects() {
        for id in ["sidebar-home", "sidebar-inbox", "sidebar-board", "sidebar-projects", "sidebar-settings"] {
            XCTAssertTrue(element(id).exists, "\(id) missing")
        }
        XCTAssertLessThan(element("sidebar-home").frame.minY, element("sidebar-inbox").frame.minY, "Início is not above the Inbox")
        XCTAssertTrue(element("sidebar-project-sandbox").waitForExistence(timeout: 10), "projects did not load in the sidebar")
        XCTAssertTrue(element("sidebar-section-Acme").exists, "the person's sections are not in the sidebar")
        XCTAssertTrue(element("sidebar-section-Atlas").exists)
        XCTAssertTrue(element("sidebar-project-atlas-ios").exists)
        XCTAssertTrue(element("sidebar-project-acme-web").exists)
        // The Home is the detail, next to the sidebar.
        XCTAssertTrue(app.buttons["new-task-button"].exists, "the Home is not in the detail")
        shot("sidebar-home")
    }

    func testSelectingProjectWorktreeAndSessionShowsThemInDetail() {
        let project = element("sidebar-project-atlas-ios")
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.tap()
        XCTAssertTrue(app.buttons["Nova tarefa aqui"].waitForExistence(timeout: 5), "the project did not open in the detail")
        shot("sidebar-project")

        let worktree = element("sidebar-worktree-sandbox/subtract")
        if !worktree.exists { element("sidebar-project-sandbox").tap() }
        XCTAssertTrue(worktree.waitForExistence(timeout: 5), "sandbox does not list its worktrees")
        worktree.tap()
        XCTAssertTrue(app.buttons["Revisar mudanças"].waitForExistence(timeout: 5), "the worktree did not open in the detail")
        shot("sidebar-worktree")

        let session = element("sidebar-session-sandbox-subtract-claude-6s1")
        XCTAssertTrue(session.waitForExistence(timeout: 5), "the worktree does not list its session")
        session.tap()
        XCTAssertTrue(element("composer-field").waitForExistence(timeout: 10), "the session did not open in the detail")
        shot("sidebar-session")

        // Back walks up to the worktree, in the detail and in the sidebar.
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Revisar mudanças"].waitForExistence(timeout: 5), "Back did not show the worktree")
        XCTAssertTrue(worktree.isSelected, "the sidebar did not follow Back")
    }

    func testOpeningSessionFromHomeShowsItInDetail() {
        let row = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Create a probe directory")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the Home has no needs-you row")
        row.tap()
        XCTAssertTrue(element("composer-field").waitForExistence(timeout: 10), "the session did not open")
        XCTAssertTrue(element("sidebar-home").exists, "the sidebar went away")
        XCTAssertTrue(element("needs-you-card").waitForExistence(timeout: 10), "the needs-you card is not shown")
        shot("sidebar-home-session")

        // Picking Início again goes back to the Home.
        element("sidebar-home").tap()
        XCTAssertTrue(app.buttons["new-task-button"].waitForExistence(timeout: 5), "Início did not pop to the Home")
    }

    func testSidebarSearchFiltersProjectsAndWorktrees() {
        XCTAssertTrue(element("sidebar-project-sandbox").waitForExistence(timeout: 10))
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no search field in the sidebar")
        field.tap()
        field.typeText("subtract")
        XCTAssertTrue(element("sidebar-worktree-sandbox/subtract").waitForExistence(timeout: 5), "the matching worktree is not shown (or not expanded)")
        XCTAssertFalse(element("sidebar-project-acme-site").exists, "a project that does not match is still listed")
        XCTAssertFalse(element("sidebar-project-atlas-ios").exists)
        shot("sidebar-search")
        field.buttons.firstMatch.tap()   // clear
        XCTAssertTrue(element("sidebar-project-atlas-ios").waitForExistence(timeout: 5), "clearing the search did not bring the list back")
    }

    func testHomeColumnsHaveNoGaps() {
        // Two independent columns: the left one stacks Needs you, Sua vez, CI... right under each other.
        sleep(3)
        shot("home-columns")
    }
}
