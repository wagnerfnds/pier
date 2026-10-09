import Testing

@testable import PierKit

@Suite struct PanelNavigatorTests {
    @Test func tabButtonsOpenAndTheSameOneCloses() {
        var n = PanelNavigator()
        #expect(!n.isOpen)
        n.toggle(root: .inbox)
        #expect(n.isOpen && n.top == .inbox && !n.canGoBack)
        n.toggle(root: .agents)
        #expect(n.top == .agents && n.stack.count == 1, "another button replaces the stack")
        n.toggle(root: .agents)
        #expect(!n.isOpen, "the same button again closes")
    }

    @Test func pushBackAndEscape() {
        var n = PanelNavigator()
        n.toggle(root: .agents)
        n.show(.agent("devbox/a"))
        n.show(.agent("devbox/a"))
        #expect(n.stack == [.agents, .agent("devbox/a")], "the same screen is not pushed twice")
        #expect(n.canGoBack)
        let closed = n.escape()
        #expect(!closed && n.top == .agents, "Esc goes back first")
        let closedAtRoot = n.escape()
        #expect(closedAtRoot && !n.isOpen, "Esc at the root closes")
        let went = n.back()
        #expect(!went, "nothing to go back to when closed")
    }

    @Test func rootsReplaceTheStackAndSubScreensStack() {
        var n = PanelNavigator()
        n.show(.compose(chat: false))
        n.show(.project)
        #expect(n.stack == [.compose(chat: false), .project])
        n.show(.talk)
        #expect(n.stack == [.talk], "a root replaces whatever was there")
        #expect(PanelScreen.agent("x").isRoot == false && PanelScreen.project.isRoot == false)
    }

    @Test func indicatorsStartedTasksAndGoneAgents() {
        var n = PanelNavigator()
        n.showAgent("devbox/a")
        #expect(n.stack == [.agents, .agent("devbox/a")])
        n.show(.compose(chat: true))
        n.started(agent: "devbox/new")
        #expect(n.stack == [.agents, .agent("devbox/new")], "the form gives way to the agent, the list under it")
        n.agentGone("devbox/other")
        #expect(n.top == .agent("devbox/new"), "another agent going does nothing")
        n.agentGone("devbox/new")
        #expect(n.stack == [.agents])
        var lone = PanelNavigator()
        lone.show(.agents); lone.show(.agent("x")); lone.toggle(root: .agents)   // the list button, from an agent: the list
        #expect(lone.stack == [.agents])
        lone.toggle(root: .agents)                                                 // and again: closed
        #expect(!lone.isOpen)
    }
}
