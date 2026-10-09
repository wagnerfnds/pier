import XCTest

/// Answering from the notification, against the mock box with `-uiTestAsk 1` (an agent asking "Which layout for the pricing
/// page?" with three choices drawn on its screen): the notification the app posts carries the choices as its buttons (a
/// category of their own), the banner on screen offers them, and a choice button answers the question; the same path a push
/// takes through the service extension (docs/PUSH.md 4.3). Screenshots go to the xcresult and, with
/// `TEST_RUNNER_KBD_SHOTS=<dir>`, to that folder as `notif-*.png`.
final class NotificationUITests: XCTestCase {
    private let ask = "sandbox-ask-claude-q1"
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private var pad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var device: String { pad ? "ipad" : "iphone" }

    private func launch(_ extra: [String]) {
        app = XCUIApplication()
        app.launchArguments = ["-uiTestMock", "1", "-uiTestAsk", "1", "-undoSeconds", "0", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"] + extra
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func text(containing s: String, in a: XCUIApplication? = nil) -> XCUIElement {
        (a ?? app).descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }

    private func shot(_ name: String, of a: XCUIApplication? = nil) {
        let target = a ?? app!
        let a = XCTAttachment(screenshot: target.screenshot()); a.name = "\(name)-\(device)"; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["KBD_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? target.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("notif-\(name)-\(device).png"))
        }
    }

    /// The system's permission prompt, the first time the app asks for notifications on this simulator.
    private func allowNotifications(timeout: TimeInterval = 6) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons.matching(NSPredicate(format: "label == 'Allow' OR label == 'Permitir'")).firstMatch
        if allow.waitForExistence(timeout: timeout) { allow.tap() }
    }

    /// The dialog the debug intent runner shows with what it did (`DebugSnippetOverlay`); a tap dismisses it.
    private func intentDialog(containing s: String, timeout: TimeInterval = 25) -> XCUIElement {
        let e = text(containing: s)
        XCTAssertTrue(e.waitForExistence(timeout: timeout), "the intent runner did not report \(s)")
        return e
    }

    func testQuestionNotificationCarriesItsChoicesAsButtons() {
        launch(["-runIntent", "postNotif", "-intentSession", "devbox/\(ask)", "-startTab", "inbox"])
        allowNotifications(timeout: 3)
        // The banner at the top of the screen (the app is in front) stays only a few seconds: look for it first. Long-press
        // expands it to the choice buttons, and one of them answers the question without opening the app, the same as
        // from the Lock Screen. A banner gone by (or never shown by the simulator) is read from Notification Center instead.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var notification = text(containing: "pricing page", in: springboard)
        var fromCenter = false
        if !notification.waitForExistence(timeout: 8) {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
                .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
            notification = text(containing: "pricing page", in: springboard)
            fromCenter = true
            XCTAssertTrue(notification.waitForExistence(timeout: 8), "the notification is neither on screen nor in Notification Center")
        }
        shot(fromCenter ? "center" : "banner", of: springboard)
        notification.press(forDuration: 1.5)
        let choice = springboard.buttons["One plan"]
        let expanded = choice.waitForExistence(timeout: 6)
        shot(expanded ? "expanded" : "not-expanded", of: springboard)
        if expanded {
            choice.tap()
        } else if fromCenter {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
        }
        app.activate()
        // The app registered a category for the three choices and posted the notification with it.
        let line = intentDialog(containing: "category=CHOICE:").label
        XCTAssertTrue(line.contains("posted waiting"), line)
        XCTAssertTrue(line.contains("buttons=Three tiers | One plan | A table | Abrir"), line)
        shot("posted")
        text(containing: "category=CHOICE:").tap()   // dismisses the intent dialog
        if expanded {
            // The mock agent took the choice and carried on: the question left the Inbox and its answer is on the finished card.
            XCTAssertTrue(text(containing: "Going with One plan").waitForExistence(timeout: 25), "the choice did not reach the agent")
            shot("answered")
        }
    }

    func testChoiceButtonAnswersTheQuestion() {
        // The action handler, as the system calls it for a `CHOICE_<n>` button (here without the banner round-trip).
        launch(["-runIntent", "notifAction", "-notifActionID", "CHOICE_1", "-intentSession", "devbox/\(ask)", "-startTab", "inbox"])
        let dialog = intentDialog(containing: "action CHOICE_1 -> done")
        dialog.tap()
        XCTAssertTrue(text(containing: "Going with One plan").waitForExistence(timeout: 25), "the choice did not reach the agent")
        XCTAssertFalse(element("inbox-card-needs-\(ask)").exists, "the question is still waiting")
        shot("choice-answered")
    }

    func testChoiceThatIsGoneFails() {
        // A choice the agent no longer offers is refused (the box is read again first; nothing is typed blindly).
        launch(["-runIntent", "notifAction", "-notifActionID", "CHOICE_3", "-intentSession", "devbox/\(ask)", "-startTab", "inbox"])
        _ = intentDialog(containing: "action CHOICE_3 -> failed")
        XCTAssertTrue(element("inbox-card-needs-\(ask)").waitForExistence(timeout: 10), "the question should still be waiting")
    }
}
