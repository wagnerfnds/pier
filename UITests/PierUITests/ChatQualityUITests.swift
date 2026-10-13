import XCTest

/// The chat measured and checked against the chat lab (`-uiTestChatLab 1`: a long record of hard Markdown, and a reply
/// streamed like Claude Code's when a message is sent):
/// - a streamed reply never shows twice (the record has the block while the screen still shows it, docs/ARCHITECTURE.md);
/// - a message shows the moment it is sent, during the undo window, and stays on screen until the box's copy replaces it;
/// - scrolling the long conversation: hitches (XCTOSSignpostMetric) and, while a reply streams, CPU and memory.
/// The measured numbers go to the test log and, with `TEST_RUNNER_CHAT_METRICS=<file>`, to a JSON file.
final class ChatQualityUITests: XCTestCase {
    var app: XCUIApplication!

    static let lab = "chatlab-claude-z9"
    static let marker = "streamcheck-7f3a"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestMock", "1", "-uiTestChatLab", "1", "-openSession", Self.lab,
                               "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
    }

    // MARK: helpers

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func count(containing s: String) -> Int {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).count
    }
    private func text(containing s: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }

    private func record(_ name: String, _ value: Double, unit: String) {
        print("CHAT-METRIC \(name)=\(String(format: "%.3f", value)) \(unit)")
        guard let path = ProcessInfo.processInfo.environment["CHAT_METRICS"] else { return }
        let url = URL(fileURLWithPath: path)
        var all = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
        all[name] = ["value": value, "unit": unit]
        try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }

    private func openLab(undo: Int) {
        app.launchArguments += ["-undoSeconds", "\(undo)"]
        app.launch()
        XCTAssertTrue(element("composer-field").waitForExistence(timeout: 20), "the chat lab did not open")
    }

    private func send(_ message: String) {
        let field = element("composer-field")
        field.tap()
        field.typeText(message)
        element("composer-send").tap()
    }

    // MARK: correctness

    func testStreamedReplyNeverShowsTwice() {
        openLab(undo: 0)
        send("Plan the fix, step by step")
        // The mock writes for ~5 s, then keeps the words on screen 2 s after the record has them.
        var most = 0, seen = false
        let end = Date().addingTimeInterval(16)
        while Date() < end {
            let n = count(containing: Self.marker)
            most = max(most, n)
            if n > 0 { seen = true }
            if seen, n == 1, !text(containing: "Brewing").exists, Date() > end.addingTimeInterval(-6) { break }
            usleep(150_000)
        }
        XCTAssertTrue(seen, "the streamed reply never showed")
        XCTAssertLessThanOrEqual(most, 1, "the streamed reply showed twice at once (draft and record)")
        XCTAssertTrue(text(containing: Self.marker).waitForExistence(timeout: 5), "the reply is gone after the turn ended")
    }

    func testOwnMessageShowsAtOnceAndStays() {
        openLab(undo: 2)
        let message = "Is the discount applied before tax now?"
        // The person's bubble only (on its way, or the box's copy), not the undo toast that names the message too.
        let bubble = app.descendants(matching: .any).matching(NSPredicate(
            format: "(identifier == 'outgoing-message' OR identifier == 'user-message') AND label CONTAINS %@", message)).firstMatch
        let field = element("composer-field")
        field.tap()
        field.typeText(message)
        element("composer-send").tap()
        // While the undo toast is up the message has not gone out yet: the bubble must already be in the conversation.
        let toast = element("undo-toast")
        XCTAssertTrue(toast.waitForExistence(timeout: 2), "no undo toast after sending")
        XCTAssertTrue(bubble.exists, "the message is not in the conversation while its undo window runs")
        XCTAssertTrue(toast.exists, "the undo window ended before the check (the run was too slow to tell)")
        // Through the undo window and the send, the words never leave the screen.
        let until = Date().addingTimeInterval(4)
        var gaps = 0
        while Date() < until {
            if !bubble.exists { gaps += 1 }
            usleep(200_000)
        }
        XCTAssertEqual(gaps, 0, "the message disappeared while it went out")
    }

    // MARK: measurements

    func testScrollingTheLongConversation() throws {
        openLab(undo: 0)
        let list = app.scrollViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        sleep(2)   // the first read and layout
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            list.swipeDown(velocity: .fast)
            list.swipeDown(velocity: .fast)
            list.swipeUp(velocity: .fast)
            list.swipeUp(velocity: .fast)
        }
    }

    func testStreamingCost() throws {
        openLab(undo: 0)
        sleep(2)
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        options.invocationOptions = [.manuallyStop]
        var round = 0
        measure(metrics: [XCTCPUMetric(application: app), XCTMemoryMetric(application: app), XCTClockMetric()], options: options) {
            round += 1
            send("Round \(round): plan it again")
            // The reply streams for ~5 s and settles 2 s later.
            _ = text(containing: "Reply").waitForExistence(timeout: 10)
            let end = Date().addingTimeInterval(12)
            while Date() < end, text(containing: "Brewing").exists || !text(containing: "Reply \(round + 0)").exists { usleep(250_000) }
            stopMeasuring()
        }
    }
}
