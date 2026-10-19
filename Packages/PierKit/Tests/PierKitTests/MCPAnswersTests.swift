import Foundation
import Testing

@testable import PierKit

/// A notification's buttons for Claude Code's question about the MCP servers, as pierd words them in either language.
@Suite struct MCPAnswersTests {
    @Test func buttonsInEitherLanguage() {
        #expect(MCPAnswers.choice("Ativar todos") == .enableAll)
        #expect(MCPAnswers.choice("Enable all") == .enableAll)
        #expect(MCPAnswers.choice(" Recusar ") == .turnDown)
        #expect(MCPAnswers.choice("Turn down") == .turnDown)
        #expect(MCPAnswers.choice("Yes") == nil)
    }

    @Test func whatEachTurnsOn() throws {
        let q = try JSONDecoder.pier.decode(MCPQuestion.self, from: Fixture.data("mcp_question.json"))
        #expect(MCPAnswers.enable(.enableAll, in: q) == ["laravel-boost", "herd"])
        #expect(MCPAnswers.enable(.turnDown, in: q).isEmpty)
    }
}
