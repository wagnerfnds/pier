import XCTest

/// "Every answer waits a moment; Desfazer takes it back" and "titles are written by AI", against the mock box:
/// a permission answered and undone (the card comes back, nothing is sent), answered and left alone (it goes out after the
/// window), a composer message undone (its text comes back), and a new task whose prompt-derived title is replaced by the
/// one Haiku wrote (the mock answers the title prompt after 3 s).
final class UndoAndTitleUITests: XCTestCase {
    var app: XCUIApplication!

    static let waiting = "sandbox-claude-w9q"
    static let finished = "sandbox-subtract-claude-6s1"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestMock", "1", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
    }

    // MARK: helpers

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func text(containing s: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }
    private func shot(_ name: String) {
        let s = app.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["KBD_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    /// `undo`: the undo window for this run (3 s: XCUITest waits for the app to idle around each action, and the toast
    /// animates for the whole window, so a tap can take a second).
    private func launch(session: String? = nil, undo: Int = 3, extra: [String] = []) {
        app.launchArguments += ["-undoSeconds", "\(undo)"]
        if let session { app.launchArguments += ["-openSession", session] }
        app.launchArguments += extra
        app.launch()
    }

    /// The agent's reply to anything the mock receives (`send` and answers both end in it).
    private var reply: XCUIElement { text(containing: "I read your message") }

    // MARK: permission

    func testPermissionAnsweredThenUndoneSendsNothing() {
        launch(session: Self.waiting)
        let allow = element("needs-allow")
        XCTAssertTrue(allow.waitForExistence(timeout: 15), "needs-you card did not show")
        sleep(1)   // the card slides in
        allow.tap()
        let toast = element("undo-toast")
        XCTAssertTrue(toast.waitForExistence(timeout: 3), "no undo toast after answering")
        XCTAssertTrue(text(containing: "Permitir").exists, "the toast does not say what is being sent")
        XCTAssertFalse(element("needs-you-card").exists, "the card stays up while the answer waits")
        shot("undo-permission-pending")
        element("undo-button").tap()
        XCTAssertTrue(allow.waitForExistence(timeout: 3), "the card did not come back after Desfazer")
        XCTAssertTrue(toast.waitForNonExistence(timeout: 2), "the toast stayed after Desfazer")
        shot("undo-permission-undone")
        // Well past the window: still waiting, nothing reached the agent.
        sleep(4)
        XCTAssertTrue(allow.exists, "the card went away: the answer was sent anyway")
        XCTAssertFalse(reply.exists, "the agent got the undone answer")
    }

    func testPermissionAnsweredGoesOutAfterTheWindow() {
        launch(session: Self.waiting)
        let allow = element("needs-allow")
        XCTAssertTrue(allow.waitForExistence(timeout: 15), "needs-you card did not show")
        sleep(1)   // the card slides in
        allow.tap()
        let toast = element("undo-toast")
        XCTAssertTrue(toast.waitForExistence(timeout: 3), "no undo toast after answering")
        let tapped = Date()
        XCTAssertTrue(toast.waitForNonExistence(timeout: 6), "the toast never went away")
        XCTAssertGreaterThan(Date().timeIntervalSince(tapped), 1.0, "the answer did not wait the window")
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "the answer never reached the agent")
        XCTAssertFalse(element("needs-allow").exists, "the card came back after the answer went out")
        shot("undo-permission-sent")
    }

    func testCommandZUndoes() throws {
        // Like PaletteUITests / InboxUITests: the iPhone simulator does not deliver XCUITest's hardware keys to the app.
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("hardware keyboard: iPad / Mac") }
        launch(session: Self.waiting, undo: 5)
        let allow = element("needs-allow")
        XCTAssertTrue(allow.waitForExistence(timeout: 15), "needs-you card did not show")
        sleep(1)   // the card slides in
        allow.tap()
        XCTAssertTrue(element("undo-toast").waitForExistence(timeout: 2), "no undo toast after answering")
        // The first hardware key XCUITest synthesizes after the tap never reaches the app (waiting a second does not help;
        // a key typed first does): spend it on a bare ⇧, which does nothing.
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(allow.waitForExistence(timeout: 3), "⌘Z did not undo the answer")
        // Esc is wired too (the ring's shortcut, the composer's key handler), but the iPhone simulator never delivers an
        // XCUITest Esc to the app (the palette's Esc does not fire either), so only ⌘Z is checked here.
        sleep(6)
        XCTAssertTrue(allow.exists, "the undone answer went out")
        XCTAssertFalse(reply.exists, "the agent got the undone answer")
    }

    // MARK: composer

    func testComposerMessageUndoneComesBackToTheField() {
        launch(session: Self.finished)
        let field = element("composer-field")
        XCTAssertTrue(field.waitForExistence(timeout: 15), "session screen did not open")
        field.tap()
        let message = "Roda os testes de novo, por favor"
        field.typeText(message)
        element("composer-send").tap()
        let toast = element("undo-toast")
        XCTAssertTrue(toast.waitForExistence(timeout: 2), "no undo toast after sending")
        XCTAssertTrue(text(containing: message).exists, "the toast does not show the message")
        XCTAssertNotEqual(field.value as? String, message, "the composer kept the text while it waits")
        shot("undo-composer-pending")
        element("undo-button").tap()
        XCTAssertTrue(toast.waitForNonExistence(timeout: 2), "the toast stayed after Desfazer")
        for _ in 0..<15 where (field.value as? String) != message { usleep(200_000) }
        XCTAssertEqual(field.value as? String, message, "the text did not come back to the composer")
        shot("undo-composer-undone")
        sleep(4)
        XCTAssertFalse(reply.exists, "the undone message reached the agent")
    }

    func testComposerMessageGoesOutAfterTheWindow() {
        launch(session: Self.finished)
        let field = element("composer-field")
        XCTAssertTrue(field.waitForExistence(timeout: 15), "session screen did not open")
        field.tap()
        field.typeText("Pode seguir")
        element("composer-send").tap()
        XCTAssertTrue(element("undo-toast").waitForExistence(timeout: 2), "no undo toast after sending")
        XCTAssertFalse(reply.exists, "sent before the window ended")
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "the message never reached the agent")
    }

    func testUndoOffSendsAtOnce() {
        launch(session: Self.waiting, undo: 0)
        let allow = element("needs-allow")
        XCTAssertTrue(allow.waitForExistence(timeout: 15), "needs-you card did not show")
        sleep(1)   // the card slides in
        allow.tap()
        XCTAssertTrue(reply.waitForExistence(timeout: 6), "the answer did not go out")
        XCTAssertFalse(element("undo-toast").exists, "a toast with the undo time off")
    }

    // MARK: AI titles

    func testNewTaskGetsAnAITitle() {
        let prompt = "Responda apenas com o total da fatura de outubro e arredonde para cima"
        launch()
        let newTask = app.buttons["Nova tarefa"].firstMatch
        XCTAssertTrue(newTask.waitForExistence(timeout: 15), "no Nova tarefa on the Home")
        newTask.tap()
        let editor = element("compose-prompt")
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "compose did not open")
        editor.tap()
        editor.typeText(prompt)
        let start = element("compose-start")
        for _ in 0..<20 where !start.isEnabled { usleep(250_000) }
        start.tap()
        let field = element("composer-field")
        if !field.waitForExistence(timeout: 20) { shot("title-compose-stuck") }
        XCTAssertTrue(field.exists, "the new session did not open")
        // First the box's own title (the prompt cut short), then the one the model wrote.
        let derived = text(containing: String(prompt.prefix(20)))
        XCTAssertTrue(derived.waitForExistence(timeout: 3), "the prompt-derived title was not shown first")
        shot("title-before")
        let ai = text(containing: "Ajustar arredondamento da fatura")
        XCTAssertTrue(ai.waitForExistence(timeout: 12), "the AI title never replaced the prompt-derived one")
        shot("title-after")
    }

    func testGenerateTitleFromTheMenu() {
        launch(session: Self.finished)
        XCTAssertTrue(element("composer-field").waitForExistence(timeout: 15), "session screen did not open")
        sleep(2)   // the transcript (its first message) loads
        app.buttons["Mais ações"].firstMatch.tap()
        let item = app.buttons["Gerar título com IA"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no Gerar título com IA in the ⋯ menu")
        item.tap()
        let ai = app.staticTexts.matching(NSPredicate(format: "label IN {'Fix invoice total rounding', 'Ajustar arredondamento da fatura'}")).firstMatch
        XCTAssertTrue(ai.waitForExistence(timeout: 12), "the AI title did not arrive")
        shot("title-menu")
    }

    // MARK: setting

    func testUndoTimeSettingIsOffered() {
        launch(extra: ["-startTab", "settings"])
        let picker = element("undo-seconds")
        for _ in 0..<6 where !(picker.exists && picker.isHittable) { app.swipeUp() }
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "no Tempo para desfazer in Ajustes")
        XCTAssertTrue(text(containing: "Tempo para desfazer").exists)
        shot("undo-setting")
    }
}
