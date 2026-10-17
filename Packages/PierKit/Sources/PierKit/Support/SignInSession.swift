import Foundation

public extension Session {
    /// The terminal pierd opens for someone to sign an agent account in (`POST /v1/accounts/{id}/login`, docs/API.md
    /// 2.10): `login-<account>`, at no location, started with no agent preset. It runs the agent's CLI, but nobody works
    /// there: it opens as a terminal (the real one, where the sign-in link and code are copied and pasted). pierd lists it
    /// with no agent; an older one listed the CLI as its agent, and it still opens as a terminal here.
    var isSignIn: Bool { name.hasPrefix("login-") && (location ?? "").isEmpty && (preset ?? "").isEmpty && !chat }
}
