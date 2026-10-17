import Foundation
import Testing

@testable import PierKit

@Suite struct SignInTests {
    @Test func toolsAndLoginsDecode() throws {
        let tools: [BoxTool] = try Fixture.decode("tools.json")
        #expect(tools.map(\.id) == ["claude", "codex", "gh"])
        #expect(tools[0].installed && tools[0].version == "2.1.302 (Claude Code)" && !tools[0].installing)
        #expect(!tools[2].installed && tools[2].error?.hasPrefix("checksum mismatch") == true && tools[2].name == "GitHub CLI")
        let installing: [BoxTool] = try Fixture.decode("tools_installing.json")
        #expect(installing.filter(\.installing).map(\.id) == ["codex", "gh"])

        let gh: Login = try Fixture.decode("login_open_link.json")
        #expect(gh.state == .openLink && gh.userCode == "1B8C-23C0" && gh.url?.absoluteString == "https://github.com/login/device")
        #expect(!gh.needsCode && gh.account == nil && gh.session == "login-gh" && gh.started != nil && gh.finished == nil)
        let claude: Login = try Fixture.decode("login_enter_code.json")
        #expect(claude.state == .enterCode && claude.needsCode && claude.account == "claude" && claude.url?.host == "claude.com")
        let done: Login = try Fixture.decode("login_done.json")
        #expect(done.state == .done && done.state.isFinal && done.finished != nil)
        let failed: Login = try Fixture.decode("login_failed.json")
        #expect(failed.state == .failed && failed.error?.contains("status code 400") == true)
        let list: [Login] = try Fixture.decode("logins.json")
        #expect(list.map(\.state) == [.waiting, .failed])
        // A state pierd may add later reads as itself, not as a failure to decode.
        let later = try JSONDecoder.pier.decode(Login.self, from: Data(#"{"id":"x","tool":"gh","state":"verifying"}"#.utf8))
        #expect(later.state == .unknown("verifying") && !later.state.isFinal && SignIn.step(later) == .starting)

        // The old accounts route answers its session, now with the sign-in that runs in it.
        let s: Session = try Fixture.decode("account_login.json")
        #expect(s.name == "login-claude-1a2b3c4d")
        let e: BoxError = try Fixture.decode("tool_missing.json")
        #expect(e.code == "tool_missing")
    }

    @Test func routes() async throws {
        let t = MockTransport { method, path, _ in
            switch (method, path) {
            case (_, "/v1/tools"): return (200, try Fixture.data("tools.json"))
            case (_, "/v1/tools/install"): return (202, try Fixture.data("tools_installing.json"))
            case (.get, "/v1/logins"): return (200, try Fixture.data("logins.json"))
            case (_, let p) where p.hasSuffix("/code"): return (200, try Fixture.data("login_done.json"))
            default: return (200, try Fixture.data("login_open_link.json"))
            }
        }
        let a = BoxAPI(transport: t, eventPolicy: EventStreamPolicy(jitter: 0))
        _ = try await a.tools()
        _ = try await a.installTools(["gh"])
        _ = try await a.startLogin(tool: "gh")
        _ = try await a.startLogin(tool: "claude", account: "claude-1a2b")
        _ = try await a.login(id: "da71")
        _ = try await a.logins()
        _ = try await a.sendLoginCode(id: "da71", code: "abc#def")
        try await a.cancelLogin(id: "da71")
        #expect(t.requests.map { "\($0.method) \($0.path)" } == [
            "GET /v1/tools", "POST /v1/tools/install", "POST /v1/logins", "POST /v1/logins", "GET /v1/logins/da71", "GET /v1/logins",
            "POST /v1/logins/da71/code", "DELETE /v1/logins/da71",
        ])
        #expect(t.requests[1].body == #"{"tools":["gh"]}"#)
        #expect(t.requests[2].body == #"{"tool":"gh"}"#)
        #expect(t.requests[3].body == #"{"account":"claude-1a2b","tool":"claude"}"#)
        #expect(t.requests[6].body == #"{"code":"abc#def"}"#)
    }

    @Test func sheetSteps() throws {
        #expect(SignIn.step(nil) == .starting)
        let gh: Login = try Fixture.decode("login_open_link.json")
        #expect(SignIn.step(gh) == .open)
        let claude: Login = try Fixture.decode("login_enter_code.json")
        #expect(SignIn.step(claude) == .paste)
        // Claude Code's link before its prompt: the field is offered already.
        #expect(SignIn.step(Login(id: "1", tool: "claude", state: .openLink, needsCode: true)) == .paste)
        #expect(SignIn.step(Login(id: "1", tool: "claude", state: .waiting, needsCode: true)) == .confirming)
        #expect(SignIn.step(try Fixture.decode("login_done.json", as: Login.self)) == .done)
        #expect(SignIn.step(Login(id: "1", tool: "gh", state: .failed, error: "canceled")) == .failed("canceled"))
    }

    @Test func pastedCodes() {
        #expect(SignIn.cleanCode("  abc123#state-xyz \n") == "abc123#state-xyz")
        #expect(SignIn.cleanCode("\n\nabc#def\nsomething else") == "abc#def")
        #expect(SignIn.cleanCode(" \n ") == "")
    }

    /// The cards' buttons: a sign-in where the box signs in from the app, an install where it installs; an older box's
    /// card names its tool only in its name.
    @Test func healthCardActions() throws {
        let issues = BoxHealth.issues(in: try Fixture.decode("doctor_signin.json"))
        let byName = Dictionary(uniqueKeysWithValues: issues.map { ($0.name, $0) })
        #expect(SignIn.action(for: try #require(byName["Claude Code sign-in"]), logins: true, tools: true) == .signIn(tool: "claude", account: "claude"))
        let trabalho = try #require(byName["Claude Code (Trabalho) sign-in"])
        #expect(trabalho.kind == .agentSignIn(agent: "Claude Code (Trabalho)") && trabalho.account == "claude-1a2b3c4d")
        #expect(SignIn.action(for: trabalho, logins: true, tools: true) == .signIn(tool: "claude", account: "claude-1a2b3c4d"))
        #expect(SignIn.action(for: try #require(byName["gh"]), logins: true, tools: true) == .install(["gh"]))
        #expect(SignIn.action(for: try #require(byName["gh"]), logins: true, tools: false) == nil)
        #expect(SignIn.action(for: try #require(byName["survives logout"]), logins: true, tools: true) == nil)
        // The missing Codex is information, not a card.
        #expect(byName["Codex"] == nil)

        let old = BoxHealth.issues(in: [
            DoctorCheck(area: "Agents", name: "Codex sign-in", status: "warn", fix: "codex login --device-auth"),
            DoctorCheck(area: "Agents", name: "agent CLIs", status: "info", fix: "Install it on the box"),
        ])
        #expect(SignIn.action(for: old[0], logins: true, tools: true) == .signIn(tool: "codex", account: nil))
        #expect(SignIn.action(for: old[0], logins: false, tools: true) == nil)
        #expect(SignIn.action(for: old[1], logins: true, tools: true) == .install(["claude", "codex"]))
    }

    /// The onboarding's rows: installed or not, then signed in by the agent's default account or doctor's GitHub line.
    @Test func accountRows() throws {
        let tools: [BoxTool] = try Fixture.decode("tools.json")
        let accounts = [
            AgentAccount(id: "claude", agent: "claude", name: "Claude Code", builtin: true, signedIn: true, signedInKnown: false, isDefault: false),
            AgentAccount(id: "claude-1", agent: "claude", name: "Trabalho", signedIn: false, signedInKnown: true, isDefault: true),
            AgentAccount(id: "codex", agent: "codex", name: "Codex", builtin: true, signedIn: true, signedInKnown: true, isDefault: true),
        ]
        var rows = SignIn.rows(tools: tools, accounts: accounts, doctor: [])
        #expect(rows.map(\.tool) == ["claude", "codex", "gh"])
        #expect(rows[0] == SignIn.Row(tool: "claude", status: .signedOut, account: "claude-1"))
        #expect(rows[1] == SignIn.Row(tool: "codex", status: .signedIn, account: "codex"))
        #expect(rows[2].status == .installFailed(tools[2].error ?? ""))
        #expect(!SignIn.allSet(rows))

        let installed = tools.map { BoxTool(id: $0.id, installed: true) }
        let doctor = [DoctorCheck(area: "Agents", name: "GitHub sign-in", status: "warn", tool: "gh")]
        rows = SignIn.rows(tools: installed, accounts: [], doctor: doctor)
        // No accounts read: doctor says what it can (nothing about the agents here).
        #expect(rows.map(\.status) == [.unknown, .unknown, .signedOut])
        let busy: [BoxTool] = try Fixture.decode("tools_installing.json")
        #expect(SignIn.rows(tools: busy, accounts: accounts, doctor: []).map(\.status) == [.signedOut, .installing, .installing])
        let signedIn = SignIn.rows(tools: installed, accounts: [], doctor: [
            DoctorCheck(area: "Agents", name: "Claude Code sign-in", status: "ok", tool: "claude", account: "claude"),
            DoctorCheck(area: "Agents", name: "Codex sign-in", status: "ok"),
            DoctorCheck(area: "Agents", name: "GitHub sign-in", status: "ok", tool: "gh"),
        ])
        #expect(SignIn.allSet(signedIn))

        // gh's own status in the tools list wins over doctor, which says only "information" on a box without a project
        // on GitHub.
        let ghOut: [BoxTool] = try Fixture.decode("tools_signed_out.json")
        #expect(ghOut.last?.signedIn == false && ghOut.first?.signedIn == nil)
        let rowsOut = SignIn.rows(tools: ghOut, accounts: accounts, doctor: [DoctorCheck(area: "Agents", name: "GitHub sign-in", status: "info", tool: "gh")])
        #expect(rowsOut.last == SignIn.Row(tool: "gh", status: .signedOut))
    }
}
