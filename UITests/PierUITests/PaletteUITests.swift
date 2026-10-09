import XCTest

/// ⌘K command palette and menu shortcuts, with a hardware keyboard (iPad; the same commands drive the Mac menu bar).
final class PaletteUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestMock", "1", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Início"].waitForExistence(timeout: 15), "home did not load")
        if UIDevice.current.userInterfaceIdiom != .pad { throw XCTSkip("keyboard shortcuts: iPad / Mac") }
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["KBD_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    func testCommandKFindsAndOpens() {
        sleep(2)
        app.typeKey("k", modifierFlags: .command)
        let field = element("palette-field")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘K did not open the palette")
        XCTAssertTrue(element("palette-item-action-board").exists, "actions are not listed")
        shot("palette-empty")
        field.typeText("subtr")
        sleep(1)
        shot("palette-query")
        XCTAssertTrue(element("palette-item-worktree-devbox/sandbox/subtract").waitForExistence(timeout: 5)
                      || app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'palette-item-worktree-' AND identifier ENDSWITH '/subtract'")).firstMatch.exists,
                      "the worktree is not found")
        shot("palette-query")
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.upArrow, modifierFlags: [])
        field.typeText("\n")
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Return did not close the palette")
        // "subtr" is a prefix of the worktree, only inside the session's title: the worktree is the first result.
        XCTAssertFalse(element("composer-field").waitForExistence(timeout: 3), "a session opened instead of the worktree")
        XCTAssertTrue(app.staticTexts["subtract"].waitForExistence(timeout: 8), "the worktree did not open")
        shot("palette-opened")
    }

    func testMenuShortcuts() {
        sleep(2)
        app.typeKey("3", modifierFlags: .command)
        sleep(2)
        shot("shortcut-board")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'board-column'")).firstMatch.waitForExistence(timeout: 6),
                      "⌘3 did not open the board")
        app.typeKey("4", modifierFlags: .command)
        sleep(2)
        shot("shortcut-projects")
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.buttons["new-task-button"].waitForExistence(timeout: 6), "⌘1 did not open the Home")
        app.typeKey("p", modifierFlags: .command)
        XCTAssertTrue(element("palette-field").waitForExistence(timeout: 5), "⌘P did not open the palette")
        // The simulator does not deliver Esc from XCUITest; the "esc" chip is the same close action.
        app.buttons["Fechar"].firstMatch.tap()
        XCTAssertTrue(element("palette-field").waitForNonExistence(timeout: 5), "the palette did not close")
    }
}
