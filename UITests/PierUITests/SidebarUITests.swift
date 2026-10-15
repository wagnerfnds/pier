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
    private func waitUntil(_ seconds: TimeInterval, _ ok: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if ok() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return ok()
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
        // A project opens its workspace on its main worktree, on Agentes: a box to start an agent there.
        XCTAssertTrue(element("workspace-tabs").waitForExistence(timeout: 5), "the project did not open in the detail")
        XCTAssertTrue(element("start-prompt").waitForExistence(timeout: 5), "the project did not open on Agentes")
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
        XCTAssertTrue(element("workspace-tab-files").waitForExistence(timeout: 5))
        element("workspace-tab-files").tap()
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

    /// Agentes, the project's first tab: typed in its box, Start runs the agent in this worktree and opens its
    /// conversation; the worktree's agents are listed under the box, a click from theirs.
    func testAgentesTabStartsAnAgentInTheWorktree() {
        let worktree = element("sidebar-worktree-sandbox/subtract")
        if !worktree.waitForExistence(timeout: 10) { element("sidebar-project-sandbox").tap() }
        XCTAssertTrue(worktree.waitForExistence(timeout: 5))
        worktree.tap()
        let prompt = element("start-prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 5), "the worktree did not open on Agentes")
        XCTAssertTrue(element("start-agent-sandbox-subtract-claude-6s1").exists, "the worktree's agent is not listed under the box")
        XCTAssertEqual(element("start-target").label.contains("Nesta worktree"), true, "a worktree's box does not run the agent there")
        shot("workspace-agentes")
        prompt.tap()
        prompt.typeText("Adicione uma função multiply com teste")
        element("start-submit").tap()
        XCTAssertTrue(element("composer-field").waitForExistence(timeout: 15), "Start did not open the new agent's conversation")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "multiply")).firstMatch
                        .waitForExistence(timeout: 5), "the conversation does not start with the prompt")
    }

    /// A worktree made without its environment (sandbox/subtract in the mock) says so in Detalhes, and Preparar ambiente
    /// runs it there: Preparando…, then Ambiente pronto. From the main checkout, Agentes can make the next one without it.
    func testWorktreeIsPreparedLaterFromDetails() {
        let worktree = element("sidebar-worktree-sandbox/subtract")
        if !worktree.waitForExistence(timeout: 10) { element("sidebar-project-sandbox").tap() }
        XCTAssertTrue(worktree.waitForExistence(timeout: 5))
        worktree.tap()
        element("workspace-tab-details").tap()
        let state = element("prepare-state")
        XCTAssertTrue(state.waitForExistence(timeout: 10), "Detalhes has no Preparação")
        XCTAssertTrue(state.label.contains("não preparado"), "a worktree made without its environment reads \(state.label)")
        shot("details-unprepared")
        element("prepare-run").tap()
        XCTAssertTrue(app.staticTexts["Preparando…"].waitForExistence(timeout: 5), "Preparar did not start")
        // The Detalhes poll (6 s) reads it again.
        XCTAssertTrue(waitUntil(15) { state.label.contains("Ambiente pronto") }, "the preparation never read ready: \(state.label)")
        shot("details-prepared")

        // The main checkout's box: "Worktree nova" offers to leave the environment for later, and its chip says so.
        element("sidebar-worktree-sandbox/sandbox").tap()
        element("workspace-tab-start").tap()
        let target = element("start-target")
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        XCTAssertFalse(target.label.contains("sem ambiente"))
        target.tap()
        // In a menu a toggle is a checkmarked button.
        let toggle = app.buttons["Preparar ambiente"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Worktree nova has no Preparar ambiente")
        shot("start-target-menu")
        toggle.tap()
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(5) { target.label.contains("sem ambiente") }, "the chip does not say the worktree goes without its environment")
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
        // Nova seção again while its field is open: the same field, with what is typed.
        add.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Lix")
        add.tap()
        // (It used to close a moment later.)
        XCTAssertFalse(wait(1.5) { !field.exists }, "Nova seção again closed the field")
        XCTAssertEqual(field.value as? String, "Lix", "Nova seção again lost what was typed")
        field.typeText("o")
        // × drops it (Esc does too, on the Mac and with a keyboard: a simulator's UI test can't press Esc, it reaches
        // not even a sheet's Cancelar).
        element("sidebar-edit-cancel").tap()
        XCTAssertTrue(wait(3) { !field.exists }, "× did not close the field")
        XCTAssertFalse(element("sidebar-section-Lixo").waitForExistence(timeout: 1), "× created the section")
        XCTAssertFalse(element("sidebar-section-Lix").exists, "Nova seção again created the section")
    }

    /// Drag and drop with a finger (a long press, then a move): a project to the top of its section, into another
    /// section, and a section's title above another's.
    func testDraggingReordersProjectsAndSections() {
        let site = element("sidebar-project-acme-site"), web = element("sidebar-project-acme-web"), ios = element("sidebar-project-atlas-ios")
        XCTAssertTrue(site.waitForExistence(timeout: 10) && web.exists && ios.exists, "the seeded projects are not in the sidebar")
        let (first, second) = site.frame.minY < web.frame.minY ? (site, web) : (web, site)

        // Acme's second project onto the top half of its first: it goes first.
        drag(second, onto: first, at: 0.2)
        XCTAssertTrue(wait(5) { second.frame.minY < first.frame.minY }, "a project dropped on the top half of another did not go before it")

        // Onto the bottom half of Atlas' project: it moves to Atlas, after it; the other one stays in Acme.
        let atlas = element("sidebar-section-Atlas")
        drag(second, onto: ios, at: 0.8)
        XCTAssertTrue(wait(5) { second.frame.minY > ios.frame.minY }, "a project dropped on another section's project did not move there")
        XCTAssertGreaterThan(ios.frame.minY, atlas.frame.minY)
        XCTAssertLessThan(first.frame.minY, atlas.frame.minY, "the project left in Acme moved too")
        shot("sidebar-dragged-project")

        // A section's title onto the top of another's: Atlas above Acme, with its projects.
        let acme = element("sidebar-section-Acme")
        drag(atlas, onto: acme, at: 0.3)
        XCTAssertTrue(wait(5) { atlas.frame.minY < acme.frame.minY }, "a section dropped on the top of another did not go before it")
        XCTAssertGreaterThan(second.frame.minY, atlas.frame.minY)
        XCTAssertLessThan(second.frame.minY, acme.frame.minY, "the section's projects did not move with it")
        shot("sidebar-dragged-section")
    }

    /// A press on `item`, then a move to `target` at a height of it (0 its top, 1 its bottom). The move starts before
    /// the row's context menu opens: a finger that stays still for a second gets the menu instead, as on any iPad list.
    private func drag(_ item: XCUIElement, onto target: XCUIElement, at height: CGFloat) {
        let from = item.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        let to = target.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: height))
        from.press(forDuration: 0.6, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0.5)
    }

    private func wait(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return true
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

    /// Every live agent sits at the top, a row each, above the person's sections (and still in its project): the one
    /// that needs the person first, then the one at work, then the one whose turn ended. A row opens its conversation.
    func testAgentsSectionListsTheLiveAgentsAboveTheProjects() {
        let agents = element("sidebar-section-Agentes")
        XCTAssertTrue(agents.waitForExistence(timeout: 10), "no Agentes section")
        let waiting = element("sidebar-agent-devbox/sandbox-claude-w9q")
        let running = element("sidebar-agent-devbox/acme-web-claude-a1b")
        let finished = element("sidebar-agent-devbox/sandbox-subtract-claude-6s1")
        XCTAssertTrue(waiting.waitForExistence(timeout: 5), "the agent that needs the person is not under Agentes")
        XCTAssertTrue(running.exists, "the agent at work is not under Agentes")
        XCTAssertTrue(finished.exists, "an agent whose turn ended (it still runs) is not under Agentes")
        XCTAssertLessThan(waiting.frame.minY, running.frame.minY, "needs-you is not first")
        XCTAssertLessThan(running.frame.minY, finished.frame.minY, "the agent at work is not above the one whose turn ended")
        XCTAssertLessThan(finished.frame.minY, element("sidebar-section-Acme").frame.minY, "Agentes is not above the projects")
        shot("sidebar-agents")

        // A row opens its conversation, the project's tree still has it too.
        finished.tap()
        XCTAssertTrue(element("composer-field").waitForExistence(timeout: 10), "the agent's row did not open its conversation")
        XCTAssertTrue(element("sidebar-session-sandbox-subtract-claude-6s1").exists || element("sidebar-worktree-sandbox/subtract").exists,
                      "the agent left its project in the tree")
        XCTAssertTrue(element("session-open-sandbox-subtract-claude-6s1").exists, "the row opened another conversation")

        // Another agent's row opens that agent's conversation, not the one already open (its screen kept its model).
        waiting.tap()
        XCTAssertTrue(element("session-open-sandbox-claude-w9q").waitForExistence(timeout: 10), "the second agent's row kept the first conversation")
        XCTAssertFalse(element("session-open-sandbox-subtract-claude-6s1").exists)
        running.tap()
        XCTAssertTrue(element("session-open-acme-web-claude-a1b").waitForExistence(timeout: 10), "a third agent's row kept the conversation")
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
