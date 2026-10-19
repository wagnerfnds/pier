// Codable models of pierd's JSON (docs/API.md §13.3), checked against the Go structs in Server/pierd.
import Foundation

public struct QuestionOption: Codable, Sendable, Hashable {
    public let label: String
    public let description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }

    enum CodingKeys: String, CodingKey {
        case label
        case description
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.label = try c.decode(String.self, forKey: .label)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
    }
}

public struct Question: Codable, Sendable, Hashable {
    public let question: String
    public let header: String?
    public let multi: Bool?
    public let options: [QuestionOption]
    public let id: String?

    public init(question: String, header: String? = nil, multi: Bool? = nil, options: [QuestionOption] = [], id: String? = nil) {
        self.question = question
        self.header = header
        self.multi = multi
        self.options = options
        self.id = id
    }

    enum CodingKeys: String, CodingKey {
        case question
        case header
        case multi
        case options
        case id
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.question = try c.decode(String.self, forKey: .question)
        self.header = try c.decodeIfPresent(String.self, forKey: .header)
        self.multi = try c.decodeIfPresent(Bool.self, forKey: .multi)
        self.options = try c.decodeIfPresent([QuestionOption].self, forKey: .options) ?? []
        self.id = try c.decodeIfPresent(String.self, forKey: .id)
    }
}

public struct QuestionAnswer: Codable, Sendable, Hashable {
    public var picks: [String]?
    public var other: String?

    public init(picks: [String]? = nil, other: String? = nil) {
        self.picks = picks
        self.other = other
    }

    enum CodingKeys: String, CodingKey {
        case picks
        case other
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.picks = try c.decodeIfPresent([String].self, forKey: .picks)
        self.other = try c.decodeIfPresent(String.self, forKey: .other)
    }
}

/// Claude Code's question about a repository's MCP servers (its `.mcp.json`) before it starts, read off the screen by the
/// box (`GET /v1/sessions/{name}/mcp`, capability `answer.mcp`, docs/API.md §5.4): each server and whether it is ticked.
/// Checked against Server/pierd/internal/box/mcpask.go.
public struct MCPQuestion: Codable, Sendable, Hashable {
    public struct Server: Codable, Sendable, Hashable, Identifiable {
        public let name: String
        public let enabled: Bool
        public var id: String { name }

        public init(name: String, enabled: Bool) { self.name = name; self.enabled = enabled }

        enum CodingKeys: String, CodingKey { case name, enabled }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        }
    }

    public let servers: [Server]

    public init(servers: [Server]) { self.servers = servers }

    enum CodingKeys: String, CodingKey { case servers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        servers = try c.decodeIfPresent([Server].self, forKey: .servers) ?? []
    }
}
