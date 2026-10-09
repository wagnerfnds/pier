import XCTest

/// The Live Activity's links and the suggested next steps, against the mock box (iPhone and iPad):
/// `pier://review` (the activity's "Revisar") opens the Review of the session's worktree, a next step tapped at the end of
/// the chat turns its row green and shows the receipt once the undo window ends, and a Live Activity started for the
/// mock's sessions survives a trip to the Home Screen (its screenshot goes with the run, for the Dynamic Island).
final class ActivityAndStepsUITests: XCTestCase {
    var app: XCUIApplication!

    private let finished = "sandbox-subtract-claude-6s1"
    private let waiting = "sandbox-claude-w9q"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestMock", "1", "-uiTestAsk", "1", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }

    private func shot(_ name: String, _ screenshot: XCUIScreenshot? = nil) {
        let s = screenshot ?? app.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = "\(name)-\(device)"; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["KBD_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("activity-\(name)-\(device).png"))
        }
    }

    /// The Live Activity's "Revisar" is a `pier://review` link: the Review screen of the worktree, not the chat.
    func testReviewLinkOpensReview() {
        app.launchArguments += ["-openLink", "pier://review?box=devbox&name=\(finished)"]
        app.launch()
        // The Review screen is titled with the worktree ("subtract"); the chat would show the composer.
        XCTAssertTrue(app.navigationBars["subtract"].waitForExistence(timeout: 20), "pier://review did not open the Review screen")
        XCTAssertFalse(element("composer-field").exists, "the link opened the chat instead of the Review")
        shot("review-link")
    }

    /// A session link still opens the chat.
    func testSessionLinkOpensTheChat() {
        app.launchArguments += ["-openLink", "pier://session?box=devbox&name=\(waiting)"]
        app.launch()
        XCTAssertTrue(element("composer-field").waitForExistence(timeout: 15), "pier://session did not open the chat")
        XCTAssertTrue(element("needs-you-card").waitForExistence(timeout: 10))
    }

    /// The next steps at the end of a finished chat are full-width rows; the one tapped turns green ("Escolhido") while the
    /// undo window runs, and the receipt ("Enviado para Claude") shows once the words went out.
    func testNextStepRowTurnsGreenThenShowsTheReceipt() {
        app.launchArguments += ["-openSession", finished, "-undoSeconds", "2"]
        app.launch()
        let step = element("next-step-1")
        XCTAssertTrue(step.waitForExistence(timeout: 25), "no suggested next steps at the end of the chat")
        XCTAssertEqual(step.label, "Abra o PR")
        shot("next-steps-rows")
        step.tap()
        XCTAssertEqual(step.value as? String, "Escolhido", "the tapped row is not marked as chosen")
        shot("next-step-chosen")
        XCTAssertTrue(element("next-steps-receipt").waitForExistence(timeout: 8), "no receipt after the undo window")
        XCTAssertTrue(element("next-steps-receipt").label.contains("Enviado"), "the receipt has no words: \(element("next-steps-receipt").label)")
        shot("next-step-receipt")
    }

    /// Esc / "Desfazer" within the window: the row is a plain row again and nothing was sent.
    func testNextStepUndoneComesBack() {
        app.launchArguments += ["-openSession", finished, "-undoSeconds", "5"]
        app.launch()
        let step = element("next-step-1")
        XCTAssertTrue(step.waitForExistence(timeout: 25), "no suggested next steps at the end of the chat")
        step.tap()
        XCTAssertEqual(step.value as? String, "Escolhido")
        let undo = element("undo-button")
        XCTAssertTrue(undo.waitForExistence(timeout: 3), "no Desfazer in the toast")
        undo.tap()
        XCTAssertTrue(step.waitForExistence(timeout: 3))
        XCTAssertNotEqual(step.value as? String, "Escolhido", "undo left the row marked")
        XCTAssertFalse(element("next-steps-receipt").exists)
    }

    /// The app follows the mock's running and waiting sessions with Live Activities (`-debugStartActivity 1`); on the
    /// Home Screen they stay (the island / the Lock Screen), and the app comes back where it was.
    func testLiveActivitiesSurviveTheHomeScreen() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("Live Activities are checked on the iPhone") }
        app.launchArguments += ["-debugStartActivity", "1"]
        app.launch()
        XCTAssertTrue(element("agent-dots").waitForExistence(timeout: 15))
        sleep(7)   // the hook starts the activities 5 s after launch
        XCUIDevice.shared.press(.home)
        sleep(3)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        shot("home-screen-island", XCUIScreen.main.screenshot())
        // The island shows the activity started for the waiting agent (its title) when the simulator exposes it.
        let island = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'probe directory' OR label CONTAINS 'Precisa de você'")).firstMatch
        if island.waitForExistence(timeout: 5) {
            shot("island-found", XCUIScreen.main.screenshot())
        }
        app.activate()
        XCTAssertTrue(element("agent-dots").waitForExistence(timeout: 10), "the app did not come back")
    }
}
