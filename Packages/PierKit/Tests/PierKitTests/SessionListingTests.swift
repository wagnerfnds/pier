import Foundation
import Testing

@testable import PierKit

@Suite struct SessionListingTests {
    @Test func aTerminalConnectingIsNoNews() {
        let a = Session(name: "s", attached: 0, agent: "claude", agentState: .running)
        let b = Session(name: "s", attached: 2, agent: "claude", agentState: .running)
        #expect(a != b)
        #expect(Session.sameListing([a], [b]))
        #expect(!Session.sameListing([a], [a, b]))
    }

    /// Every field but `attached` counts. A field added to `Session` fails the first check until `sameListing` compares
    /// it too (and this list names it).
    @Test func everyOtherFieldCounts() {
        let labels = Set(Mirror(reflecting: Session(name: "s")).children.compactMap(\.label))
        #expect(labels == ["name", "location", "dir", "command", "created", "attached", "exited", "agent", "agentState", "stateSince",
                           "preset", "turn", "stateSeq", "fidelity", "title", "queued", "ask", "service", "chat"])
        let base = Session(name: "s")
        let other: [Session] = [
            Session(name: "t"), Session(name: "s", location: "l"), Session(name: "s", dir: "/d"), Session(name: "s", command: "c"),
            Session(name: "s", created: Date(timeIntervalSince1970: 1)), Session(name: "s", exited: true), Session(name: "s", agent: "codex"),
            Session(name: "s", agentState: .waiting), Session(name: "s", stateSince: Date(timeIntervalSince1970: 2)),
            Session(name: "s", preset: "p"), Session(name: "s", turn: "t1"), Session(name: "s", fidelity: "f"),
            Session(name: "s", title: "x"), Session(name: "s", queued: 1), Session(name: "s", ask: Ask(tool: "Bash")),
            Session(name: "s", service: "dev"), Session(name: "s", chat: true),
        ]
        for o in other { #expect(!base.sameListing(as: o)) }
        #expect(base.sameListing(as: Session(name: "s", attached: 5)))
        #expect(base.sameListing(as: Session(name: "s", stateSeq: 3)))
    }

    /// An agent at work fires an event for every tool it runs; the turn going on is no news, a new one or a new state is.
    @Test func aToolRunInTheSameTurnIsNoNews() {
        let t0 = Date(timeIntervalSince1970: 100), t1 = Date(timeIntervalSince1970: 130)
        let a = Session(name: "s", agent: "claude", agentState: .running, stateSince: t0, turn: "s#3", stateSeq: 10)
        #expect(a.sameListing(as: Session(name: "s", agent: "claude", agentState: .running, stateSince: t1, turn: "s#3", stateSeq: 14)))
        #expect(!a.sameListing(as: Session(name: "s", agent: "claude", agentState: .running, stateSince: t1, turn: "s#4", stateSeq: 14)))
        #expect(!a.sameListing(as: Session(name: "s", agent: "claude", agentState: .waiting, stateSince: t1, turn: "s#3", stateSeq: 14)))
        let w = Session(name: "s", agent: "claude", agentState: .waiting, stateSince: t0, turn: "s#3")
        #expect(!w.sameListing(as: Session(name: "s", agent: "claude", agentState: .waiting, stateSince: t1, turn: "s#3")))
    }
}
