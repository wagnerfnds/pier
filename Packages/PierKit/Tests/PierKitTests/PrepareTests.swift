import Foundation
import Testing

@testable import PierKit

@Suite struct PrepareTests {
    @Test func statusesDecode() throws {
        let skipped = try Fixture.decode("prepare_skipped.json", as: PrepareStatus.self)
        #expect(skipped.state == .skipped && skipped.since != nil && skipped.services == ["web", "compose"] && skipped.hasWork)
        let failed = try Fixture.decode("prepare_failed.json", as: PrepareStatus.self)
        #expect(failed.state == .failed && failed.error?.contains("missing script") == true)
        let unknown = try Fixture.decode("prepare_unknown.json", as: PrepareStatus.self)
        #expect(unknown.state == .unknown && unknown.since == nil && !unknown.hasWork)
        // A state a later box adds reads as unknown rather than failing the whole screen.
        let later = try JSONDecoder.pier.decode(PrepareStatus.self, from: Data(#"{"state":"paused"}"#.utf8))
        #expect(later.state == .unknown && later.services.isEmpty)
    }

    /// prepare goes out only when it was set: an older box never sees the field, and nil keeps today's behavior.
    @Test func requestsCarryPrepareOnlyWhenSet() throws {
        func body<T: Encodable>(_ v: T) throws -> String { String(decoding: try PierJSON.makeEncoder().encode(v), as: UTF8.self) }
        #expect(try body(WorktreeRequest(name: "quick", prepare: false)).contains(#""prepare":false"#))
        #expect(try !body(WorktreeRequest(name: "full")).contains("prepare"))
        #expect(try body(TaskRequest(location: "shop", name: "quick", prepare: false)).contains(#""prepare":false"#))
        #expect(try !body(TaskRequest(location: "shop", name: "full")).contains("prepare"))
    }

    @Test func routes() async throws {
        let t = MockTransport { method, path, _ in
            (method == .post ? 202 : 200, try Fixture.data(method == .post ? "prepare_running.json" : "prepare_skipped.json"))
        }
        let a = BoxAPI(transport: t, eventPolicy: EventStreamPolicy(jitter: 0))
        #expect(try await a.prepareStatus(location: "shop", worktree: "fix/login").state == .skipped)
        #expect(try await a.prepare(location: "shop", worktree: "fix/login").state == .running)
        #expect(t.requests.map { "\($0.method) \($0.path)" } == [
            "GET /v1/locations/shop/worktrees/fix%2Flogin/prepare",
            "POST /v1/locations/shop/worktrees/fix%2Flogin/prepare",
        ])
    }

    /// A setup agent's preparation: its session, whether it waits for someone, the box's default for the next one.
    @Test func agentStatusesDecode() throws {
        let running = try Fixture.decode("prepare_agent_running.json", as: PrepareStatus.self)
        #expect(running.state == .running && running.byAgent && running.session == "shop-login-setup" && running.waiting)
        #expect(!running.hasWork && running.hasAnything && running.prepareWith == .agent)
        let failed = try Fixture.decode("prepare_agent_failed.json", as: PrepareStatus.self)
        #expect(failed.state == .failed && failed.byAgent && failed.error?.contains("pierd prepare done") == true && failed.prepareWith == .script)
        // An older box: a script, no default way, nothing new.
        let old = try Fixture.decode("prepare_skipped.json", as: PrepareStatus.self)
        #expect(!old.byAgent && old.kind == nil && old.prepareWith == nil && !old.waiting)
        // A way a later box adds is left to the box.
        let later = try JSONDecoder.pier.decode(PrepareStatus.self, from: Data(#"{"state":"ready","prepare_with":"robot"}"#.utf8))
        #expect(later.state == .ready && later.prepareWith == nil)
        let loc = try Fixture.decode("locations.json", as: [Location].self)
        #expect(loc.first?.prepareWith == .agent && loc.dropFirst().allSatisfy { $0.prepareWith == nil })
        // The person's consent: allowed for the first project only.
        #expect(loc.first?.setupAgent == true && loc.dropFirst().allSatisfy { !$0.setupAgent })
        let allowed = try Fixture.decode("location_setup_agent.json", as: Location.self)
        #expect(allowed.setupAgent && allowed.prepareWith == .agent)
        // A setup agent's session says so; every other session does not.
        let sessions = try Fixture.decode("sessions_setup.json", as: [Session].self)
        #expect(sessions.map(\.setup) == [true, false])
        #expect(try Fixture.decode("sessions_mixed.json", as: [Session].self).allSatisfy { !$0.setup })
    }

    /// The consent goes to the project's own route, as a yes or a no.
    @Test func consentRoute() async throws {
        let t = MockTransport { _, _, _ in (200, try Fixture.data("location_setup_agent.json")) }
        let a = BoxAPI(transport: t, eventPolicy: EventStreamPolicy(jitter: 0))
        #expect(try await a.setSetupAgent(location: "leads-app", allowed: true).setupAgent)
        _ = try await a.setSetupAgent(location: "a b", allowed: false)
        #expect(t.requests.map { "\($0.method) \($0.path)" } == ["PUT /v1/locations/leads-app/setup-agent", "PUT /v1/locations/a%20b/setup-agent"])
        #expect(t.requests.map(\.body) == [#"{"allowed":true}"#, #"{"allowed":false}"#])
    }

    /// prepare_with goes out only when set, by its name.
    @Test func requestsCarryPrepareWithOnlyWhenSet() throws {
        func body<T: Encodable>(_ v: T) throws -> String { String(decoding: try PierJSON.makeEncoder().encode(v), as: UTF8.self) }
        #expect(try body(WorktreeRequest(name: "login", prepareWith: .agent)).contains(#""prepare_with":"agent""#))
        #expect(try !body(WorktreeRequest(name: "login")).contains("prepare_with"))
        #expect(try body(TaskRequest(location: "shop", name: "login", prepareWith: .script)).contains(#""prepare_with":"script""#))
        #expect(try !body(TaskRequest(location: "shop", name: "login")).contains("prepare_with"))
    }

    @Test func prepareWithAWay() async throws {
        let t = MockTransport { _, _, _ in (202, try Fixture.data("prepare_agent_running.json")) }
        let a = BoxAPI(transport: t, eventPolicy: EventStreamPolicy(jitter: 0))
        #expect(try await a.prepare(location: "shop", worktree: "login", with: .agent).session == "shop-login-setup")
        _ = try await a.prepare(location: "shop", worktree: "login")
        #expect(t.requests.map(\.body) == [#"{"prepare_with":"agent"}"#, nil])
    }

    /// The composer's ways: none on an older box, only the code or the script without setup agents, all three with
    /// them; the project's default picked first unless the person asked for only the code last time; the default left
    /// as it was left to the box, a way the person picked (or another one) named; a setup agent asks for consent
    /// until the project allows them.
    @Test func composerChoice() {
        #expect(PrepareChoice.modes(canSkip: false, canAgent: true).isEmpty)
        #expect(PrepareChoice.modes(canSkip: true, canAgent: false) == [.none, .script])
        let all = PrepareChoice.modes(canSkip: true, canAgent: true)
        #expect(all == [.none, .script, .agent])
        #expect(PrepareChoice.initial(projectDefault: .agent, skippedLastTime: false, modes: all) == .agent)
        #expect(PrepareChoice.initial(projectDefault: .script, skippedLastTime: false, modes: all) == .script)
        #expect(PrepareChoice.initial(projectDefault: .agent, skippedLastTime: true, modes: all) == .none)
        #expect(PrepareChoice.initial(projectDefault: .agent, skippedLastTime: false, modes: [.none, .script]) == .script)
        #expect(PrepareChoice.initial(projectDefault: nil, skippedLastTime: false, modes: all) == .script)

        #expect(PrepareChoice.request(.none, picked: true, projectDefault: .agent, canSkip: true, canAgent: true) == (false, nil))
        #expect(PrepareChoice.request(.agent, picked: false, projectDefault: .agent, canSkip: true, canAgent: true) == (nil, nil))
        #expect(PrepareChoice.request(.agent, picked: true, projectDefault: .agent, canSkip: true, canAgent: true) == (nil, .agent))
        #expect(PrepareChoice.request(.script, picked: false, projectDefault: .script, canSkip: true, canAgent: true) == (nil, nil))
        #expect(PrepareChoice.request(.script, picked: true, projectDefault: .script, canSkip: true, canAgent: true) == (nil, .script))
        #expect(PrepareChoice.request(.script, picked: false, projectDefault: .agent, canSkip: true, canAgent: true) == (nil, .script))
        #expect(PrepareChoice.request(.agent, picked: true, projectDefault: .script, canSkip: true, canAgent: true) == (nil, .agent))
        #expect(PrepareChoice.request(.script, picked: true, projectDefault: nil, canSkip: true, canAgent: false) == (nil, nil))
        #expect(PrepareChoice.request(.none, picked: true, projectDefault: nil, canSkip: false, canAgent: false) == (nil, nil))

        #expect(PrepareChoice.asksConsent(.agent, allowed: false))
        #expect(!PrepareChoice.asksConsent(.agent, allowed: true))
        #expect(!PrepareChoice.asksConsent(.script, allowed: false) && !PrepareChoice.asksConsent(.none, allowed: false))
    }
}

@Suite struct PreviewTests {
    @Test func previewDecodes() throws {
        let p = try Fixture.decode("preview.json", as: WorktreePreview.self)
        #expect(p.port == 41010 && p.path == "/login" && p.login?.user == "demo@example.com" && p.login?.password == "demo-pass-123")
        #expect(p.updated != nil && p.share?.auto == true && p.share?.expires != nil && !p.isEmpty)
        #expect(try Fixture.decode("preview_empty.json", as: WorktreePreview.self).isEmpty)
        let settings = try Fixture.decode("settings_prepare.json", as: BoxSettings.self)
        #expect(settings.prepareRulesDefault && settings.prepareRules?.contains("Docker") == true && settings.autoShare == true)
        let old = try Fixture.decode("settings.json", as: BoxSettings.self)
        #expect(old.prepareRules == nil && old.autoShare == nil)
    }

    /// The public page and the box's own, at the preview's path.
    @Test func links() throws {
        let p = try Fixture.decode("preview.json", as: WorktreePreview.self)
        #expect(Previews.publicURL(p)?.absoluteString == "https://p-abcd2345k3vq7x2mfa4rj6bn.docktopier.com/login")
        #expect(Previews.directURL(p, host: "192.0.2.10")?.absoluteString == "http://192.0.2.10:41010/login")
        #expect(Previews.directURL(p, host: "") == nil)
        let root = WorktreePreview(port: 41010, path: "/", share: PreviewShare(name: "x", url: "https://p-x.docktopier.com/"))
        #expect(Previews.publicURL(root)?.absoluteString == "https://p-x.docktopier.com")
        #expect(Previews.directURL(WorktreePreview(url: "https://staging.example.com/app"), host: "192.0.2.10")?.absoluteString == "https://staging.example.com/app")
        #expect(Previews.publicURL(WorktreePreview(port: 41010)) == nil)
    }

    /// PUT sends what is recorded, never the box's own answers.
    @Test func routes() async throws {
        let t = MockTransport { _, _, _ in (200, try Fixture.data("preview.json")) }
        let a = BoxAPI(transport: t, eventPolicy: EventStreamPolicy(jitter: 0))
        let p = try await a.preview(location: "shop", worktree: "login")
        _ = try await a.setPreview(location: "shop", worktree: "login", p)
        #expect(t.requests.map { "\($0.method) \($0.path)" } == ["GET /v1/locations/shop/worktrees/login/preview", "PUT /v1/locations/shop/worktrees/login/preview"])
        let sent = try #require(t.requests.last?.body)
        #expect(sent.contains(#""port":41010"#) && sent.contains("demo@example.com") && !sent.contains("updated") && !sent.contains("share"))

        let s = MockTransport { _, _, _ in (200, try Fixture.data("settings_prepare.json")) }
        let b = BoxAPI(transport: s, eventPolicy: EventStreamPolicy(jitter: 0))
        _ = try await b.setPrepareRules("- No Docker.")
        _ = try await b.setAutoShare(false)
        #expect(s.requests.map(\.body) == [#"{"prepare_rules":"- No Docker."}"#, #"{"auto_share":false}"#])
    }
}
