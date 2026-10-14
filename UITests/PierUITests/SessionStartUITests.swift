import XCTest

/// A new task opens straight into its chat: the prompt and the agent starting, never the agent's terminal or a session
/// that reads as closed, while Claude Code has not written its record yet (the mock answers `source: "none"` for a new
/// task's first seconds, as pierd does; `-mockRecordDelay` makes that long enough to look at).
final class SessionStartUITests: XCTestCase {
    func testNewTaskOpensOnItsChat() {
        let app = XCUIApplication()
        let prompt = "Qual stack estamos usando neste projeto?"
        app.launchArguments = ["-uiTestMock", "1", "-mockRecordDelay", "10", "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR",
                               "-openCompose", "1", "-composeProject", "sandbox", "-composePrompt", prompt, "-composeSubmit", "1"]
        app.launch()
        func containing(_ s: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
        }
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "composer-field").firstMatch.waitForExistence(timeout: 20),
                      "the new task's chat did not open")
        XCTAssertTrue(containing(prompt).waitForExistence(timeout: 3), "the prompt is not the chat's first message")
        XCTAssertTrue(containing("Iniciando").waitForExistence(timeout: 3), "the chat does not say the agent is starting")
        XCTAssertFalse(containing("Sem registro de conversa").exists, "the chat fell back to the agent's screen")
        XCTAssertFalse(containing("Ver terminal completo").exists, "the chat offered the terminal while starting")
        XCTAssertFalse(containing("foi encerrada").exists, "a session just started read as closed")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "new-task-starting"; shot.lifetime = .keepAlways
        add(shot)
        // The record is written, then the reply comes, in the same chat.
        XCTAssertTrue(containing("Started. I'll let you know").waitForExistence(timeout: 20), "the reply never came")
        XCTAssertFalse(containing("Sem registro de conversa").exists)
    }
}
