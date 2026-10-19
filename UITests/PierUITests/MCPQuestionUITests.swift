import XCTest

/// Claude Code's question about a repository's MCP servers (`.mcp.json`), answered from the conversation instead of the
/// terminal: the needs-you card lists the servers with their switches, and the answer goes to the box (`POST …/mcp`), which
/// presses the dialog's keys. Against the mock box (`-uiTestMCP 1`: two servers, both ticked, as Claude Code 2.1.30x asks).
final class MCPQuestionUITests: XCTestCase {
    var app: XCUIApplication!

    static let session = "sandbox-mcpq-claude-m2"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestMock", "1", "-uiTestMCP", "1", "-undoSeconds", "0", "-openSession", Self.session,
                               "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func text(containing s: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }

    func testOneServerTurnedOffThenTheRestEnabled() {
        app.launch()
        let enable = element("mcp-enable")
        XCTAssertTrue(enable.waitForExistence(timeout: 15), "the MCP question did not show in the conversation")
        XCTAssertTrue(text(containing: "servidores MCP").exists, "the card does not say what Claude asks")
        let herd = element("mcp-server-herd")
        XCTAssertTrue(herd.exists, "no switch for herd")
        sleep(1)   // the card slides in
        herd.tap()
        XCTAssertTrue(text(containing: "Ativar 1").waitForExistence(timeout: 3), "the button does not follow the switches")
        enable.tap()
        XCTAssertTrue(text(containing: "Started with laravel-boost").waitForExistence(timeout: 10),
                      "the answer never reached the agent, or turned on the wrong servers")
        XCTAssertFalse(element("mcp-enable").exists, "the card stayed after the answer")
    }

    func testTurnedDown() {
        app.launch()
        let down = element("mcp-turn-down")
        XCTAssertTrue(down.waitForExistence(timeout: 15), "the MCP question did not show in the conversation")
        sleep(1)
        down.tap()
        XCTAssertTrue(text(containing: "without the project's MCP servers").waitForExistence(timeout: 10), "turning them down never reached the agent")
    }
}
