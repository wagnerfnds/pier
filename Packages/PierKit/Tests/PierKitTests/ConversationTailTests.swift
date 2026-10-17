import Testing

@testable import PierKit

@Suite struct ConversationTailTests {
    private func item(_ kind: String, _ id: String) -> ConversationBlock {
        .item(TranscriptItem(kind: kind, id: id, text: id))
    }

    private func tailIDs(_ blocks: [ConversationBlock]) -> [String] {
        blocks[ConversationTail.startIndex(in: blocks)...].map(\.id)
    }

    @Test func keepsOnlyTwoLatestAnsweredTurnsWithTheirPrompts() {
        let blocks = [item("user", "u1"), item("text", "a1"), item("user", "u2"), item("text", "a2"),
                      item("user", "u3"), item("text", "a3")]
        #expect(tailIDs(blocks) == ["u2", "a2", "u3", "a3"])
    }

    @Test func keepsFoldsAndShortPostscriptWithTheLongResponse() {
        let blocks = [item("user", "u1"), item("text", "a1"), item("user", "u2"), item("text", "a2"),
                      item("user", "u3"), .fold(id: "work", steps: [], live: false),
                      item("text", "tall"), item("edit", "edit"), item("text", "postscript")]
        #expect(tailIDs(blocks) == ["u2", "a2", "u3", "work", "tall", "edit", "postscript"])
    }

    @Test func recordingTheNextReplyRetainsThePreviousTallResponse() {
        let before = [item("user", "u1"), item("text", "a1"), item("user", "u2"), item("text", "tall"),
                      item("user", "u3"), .fold(id: "work", steps: [], live: true)]
        let after = before + [item("text", "new-reply")]
        #expect(tailIDs(before) == ["u1", "a1", "u2", "tall", "u3", "work"])
        #expect(tailIDs(after) == ["u2", "tall", "u3", "work", "new-reply"])
    }

    @Test func prependingEarlierHistoryPreservesTheTailIDs() {
        let current = [item("user", "u2"), item("text", "a2"), item("user", "u3"), item("text", "a3")]
        let older = [item("user", "u1"), item("text", "a1")]
        #expect(tailIDs(older + current) == tailIDs(current))
    }

    @Test func commandsAndReportsAreTheirOwnResponseTurns() {
        let blocks = [item("user", "u1"), item("text", "a1"), item("command", "command"), item("report", "report")]
        #expect(tailIDs(blocks) == ["command", "report"])
    }

    @Test func emptyUnansweredAndTruncatedHistoriesStayBounded() {
        #expect(ConversationTail.startIndex(in: []) == 0)
        let unanswered = [item("user", "u1"), item("notice", "n1"), item("user", "u2"),
                          .fold(id: "work", steps: [], live: true)]
        #expect(tailIDs(unanswered) == ["u2", "work"])
        #expect(tailIDs([item("notice", "n1"), item("notice", "n2")]) == ["n2"])
        #expect(tailIDs([item("text", "partial"), item("user", "u2"), item("text", "a2")]) == ["partial", "u2", "a2"])
    }
}
