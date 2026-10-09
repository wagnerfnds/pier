import XCTest

/// Marketing screenshots that need the system's own UI or a rotation, against the mock box's showcase dataset
/// (`-uiTestShowcase 1`): the Dynamic Island and the Lock Screen with a Live Activity, a notification with a question's
/// choices as its buttons, the iPad in landscape. Skipped unless `TEST_RUNNER_SHOWCASE_SHOTS=<dir>` names a folder for the
/// PNGs (`xcodebuild test … -only-testing:PierUITests/ShowcaseShots`); `TEST_RUNNER_SHOWCASE_LANG=pt-BR` shoots the app (and the
/// showcase dataset) in Brazilian Portuguese. Not a test of behaviour: nothing here asserts.
final class ShowcaseShots: XCTestCase {
    private var dir: URL!
    private let question = "storefront-pricing-page-claude-c41e"
    private let finished = "billing-api-webhook-retries-claude-9b1d"

    override func setUpWithError() throws {
        guard let d = ProcessInfo.processInfo.environment["SHOWCASE_SHOTS"], !d.isEmpty else { throw XCTSkip("SHOWCASE_SHOTS not set") }
        dir = URL(fileURLWithPath: d)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        continueAfterFailure = true
    }

    private var pad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var portuguese: Bool { ProcessInfo.processInfo.environment["SHOWCASE_LANG"]?.lowercased().hasPrefix("pt") ?? false }
    /// Words of the question's notification as the showcase writes them in the app's language.
    private var questionWords: String { portuguese ? "página de preços" : "pricing page" }
    private var secondChoice: String { portuguese ? "Um plano só" : "One plan" }
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    private func launch(_ extra: [String], appearance: String = "dark") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMock", "1", "-uiTestShowcase", "1", "-undoSeconds", "2", "-appearance", appearance,
                               "-AppleLanguages", portuguese ? "(pt-BR)" : "(en)", "-AppleLocale", portuguese ? "pt_BR" : "en_US"] + extra
        app.launch()
        return app
    }

    /// The whole screen (the system's UI included), as a PNG.
    private func save(_ name: String) {
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appendingPathComponent(name + ".png"))
    }

    private func lockButton() {
        let sel = NSSelectorFromString("pressLockButton")
        if XCUIDevice.shared.responds(to: sel) { XCUIDevice.shared.perform(sel) }
    }

    private func allowNotifications() {
        let allow = springboard.buttons.matching(NSPredicate(format: "label == 'Allow' OR label == 'Permitir'")).firstMatch
        if allow.waitForExistence(timeout: 5) { allow.tap() }
    }

    func testIslandAndLockScreen() throws {
        guard !pad else { throw XCTSkip("iPhone only") }
        let app = launch(["-debugStartActivity", "1", "-startTab", "inbox"])
        sleep(10)   // the activities start a few seconds after launch
        XCUIDevice.shared.press(.home)
        sleep(3)
        save("iphone-island-compact")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.025)).press(forDuration: 1.0)
        sleep(2)
        save("iphone-island-expanded")
        XCUIDevice.shared.press(.home)
        sleep(1)
        lockButton()
        sleep(2)
        save("iphone-lock-1")
        lockButton()
        sleep(2)
        save("iphone-lock-2")
        springboard.swipeUp()
        sleep(2)
        app.activate()
    }

    func testNotificationWithChoices() throws {
        guard !pad else { throw XCTSkip("iPhone only") }
        let app = launch(["-runIntent", "postNotif", "-intentSession", "devbox/\(question)", "-intentDelay", "8", "-startTab", "inbox"])
        allowNotifications()
        sleep(1)
        XCUIDevice.shared.press(.home)   // the banner arrives over the Home Screen
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", questionWords)).firstMatch
        _ = banner.waitForExistence(timeout: 20)
        sleep(1)
        save("iphone-notification-banner")
        banner.press(forDuration: 1.5)
        _ = springboard.buttons[secondChoice].waitForExistence(timeout: 6)
        sleep(1)
        save("iphone-notification-expanded")
        app.activate()
        sleep(1)
        // The same notification on the Lock Screen.
        app.terminate()
        let again = launch(["-runIntent", "postNotif", "-intentSession", "devbox/\(question)", "-intentDelay", "8", "-startTab", "inbox"])
        sleep(1)
        XCUIDevice.shared.press(.home)
        sleep(1)
        lockButton()
        sleep(12)
        save("iphone-lock-notification")
        let locked = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", questionWords)).firstMatch
        if locked.waitForExistence(timeout: 5) {
            locked.press(forDuration: 1.5)
            sleep(1)
            save("iphone-lock-notification-expanded")
        }
        springboard.swipeUp()
        sleep(2)
        again.activate()
    }

    func testIPadLandscape() throws {
        guard pad else { throw XCTSkip("iPad only") }
        XCUIDevice.shared.orientation = .landscapeLeft
        var app = launch(["-startTab", "board", "-seedSections", "1"])
        sleep(16)
        save("ipad-board-landscape-dark")
        app.terminate()
        app = launch(["-openSession", finished, "-seedSections", "1"])
        sleep(18)
        save("ipad-session-landscape-dark")
        app.terminate()
        app = launch(["-openPalette", "1", "-seedSections", "1"])
        sleep(10)
        save("ipad-palette-landscape-dark")
        app.terminate()
        app = launch(["-seedSections", "1"], appearance: "light")
        sleep(20)
        save("ipad-home-landscape-light")
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
    }
}
