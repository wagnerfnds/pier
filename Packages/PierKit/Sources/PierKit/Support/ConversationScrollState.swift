/// The reader's intent in a conversation, separate from the scroll view's changing layout estimates.
/// Geometry from initial layout, content growth or programmatic scrolling must not detach the reader or fetch history.
public struct ConversationScrollState: Sendable, Equatable {
    public private(set) var followsBottom = true
    public private(set) var isNearTop = false

    public init() {}

    /// Apply geometry produced during a real user scroll (including its deceleration).
    /// Returns true once on entering the history-loading zone; the caller still checks whether older items exist.
    /// The caller must pass false for layout changes and programmatic scrolling, even when the content moved.
    @discardableResult
    public mutating func update(fromTop: Double, fromBottom: Double, scrollable: Bool,
                                userInteracting: Bool) -> Bool {
        guard userInteracting, fromTop.isFinite, fromBottom.isFinite else { return false }

        // Hysteresis keeps small changes around the bottom from toggling the reader's intent.
        if followsBottom, fromBottom > 160 {
            followsBottom = false
        } else if !followsBottom, fromBottom < 40 {
            followsBottom = true
        }

        let nearTop = scrollable && fromTop < 240 && fromBottom > 240
        let enteredTop = nearTop && !isNearTop
        isNearTop = nearTop
        return enteredTop
    }

    /// A send or an explicit "go to end" means follow again, regardless of the latest layout estimate.
    public mutating func requestFollow() {
        followsBottom = true
        isNearTop = false
    }

    /// Loading earlier messages is an explicit request to read history, even if all current messages fit on screen.
    public mutating func requestHistory() {
        followsBottom = false
        isNearTop = true
    }

    /// End a real scroll without changing follow intent. Another gesture at the top may request the next page.
    public mutating func endInteraction() {
        isNearTop = false
    }
}
