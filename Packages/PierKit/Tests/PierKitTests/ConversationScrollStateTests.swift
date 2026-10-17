import Testing

@testable import PierKit

@Suite struct ConversationScrollStateTests {
    @Test func initialEstimatedTopDoesNotLoadHistoryOrDetach() {
        var state = ConversationScrollState()
        // A lazy stack can report the top while it is still finding the initial bottom position.
        let loadsHistory = state.update(fromTop: 0, fromBottom: 12_000, scrollable: true, userInteracting: false)
        #expect(!loadsHistory)
        #expect(state.followsBottom)
        #expect(!state.isNearTop)
    }

    @Test func idleGrowthDoesNotChangeFollowIntent() {
        var state = ConversationScrollState()
        let loadsWhileIdle = state.update(fromTop: 4_000, fromBottom: 800, scrollable: true, userInteracting: false)
        #expect(!loadsWhileIdle)
        #expect(state.followsBottom)

        state.update(fromTop: 4_000, fromBottom: 800, scrollable: true, userInteracting: true)
        #expect(!state.followsBottom)
        state.endInteraction()
        // An estimate shrinking, a prepend or an automatic scroll reaching the bottom cannot reattach a reader.
        for bottom in [0.0, 20, 500, 5_000] {
            let loadsHistory = state.update(fromTop: 0, fromBottom: bottom, scrollable: true, userInteracting: false)
            #expect(!loadsHistory)
            #expect(!state.followsBottom)
            #expect(!state.isNearTop)
        }
    }

    @Test func userScrollUsesBottomHysteresis() {
        var state = ConversationScrollState()
        state.update(fromTop: 1_000, fromBottom: 160, scrollable: true, userInteracting: true)
        #expect(state.followsBottom)
        state.update(fromTop: 1_000, fromBottom: 161, scrollable: true, userInteracting: true)
        #expect(!state.followsBottom)
        for bottom in [160.0, 100, 40] {
            state.update(fromTop: 1_000, fromBottom: bottom, scrollable: true, userInteracting: true)
            #expect(!state.followsBottom)
        }
        state.update(fromTop: 1_000, fromBottom: 39, scrollable: true, userInteracting: true)
        #expect(state.followsBottom)
        state.update(fromTop: 1_000, fromBottom: 100, scrollable: true, userInteracting: true)
        #expect(state.followsBottom)
    }

    @Test func historyLoadsOncePerEntryDuringRealScroll() {
        var state = ConversationScrollState()
        let loadsOnEntry = state.update(fromTop: 239, fromBottom: 1_000, scrollable: true, userInteracting: true)
        #expect(loadsOnEntry)
        #expect(state.isNearTop)
        #expect(!state.followsBottom)
        let loadsInsideZone = state.update(fromTop: 100, fromBottom: 1_139, scrollable: true, userInteracting: true)
        #expect(!loadsInsideZone)
        let loadsOnExit = state.update(fromTop: 300, fromBottom: 939, scrollable: true, userInteracting: true)
        #expect(!loadsOnExit)
        #expect(!state.isNearTop)
        let loadsOnReentry = state.update(fromTop: 200, fromBottom: 1_039, scrollable: true, userInteracting: true)
        #expect(loadsOnReentry)
    }

    @Test func historyZoneRequiresScrollableContentAndBothDistances() {
        var state = ConversationScrollState()
        let loadsEmpty = state.update(fromTop: 0, fromBottom: 0, scrollable: false, userInteracting: true)
        #expect(!loadsEmpty)
        let loadsUnscrollable = state.update(fromTop: 0, fromBottom: 1_000, scrollable: false, userInteracting: true)
        #expect(!loadsUnscrollable)
        let loadsAtTopBoundary = state.update(fromTop: 240, fromBottom: 1_000, scrollable: true, userInteracting: true)
        #expect(!loadsAtTopBoundary)
        let loadsAtBottomBoundary = state.update(fromTop: 0, fromBottom: 240, scrollable: true, userInteracting: true)
        #expect(!loadsAtBottomBoundary)
        #expect(!state.isNearTop)
        let loadsBeyondTop = state.update(fromTop: -10, fromBottom: 1_000, scrollable: true, userInteracting: true)
        #expect(loadsBeyondTop)
    }

    @Test func prependAndProgrammaticScrollDoNotRequestAnotherPage() {
        var state = ConversationScrollState()
        let loadsOnEntry = state.update(fromTop: 0, fromBottom: 3_000, scrollable: true, userInteracting: true)
        #expect(loadsOnEntry)
        state.endInteraction()
        for top in [0.0, 200, 6_000, 0] {
            let loadsWhileIdle = state.update(fromTop: top, fromBottom: 3_000, scrollable: true, userInteracting: false)
            #expect(!loadsWhileIdle)
            #expect(!state.isNearTop)
        }
        #expect(!state.followsBottom)
        // The reader deliberately scrolling again may load another page.
        let loadsOnNewGesture = state.update(fromTop: 0, fromBottom: 3_000, scrollable: true, userInteracting: true)
        #expect(loadsOnNewGesture)
    }

    @Test func explicitFollowClearsTopAndSurvivesStaleIdleGeometry() {
        var state = ConversationScrollState()
        state.update(fromTop: 0, fromBottom: 2_000, scrollable: true, userInteracting: true)
        state.requestFollow()
        #expect(state.followsBottom)
        #expect(!state.isNearTop)
        let loadsFromStaleGeometry = state.update(fromTop: 0, fromBottom: 2_000, scrollable: true, userInteracting: false)
        #expect(!loadsFromStaleGeometry)
        #expect(state.followsBottom)
        #expect(!state.isNearTop)
    }

    @Test func invalidEstimatesCannotChangeIntent() {
        var state = ConversationScrollState()
        for (top, bottom) in [(Double.nan, 500.0), (0.0, Double.infinity), (-Double.infinity, 500.0)] {
            let loadsFromInvalidGeometry = state.update(fromTop: top, fromBottom: bottom, scrollable: true, userInteracting: true)
            #expect(!loadsFromInvalidGeometry)
            #expect(state == ConversationScrollState())
        }
    }

    @Test func loadingHistoryExplicitlyDetachesEvenFromAShortConversation() {
        var state = ConversationScrollState()
        state.requestHistory()
        #expect(!state.followsBottom)
        #expect(state.isNearTop)
        // The prepend and any new reply arriving while it is laid out cannot jump the reader back to the end.
        let loadsWhileIdle = state.update(fromTop: 600, fromBottom: 0, scrollable: true, userInteracting: false)
        #expect(!loadsWhileIdle)
        #expect(!state.followsBottom)
        state.endInteraction()
        #expect(!state.followsBottom)
        state.requestFollow()
        #expect(state.followsBottom)
    }
}
