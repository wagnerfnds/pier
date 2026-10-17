import XCTest

/// A worktree's terminal is a real one (LiveTerminal.swift, libghostty fed by the box's terminal stream): what is typed
/// goes straight to the shell, ⌃C (the keys bar's, or the hardware keyboard's) stops what runs, the tab is named after
/// it, and on the iPad side by side and back keeps its stream. Against the mock box's shells (UITestMockTerminals.swift),
/// whose stream echoes and runs lines as a shell
/// would. The terminal's text is its accessibility value (what VoiceOver reads), refreshed after each key.
final class LiveTerminalUITests: XCTestCase {
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMock", "1", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR",
                               "-openSession", "sandbox-subtract-claude-6s1", "-sessionNewTerminal", "1"] + extra
        app.launch()
        return app
    }

    private func screen(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "live-terminal").firstMatch
    }

    private func waitFor(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) {
        let term = screen(app)
        let found = NSPredicate { _, _ in (term.value as? String)?.contains(text) == true }
        let ok = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: found, object: nil)], timeout: timeout) == .completed
        XCTAssertTrue(ok, "the terminal never showed “\(text)”; it shows: \(term.value as? String ?? "nothing")", file: file, line: line)
    }

    /// A terminal just opened takes the keyboard by itself, and a tap on the terminal toggles it (Ghostty's way): it is
    /// tapped only while the keyboard is down.
    private func keyboardUp(_ app: XCUIApplication, _ term: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { tap(term) }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8), "the keyboard did not come up for the terminal",
                      file: file, line: line)
    }

    /// A tap where the terminal's text is, by position: the chat kept under the terminal (for going back to it at once)
    /// stays in the accessibility tree, so XCUITest takes the terminal's middle for covered and taps elsewhere (the keys
    /// bar's Esc).
    private func tap(_ term: XCUIElement) {
        term.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
    }

    func testTypingRunsInTheShellAndControlCStopsIt() {
        let app = launch()
        let term = screen(app)
        XCTAssertTrue(term.waitForExistence(timeout: 25), "the terminal tab did not open")
        waitFor(app, "ubuntu@devbox:~/code/sandbox-subtract$")
        keyboardUp(app, term)
        app.typeText("ls\n")
        waitFor(app, "test_calc.py")
        app.typeText("npm run dev\n")
        waitFor(app, "VITE v5.4.2")
        // The tab says what runs; while a line is being typed it does not.
        let tab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'terminal-tab-'")).firstMatch
        let named = NSPredicate(format: "label == 'npm run dev'")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: named, object: tab)], timeout: 8), .completed,
                       "the tab is not named after what runs: \(tab.label)")
        // A tap puts the keyboard away, and the keys bar under the terminal shows with ⌃C.
        tap(term)
        let interrupt = app.buttons["Control C, interromper"]
        XCTAssertTrue(interrupt.waitForExistence(timeout: 5), "the keys bar did not show with the keyboard down")
        interrupt.tap()
        waitFor(app, "^C")
        keyboardUp(app, term)
        app.typeText("pwd\n")
        waitFor(app, "/home/ubuntu/code/sandbox-subtract")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "live-terminal"; shot.lifetime = .keepAlways
        add(shot)
    }

    /// The hardware keyboard's ⌃C reaches the shell: the text system takes Ctrl+letter for itself unless the terminal
    /// claims it (on the Mac, ⌃C never left the old command line).
    func testHardwareControlCReachesTheShell() {
        let app = launch()
        let term = screen(app)
        XCTAssertTrue(term.waitForExistence(timeout: 25), "the terminal tab did not open")
        waitFor(app, "ubuntu@devbox:~/code/sandbox-subtract$")
        keyboardUp(app, term)
        app.typeText("sleep 30\n")
        waitFor(app, "sleep 30")
        app.typeKey("c", modifierFlags: .control)
        waitFor(app, "^C")
        app.typeText("echo after\n")
        waitFor(app, "after\nubuntu@devbox")
    }

    /// A box before terminal streams (`-mockTTY 0`) keeps the screen read every second and the command line.
    func testABoxWithoutStreamsKeepsTheCommandLine() {
        let app = launch(["-mockTTY", "0"])
        let field = app.descendants(matching: .any).matching(identifier: "terminal-field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 25), "the command line did not show")
        XCTAssertFalse(screen(app).exists, "a box without streams got a live terminal")
    }

    /// Side by side and back (the iPad; the Mac runs the same code): the terminal moves between the panes as the same
    /// view, so its stream goes on (no other one opened, no word over its screen such as "Reconectando…") and what it
    /// showed stays. The mock draws a terminal's lines again on a new stream, so the text alone would not tell: the
    /// stream's state and count (`live-terminal-stream`, Debug with the mock only) do.
    func testSideBySideAndBackKeepsTheTerminalStreaming() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("side by side is for the iPad and the Mac") }
        // On its side: room for the sidebar, the conversation and the terminal.
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        let app = launch()
        let term = screen(app)
        XCTAssertTrue(term.waitForExistence(timeout: 25), "the terminal tab did not open")
        waitFor(app, "ubuntu@devbox:~/code/sandbox-subtract$")
        keyboardUp(app, term)
        app.typeText("echo kept-across-panes\n")
        waitFor(app, "kept-across-panes\nubuntu@devbox")
        let stream = app.descendants(matching: .any).matching(identifier: "live-terminal-stream").firstMatch
        XCTAssertTrue(stream.waitForExistence(timeout: 5), "the terminal says nothing of its stream")
        let before = stream.value as? String ?? ""
        XCTAssertTrue(before.hasPrefix("live "), "the terminal is not live: \(before)")

        let toggle = app.buttons["session-side-by-side"]
        let conversation = app.buttons["session-tab-conversation"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the strip has no side-by-side button")
        toggle.tap()
        // Side by side both show, so Conversa is no tab.
        XCTAssertTrue(gone(conversation), "the tabs did not go side by side")
        waitFor(app, "kept-across-panes")
        XCTAssertEqual(stream.value as? String, before, "side by side, the terminal opened another stream or showed a word over its screen")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "side-by-side"; shot.lifetime = .keepAlways
        add(shot)

        toggle.tap()
        XCTAssertTrue(conversation.waitForExistence(timeout: 5), "the tabs did not come back")
        // Back in tabs the conversation shows; the terminal's tab brings the terminal back, on the same stream.
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'terminal-tab-'")).firstMatch.tap()
        waitFor(app, "kept-across-panes")
        XCTAssertEqual(stream.value as? String, before, "back in tabs, the terminal opened another stream or showed a word over its screen")
    }

    private func gone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let absent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [absent], timeout: timeout) == .completed
    }
}
