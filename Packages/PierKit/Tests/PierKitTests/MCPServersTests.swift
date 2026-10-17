import Foundation
import Testing

@testable import PierKit

@Suite struct MCPServersTests {
    @Test func decodes() throws {
        let list = try Fixture.decode("mcp.json", as: MCPServerList.self).servers
        #expect(list.map(\.name) == ["crm", "docs", "staging"])
        let crm = list[0]
        #expect(crm.transport == "http" && crm.url == "https://mcp.example.com/mcp" && crm.tokenSet && crm.tokenVar == "PIER_MCP_CRM_TOKEN")
        #expect(crm.headers == ["X-Team": "green"] && crm.agents == ["claude", "codex"] && crm.enabled && crm.status.isEmpty && crm.problems.isEmpty)
        let docs = list[1]
        #expect(docs.transport == "stdio" && docs.command == "npx" && docs.args == ["-y", "docs-mcp"] && docs.env == ["DOCS_REGION": "eu"])
        #expect(docs.tokenVar == nil && !docs.tokenSet && docs.agents == ["codex"])
        #expect(!list[2].enabled)

        let status = try Fixture.decode("mcp_status.json", as: MCPServerList.self).servers
        #expect(status[0].status["claude"] == MCPAgentStatus(state: "connected", account: "Claude Code"))
        #expect(status[1].problems.count == 2 && status[1].status["codex"]?.state == "taken")
        #expect(status[2].status["codex"]?.issue == "the server refused the token (HTTP 401)")
        #expect(status[3].status == ["codex": MCPAgentStatus(state: "disabled")])

        let saved = try Fixture.decode("mcp_server.json", as: MCPServer.self)
        #expect(saved.name == "handmade" && saved.problems.first?.hasPrefix("Claude Code: already has a server named handmade") == true)
    }

    @Test func health() throws {
        let s = try Fixture.decode("mcp_status.json", as: MCPServerList.self).servers
        #expect(MCPServers.health(s[0]) == .connected)
        #expect(MCPServers.health(s[1]) == .failing(agent: "claude", issue: "a server of this name that pierd did not add"))
        #expect(MCPServers.health(s[2]) == .failing(agent: "claude", issue: "Dynamic Client Registration rejected (HTTP 401):"))
        #expect(MCPServers.health(s[3]) == .off)
        // Before a status was asked for: the last sync's problem, else nothing known.
        let saved = try Fixture.decode("mcp_server.json", as: MCPServer.self)
        #expect(MCPServers.health(saved) == .failing(agent: nil, issue: saved.problems.first))
        #expect(MCPServers.health(MCPServer(name: "x")) == .unknown)
        // Codex with a stdio server only knows it is configured; an agent the box lacks says nothing.
        let stdio = MCPServer(name: "d", transport: "stdio", status: ["claude": MCPAgentStatus(state: "connected"), "codex": MCPAgentStatus(state: "configured")])
        #expect(MCPServers.health(stdio) == .configured)
        let noCodex = MCPServer(name: "d", status: ["claude": MCPAgentStatus(state: "connected"), "codex": MCPAgentStatus(state: "unavailable", issue: "Codex is not installed on this box")])
        #expect(MCPServers.health(noCodex) == .connected)
        let slow = MCPServer(name: "d", status: ["claude": MCPAgentStatus(state: "unknown", issue: "claude mcp list did not finish within 20s"), "codex": MCPAgentStatus(state: "connected")])
        #expect(MCPServers.health(slow) == .unknown)
        #expect(MCPServers.kind(MCPAgentStatus(state: "needs_auth")) == .failed && MCPServers.kind(MCPAgentStatus(state: "pending")) == .unknown)
        // pierd's entry changed by hand: pierd no longer manages it there, which the row says.
        let changed = MCPServer(name: "d", status: ["claude": MCPAgentStatus(state: "changed", issue: "changed by hand since pierd wrote it"),
                                                    "codex": MCPAgentStatus(state: "connected")])
        #expect(MCPServers.kind(changed.status["claude"]!) == .changed)
        #expect(MCPServers.health(changed) == .failing(agent: "claude", issue: "changed by hand since pierd wrote it"))
    }

    @Test func rules() {
        for n in ["crm", "my-server", "a_b", "x1", String(repeating: "a", count: 40)] { #expect(MCPServers.isValidName(n), "\(n)") }
        for n in ["", "CRM", "a.b", "a b", "é", String(repeating: "a", count: 41)] { #expect(!MCPServers.isValidName(n), "\(n)") }
        #expect(MCPServers.suggestedName(for: "https://mcp.acme.com/mcp") == "acme")
        #expect(MCPServers.suggestedName(for: "https://api.example.co.uk/v1/mcp") == "example")
        #expect(MCPServers.suggestedName(for: "https://tools.example.com") == "tools")
        #expect(MCPServers.suggestedName(for: "http://127.0.0.1:8080/mcp") == "")
        #expect(MCPServers.suggestedName(for: "not a url") == "")
        #expect(MCPServers.isValidURL("https://mcp.example.com/mcp") && MCPServers.isValidURL("http://localhost:3000/mcp"))
        #expect(!MCPServers.isValidURL("ftp://x.example.com") && !MCPServers.isValidURL("mcp.example.com") && !MCPServers.isValidURL("https://"))
        #expect(MCPServers.isValidHeader(name: "X-Team", value: "green"))
        #expect(!MCPServers.isValidHeader(name: "Authorization", value: "Bearer x") && !MCPServers.isValidHeader(name: "authorization", value: "x"))
        #expect(!MCPServers.isValidHeader(name: "X Team", value: "x") && !MCPServers.isValidHeader(name: "X-Team", value: "a\nb"))
        #expect(MCPServers.isValidToken("sk_live_123") && !MCPServers.isValidToken("two words") && !MCPServers.isValidToken("a\n"))
        #expect(MCPServers.tokenVariable("my-server") == "PIER_MCP_MY_SERVER_TOKEN")
    }

    @Test func routes() async throws {
        let t = MockTransport { method, path, _ in
            switch (method, path) {
            case (.get, "/v1/mcp"): return (200, try Fixture.data("mcp.json"))
            case (.get, "/v1/mcp?status=1"), (.get, "/v1/mcp?status=deep"): return (200, try Fixture.data("mcp_status.json"))
            case (.put, _): return (200, try Fixture.data("mcp_server.json"))
            default: return (200, Data(#"{"removed":"crm"}"#.utf8))
            }
        }
        let a = BoxAPI(transport: t, eventPolicy: EventStreamPolicy(jitter: 0))
        #expect(try await a.mcpServers().count == 3)
        #expect(try await a.mcpServers(status: true).count == 4)
        #expect(try await a.mcpServers(status: true, deep: true).count == 4)
        // A new server with its token; then saved again as it is (the box keeps the token); then the token removed.
        _ = try await a.setMCPServer(name: "crm", MCPServerUpdate(url: "https://mcp.example.com/mcp", headers: ["X-Team": "green"], token: "tok"))
        let crm = try Fixture.decode("mcp.json", as: MCPServerList.self).servers[0]
        var off = MCPServerUpdate(crm)
        off.enabled = false
        _ = try await a.setMCPServer(name: "crm", off)
        var cleared = MCPServerUpdate(crm)
        cleared.token = ""
        _ = try await a.setMCPServer(name: "crm", cleared)
        try await a.removeMCPServer(name: "crm")
        #expect(t.requests.map { "\($0.method) \($0.path)" } == [
            "GET /v1/mcp", "GET /v1/mcp?status=1", "GET /v1/mcp?status=deep", "PUT /v1/mcp/crm", "PUT /v1/mcp/crm", "PUT /v1/mcp/crm",
            "DELETE /v1/mcp/crm",
        ])
        #expect(t.requests[3].body == #"{"agents":["claude","codex"],"enabled":true,"headers":{"X-Team":"green"},"token":"tok","transport":"http","url":"https://mcp.example.com/mcp"}"#)
        #expect(t.requests[4].body == #"{"agents":["claude","codex"],"enabled":false,"headers":{"X-Team":"green"},"transport":"http","url":"https://mcp.example.com/mcp"}"#)
        #expect(t.requests[5].body?.contains(#""token":"""#) == true)
    }
}
