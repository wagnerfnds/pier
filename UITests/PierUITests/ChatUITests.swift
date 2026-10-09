import XCTest

/// Chats: an agent tied to no project. With `-uiTestChats 1` the mock box lists one (`chat-claude-c4t`, its turn
/// ended), which shows on the Home (and, on regular width, under Conversas in the sidebar) placed as "Conversa"; New
/// task ⟶ Conversa starts another, which opens on the usual session screen. Each runs light and dark, with screenshots.
final class ChatUITests: XCTestCase {
    var app: XCUIApplication!

    static let chat = "chat-claude-c4t"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: helpers

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func text(containing s: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }
    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }
    private func shot(_ name: String) {
        let s = app.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = "\(name)-\(device)"; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["KBD_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(device).png"))
        }
    }

    private func launch(_ appearance: String) {
        app.terminate()
        app.launchArguments = ["-uiTestMock", "1", "-uiTestChats", "1", "-appearance", appearance, "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        XCTAssertTrue(element("new-task-button").waitForExistence(timeout: 15), "home did not load")
    }

    // MARK: tests

    func testExistingChatAppearsInHomeAndOpens() {
        for mode in ["light", "dark"] {
            launch(mode)
            let row = text(containing: "Plan a home server for the team")
            XCTAssertTrue(row.waitForExistence(timeout: 15), "the chat is not on the Home (\(mode))")
            XCTAssertTrue(text(containing: "Conversa").exists, "the chat is not placed as a Conversa (\(mode))")
            if element("sidebar-home").exists {
                XCTAssertTrue(element("sidebar-section-Conversas").exists, "no Conversas in the sidebar (\(mode))")
                XCTAssertTrue(element("sidebar-chat-\(Self.chat)").exists, "the chat is not in the sidebar (\(mode))")
            }
            shot("chat-home-\(mode)")
            row.tap()
            XCTAssertTrue(element("composer-field").waitForExistence(timeout: 15), "the chat did not open (\(mode))")
            XCTAssertTrue(text(containing: "Tailscale").waitForExistence(timeout: 10), "the chat's conversation is not shown (\(mode))")
            shot("chat-session-\(mode)")
        }
    }

    func testNewChatFromTheNewTaskFlowOpens() {
        for mode in ["light", "dark"] {
            launch(mode)
            element("new-task-button").tap()
            let kind = element("compose-kind")
            XCTAssertTrue(kind.waitForExistence(timeout: 10), "no Tarefa / Conversa choice (\(mode))")
            kind.buttons["Conversa"].tap()
            XCTAssertTrue(element("compose-chat-place").waitForExistence(timeout: 5), "Conversa did not replace the project (\(mode))")
            XCTAssertTrue(app.buttons["Iniciar conversa"].exists, "the button does not say it starts a chat (\(mode))")
            let prompt = element("compose-prompt")
            prompt.tap()
            prompt.typeText("Help me think through a reading club app")
            shot("chat-compose-\(mode)")
            let start = element("compose-start")
            let deadline = Date().addingTimeInterval(10)
            while !start.isEnabled && Date() < deadline { usleep(200_000) }
            XCTAssertTrue(start.isEnabled, "Iniciar conversa stayed disabled (\(mode))")
            start.tap()
            XCTAssertTrue(element("composer-field").waitForExistence(timeout: 15), "the new chat did not open (\(mode))")
            XCTAssertTrue(text(containing: "Let's think it through").waitForExistence(timeout: 10), "the new chat's agent did not answer (\(mode))")
            shot("chat-new-session-\(mode)")
        }
    }
}
