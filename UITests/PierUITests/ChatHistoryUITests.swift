import XCTest

/// Synthetic reproduction of the Mac chat's layout loop: a bottom-anchored, paginated conversation with uneven
/// rows, including one much taller than the viewport. Run this suite on Mac Catalyst (or an iPad simulator).
/// The mock's initial page has only turns 234–240; turns 228–233 appear only after an older-page request.
final class ChatHistoryUITests: XCTestCase {
    private var app: XCUIApplication!
    private let lab = "chatlab-claude-z9"
    private let other = "sandbox-subtract-claude-6s1"
    private var latestTurn = 240

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMock", "1", "-uiTestChatLab", "1", "-uiTestChatLabTurns", "240", "-uiTestChatLabPageSize", "24",
            "-uiTestChatLabProbe", "1",
            // The hosted Mac runner has a 1024x768 display. Keep the composer and toolbar inside its usable area.
            "-openSession", lab, "-undoSeconds", "0", "-session.inspector", "0", "-macWindowSize", "960x640",
            "-session.view.devbox/\(lab)", "conversation", "-session.view.devbox/\(other)", "conversation",
            "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR",
        ]
    }

    override func tearDownWithError() throws {
        if let run = testRun, run.failureCount > 0, app.state == .runningForeground {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "synthetic-chat-failure"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let frames = "window=\(app.windows.firstMatch.frame) conversation=\(conversation.frame) "
                + "composer=\(element("composer-field").frame) historyRequests=\(historyRequests.map(String.init) ?? "missing") "
                + "latest=\(marker(latestTurn).exists ? String(describing: marker(latestTurn).frame) : "missing")"
            let diagnostic = XCTAttachment(string: frames)
            diagnostic.name = "synthetic-chat-frames"
            diagnostic.lifetime = .keepAlways
            add(diagnostic)
            print("CHAT-HISTORY \(frames)")
        }
        try super.tearDownWithError()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func marker(_ turn: Int) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "history-turn-\(turn)")).firstMatch
    }

    private var conversation: XCUIElement { element("conversation-scroll") }
    private var historyRequests: Int? { (element("chat-history-before-count").value as? String).flatMap(Int.init) }

    /// Keep a failed pointer navigation distinguishable from an unavailable session without dumping the chat tree.
    private func assertSessionOpens(_ name: String, _ message: String = "the session did not open",
                                    file: StaticString = #filePath, line: UInt = #line) {
        let opened = element("session-open-\(name)").waitForExistence(timeout: 5)
        if !opened {
            let labOpen = element("session-open-\(lab)").exists
            let otherOpen = element("session-open-\(other)").exists
            let labRow = element("sidebar-chat-\(lab)")
            let otherRow = element("sidebar-agent-devbox/\(other)")
            let labSelected = labRow.exists ? String(labRow.isSelected) : "missing"
            let otherSelected = otherRow.exists ? String(otherRow.isSelected) : "missing"
            let windows = app.windows.allElementsBoundByIndex.map { $0.label }
            print("CHAT-NAVIGATION expected=\(name) labOpen=\(labOpen) otherOpen=\(otherOpen) "
                  + "labSelected=\(labSelected) otherSelected=\(otherSelected) windows=\(windows)")
        }
        XCTAssertTrue(opened, message, file: file, line: line)
    }

    private func assertLatestVisible() {
        let latest = marker(latestTurn)
        XCTAssertTrue(latest.waitForExistence(timeout: 15), "the newest reply never appeared; the layout may be spinning")
        assertVisible(latest, "the chat did not settle at the latest reply")
    }

    /// Call after existence is confirmed. A large Markdown AX tree can make one predicate evaluation consume the
    /// waiter's whole budget even when the marker is already on screen; check its actual frames before polling.
    private func assertVisible(_ marker: XCUIElement, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        if marker.frame.intersects(conversation.frame) { return }
        let visible = NSPredicate { _, _ in marker.frame.intersects(self.conversation.frame) }
        let expectation = XCTNSPredicateExpectation(predicate: visible, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, message, file: file, line: line)
    }

    private func openLab(requireLatestVisible: Bool = true) {
        app.launch()
        XCTAssertTrue(element("session-open-\(lab)").waitForExistence(timeout: 15), "the lab session did not open")
        XCTAssertTrue(conversation.waitForExistence(timeout: 10), "the conversation was replaced by a terminal or fallback")
        if requireLatestVisible {
            assertLatestVisible()
        } else {
            // The opening-position tests cover visibility. The send regression must still run if that alone fails.
            XCTAssertTrue(marker(latestTurn).waitForExistence(timeout: 15), "the long record never loaded")
        }
        XCTAssertTrue(element("chat-history-before-count").waitForExistence(timeout: 5), "the DEBUG history probe is missing")
        XCTAssertEqual(historyRequests, 0, "opening at the bottom fetched history without a user scroll")
    }

    /// Typing and reading the unsent draft exercises the main thread, not just the presence of stale view objects.
    private func assertComposerResponds(_ draft: String) {
        let field = element("composer-field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 5), .completed,
                       "the composer is outside the clickable viewport or layout stopped responding")
        field.tap()
        field.typeText(draft)
        XCTAssertTrue((field.value as? String)?.contains(draft) == true, "the composer stopped responding after layout")
    }

    func testTallTailOpensAtTheBottomAndRemainsResponsive() {
        app.launchArguments += ["-uiTestChatLabTallTail", "1"]
        openLab()
        assertComposerResponds("synthetic-layout-check")
        XCTAssertTrue(conversation.exists, "the app left conversation mode")
        // Changing the available width must settle too (when the regular-width inspector is available).
        let inspector = element("session-inspector-toggle")
        if inspector.exists {
            inspector.tap()
            assertLatestVisible()
            inspector.tap()
            assertComposerResponds("-after-resize")
        }
        XCTAssertEqual(historyRequests, 0, "typing or resizing at the bottom fetched older history")
    }

    func testSendingAfterTallTailKeepsTheCompletedReplyVisible() {
        app.launchArguments += ["-uiTestChatLabTallTail", "1"]
        openLab(requireLatestVisible: false)
        assertComposerResponds("Synthetic follow-up after the tall reply")
        element("composer-send").tap()

        // This is the existing fixture's last paragraph, so its appearance proves the full reply arrived.
        let endOfReply = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Tell me if you want the receipts changed in the same PR.")).firstMatch
        XCTAssertTrue(endOfReply.waitForExistence(timeout: 20), "the complete synthetic reply never appeared")
        // The mock clears its draft two seconds after appending the record. Its session list does not publish
        // events, so a stale running toolbar is not a reliable indication of this handoff completing.
        let brewing = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Brewing")).firstMatch
        XCTAssertTrue(brewing.waitForNonExistence(timeout: 15), "the synthetic draft did not finish its handoff")
        assertVisible(endOfReply, "the conversation became blank or lost the completed reply after the draft cleared")
        assertComposerResponds("synthetic-after-complete-reply")
        XCTAssertTrue(endOfReply.exists && endOfReply.frame.intersects(conversation.frame),
                      "typing after the completed reply displaced it outside the viewport")
        XCTAssertEqual(historyRequests, 0, "sending at the bottom fetched older history")
    }

    func testScrollingLoadsEarlierPagesAndReturnsToLatestReply() {
        openLab()
        let olderTurns = 228...233
        // The lab has 240 turns, but the initial response contains only its last 24 items.
        XCTAssertFalse(olderTurns.contains { marker($0).exists }, "an older page is already visible before any scroll")
        for _ in 0..<24 {
            if (historyRequests ?? 0) > 0 { break }
            conversation.swipeDown(velocity: .fast)
        }
        XCTAssertGreaterThan(historyRequests ?? -1, 0, "scrolling to the top never requested the next history page")
        // A fling may pass turn 233 while the prepended page settles. Require new content, without requiring a
        // particular off-screen lazy row to remain materialized after the gesture.
        let olderVisible = NSPredicate { _, _ in olderTurns.contains { self.marker($0).exists } }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: olderVisible, object: nil)], timeout: 5),
                       .completed, "the history request completed without rendering any row from the older page")
        let end = app.buttons["Ir para o fim"].firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 5), "scrolling away from the bottom did not offer a return")
        end.tap()
        assertLatestVisible()
        assertComposerResponds("Synthetic reply after loading history")
        element("composer-send").tap()
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "streamcheck-7f3a")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15), "the chat could not render a streamed reply after pagination")
    }

    func testSwitchingSessionsKeepsTheLongConversationResponsive() throws {
        app.launchArguments += ["-uiTestChatLabTallTail", "1"]
        openLab()
        let labRow = element("sidebar-chat-\(lab)")
        let otherRow = element("sidebar-agent-devbox/\(other)")
        guard labRow.exists, otherRow.exists else {
            throw XCTSkip("session switching uses the regular-width Mac/iPad sidebar")
        }
        for _ in 0..<3 {
            otherRow.tap()
            assertSessionOpens(other, "the other session did not open")
            labRow.tap()
            assertSessionOpens(lab, "the long conversation did not reopen")
            assertLatestVisible()
        }
        assertComposerResponds("synthetic-after-session-switch")
        XCTAssertEqual(historyRequests, 0, "switching sessions fetched history without a user scroll")
    }

    /// The production server's first window is up to 300 items, even though older-page requests ask for 120.
    /// Exercise that loaded volume with ordinary Markdown; the tall-tail cases separately cover one huge row.
    func testFullInitialPageRemainsResponsiveAfterSwitchingSessions() {
        let pageFlag = app.launchArguments.firstIndex(of: "-uiTestChatLabPageSize")!
        app.launchArguments[pageFlag + 1] = "300"
        openLab()

        let labRow = element("sidebar-chat-\(lab)")
        let otherRow = element("sidebar-agent-devbox/\(other)")
        XCTAssertTrue(labRow.waitForExistence(timeout: 5), "the lab sidebar entry is missing")
        XCTAssertTrue(otherRow.waitForExistence(timeout: 5), "the other session sidebar entry is missing")
        otherRow.tap()
        assertSessionOpens(other, "the other session did not open")
        labRow.tap()
        assertSessionOpens(lab, "the full initial page did not reopen")
        assertLatestVisible()
        assertComposerResponds("synthetic-full-page")
        assertLatestVisible()
        XCTAssertEqual(historyRequests, 0, "opening or switching the full initial page fetched older history")
    }

    /// The reported freeze also occurs in short records. Long history is a stress case, not a precondition.
    func testSmallUnpagedConversationRemainsResponsiveAcrossSessionSwitches() throws {
        latestTurn = 5
        for (flag, value) in [("-uiTestChatLabTurns", "5"), ("-uiTestChatLabPageSize", "0")] {
            let index = app.launchArguments.firstIndex(of: flag)!
            app.launchArguments[index + 1] = value
        }
        // Five invented turns (20 items), ordinary mixed Markdown, no oversized final reply or earlier pages.
        openLab()
        // Complete sentences avoid a native autocorrection candidate consuming the following sidebar click.
        assertComposerResponds("This conversation is ready.")
        let labRow = element("sidebar-chat-\(lab)")
        let otherRow = element("sidebar-agent-devbox/\(other)")
        guard labRow.exists, otherRow.exists else {
            throw XCTSkip("session switching uses the regular-width Mac/iPad sidebar")
        }
        for round in 1...3 {
            otherRow.tap()
            assertSessionOpens(other)
            labRow.tap()
            assertSessionOpens(lab)
            assertLatestVisible()
            assertComposerResponds("This is switch number \(round).")
        }
        XCTAssertEqual(historyRequests, 0, "an unpaged conversation requested older history")
    }
}
