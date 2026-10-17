import Foundation
import Testing

@testable import PierKit

/// pierd answers 409 `not_submitted` when an agent never took a prompt typed into it (docs/API.md 4.3), with `kept`
/// saying whether the text is still in the agent's input box.
@Suite struct SendNotSubmittedTests {
    @Test func decodesNotSubmitted() throws {
        let gone = try Fixture.decode("send_not_submitted.json", as: BoxError.self)
        #expect(gone.kind == .notSubmitted && !gone.kept)
        let kept = try Fixture.decode("send_not_submitted_kept.json", as: BoxError.self)
        #expect(kept.kind == .notSubmitted && kept.kept)
    }

    /// From the wire to the error a send throws: the status, the code and `kept` all arrive.
    @Test func keptReachesTheSender() async throws {
        let body = try Fixture.data("send_not_submitted_kept.json")
        let t = MockTransport { _, _, _ in throw mapHTTPError(status: 409, body: body) }
        do {
            _ = try await BoxAPI(transport: t).send(session: "shop-claude", SendRequest(text: "run the tests", when: .idle))
            Issue.record("the send did not fail")
        } catch let e as BoxError {
            #expect(e.status == 409 && e.kind == .notSubmitted && e.kept && e.error.contains("input box"))
        }
    }

    /// A code this version does not know still decodes, with its words, so the app can show them.
    @Test func anUnknownCodeStillDecodes() throws {
        let e = try JSONDecoder().decode(BoxError.self, from: Data(#"{"error":"something new","code":"brand_new","extra":1}"#.utf8))
        #expect(e.kind == nil && e.code == "brand_new" && e.error == "something new" && !e.kept)
        if case .api(let status, let message, let code, let kept) = mapHTTPError(status: 409, body: Data(#"{"error":"x","code":"brand_new"}"#.utf8)) {
            #expect(status == 409 && message == "x" && code == "brand_new" && !kept)
        } else {
            Issue.record("not an api error")
        }
    }
}

@Suite struct SignInSessionTests {
    @Test func aSignInTerminalIsKnownAsOne() {
        // As pierd lists it now (no agent), and as an older pierd did (the CLI as its agent).
        #expect(Session(name: "login-claude-1a2b", command: "claude /login").isSignIn)
        #expect(Session(name: "login-codex", command: "codex login --device-auth", agent: "codex").isSignIn)
        // A project's session, or an agent started with a preset, under that name is not one.
        #expect(!Session(name: "login-fix", location: "shop", agent: "claude").isSignIn)
        #expect(!Session(name: "login-fix", agent: "claude", preset: "claude").isSignIn)
        #expect(!Session(name: "shop-claude-1", agent: "claude").isSignIn)
    }
}
