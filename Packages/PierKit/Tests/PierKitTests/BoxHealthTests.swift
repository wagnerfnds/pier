import Foundation
import Testing

@testable import PierKit

@Suite struct BoxHealthTests {
    @Test func realReportKeepsOnlyWhatNeedsAHand() throws {
        let checks: [DoctorCheck] = try Fixture.decode("doctor.json")
        let issues = BoxHealth.issues(in: checks)
        // One warning in that report: pierd is not a service. Nothing ok or informational makes a card.
        #expect(issues.map(\.id) == ["pierd/starts at boot"])
        #expect(issues[0].kind == .service)
        #expect(issues[0].severity == .warn)
        #expect(issues[0].fix == "pierd install")
    }

    @Test func kindsAndOrder() {
        let checks = [
            DoctorCheck(area: "Agents", name: "Claude Code hooks", status: "warn", detail: "not installed", fix: "pierd integrations install claude"),
            DoctorCheck(area: "Agents", name: "Codex sign-in", status: "warn", detail: "not signed in on this box", fix: "On the box, run codex login --device-auth"),
            DoctorCheck(area: "Locations", name: "shop", status: "fail", detail: "/home/u/shop no longer exists", fix: "pierd location rm shop"),
            DoctorCheck(area: "Worktrees and sessions", name: "tmux", status: "fail", detail: "not installed", fix: "apt install tmux"),
            DoctorCheck(area: "pierd", name: "survives logout", status: "warn", detail: "pierd stops when you log out", fix: "sudo loginctl enable-linger u"),
            DoctorCheck(area: "pierd", name: "listening", status: "warn", detail: "0.0.0.0:7444 answers on every interface"),
            DoctorCheck(area: "pierd", name: "paired clients", status: "warn", detail: "none yet", fix: "pierd pair"),
            DoctorCheck(area: "Events", name: "journal", status: "warn", detail: "3 writes failed"),
            DoctorCheck(area: "Agents", name: "agent CLIs", status: "info", detail: "none found", fix: "Install it on the box"),
            DoctorCheck(area: "Worktrees and sessions", name: "PATH", status: "info", detail: "/usr/bin"),
            DoctorCheck(area: "Something new", name: "disk", status: "warn", detail: "90% full"),
            DoctorCheck(area: "Agents", name: "Claude Code sign-in", status: "ok", detail: "signed in"),
        ]
        let issues = BoxHealth.issues(in: checks)
        // Failures first, then the warnings in the report's order; the pairing line, plain information and ok stay out.
        #expect(issues.map(\.kind) == [
            .location(name: "shop"), .tool(name: "tmux"),
            .agentHooks(agent: "Claude Code"), .agentSignIn(agent: "Codex"), .lingering, .listening, .events(name: "journal"),
            .noAgents, .other(area: "Something new", name: "disk"),
        ])
        #expect(issues.first { $0.kind == .noAgents }?.severity == .warn)
        #expect(issues.first { $0.kind == .agentSignIn(agent: "Codex") }?.fix == "On the box, run codex login --device-auth")
        #expect(issues.map(\.id).contains("pierd/survives logout"))
        #expect(!issues.contains { $0.id.hasPrefix("pierd/paired") })
    }
}
