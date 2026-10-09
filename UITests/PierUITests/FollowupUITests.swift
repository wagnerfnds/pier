import XCTest

/// The follow-up items, driven through the real UI against the mock box with `-uiTestExtras 1`: a Claude startup dialog
/// (MCP) answered with buttons, an AI-written commit/PR text in Aprovar, "Sua vez" vs "Encerradas", background work.
final class FollowupUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestMock", "1", "-uiTestExtras", "1", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Início"].waitForExistence(timeout: 15), "home did not load")
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

    private func openSession(titled prefix: String) {
        // The Home settles once the background signals arrive (a session moves to "Trabalhando agora"); tap after that.
        sleep(3)
        let row = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        var tries = 0
        while !(row.exists && row.isHittable), tries < 6 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "session row '\(prefix)' not found")
        row.tap()
        XCTAssertTrue(element("composer-field").waitForExistence(timeout: 10), "session screen did not open")
    }

    /// Item 6: Claude's "New MCP server found" dialog (no hook marks the agent as waiting) becomes buttons in the chat.
    func testMcpStartupDialogBecomesButtons() {
        // An idle agent is not on the Home: open it directly, as a notification or the Projects list would.
        app.terminate()
        app.launchArguments += ["-openSession", "sandbox-mcp-claude-m1"]
        app.launch()
        XCTAssertTrue(element("composer-field").waitForExistence(timeout: 15), "session screen did not open")
        let card = element("needs-you-card")
        XCTAssertTrue(card.waitForExistence(timeout: 12), "no card for the MCP dialog on screen")
        let option = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Use this MCP server'")).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "the dialog's options are not buttons")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Continue without using this MCP server'")).firstMatch.exists)
        XCTAssertTrue(text(containing: "New MCP server found").exists, "the dialog's question is not shown")
        shot("followup-mcp-dialog")
        option.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 10), "the card stayed after answering")
        XCTAssertTrue(text(containing: "MCP server enabled").waitForExistence(timeout: 10), "the agent did not continue")
        shot("followup-mcp-answered")
    }

    /// Item 2: Aprovar asks the box's Haiku for the commit message and PR text, written from the diff.
    func testApproveSheetWritesTheTextWithAI() {
        openSession(titled: "Add a subtract function")
        sleep(2)
        let revisar = app.buttons["Revisar"].firstMatch
        if revisar.exists { revisar.tap() } else { app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.83, dy: 0.855)).tap() }
        let approve = app.buttons["Aprovar"].firstMatch
        XCTAssertTrue(approve.waitForExistence(timeout: 10), "review screen has no Aprovar")
        for _ in 0..<20 where !approve.isEnabled { sleep(1) }
        XCTAssertTrue(approve.isEnabled, "Aprovar stayed disabled")
        approve.tap()
        XCTAssertTrue(text(containing: "Texto escrito pela IA").waitForExistence(timeout: 15), "the AI draft did not arrive")
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String ?? "").hasPrefix("Add subtract() to calc.py with a test"),
                      "commit message is not the AI draft: \(editor.value ?? "nil")")
        shot("followup-approve-ai")
    }

    /// Item 4 (+ background): "Sua vez" lists finished turns; exited sessions fold under "Encerradas"; a finished turn
    /// with work still running in the background reads as working.
    func testHomeYourTurnClosedAndBackground() {
        XCTAssertTrue(text(containing: "Sua vez").waitForExistence(timeout: 10), "no Sua vez widget")
        var tries = 0
        let closed = text(containing: "Encerradas (")
        while !(closed.exists && closed.isHittable), tries < 6 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(closed.exists, "no Encerradas section")
        closed.tap()
        XCTAssertTrue(text(containing: "Old finished experiment").waitForExistence(timeout: 5), "exited session not under Encerradas")
        shot("followup-home-closed")
        // The background session is listed as working, with what runs.
        app.swipeDown(); app.swipeDown(); app.swipeDown()
        XCTAssertTrue(text(containing: "Em segundo plano · scripts/verificar.sh 41710").waitForExistence(timeout: 25),
                      "finished turn with background work is not shown as working")
        shot("followup-home-background")
    }

    /// Background work shows above the composer and in the title line.
    func testChatShowsBackgroundWork() {
        openSession(titled: "Run the full verification")
        let strip = element("background-strip")
        XCTAssertTrue(strip.waitForExistence(timeout: 10), "no background strip")
        XCTAssertTrue(text(containing: "1 tarefa em segundo plano").exists)
        XCTAssertTrue(text(containing: "1 em segundo plano").exists, "title line does not say so")
        text(containing: "1 tarefa em segundo plano").tap()
        XCTAssertTrue(text(containing: "scripts/verificar.sh 41710").waitForExistence(timeout: 3))
        shot("followup-chat-background")
    }

    /// The terminal view (lazy lines) shows the screen and stays at its end.
    func testTerminalViewShowsTheScreen() {
        openSession(titled: "Add a subtract function")
        app.buttons["Mais ações"].tap()
        app.buttons["Ver terminal"].tap()
        let pane = element("Terminal")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Terminal'")).firstMatch.waitForExistence(timeout: 10), "no terminal")
        _ = pane
        let anyLine = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '❯' OR label CONTAINS '─'")).firstMatch
        XCTAssertTrue(anyLine.waitForExistence(timeout: 10), "terminal shows no screen lines")
        shot("followup-terminal")
        // The view mode is remembered per session: put it back so other tests open the chat.
        app.buttons["Mais ações"].tap()
        app.buttons["Ver como conversa"].tap()
        XCTAssertTrue(element("composer-field").waitForExistence(timeout: 5))
    }
}

/// Ending a session cleans up after it; the Faxina screen plans and runs the cleanup across the box.
final class CleanupUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestMock", "1", "-uiTestExtras", "1", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func text(_ s: String) -> XCUIElement { app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch }
    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["KBD_SHOTS"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    func testEndSessionCleansTheWorktree() {
        app.launchArguments += ["-openSession", "sandbox-subtract-claude-6s1"]
        app.launch()
        XCTAssertTrue(element("composer-field").waitForExistence(timeout: 15))
        app.buttons["Mais ações"].tap()
        app.buttons["Encerrar sessão"].tap()
        XCTAssertTrue(text("Encerrar e limpar").waitForExistence(timeout: 8), "no cleanup option")
        XCTAssertTrue(text("Tudo enviado ao GitHub").waitForExistence(timeout: 8), "pushed worktree not recognised as safe")
        shot("end-session-sheet")
        element("end-session-run").tap()
        XCTAssertTrue(element("composer-field").waitForNonExistence(timeout: 10), "the session screen stayed")
        XCTAssertTrue(text("serviços parados").waitForExistence(timeout: 8), "no cleanup confirmation")
        XCTAssertTrue(text("main atualizada").exists, "main was not updated")
        shot("end-session-done")
    }

    func testFaxinaPlansAndRuns() {
        app.launch()
        XCTAssertTrue(app.staticTexts["Início"].waitForExistence(timeout: 15))
        app.buttons["Projetos"].tap()
        app.buttons["Faxina"].tap()
        XCTAssertTrue(text("Worktrees sem ninguém").waitForExistence(timeout: 10))
        XCTAssertTrue(text("sandbox · old-pr").exists && text("branch enviada").exists)
        XCTAssertTrue(text("sandbox · wip").exists && text("2 commit(s) só nesta máquina").exists, "risky worktree not flagged")
        XCTAssertTrue(text("Atualizar a main de cada projeto").exists)
        shot("faxina-plan")
        // Only the worktrees: clear everything, then tick that group.
        element("housekeeping-selection").tap()
        app.buttons["Desmarcar tudo"].tap()
        XCTAssertTrue(element("housekeeping-run").label.contains("(0)"))
        element("toggle-removeWorktree").tap()
        XCTAssertTrue(element("housekeeping-run").label.contains("(2)"), "group toggle did not tick both worktrees: \(element("housekeeping-run").label)")
        element("toggle-removeWorktree").tap()
        XCTAssertTrue(element("housekeeping-run").label.contains("(0)"))
        element("housekeeping-selection").tap()
        app.buttons["Só os seguros"].tap()
        let run = element("housekeeping-run")
        XCTAssertTrue(run.label.contains("Executar"))
        run.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Atualizar 4 main(s)'")).firstMatch.waitForExistence(timeout: 5), "no confirmation summary")
        shot("faxina-confirm")
        app.buttons["Executar"].firstMatch.tap()
        XCTAssertTrue(text("worktree(s) removida(s)").waitForExistence(timeout: 15), "no results")
        XCTAssertTrue(text("main atualizada").exists)
        XCTAssertFalse(text("sandbox · wip").exists, "the risky worktree was touched although it was not ticked")
        shot("faxina-done")
    }
}
