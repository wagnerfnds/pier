import Foundation
import Testing

@testable import PierKit

@Suite struct AgentBoardTests {
    private func s(_ name: String, _ state: AgentState?, location: String = "sandbox", exited: Bool = false, agent: String? = "claude",
                   title: String? = nil, ago: TimeInterval = 60) -> Session {
        Session(name: name, location: location, created: Date(timeIntervalSince1970: 1_000), exited: exited, agent: agent,
                agentState: state, stateSince: Date(timeIntervalSince1970: 100_000 - ago), title: title)
    }
    private func item(_ s: Session, box: String = "devbox") -> AgentBoard.Item { AgentBoard.Item(box: box, session: s) }

    @Test func columnsFollowTheStateAndThePhonesMarks() {
        #expect(AgentBoard.column(s("a", .waiting), archived: false, background: false) == .needsYou)
        #expect(AgentBoard.column(s("a", .running), archived: false, background: false) == .working)
        #expect(AgentBoard.column(s("a", .finished), archived: false, background: false) == .yourTurn)
        #expect(AgentBoard.column(s("a", .finished), archived: false, background: true) == .working)
        #expect(AgentBoard.column(s("a", .finished), archived: true, background: true) == .closed)
        #expect(AgentBoard.column(s("a", .idle), archived: false, background: false) == .ready)
        #expect(AgentBoard.column(s("a", nil), archived: false, background: false) == .ready)
        #expect(AgentBoard.column(s("a", .idle), archived: true, background: false) == .closed)
        #expect(AgentBoard.column(s("a", .running, exited: true), archived: false, background: false) == .closed)
        // A plain terminal is not on the board.
        #expect(AgentBoard.column(s("a", nil, agent: nil), archived: false, background: false) == nil)
    }

    @Test func buildSortsNeedsYouOldestFirstAndTheRestNewestFirst() {
        let items = [
            item(s("w1", .waiting, ago: 30)), item(s("w2", .waiting, ago: 300)),
            item(s("r1", .running, ago: 30)), item(s("r2", .running, ago: 300)),
            item(s("f1", .finished, ago: 10)), item(s("f2", .finished, ago: 20)),
            item(s("bg", .finished, ago: 5)), item(s("x", .finished, exited: true)),
        ]
        let b = AgentBoard.build(items, archived: { $0.session.name == "f2" }, background: ["devbox/bg"])
        #expect(b[.needsYou]?.map(\.session.name) == ["w2", "w1"])
        #expect(b[.working]?.map(\.session.name) == ["bg", "r1", "r2"])
        #expect(b[.yourTurn]?.map(\.session.name) == ["f1"])
        #expect(b[.closed]?.map(\.session.name) == ["f2", "x"])
        #expect(b[.ready] == [])
    }

    @Test func equalTimesKeepAStableOrder() {
        let items = [item(s("b", .running)), item(s("a", .running)), item(s("c", .running))]
        let one = AgentBoard.build(items, archived: { _ in false }, background: [])
        let two = AgentBoard.build(items.reversed(), archived: { _ in false }, background: [])
        #expect(one[.working]?.map(\.id) == ["devbox/a", "devbox/b", "devbox/c"])
        #expect(one == two)
    }

    @Test func filtersByBoxProjectAndWords() {
        let items = [
            item(s("one", .running, location: "sandbox/subtract", title: "Add a subtract function")),
            item(s("two", .running, location: "acme-web", title: "Migrate the billing page"), box: "lab"),
            item(s("three", .finished, location: "sandbox", title: "Billing report")),
        ]
        func names(_ f: AgentBoard.Filter, _ extra: (AgentBoard.Item) -> [String] = { _ in [] }) -> [String] {
            AgentBoard.build(items, filter: f, archived: { _ in false }, background: [], names: extra).values.flatMap { $0 }.map(\.session.name).sorted()
        }
        #expect(names(.init(box: "lab")) == ["two"])
        #expect(names(.init(project: "devbox/sandbox")) == ["one", "three"])
        #expect(names(.init(text: "billing")) == ["three", "two"])
        #expect(names(.init(text: "BILLING page")) == ["two"])
        #expect(names(.init(text: "subtract")) == ["one"])           // worktree and title
        #expect(names(.init(text: "Acme"), { $0.location == "acme-web" ? ["Acme"] : [] }) == ["two"])
        #expect(AgentBoard.Filter(text: "  ").isActive == false)
    }

    @Test func dropsArchiveAndUnarchiveOnly() {
        let done = s("f", .finished), idle = s("i", .idle), run = s("r", .running), gone = s("x", .finished, exited: true)
        #expect(AgentBoard.move(done, from: .yourTurn, to: .closed) == .archive)
        #expect(AgentBoard.move(idle, from: .ready, to: .closed) == .archive)
        #expect(AgentBoard.move(done, from: .working, to: .closed) == .archive)     // finished turn with background work
        #expect(AgentBoard.move(run, from: .working, to: .closed) == nil)
        #expect(AgentBoard.move(s("w", .waiting), from: .needsYou, to: .closed) == nil)
        #expect(AgentBoard.move(done, from: .closed, to: .yourTurn) == .unarchive)
        #expect(AgentBoard.move(done, from: .closed, to: .working) == nil)
        #expect(AgentBoard.move(gone, from: .closed, to: .yourTurn) == nil)
        #expect(AgentBoard.move(done, from: .yourTurn, to: .ready) == nil)
    }

    @Test func projectsAreUniqueAndSorted() {
        let items = [item(s("a", .running, location: "zeta/wt")), item(s("b", .running, location: "alpha")), item(s("c", .idle, location: "zeta")),
                     item(s("d", .running, location: "alpha"), box: "lab")]
        #expect(AgentBoard.projects(items).map { "\($0.box)/\($0.location)" } == ["devbox/alpha", "devbox/zeta", "lab/alpha"])
    }
}
