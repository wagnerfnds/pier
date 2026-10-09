import XCTest
@testable import PierKit

final class IntentSupportTests: XCTestCase {
    func sess(_ n: String, _ st: AgentState?, agent: String? = "claude", exited: Bool = false, ask: Ask? = nil) -> Session {
        Session(name: n, exited: exited, agent: agent, agentState: st, ask: ask)
    }

    func testSummaryPT() {
        let c = AgentCounts(sessions: [sess("a", .waiting), sess("b", .waiting), sess("c", .running), sess("d", .running, exited: true), sess("e", nil, agent: nil)])
        XCTAssertEqual(c.needsYou, 2)
        XCTAssertEqual(c.working, 1)
        XCTAssertEqual(c.summary(.pt), "2 precisam de você, 1 trabalhando.")
        XCTAssertEqual(c.summary(.en), "2 need you, 1 working.")
        XCTAssertEqual(AgentCounts().summary(.pt), "Nenhum agente ativo.")
        XCTAssertEqual(AgentCounts(needsYou: 1, finished: 3).summary(.pt), "1 precisa de você, 3 terminaram.")
    }

    func testCategories() {
        XCTAssertEqual(NotificationCategoryID.category(state: .waiting, ask: Ask(tool: "Bash", input: "ls")), "NEEDS_YOU")
        XCTAssertEqual(NotificationCategoryID.category(state: .waiting, ask: Ask(tool: "AskUserQuestion")), "NEEDS_YOU_QUESTION")
        XCTAssertEqual(NotificationCategoryID.category(state: .waiting, ask: nil), "NEEDS_YOU_QUESTION")
        XCTAssertEqual(NotificationCategoryID.category(state: .finished, ask: nil), "FINISHED")
        XCTAssertNil(NotificationCategoryID.category(state: .running, ask: nil))
    }
}
