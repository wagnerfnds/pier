import Foundation

/// How an open conversation tells a box that is slow from a connection that died (a network change the system did not
/// report, a NAT that forgot the flow, a box that rebooted without closing it): requests that fail on the connection
/// itself, poll after poll, mean it is dead. The screen then drops it, so the next request dials again, racing the
/// box's address and its relay (`H2Connection.dial`), instead of waiting for the PING watchdog (up to ~45 s).
public struct LinkWatch: Sendable, Equatable {
    /// Polls in a row that failed on the connection (not on the box's answer).
    public private(set) var failures = 0
    public private(set) var lastReset: Date?

    /// Failed polls before the connection is dropped.
    public static let resetAfter = 2
    /// A dropped connection gets this long to come back before it is dropped again.
    public static let minResetGap: TimeInterval = 15

    public init() {}

    /// Something is wrong with the way to the box right now (for the screen to say so).
    public var troubled: Bool { failures > 0 }

    public mutating func succeeded() { failures = 0 }

    /// Records a poll that failed on the connection. True when the connection should be dropped now.
    public mutating func failed(at now: Date = Date()) -> Bool {
        failures += 1
        guard failures >= Self.resetAfter else { return false }
        if let last = lastReset, now.timeIntervalSince(last) < Self.minResetGap { return false }
        lastReset = now
        return true
    }

    /// A failure of the way to the box (worth a new connection), as opposed to an answer of the box (404, 409, ...)
    /// or a request the caller cancelled.
    public static func isLinkFailure(_ error: Error) -> Bool {
        guard let e = error as? PierError else { return false }
        switch e {
        case .transport, .timeout, .tls: return true
        default: return false
        }
    }
}
