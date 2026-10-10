import Foundation
import Testing

@testable import PierKit

@Suite struct SidebarRulesTests {
    private func s(_ name: String, _ state: AgentState?, location: String = "sandbox", exited: Bool = false, agent: String? = "claude",
                   ago: TimeInterval = 60) -> Session {
        Session(name: name, location: location, created: Date(timeIntervalSince1970: 1_000), exited: exited, agent: agent,
                agentState: state, stateSince: Date(timeIntervalSince1970: 100_000 - ago))
    }
    private func item(_ s: Session, box: String = "devbox") -> AgentBoard.Item { AgentBoard.Item(box: box, session: s) }

    @Test func listedLeavesOutArchivedExitedAndTerminals() {
        #expect(SidebarRules.isListed(s("a", .finished), archived: false, background: false))
        #expect(SidebarRules.isListed(s("a", .idle), archived: false, background: false))
        #expect(!SidebarRules.isListed(s("a", .finished), archived: true, background: false))
        #expect(!SidebarRules.isListed(s("a", .running, exited: true), archived: false, background: false))
        #expect(!SidebarRules.isListed(s("a", nil, agent: nil), archived: false, background: false))
        // A new turn of an archived session is back: the mark predates it (the caller's `archived` is false then).
        #expect(SidebarRules.isListed(s("a", .waiting), archived: false, background: false))
    }

    @Test func workingGroupsByWorktreeNeedsYouFirst() {
        let items = [
            item(s("run-main", .running, location: "web", ago: 10)),
            item(s("run-wt", .running, location: "web/login", ago: 50)),
            item(s("wait-wt", .waiting, location: "web/login", ago: 20)),
            item(s("done", .finished, location: "api")),
            item(s("bg", .finished, location: "api/jobs", ago: 5)),
            item(s("old-wait", .waiting, location: "docs", ago: 400)),
            item(s("archived-run", .running, location: "ops")),
            item(s("chat", .running, location: "", ago: 30)),
        ]
        let w = SidebarRules.working(items, archived: { $0.session.name == "archived-run" }, background: ["devbox/bg"])
        // Waits first, oldest on top; then the newest activity. An archive wins only over a finished turn: "archived-run"
        // still runs, so it is working.
        #expect(w.map(\.id) == ["devbox/docs", "devbox/web/login", "devbox/api/jobs", "devbox/web", "devbox/chat", "devbox/ops"])
        let login = w[1]
        #expect(login.location == "web" && login.worktree == "login")
        #expect(login.items.map(\.session.name) == ["wait-wt", "run-wt"])
        #expect(login.needsYou)
        #expect(w[3].worktree == nil && !w[3].needsYou)
        #expect(w[4].isChat)
    }

    @Test func workingSeparatesBoxes() {
        let items = [item(s("a", .running, location: "web"), box: "one"), item(s("b", .running, location: "web"), box: "two")]
        #expect(Set(SidebarRules.working(items, archived: { _ in false }, background: []).map(\.id)) == ["one/web", "two/web"])
    }

    @Test func archivedIsClosedNewestFirst() {
        let items = [
            item(s("old", .finished, ago: 500)),
            item(s("exited", .running, exited: true, ago: 100)),
            item(s("open", .finished, ago: 1)),
            item(s("arch", .idle, ago: 300)),
            item(s("term", nil, exited: true, agent: nil)),
        ]
        let a = SidebarRules.archived(items, archived: { ["old", "arch"].contains($0.session.name) })
        #expect(a.map(\.session.name) == ["exited", "arch", "old"])
    }
}
