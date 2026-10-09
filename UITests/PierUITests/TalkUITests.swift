import XCTest

/// Falar against the mock box: a typed request -> the router's decision card -> Enviar -> the receipt -> the session opens
/// and the agent replies; a "new task" request creates a task; an ambiguous one shows the router's question (and the answer
/// routes); a decision naming a session that does not exist is refused; the hold-to-talk mic (iPhone) and the sheet's mic
/// feed the transcript (`-talkTranscript` stands in for the microphone); the palette hands a "> request" to Falar (iPad).
/// The mock's router answers by keyword (see the "Falar router" block in App/Debug/UITestMock.swift).
/// Screenshots go to the xcresult and, with `TEST_RUNNER_KBD_SHOTS=<dir>`, to that folder as `talk-*.png`.
final class TalkUITests: XCTestCase {
    var app: XCUIApplication!

    private let transcript = "Pede para o agente do subtract testar números negativos"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestMock", "1", "-undoSeconds", "0", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
    }

    private func launch(_ extra: [String] = []) {
        app.launchArguments += extra
        app.launch()
        XCTAssertTrue(app.staticTexts["Início"].waitForExistence(timeout: 15), "home did not load")
    }

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func text(containing s: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }
    private func value(_ e: XCUIElement) -> String { (e.value as? String) ?? "" }
    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "\(name)-\(device)"; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["KBD_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("talk-\(name)-\(device).png"))
        }
    }

    /// Opens Falar from the Home toolbar and types `request`.
    private func openTalk(typing request: String) {
        let button = element("talk-button")
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no Falar button in the Home toolbar")
        sleep(2)   // the Home settles (sessions, signals) before the sheet opens
        button.tap()
        let field = element("talk-field")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Falar did not open")
        shot("empty")
        field.tap()
        field.typeText(request)
    }

    private func route() {
        element("talk-route").tap()
    }

    private func decisionCard() -> XCUIElement {
        let card = element("talk-decision")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "no decision card")
        return card
    }

    // MARK: tests

    func testTypedRequestGoesToTheChosenSessionAndOpensIt() {
        launch()
        openTalk(typing: "Pede para o agente do subtract testar números negativos")
        shot("typed")
        route()
        _ = decisionCard()
        XCTAssertTrue(text(containing: "Mandar para").exists, "the card does not say where it goes")
        XCTAssertTrue(element("talk-decision-title").label.contains("subtract"), "the card names another session: \(element("talk-decision-title").label)")
        XCTAssertEqual(element("talk-decision-text").label, "Add a test for subtracting negative numbers.")
        shot("decision-send")
        element("talk-send").tap()
        let receipt = element("talk-receipt")
        XCTAssertTrue(receipt.waitForExistence(timeout: 8), "no receipt after sending")
        XCTAssertTrue(element("talk-field").waitForNonExistence(timeout: 5), "the sheet stayed open")
        XCTAssertTrue(element("talk-receipt-title").label.hasPrefix("Enviado para"), "receipt: \(element("talk-receipt-title").label)")
        shot("receipt")
        element("talk-receipt-open").tap()
        XCTAssertTrue(element("composer-field").waitForExistence(timeout: 10), "the receipt did not open the session")
        XCTAssertTrue(text(containing: "Add a test for subtracting negative numbers.").waitForExistence(timeout: 10), "the message is not in the conversation")
        XCTAssertTrue(text(containing: "Got it. I read your message").waitForExistence(timeout: 12), "the agent did not reply")
        shot("session-replied")
    }

    func testNewTaskRequestCreatesATask() {
        launch()
        openTalk(typing: "Nova tarefa no sandbox: escrever o README")
        route()
        _ = decisionCard()
        XCTAssertTrue(text(containing: "Nova tarefa em").exists, "the card is not a new task")
        XCTAssertEqual(element("talk-decision-title").label, "sandbox")
        XCTAssertTrue(text(containing: "Escrever o README").exists, "the task's title is not shown")
        shot("decision-new-task")
        // Editar: the prompt can be changed before it goes.
        element("talk-edit").tap()
        let edit = element("talk-edit-field")
        XCTAssertTrue(edit.waitForExistence(timeout: 3), "Editar did not make the text editable")
        edit.tap()
        edit.typeText(" Keep it short.")
        element("talk-edit").tap()   // Pronto
        XCTAssertTrue(element("talk-decision-text").waitForExistence(timeout: 3))
        XCTAssertTrue(element("talk-decision-text").label.hasSuffix("Keep it short."), "the edit was lost: \(element("talk-decision-text").label)")
        element("talk-send").tap()
        XCTAssertTrue(element("talk-receipt").waitForExistence(timeout: 10), "no receipt after creating the task")
        XCTAssertTrue(element("talk-receipt-title").label.contains("Nova tarefa em sandbox"), "receipt: \(element("talk-receipt-title").label)")
        shot("receipt-new-task")
        element("talk-receipt-open").tap()
        XCTAssertTrue(element("composer-field").waitForExistence(timeout: 12), "the new task's session did not open")
        XCTAssertTrue(text(containing: "Keep it short.").waitForExistence(timeout: 10), "the task's prompt is not in its conversation")
        XCTAssertTrue(text(containing: "Started. I'll let you know").waitForExistence(timeout: 12), "the new agent did not answer")
    }

    func testAmbiguousRequestAsksAndTheAnswerRoutes() {
        launch()
        openTalk(typing: "Arruma aquilo que eu falei ontem")
        route()
        let question = element("talk-question")
        XCTAssertTrue(question.waitForExistence(timeout: 10), "the router's question is not shown")
        XCTAssertEqual(question.label, "Em qual projeto: sandbox ou acme-web?")
        XCTAssertFalse(element("talk-decision").exists, "a decision showed up for an ambiguous request")
        XCTAssertEqual(value(element("talk-field")).isEmpty || value(element("talk-field")) == "Sua resposta…", true, "the field did not clear for the answer")
        shot("ask")
        let field = element("talk-field")
        field.tap()
        field.typeText("No sandbox, escrever o README")
        route()
        _ = decisionCard()
        XCTAssertEqual(element("talk-decision-title").label, "sandbox", "the answer did not lead to the sandbox task")
        // Outro agente: the person points it at another session instead.
        element("talk-pick").tap()
        let row = element("talk-target-session-sandbox-claude-w9q")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the picker does not list the sessions")
        shot("picker")
        row.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "the picker stayed open")
        XCTAssertTrue(text(containing: "Mandar para").waitForExistence(timeout: 5), "the card did not switch to the session")
        XCTAssertTrue(element("talk-decision-title").label.contains("probe directory"), "picked another session: \(element("talk-decision-title").label)")
    }

    func testUnknownSessionFromTheRouterIsRefused() {
        launch()
        openTalk(typing: "Manda pro agente fantasma")
        route()
        XCTAssertTrue(element("talk-error").waitForExistence(timeout: 10), "an unknown session was not refused")
        XCTAssertFalse(element("talk-decision").exists)
        XCTAssertFalse(element("talk-send").exists, "there is something to send to a session that does not exist")
    }

    /// Hold-to-talk on the Home (iPhone): the overlay shows while held; releasing routes what was heard.
    func testHoldToTalkFeedsTheTranscript() throws {
        if UIDevice.current.userInterfaceIdiom == .pad { throw XCTSkip("the hold-to-talk mic is on the iPhone Home") }
        launch(["-talkTranscript", transcript])
        let mic = element("talk-mic-hold")
        XCTAssertTrue(mic.waitForExistence(timeout: 10), "no hold-to-talk mic on the Home")
        XCTAssertTrue(element("new-task-button").exists, "Nova tarefa is gone")
        shot("home-mic")
        sleep(2)
        mic.press(forDuration: 2.5)
        let field = element("talk-field")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "releasing the mic did not open Falar")
        XCTAssertEqual(value(field), transcript, "the transcript did not reach the field")
        _ = decisionCard()
        XCTAssertTrue(element("talk-decision-title").label.contains("subtract"))
        shot("hold-decision")
    }

    /// The overlay while the mic is held (`-talkHoldDemo` holds it by itself, so it can be photographed).
    func testHoldOverlayShowsTheLiveTranscript() throws {
        if UIDevice.current.userInterfaceIdiom == .pad { throw XCTSkip("the hold-to-talk mic is on the iPhone Home") }
        launch(["-talkTranscript", transcript, "-talkHoldDemo", "1"])
        let words = element("talk-hold-transcript")
        XCTAssertTrue(words.waitForExistence(timeout: 10), "no overlay while the mic is held")
        let deadline = Date().addingTimeInterval(6)
        while !words.label.contains("subtract"), Date() < deadline { usleep(200_000) }
        XCTAssertTrue(words.label.hasPrefix("Pede para o agente"), "the live transcript is not shown: \(words.label)")
        shot("hold-overlay")
        XCTAssertTrue(element("talk-field").waitForExistence(timeout: 10), "letting go did not open Falar")
        XCTAssertTrue(element("talk-decision").waitForExistence(timeout: 10))
    }

    /// The sheet's mic: tap to dictate, the transcript fills the field live, tap again to stop.
    func testSheetMicDictatesIntoTheField() {
        launch(["-talkTranscript", transcript])
        element("talk-button").tap()
        let field = element("talk-field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        element("talk-mic").tap()
        let deadline = Date().addingTimeInterval(5)
        while !value(field).contains("agente"), Date() < deadline { usleep(150_000) }
        XCTAssertTrue(value(field).hasPrefix("Pede para"), "the field does not follow the dictation: \(value(field))")
        shot("listening")
        element("talk-mic").tap()
        XCTAssertEqual(value(field), transcript)
        route()
        _ = decisionCard()
    }

    /// iPad / Mac: "> request" in the palette (Return) and ⇧⌘Space hand the text to Falar.
    func testPaletteHandsARequestToTalk() throws {
        launch()
        if UIDevice.current.userInterfaceIdiom != .pad { throw XCTSkip("keyboard shortcuts: iPad / Mac") }
        sleep(2)
        app.typeKey("k", modifierFlags: .command)
        let palette = element("palette-field")
        XCTAssertTrue(palette.waitForExistence(timeout: 5), "⌘K did not open the palette")
        palette.typeText("> nova tarefa no sandbox: escrever o README")
        XCTAssertTrue(element("palette-item-request").waitForExistence(timeout: 3), "the palette does not offer Falar for a > request")
        shot("palette-request")
        palette.typeText("\n")
        XCTAssertTrue(palette.waitForNonExistence(timeout: 5), "the palette stayed open")
        _ = decisionCard()
        XCTAssertEqual(element("talk-decision-title").label, "sandbox")
        XCTAssertEqual(value(element("talk-field")), "nova tarefa no sandbox: escrever o README")
        shot("palette-decision")
        element("talk-close").tap()
        XCTAssertTrue(element("talk-field").waitForNonExistence(timeout: 5))
        app.typeKey(" ", modifierFlags: [.command, .shift])
        XCTAssertTrue(element("talk-field").waitForExistence(timeout: 5), "⇧⌘Space did not open Falar")
    }
}
