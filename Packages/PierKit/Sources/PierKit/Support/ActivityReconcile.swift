import Foundation

/// What to do with a running Live Activity given what the app knows about its session. Pure, so it can be tested.
///
/// A session the app has never heard of is NOT a finished session: a push-to-start activity is born the moment the
/// agent starts, usually before the app's list has it. Only a session positively known to be gone ends the activity.
public enum ActivityReconcile {
    public enum Decision: Equatable, Sendable {
        /// Leave the activity exactly as it is.
        case keep
        /// Follow the session (update the content from it).
        case follow
        /// The session is not in the cached list and the activity is old enough: ask the box again before ending it.
        case verifyWithFreshFetch
        /// The session is confirmed gone (or exited).
        case end
    }

    /// How long a new activity may exist without its session showing up in the app's list.
    public static let grace: TimeInterval = 120

    /// - Parameters:
    ///   - sessionKnown: the session is in the box's current list.
    ///   - sessionExited: that session's process exited.
    ///   - listLoaded: the app has a list from the box at all (nil means the box did not answer).
    ///   - age: seconds since the app first saw this activity.
    ///   - freshFetchLacksSession: a list fetched just now confirmed the session is absent.
    public static func decide(sessionKnown: Bool, sessionExited: Bool, listLoaded: Bool, age: TimeInterval, freshFetchLacksSession: Bool? = nil) -> Decision {
        if sessionKnown { return sessionExited ? .end : .follow }
        guard listLoaded else { return .keep }
        if age < grace { return .keep }
        switch freshFetchLacksSession {
        case .none: return .verifyWithFreshFetch
        case .some(true): return .end
        case .some(false): return .keep
        }
    }
}
