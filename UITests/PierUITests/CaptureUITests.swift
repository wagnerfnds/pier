import XCTest

/// What an agent showed of its work (`pierd capture add`), against the mock box: the turn's gallery under its answer
/// ("Antes" and "Depois", each with its caption), the viewer a tile opens (swipe to the next, ✕ closes it), and the
/// screenshot a browser call returned, in that call's detail. `CAPTURE_SHOTS=<dir>` also writes the screenshots.
final class CaptureUITests: XCTestCase {
    var app: XCUIApplication!

    private let finished = "sandbox-subtract-claude-6s1"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestMock", "1", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR", "-openSession", finished]
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }

    private func shot(_ name: String) {
        let s = app.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = "\(name)-\(device)"; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["CAPTURE_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("capture-\(name)-\(device).png"))
        }
    }

    /// Scrolls the conversation back until `e` is on screen (the turn is a few turns up).
    private func scrollBack(to e: XCUIElement, _ what: String) {
        let scroll = element("conversation-scroll")
        XCTAssertTrue(scroll.waitForExistence(timeout: 25), "the conversation did not open")
        for _ in 0..<16 where !(e.exists && e.isHittable) { scroll.swipeDown() }
        XCTAssertTrue(e.exists && e.isHittable, "\(what) never came into view")
    }

    private func waitGone(_ e: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: e)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    func testGalleryOpensTheViewer() {
        app.launch()
        let gallery = element("capture-gallery")
        scrollBack(to: gallery, "the turn's gallery")
        let before = gallery.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Captura, Antes'")).firstMatch
        let after = gallery.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Captura, Depois'")).firstMatch
        XCTAssertTrue(before.waitForExistence(timeout: 5), "no Antes tile")
        XCTAssertTrue(after.exists, "no Depois tile")
        XCTAssertTrue(before.label.contains("The Sign in button sits off-center on a phone"), "the tile does not carry its caption: \(before.label)")
        shot("gallery")

        before.tap()
        XCTAssertTrue(element("capture-viewer").waitForExistence(timeout: 5), "the viewer did not open")
        XCTAssertTrue(app.staticTexts["1 de 2"].waitForExistence(timeout: 5), "the viewer does not say where it is")
        XCTAssertTrue(app.staticTexts["The Sign in button sits off-center on a phone"].exists, "no caption in the viewer")
        shot("viewer-before")
        app.swipeLeft()
        XCTAssertTrue(app.staticTexts["2 de 2"].waitForExistence(timeout: 5), "a swipe did not reach the next capture")
        XCTAssertTrue(app.staticTexts["Centered, the full width of the form"].exists)
        shot("viewer-after")
        app.buttons["Fechar"].tap()
        XCTAssertTrue(waitGone(element("capture-viewer")), "✕ did not close the viewer")
        XCTAssertTrue(gallery.exists, "the conversation lost its place")
    }

    /// A finished turn's captures ride on its Inbox card, under the reply, and open the same viewer.
    func testInboxCardShowsTheTurnsCaptures() {
        app.launchArguments = ["-uiTestMock", "1", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR", "-uiTestInboxCaptures", "1", "-startTab", "inbox"]
        app.launch()
        let strip = element("inbox-captures")
        XCTAssertTrue(strip.waitForExistence(timeout: 25), "the finished card shows no captures")
        shot("inbox-card")
        strip.buttons.firstMatch.tap()
        XCTAssertTrue(element("capture-viewer").waitForExistence(timeout: 5), "the card's capture did not open")
        XCTAssertTrue(app.staticTexts["Centered, the full width of the form"].exists)
        app.buttons["Fechar"].tap()
        XCTAssertTrue(waitGone(element("capture-viewer")))
    }

    func testAToolsScreenshotShowsInItsDetail() {
        app.launchArguments += ["-sessionExpandAll", "1"]
        app.launch()
        let pictures = element("tool-images")
        scrollBack(to: pictures, "the screenshot call's picture")
        pictures.buttons.firstMatch.tap()
        XCTAssertTrue(element("capture-viewer").waitForExistence(timeout: 5), "the call's picture did not open")
        shot("tool-picture")
        app.buttons["Fechar"].tap()
        XCTAssertTrue(waitGone(element("capture-viewer")))
    }
}
