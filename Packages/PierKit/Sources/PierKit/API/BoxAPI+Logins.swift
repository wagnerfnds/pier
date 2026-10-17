import Foundation

// The tools the box can install and its sign-ins (capabilities `tools` and `logins`, docs/API.md §2.10.1, §2.13): Claude
// Code, Codex and the GitHub CLI put on the box, and signed in, from the app.

extension BoxAPI {
    /// Claude Code, Codex and the GitHub CLI: whether the box has each, and an install running or failed.
    public func tools() async throws -> [BoxTool] { try await get("/v1/tools") }

    /// Install the named tools the box lacks (every missing one with none named), in the background: answers the tools as
    /// they stand, those installing marked so; `tool.installed` / `tool.failed` say how each went.
    public func installTools(_ ids: [String] = []) async throws -> [BoxTool] {
        struct Body: Encodable { let tools: [String] }
        return try decode(try await call(.post, "/v1/tools/install", body: Body(tools: ids)).data)
    }

    /// Start a sign-in to `tool` (`claude`, `codex`, `gh`), on `account` for an agent (the box's default when nil). A sign-in
    /// already running for the same account gives way to this one. 424 `tool_missing` when the box lacks the tool.
    public func startLogin(tool: String, account: String? = nil) async throws -> Login {
        struct Body: Encodable { let tool: String; let account: String? }
        return try decode(try await call(.post, "/v1/logins", body: Body(tool: tool, account: account)).data)
    }

    public func login(id: String) async throws -> Login { try await get("/v1/logins/\(Self.seg(id))") }

    /// The sign-ins of the last hour, newest first.
    public func logins() async throws -> [Login] { try await get("/v1/logins") }

    /// Type the code the sign-in page showed into Claude Code (409 when it is not waiting for one).
    public func sendLoginCode(id: String, code: String) async throws -> Login {
        struct Body: Encodable { let code: String }
        return try decode(try await call(.post, "/v1/logins/\(Self.seg(id))/code", body: Body(code: code)).data)
    }

    /// Cancel a sign-in and end its session (a finished one stays as it was).
    @discardableResult
    public func cancelLogin(id: String) async throws -> Login {
        try decode(try await call(.delete, "/v1/logins/\(Self.seg(id))").data)
    }
}
