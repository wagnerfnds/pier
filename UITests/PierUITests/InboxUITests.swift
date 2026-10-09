import XCTest

/// The Inbox against the mock box: the waiting agent and the finished turn are listed; a permission is answered with the
/// key "1" (iPad, hardware keyboard) or a tap (iPhone); J / K move the focus; E (or a swipe) archives a finished turn; a
/// suggested next step is sent by a tap, in the Inbox and at the end of the session's chat, and the mock agent replies.
/// Screenshots go to the xcresult and, with `TEST_RUNNER_KBD_SHOTS=<dir>`, to that folder as `inbox-*.png`.
final class InboxUITests: XCTestCase {
    var app: XCUIApplication!

    private let waiting = "sandbox-claude-w9q"
    private let finished = "sandbox-subtract-claude-6s1"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestMock", "1", "-undoSeconds", "0", "-startTab", "inbox", "-inboxResetArchive", "1",
                               "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        XCTAssertTrue(card("needs", waiting).waitForExistence(timeout: 20), "the waiting agent is not in the Inbox")
    }

    private var pad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var device: String { pad ? "ipad" : "iphone" }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func card(_ kind: String, _ session: String) -> XCUIElement { element("inbox-card-\(kind)-\(session)") }
    private func text(containing s: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }
    private var focus: String { element("inbox-focus").label }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "\(name)-\(device)"; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["KBD_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("inbox-\(name)-\(device).png"))
        }
    }

    /// Waits until `condition` holds (polling), for state XCUITest has no expectation for.
    private func wait(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if condition() { return true }; usleep(250_000) }
        return condition()
    }

    func testListsTheWaitingAgentAndTheFinishedTurn() {
        XCTAssertTrue(card("done", finished).waitForExistence(timeout: 10), "the finished turn is not in the Inbox")
        XCTAssertFalse(card("done", waiting).exists)
        // The permission's options, numbered, read from the screen.
        XCTAssertTrue(element("inbox-option-1").waitForExistence(timeout: 15), "no options on the permission card")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Permitir'")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Negar'")).firstMatch.exists)
        XCTAssertTrue(text(containing: "mkdir probe_dir").exists, "the ask is not on the card")
        // The finished turn: its reply and the suggested next steps.
        XCTAssertTrue(text(containing: "Nothing was committed yet").waitForExistence(timeout: 15), "the reply is not on the card")
        XCTAssertTrue(element("next-step-1").waitForExistence(timeout: 15), "no suggested next steps")
        XCTAssertEqual(element("next-step-1").label, "Abra o PR")
        XCTAssertEqual(element("next-step-2").label, "Rode os testes de novo")
        // Needs-you first.
        XCTAssertLessThan(card("needs", waiting).frame.minY, card("done", finished).frame.minY, "needs-you is not above the finished work")
        shot("list")
        if pad {
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(2)
            shot("list-landscape")
            XCUIDevice.shared.orientation = .portrait
        }
    }

    func testAnswerPermission() {
        XCTAssertTrue(element("inbox-option-1").waitForExistence(timeout: 15), "no options on the permission card")
        if pad {
            // The first card has the focus: "1" is its first option (Permitir).
            XCTAssertTrue(wait(5) { focus == "devbox/\(waiting)" }, "the waiting card does not have the focus (\(focus))")
            shot("before-key")
            app.typeKey("1", modifierFlags: [])
        } else {
            element("inbox-option-1").tap()
        }
        XCTAssertTrue(card("needs", waiting).waitForNonExistence(timeout: 10), "the answered card stayed")
        // The mock agent continues and finishes: the same session comes back as finished work.
        XCTAssertTrue(card("done", waiting).waitForExistence(timeout: 20), "the agent did not carry on after the answer")
        shot("answered")
    }

    func testJKMovesTheFocus() throws {
        guard pad else { throw XCTSkip("hardware keyboard: iPad / Mac") }
        XCTAssertTrue(card("done", finished).waitForExistence(timeout: 10))
        XCTAssertTrue(wait(5) { focus == "devbox/\(waiting)" }, "focus does not start on the first card (\(focus))")
        app.typeKey("j", modifierFlags: [])
        XCTAssertTrue(wait(3) { focus == "devbox/\(finished)" }, "J did not move down (\(focus))")
        shot("focus-j")
        app.typeKey("j", modifierFlags: [])
        XCTAssertTrue(wait(2) { focus == "devbox/\(finished)" }, "J moved past the last card")
        app.typeKey("k", modifierFlags: [])
        XCTAssertTrue(wait(3) { focus == "devbox/\(waiting)" }, "K did not move up (\(focus))")
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(wait(3) { focus == "devbox/\(finished)" }, "↓ did not move down (\(focus))")
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(wait(3) { focus == "devbox/\(waiting)" }, "↑ did not move up (\(focus))")
    }

    func testArchiveFinishedTurn() {
        let done = card("done", finished)
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        if pad {
            app.typeKey("j", modifierFlags: [])
            XCTAssertTrue(wait(3) { focus == "devbox/\(finished)" }, "J did not move to the finished card")
            app.typeKey("e", modifierFlags: [])
        } else {
            // Swipe: the row's own action (the rightmost "Arquivar"; the card has a button with the same name).
            done.swipeLeft()
            sleep(1)
            let buttons = app.buttons.matching(NSPredicate(format: "label == 'Arquivar'")).allElementsBoundByIndex
            if done.exists, let b = buttons.max(by: { $0.frame.minX < $1.frame.minX }) { b.tap() }
        }
        XCTAssertTrue(done.waitForNonExistence(timeout: 5), "the finished card was not archived")
        // The focus moves on to the card that is left.
        if pad { XCTAssertTrue(wait(3) { focus == "devbox/\(waiting)" }, "focus did not move to the remaining card (\(focus))") }
        shot("archived")
    }

    /// A question with choices (`-uiTestAsk 1`): the card lists them, numbered; picking one answers and the agent carries on.
    func testQuestionCardOffersItsChoices() {
        app.terminate()
        app.launchArguments += ["-uiTestAsk", "1"]
        app.launch()
        let ask = "sandbox-ask-claude-q1"
        let card = card("needs", ask)
        XCTAssertTrue(card.waitForExistence(timeout: 20), "the question is not in the Inbox")
        XCTAssertTrue(text(containing: "Claude tem uma pergunta").waitForExistence(timeout: 10))
        XCTAssertTrue(text(containing: "Which layout for the pricing page?").exists)
        let second = card.descendants(matching: .any).matching(identifier: "inbox-option-2").firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 15), "no choices on the question card")
        XCTAssertEqual(second.label, "One plan")
        XCTAssertEqual(card.descendants(matching: .any).matching(identifier: "inbox-option-3").firstMatch.label, "A table")
        XCTAssertFalse(card.descendants(matching: .any).matching(identifier: "inbox-option-4").firstMatch.exists, "the agent's own rows are not choices")
        shot("question")
        if pad {
            // The permission card comes first (older); J moves to the question, then its second choice.
            app.typeKey("j", modifierFlags: [])
            XCTAssertTrue(wait(3) { focus == "devbox/\(ask)" }, "J did not move to the question (\(focus))")
            app.typeKey("2", modifierFlags: [])
        } else {
            second.tap()
        }
        XCTAssertTrue(card.waitForNonExistence(timeout: 10), "the answered question stayed")
        XCTAssertTrue(text(containing: "Going with One plan").waitForExistence(timeout: 25), "the choice did not reach the agent")
        shot("question-answered")
    }

    /// The box's own problems (`-uiTestHealth 1`: a signed-out agent, missing hooks, pierd stopping at logout) come first,
    /// each with the command to copy; "Ignorar por hoje" (or E) puts one away.
    func testBoxHealthCardsOfferTheFix() {
        app.terminate()
        app.launchArguments += ["-uiTestHealth", "1"]
        app.launch()
        let signIn = element("inbox-health-Agents.Codex-sign-in")
        XCTAssertTrue(signIn.waitForExistence(timeout: 20), "the signed-out agent is not in the Inbox")
        XCTAssertTrue(text(containing: "Codex não está autenticado em devbox").exists)
        XCTAssertTrue(text(containing: "codex login --device-auth").exists, "the fix is not on the card")
        XCTAssertTrue(element("inbox-health-Agents.Codex-hooks").exists)
        XCTAssertTrue(element("inbox-health-pierd.survives-logout").exists)
        // The boxes' cards come before the agents' (which sit below them, off the first screen on a phone).
        let first = element("inbox-health-pierd.survives-logout")
        XCTAssertLessThan(first.frame.minY, app.frame.midY, "the boxes' cards are not at the top")
        if card("needs", waiting).exists { XCTAssertLessThan(signIn.frame.minY, card("needs", waiting).frame.minY) }
        shot("health")
        // Copiar puts the command on the clipboard.
        let copy = signIn.descendants(matching: .any).matching(identifier: "inbox-health-copy").firstMatch
        XCTAssertTrue(copy.exists)
        copy.tap()
        // The button says so; what went to the clipboard shows in a hidden label (the test runner may not read the clipboard).
        XCTAssertTrue(text(containing: "Copiado").waitForExistence(timeout: 3))
        XCTAssertTrue(wait(3) { element("inbox-last-copied").label.contains("codex login --device-auth") }, "the fix was not copied")
        // Put away for today: E on the focused card (iPad: the sign-in card, focused by the tap on Copiar), the button on the iPhone.
        let hooks = element("inbox-health-Agents.Codex-hooks")
        if pad {
            XCTAssertTrue(wait(5) { focus.hasPrefix("health/devbox/") }, "a box's card does not have the focus (\(focus))")
            let focusedWasSignIn = focus.hasSuffix("Codex sign-in")
            app.typeKey("e", modifierFlags: [])
            XCTAssertTrue((focusedWasSignIn ? signIn : first).waitForNonExistence(timeout: 5), "E did not put the card away")
        } else {
            hooks.descendants(matching: .any).matching(identifier: "inbox-health-snooze").firstMatch.tap()
            XCTAssertTrue(hooks.waitForNonExistence(timeout: 5), "Ignorar por hoje did not put the card away")
        }
        shot("health-snoozed")
    }

    func testSuggestedNextStepIsSent() {
        let step = element("next-step-1")
        XCTAssertTrue(step.waitForExistence(timeout: 20), "no suggested next steps")
        step.tap()
        // The finished card leaves while the agent works, then comes back with the mock agent's answer to "Abra o PR".
        XCTAssertTrue(text(containing: "I read your message (9 characters)").waitForExistence(timeout: 20), "the suggestion did not reach the agent")
        shot("next-step-sent")
    }

    func testSuggestedNextStepInTheSession() {
        element("inbox-open-\(finished)").tap()
        XCTAssertTrue(element("composer-field").waitForExistence(timeout: 10), "the card did not open the session")
        let step = element("next-step-1")
        XCTAssertTrue(step.waitForExistence(timeout: 20), "no suggested next steps at the end of the chat")
        shot("session-next-steps")
        step.tap()
        XCTAssertTrue(text(containing: "I read your message (9 characters)").waitForExistence(timeout: 20), "the suggestion did not reach the agent")
        // A new turn: the old suggestions are gone until it finishes.
        shot("session-next-step-sent")
    }
}
