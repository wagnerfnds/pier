import XCTest

/// The Live Activity as the Lock Screen draws it (the system's own UI, not the in-app gallery): a finished turn, its reply
/// and Revisar inside the 160 pt the Lock Screen gives an activity, margins kept. Skipped unless
/// `TEST_RUNNER_ACTIVITY_SHOTS=<dir>` names a folder for the PNGs. Not a test of behaviour: nothing here asserts.
final class LiveActivityShots: XCTestCase {
    func testFinishedTurnOnTheLockScreen() throws {
        guard let d = ProcessInfo.processInfo.environment["ACTIVITY_SHOTS"], !d.isEmpty else { throw XCTSkip("ACTIVITY_SHOTS not set") }
        let dir = URL(fileURLWithPath: d)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMock", "1", "-debugActivitySession", "sandbox-subtract-claude-6s1",
                               "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        sleep(12)   // the activity starts 5 s after launch, then the sync reads the reply and the line counts
        XCUIDevice.shared.press(.home)
        sleep(1)
        let lock = NSSelectorFromString("pressLockButton")
        guard XCUIDevice.shared.responds(to: lock) else { throw XCTSkip("this simulator cannot lock") }
        XCUIDevice.shared.perform(lock)
        sleep(2)
        XCUIDevice.shared.perform(lock)   // wakes it, locked: the Lock Screen with the activity
        sleep(3)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appendingPathComponent("lock-finished.png"))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.swipeUp()
        sleep(1)
        app.activate()
    }
}
