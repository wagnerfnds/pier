import Foundation

/// The two answers to Claude Code's question about a repository's MCP servers that a notification carries as buttons
/// (pierd's `text.MCPOptions`, docs/PUSH.md 4.3, `optionsKind: "mcp"`): every server on, or every one down. A button
/// comes back as its words, in either language the box writes them.
public enum MCPAnswers {
    public enum Choice: Sendable, Equatable { case enableAll, turnDown }

    /// The answer a button's words stand for; nil for words that are not one of them.
    public static func choice(_ label: String) -> Choice? {
        switch label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ativar todos", "enable all": .enableAll
        case "recusar", "turn down": .turnDown
        default: nil
        }
    }

    /// The servers to turn on for a choice.
    public static func enable(_ choice: Choice, in question: MCPQuestion) -> [String] {
        choice == .enableAll ? question.servers.map(\.name) : []
    }
}
