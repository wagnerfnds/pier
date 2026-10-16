import XCTest

/// Several questions at once (`-uiTestAskForm 1`), asked the way Claude Code asks them: the form is only in the session's
/// ask (from its hook), not in the transcript, which gets it once answered. The chat shows the whole form and answers it;
/// the Inbox card steps through it a question at a time (a multiple choice ticks, then Enviar). Screenshots go to the
/// xcresult and, with `TEST_RUNNER_KBD_SHOTS=<dir>`, to that folder as `form-*.png`.
final class QuestionFormUITests: XCTestCase {
    private let session = "sandbox-form-claude-q2"
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }

    private func launch(_ extra: [String]) {
        app = XCUIApplication()
        app.launchArguments = ["-uiTestMock", "1", "-uiTestAskForm", "1", "-undoSeconds", "0", "-inboxResetArchive", "1",
                               "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"] + extra
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func text(containing s: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }
    private func button(_ label: String, in root: XCUIElement? = nil) -> XCUIElement {
        (root ?? app).buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "\(name)-\(device)"; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["KBD_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("form-\(name)-\(device).png"))
        }
    }

    /// Opened from its notification: the chat's card holds both questions with their options, and Enviar resposta answers
    /// all of them at once; the agent carries on.
    func testTheChatShowsTheWholeFormAndAnswersIt() {
        launch(["-openSession", session])
        XCTAssertTrue(element("composer-field").waitForExistence(timeout: 15), "session screen did not open")
        let card = element("needs-you-card")
        XCTAssertTrue(card.waitForExistence(timeout: 12), "no card for the question")
        XCTAssertTrue(text(containing: "Claude tem uma pergunta").exists)
        XCTAssertTrue(text(containing: "Which colour for the header?").waitForExistence(timeout: 5), "the first question is not on the card")
        XCTAssertTrue(text(containing: "Which sections go on the page?").exists, "the second question is not on the card")
        XCTAssertFalse(text(containing: "Type something").exists, "the agent's own rows leaked into the form")
        shot("chat")
        button("Blue", in: card).tap()
        button("Pricing", in: card).tap()
        let send = button("Enviar resposta", in: card)
        // The card scrolls when the form is taller than it.
        if !send.isHittable { card.swipeUp() }
        button("Team", in: card).tap()
        if !send.isHittable { card.swipeUp() }
        XCTAssertTrue(send.isEnabled, "the form is complete but cannot be sent")
        send.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 10), "the card stayed after answering")
        XCTAssertTrue(text(containing: "Header in Blue, with Pricing, Team").waitForExistence(timeout: 15), "the answers did not reach the agent")
        shot("chat-answered")
    }

    /// The Home's "Precisa de você" names the question in its own words, never the tool ("AskUserQuestion  Which…").
    func testTheHomeShowsTheQuestionNotTheTool() {
        launch([])
        XCTAssertTrue(text(containing: "Which colour for the header?").waitForExistence(timeout: 20), "the question is not on the Home")
        XCTAssertFalse(text(containing: "AskUserQuestion").exists, "the tool's name is on the Home")
        shot("home-question")
    }

    /// The Inbox card has rows and number keys, not a form: one question at a time ("1 de 2"), a single choice moves on,
    /// a multiple choice ticks its rows (✓) and Enviar sends every answer.
    func testTheInboxStepsThroughTheForm() {
        launch(["-startTab", "inbox"])
        let card = element("inbox-card-needs-\(session)")
        XCTAssertTrue(card.waitForExistence(timeout: 20), "the question is not in the Inbox")
        XCTAssertTrue(text(containing: "Which colour for the header? (1 de 2)").waitForExistence(timeout: 10), "the first step is not shown")
        let option = { (n: Int) in card.descendants(matching: .any).matching(identifier: "inbox-option-\(n)").firstMatch }
        XCTAssertTrue(option(2).waitForExistence(timeout: 10), "no choices on the card")
        XCTAssertEqual(option(2).label, "Blue")
        XCTAssertFalse(option(3).exists, "a single choice has only its options")
        shot("inbox-step1")
        option(2).tap()
        XCTAssertTrue(text(containing: "Which sections go on the page? (2 de 2)").waitForExistence(timeout: 5), "the card did not move on")
        XCTAssertTrue(card.exists, "the card left before the last answer")
        XCTAssertEqual(option(4).label, "Enviar")
        option(1).tap()
        option(3).tap()
        XCTAssertTrue(wait(3) { option(1).label == "✓ Pricing" && option(3).label == "✓ Team" }, "the ticks are not shown (\(option(1).label))")
        shot("inbox-step2")
        option(4).tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 10), "the answered question stayed")
        // The agent's reply lands in its record (its finished card shows it).
        XCTAssertTrue(text(containing: "Header in Blue, with Pricing, Team").waitForExistence(timeout: 25), "the answers did not reach the agent")
        shot("inbox-answered")
    }

    private func wait(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if condition() { return true }; usleep(200_000) }
        return condition()
    }
}
