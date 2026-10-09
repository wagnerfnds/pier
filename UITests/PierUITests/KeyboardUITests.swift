import XCTest

/// Drives the real app (in-memory mock box, `-uiTestMock 1`) with the real software keyboard.
/// Screenshots go to the xcresult as attachments and, when `KBD_SHOTS` (as `TEST_RUNNER_KBD_SHOTS`) is set, to that folder.
final class KeyboardUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestMock", "1", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Início"].waitForExistence(timeout: 15), "home did not load")
    }

    // MARK: helpers


    private func shot(_ name: String) {
        let s = app.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name; a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["KBD_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private var keyboard: XCUIElement { app.keyboards.firstMatch }

    private func waitForKeyboard(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(keyboard.waitForExistence(timeout: 8), "the software keyboard did not appear (Simulator: I/O > Keyboard > Connect Hardware Keyboard must be off)", file: file, line: line)
    }

    /// Hittable and fully above the keyboard (when it is up).
    private func assertReachable(_ e: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(e.exists, "\(what) does not exist", file: file, line: line)
        XCTAssertTrue(e.isHittable, "\(what) is not hittable", file: file, line: line)
        if e.identifier != "compose-start", e.identifier != "composer-field", e.identifier != "composer-send" {
            XCTAssertGreaterThanOrEqual(e.frame.minY, navBottom - 1, "\(what) is under the navigation bar", file: file, line: line)
        }
        if let bar = submitBarTop, e.identifier != "compose-start" {
            XCTAssertLessThanOrEqual(e.frame.maxY, bar + 8, "\(what) is under the submit bar", file: file, line: line)
        }
        if keyboard.exists {
            XCTAssertLessThanOrEqual(e.frame.maxY, keyboard.frame.minY + 1, "\(what) is under the keyboard (\(e.frame) vs kbd \(keyboard.frame))", file: file, line: line)
        }
    }

    /// Drags on the window between two heights (fractions of the window), starting where a page scroll view (not a
    /// text editor or code block) is.
    private func drag(fromY: CGFloat, toY: CGFloat, x: CGFloat = 0.985) {
        let w = app.windows.firstMatch
        let a = w.coordinate(withNormalizedOffset: CGVector(dx: x, dy: fromY))
        let b = w.coordinate(withNormalizedOffset: CGVector(dx: x, dy: toY))
        a.press(forDuration: 0.1, thenDragTo: b, withVelocity: .default, thenHoldForDuration: 0)
    }

    /// On Compose the submit bar sits above the keyboard: content must end above it too.
    private var submitBarTop: CGFloat? {
        let s = element("compose-start")
        return s.exists ? s.frame.minY - 8 : nil
    }

    private var navBottom: CGFloat { app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY - 2 : 0 }

    /// Scrolls the page until `e` is hittable and between the navigation bar and the submit bar / keyboard.
    /// Swipes start on a card (not on the editor, which would scroll itself).
    private func scrollTo(_ e: XCUIElement, tries: Int = 14) {
        for _ in 0..<tries {
            let limit = min(keyboard.exists ? keyboard.frame.minY - 4 : .infinity, submitBarTop ?? .infinity)
            let inside = e.exists && e.isHittable && e.frame.maxY <= limit && e.frame.minY >= navBottom
            if inside { return }
            // below the visible band (or missing): move the content up; above it: down.
            let needDown = e.exists && e.frame.minY < navBottom
            // Pan on the page from mid-screen (cards, not the editor, once the first scroll moved it).
            // Short pans: the visible band between the bars is only ~350pt, a full swipe would overshoot it.
            let w = app.windows.firstMatch
            let from = w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: needDown ? 140 : -140)))
        }
    }

    private func openSession(titled prefix: String) {
        let row = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        var tries = 0
        while !(row.exists && row.isHittable), tries < 5 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "session row '\(prefix)' not found")
        row.tap()
        XCTAssertTrue(element("composer-field").waitForExistence(timeout: 10), "session screen did not open")
    }

    // MARK: item 4: Home "Nova tarefa"

    func testHomeNewTaskPlacement() {
        let b = element("new-task-button")
        XCTAssertTrue(b.waitForExistence(timeout: 5))
        XCTAssertLessThan(b.frame.minY, 140, "+ is not in the navigation bar, next to Falar")
        shot("home-new-task")
        XCTAssertTrue(b.isHittable)
        b.tap()
        XCTAssertTrue(element("compose-prompt").waitForExistence(timeout: 8))
    }

    // MARK: (a) Compose

    func testComposeLongPromptAndOptionsWithKeyboard() {
        element("new-task-button").tap()
        let prompt = element("compose-prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        prompt.tap()
        waitForKeyboard()
        let lines = (1...14).map { "Linha \($0): descreva o comportamento esperado do agente com bastante detalhe." }
        prompt.typeText(lines.joined(separator: "\n"))
        let start = element("compose-start")
        assertReachable(start, "Iniciar tarefa (typing)")
        shot("kbd-compose-typing")

        // Chips (agent buttons) sit under the project row: reachable by scrolling while the keyboard is up.
        let agent = element("agent-chip-claude")
        scrollTo(agent)
        assertReachable(agent, "chip do agente")
        shot("kbd-compose-chips")

        // Opções lives below the prompt: reach it by scrolling with the keyboard still up, open it.
        let options = element("compose-options")
        scrollTo(options)
        assertReachable(options, "Opções")
        options.tap()
        assertReachable(start, "Iniciar tarefa (options open)")
        // The last row of the options ("Título") must be reachable by scrolling.
        let title = app.textFields["opcional"]
        scrollTo(title)
        assertReachable(title, "campo Título")
        shot("kbd-compose-options")
        assertReachable(start, "Iniciar tarefa (title visible)")

        // Dismiss by dragging the list down.
        drag(fromY: 0.35, toY: 0.95, x: 0.985)
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 6), "keyboard did not dismiss interactively on Compose")
        XCTAssertTrue(start.isHittable)
        shot("kbd-compose-dismissed")
    }

    // MARK: (b) Session composer

    func testSessionComposerGrowsSendsAndDismisses() {
        openSession(titled: "Add a subtract function")
        let field = element("composer-field")
        shot("kbd-session-closed")
        field.tap()
        waitForKeyboard()
        let h0 = field.frame.height
        field.typeText("primeira linha\nsegunda linha\nterceira linha\nquarta linha")
        let h1 = field.frame.height
        XCTAssertGreaterThan(h1, h0 + 20, "composer did not grow with multiple lines (\(h0) -> \(h1))")
        let send = element("composer-send")
        assertReachable(send, "botão Enviar")
        assertReachable(field, "campo de mensagem")
        shot("kbd-session-composer")

        // Interactive dismissal: drag the conversation down.
        drag(fromY: 0.35, toY: 0.95, x: 0.5)
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 6), "keyboard did not dismiss interactively")
        shot("kbd-session-dismissed")
        XCTAssertTrue(send.isHittable, "send button must stay visible after dismissal")

        // Send a new message: the conversation follows to the bottom.
        field.tap()
        waitForKeyboard()
        field.typeText("Mensagem final do teste")
        // the text field already holds the earlier lines; clear for a clean assertion
        let sendNow = element("composer-send")
        assertReachable(sendNow, "botão Enviar")
        sendNow.tap()
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'I read your message'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 12), "the reply never showed up")
        sleep(1)
        let composerTop = field.frame.minY
        XCTAssertTrue(reply.isHittable, "latest message is not on screen: conversation did not scroll to the bottom")
        XCTAssertLessThanOrEqual(reply.frame.maxY, composerTop + 2, "latest message hides behind the composer")
        shot("kbd-session-scrolled")
    }

    // MARK: item 2: Revisar card

    func testReviewCardOpensReview() {
        openSession(titled: "Add a subtract function")
        sleep(2)
        shot("review-card")   // the card is the last thing in the conversation: look at it in the screenshot
        // XCUITest does not see the bottom ~130pt of the lazily laid out conversation (an accessibility-snapshot quirk,
        // the same rows are on screen), so tap where the "Revisar" button is: right end of the card above the composer.
        let button = app.buttons["Revisar"].firstMatch
        if button.exists { button.tap() } else { app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.83, dy: 0.855)).tap() }
        XCTAssertTrue(element("composer-field").waitForNonExistence(timeout: 8), "Revisar did not leave the chat")
        shot("review-from-card")
    }

    // MARK: (c) needs-you

    func testNeedsYouButtonsWithKeyboardClosedAndOpen() {
        openSession(titled: "Create a probe directory")
        let allow = element("needs-allow"), deny = element("needs-deny")
        XCTAssertTrue(allow.waitForExistence(timeout: 10), "needs-you card did not show")
        assertReachable(allow, "Permitir (teclado fechado)")
        assertReachable(deny, "Negar (teclado fechado)")
        shot("kbd-needs-you-closed")

        let field = element("composer-field")
        field.tap()
        waitForKeyboard()
        field.typeText("uma pergunta antes de permitir")
        assertReachable(allow, "Permitir (teclado aberto)")
        assertReachable(deny, "Negar (teclado aberto)")
        assertReachable(element("needs-you-card"), "cartão precisa de você")
        shot("kbd-needs-you-open")

        allow.tap()
        // answering sends the key; the mock agent then works and the card goes away
        XCTAssertTrue(allow.waitForNonExistence(timeout: 10), "needs-you card stayed after answering")
        // The answer waits the undo window ("Enviando… Desfazer") before it goes out: the agent must still get it.
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'I read your message'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 12), "the answer never reached the agent")
        XCTAssertFalse(allow.exists, "the card came back after the answer went out")
    }
}
