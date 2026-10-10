import XCTest

/// Compact width (run on an iPhone simulator): a worktree's files and history one screen at a time. The iPad and the
/// Mac's workspace is covered by `SidebarUITests.testWorkspaceOpensFilesHistoryAndChanges`. Skipped on regular width.
final class WorkspaceUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestMock", "1", "-startTab", "projects", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Projetos"].waitForExistence(timeout: 15), "Projetos did not open")
        if element("sidebar-home").exists { throw XCTSkip("regular width: the workspace replaces these screens") }
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    /// sandbox → subtract: the worktree screen.
    private func openSubtract() {
        let project = app.staticTexts["sandbox"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10), "no sandbox project")
        project.tap()
        let worktree = app.staticTexts["subtract"].firstMatch
        XCTAssertTrue(worktree.waitForExistence(timeout: 10), "sandbox does not list subtract")
        worktree.tap()
        XCTAssertTrue(element("worktree-files").waitForExistence(timeout: 10), "no Arquivos on the worktree")
    }

    func testFilesOpenEditAndSave() {
        openSubtract()
        element("worktree-files").tap()
        let file = element("compact-file-calc.py")
        XCTAssertTrue(file.waitForExistence(timeout: 10), "the worktree's files did not load")
        XCTAssertTrue(element("compact-file-src").exists, "folders are not listed")
        file.tap()
        let editor = element("code-editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "the file did not open")
        XCTAssertTrue((editor.value as? String)?.contains("def subtract") == true, "the editor does not show the file")
        let save = element("editor-save")
        XCTAssertFalse(save.isEnabled, "Salvar is enabled with nothing to save")
        editor.tap()
        editor.typeText("# iPhone\n")
        XCTAssertTrue(save.isEnabled, "Salvar is not enabled after an edit")
        save.tap()
        // Saved: nothing left to save.
        let deadline = Date().addingTimeInterval(5)
        while save.isEnabled && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertFalse(save.isEnabled, "the save did not go through")
    }

    func testHistoryShowsCommitsAndPatches() {
        openSubtract()
        element("worktree-history").tap()
        let commit = app.staticTexts["Add subtract() to calc.py with a test"]
        XCTAssertTrue(commit.waitForExistence(timeout: 10), "the history did not load")
        commit.tap()
        let file = app.staticTexts["calc.py"].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), "the commit's files did not load")
        file.tap()
        XCTAssertTrue(app.staticTexts["def subtract(a, b):"].waitForExistence(timeout: 10), "the patch did not load")
    }
}
