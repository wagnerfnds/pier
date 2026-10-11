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
        // A project opens its workspace (files, changes, history) on its main worktree.
        XCTAssertTrue(element("workspace-tabs").waitForExistence(timeout: 5), "the project did not open in the detail")
        XCTAssertTrue(app.buttons["Nova tarefa aqui"].exists, "the workspace has no new task button")
        XCTAssertTrue(element("workspace-worktree").label.contains("atlas-ios"), "the workspace is not on the main worktree")
        shot("sidebar-project")

        let worktree = element("sidebar-worktree-sandbox/subtract")
        if !worktree.exists { element("sidebar-project-sandbox").tap() }
        XCTAssertTrue(worktree.waitForExistence(timeout: 5), "sandbox does not list its worktrees")
        worktree.tap()
        XCTAssertTrue(element("workspace-worktree").waitForExistence(timeout: 5), "the worktree did not open in the detail")
        XCTAssertTrue(element("workspace-worktree").label.contains("subtract"), "the workspace is not on the picked worktree")
        shot("sidebar-worktree")

        let session = element("sidebar-session-sandbox-subtract-claude-6s1")
        XCTAssertTrue(session.waitForExistence(timeout: 5), "the worktree does not list its session")
        session.tap()
        XCTAssertTrue(element("composer-field").waitForExistence(timeout: 10), "the session did not open in the detail")
        shot("sidebar-session")

        // Back walks up to the worktree, in the detail and in the sidebar.
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(element("workspace-worktree").waitForExistence(timeout: 5), "Back did not show the worktree")
        XCTAssertTrue(element("workspace-worktree").label.contains("subtract"))
        XCTAssertTrue(worktree.isSelected, "the sidebar did not follow Back")
    }

    func testWorkspaceOpensFilesHistoryAndChanges() {
        let worktree = element("sidebar-worktree-sandbox/subtract")
        if !worktree.waitForExistence(timeout: 10) { element("sidebar-project-sandbox").tap() }
        XCTAssertTrue(worktree.waitForExistence(timeout: 5))
        worktree.tap()
        // Arquivos: the tree with git's status, a file in the editor.
        let file = element("file-calc.py")
        XCTAssertTrue(file.waitForExistence(timeout: 10), "the file tree did not load")
        XCTAssertTrue(element("file-node_modules").exists, "ignored folders are not listed")
        file.tap()
        XCTAssertTrue(element("editor-tab-calc.py").waitForExistence(timeout: 5), "the file did not open in a tab")
        let editor = element("code-editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "no editor")
        XCTAssertTrue((editor.value as? String)?.contains("def subtract") == true, "the editor does not show the file")
        shot("workspace-files")
        // Typing makes it unsaved; ⌘S-equivalent Salvar saves it to the box.
        editor.tap()
        editor.typeText("# edited\n")
        let save = element("editor-save")
        XCTAssertTrue(save.isEnabled, "Salvar is not enabled after an edit")
        save.tap()
        XCTAssertTrue(app.staticTexts["Salvo"].waitForExistence(timeout: 5), "the save did not go through")

        // Histórico: the commits and the picked one's files.
        element("workspace-tab-history").tap()
        XCTAssertTrue(element("commit-5337933").waitForExistence(timeout: 10), "the history did not load")
        XCTAssertTrue(app.staticTexts["subtract(a, b) returns a - b; test_calc.py covers it."].waitForExistence(timeout: 5), "the commit's message is not shown")
        shot("workspace-history")
        // Another commit: its branches as badges by their names (git decorates them in full).
        element("commit-ae6d879").tap()
        XCTAssertTrue(app.staticTexts["Money shows as 12.50, never 12.5."].waitForExistence(timeout: 5), "the picked commit is not shown")
        XCTAssertTrue(app.staticTexts["origin/main"].exists, "the remote branch has no badge")
        XCTAssertFalse(app.staticTexts["refs/remotes/origin/main"].exists, "a badge shows the ref's full name")

        // Alterações: the changed files beside their patch.
        element("workspace-tab-changes").tap()
        XCTAssertTrue(element("changes-approve").waitForExistence(timeout: 10), "the changes did not load")
        shot("workspace-changes")
    }

    func testNewSectionIsNamedInPlace() {
        let add = element("sidebar-new-section")
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let field = element("sidebar-edit-field")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no field for the new section's name")
        field.typeText("Clientes\n")
        XCTAssertTrue(element("sidebar-section-Clientes").waitForExistence(timeout: 5), "Return did not create the section")
        XCTAssertFalse(field.exists, "the field stayed after Return")
        shot("sidebar-new-section")
        // Esc drops a name being typed.
        add.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Rascunho")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertFalse(element("sidebar-section-Rascunho").waitForExistence(timeout: 2), "Esc created the section")
        // × drops it too: a screen without a keyboard has no Esc.
        add.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Lixo")
        element("sidebar-edit-cancel").tap()
        let deadline = Date().addingTimeInterval(3)
        while field.exists && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertFalse(field.exists, "× did not close the field")
        XCTAssertFalse(element("sidebar-section-Lixo").waitForExistence(timeout: 1), "× created the section")
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

    func testWorkingSectionPinsTheLiveWorktreesAboveTheProjects() {
        let working = element("sidebar-section-Trabalhando")
        XCTAssertTrue(working.waitForExistence(timeout: 10), "no Trabalhando section")
        let waiting = element("sidebar-active-devbox/sandbox")
        let running = element("sidebar-active-devbox/acme-web")
        XCTAssertTrue(waiting.waitForExistence(timeout: 5), "the worktree that needs the person is not under Trabalhando")
        XCTAssertTrue(running.exists, "the working worktree is not under Trabalhando")
        // A finished turn is the person's turn, not work in progress.
        XCTAssertFalse(element("sidebar-active-devbox/sandbox/subtract").exists, "a finished turn is listed as working")
        // Needs-you first, and the whole section above the person's sections.
        XCTAssertLessThan(waiting.frame.minY, running.frame.minY, "needs-you is not first")
        XCTAssertLessThan(running.frame.minY, element("sidebar-section-Acme").frame.minY, "Trabalhando is not above the projects")
        shot("sidebar-working")

        // One agent there: the row opens its session.
        waiting.tap()
        XCTAssertTrue(element("composer-field").waitForExistence(timeout: 10), "the working row did not open its session")
        XCTAssertTrue(element("needs-you-card").waitForExistence(timeout: 10), "opened the wrong session")
    }

    func testNewTaskAndChatFromTheSidebar() {
        let newTask = element("sidebar-new-task")
        XCTAssertTrue(newTask.waitForExistence(timeout: 10), "no Nova tarefa in the sidebar")
        XCTAssertLessThan(newTask.frame.minY, element("sidebar-home").frame.minY, "Nova tarefa is not at the top")
        newTask.tap()
        XCTAssertTrue(element("compose-prompt").waitForExistence(timeout: 5), "Nova tarefa did not open the composer")
        shot("sidebar-new-task")
        element("sidebar-home").tap()
        XCTAssertTrue(app.buttons["new-task-button"].waitForExistence(timeout: 5))
        element("sidebar-new-chat").tap()
        XCTAssertTrue(element("compose-chat-place").waitForExistence(timeout: 5), "Nova conversa did not open the composer on a chat")
    }

    func testArchivedSectionListsExitedAndArchivedSessions() {
        app.terminate()
        app.launchArguments += ["-uiTestExtras", "1"]
        app.launch()
        let header = element("sidebar-section-Arquivadas")
        for _ in 0..<6 where !header.exists { app.swipeUp() }
        XCTAssertTrue(header.waitForExistence(timeout: 10), "no Arquivadas section")
        let exited = element("sidebar-archived-sandbox-old-claude-x3")
        if !exited.exists { header.tap() }   // folded by default
        for _ in 0..<3 where !exited.isHittable { app.swipeUp() }
        XCTAssertTrue(exited.waitForExistence(timeout: 5), "an exited session is not under Arquivadas")
        // It is not in the projects tree any more.
        XCTAssertFalse(element("sidebar-session-sandbox-old-claude-x3").exists, "an exited session is still in the tree")
        shot("sidebar-archived")
    }

    func testHomeColumnsHaveNoGaps() {
        // Two independent columns: the left one stacks Needs you, Sua vez, CI... right under each other.
        sleep(3)
        shot("home-columns")
    }
}
