import Foundation
import Testing

@testable import PierKit

private func text(_ off: Int64, _ s: String) -> TranscriptItem { TranscriptItem(kind: "text", id: "cl@\(off).1", off: off, text: s) }
private func user(_ off: Int64, _ s: String) -> TranscriptItem { TranscriptItem(kind: "user", id: "cl@\(off).1", off: off, text: s) }

@Suite struct DraftEchoTests {
    @Test func aDraftAlreadyRecordedIsSeenThroughItsMarkdown() {
        // The record has the agent's Markdown; the draft is pierd's rebuild of the screen (other escapes and wraps).
        let items = [user(1, "summarize"), text(2, "## Done\n\nI changed **three** things:\n\n1. `calc.py` got `subtract`.\n2. Tests cover it.")]
        let draft = "## Done\n\nI changed **three** things:\n\n1. `calc.py` got `subtract`.\n2. Tests cover\nit."
        #expect(DraftEcho.isRecorded(draft, in: items))
    }

    @Test func theNextBlockBeingWrittenIsNotRecorded() {
        let items = [user(1, "go"), text(2, "Let me read the config first.")]
        #expect(!DraftEcho.isRecorded("Now I'll update the parser so that it keeps", in: items))
        // The previous turn's words never hide this turn's draft.
        let older = [user(1, "a"), text(2, "Same words as before, long enough to compare."), user(3, "b")]
        #expect(!DraftEcho.isRecorded("Same words as before, long enough to compare.", in: older))
    }

    @Test func shortDraftsMatchOnlyTheNewestBlockWhole() {
        let items = [user(1, "q"), text(2, "Done."), text(3, "Next I ran the build.")]
        #expect(!DraftEcho.isRecorded("Done.", in: items))
        #expect(DraftEcho.isRecorded("Next I ran the build.", in: items))
    }

    @Test func theEndOfALongReplyIsFoundInsideIt() {
        let long = (1...40).map { "Line \($0) of a long answer with words." }.joined(separator: "\n")
        let items = [user(1, "q"), text(2, long)]
        let clipped = (25...40).map { "Line \($0) of a long answer with words." }.joined(separator: "\n")
        #expect(DraftEcho.isRecorded(clipped, in: items))
    }
}

@Suite struct LinkWatchTests {
    @Test func twoFailedPollsDropTheConnectionOnce() {
        var w = LinkWatch()
        let t0 = Date(timeIntervalSince1970: 1000)
        let first = w.failed(at: t0)
        #expect(!first && w.troubled)
        let second = w.failed(at: t0.addingTimeInterval(6))
        #expect(second)
        // Still failing right after a reset: give the new connection time before dropping it again.
        let third = w.failed(at: t0.addingTimeInterval(12))
        #expect(!third)
        let later = w.failed(at: t0.addingTimeInterval(6 + LinkWatch.minResetGap + 1))
        #expect(later)
        w.succeeded()
        #expect(!w.troubled && w.failures == 0)
    }

    @Test func onlyTheWayToTheBoxCounts() {
        #expect(LinkWatch.isLinkFailure(PierError.timeout))
        #expect(LinkWatch.isLinkFailure(PierError.transport("reset")))
        #expect(!LinkWatch.isLinkFailure(PierError.api(status: 404, message: "gone", code: "not_found")))
        #expect(!LinkWatch.isLinkFailure(BoxError(status: 409, error: "waiting", code: "agent_waiting")))
        #expect(!LinkWatch.isLinkFailure(CancellationError()))
    }
}
