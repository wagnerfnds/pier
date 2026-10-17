import Foundation

/// Every failure PierKit surfaces. Branch on the case; `errorDescription` is user presentable.
public enum PierError: Error, Sendable, LocalizedError {
    /// The box presented a key that is not the pinned one. Never auto-repin.
    case pinMismatch(expected: String, actual: String)
    /// 401: the box no longer trusts this client (revoked). Stop retrying; offer re-pairing.
    case unauthorized
    /// 429.
    case rateLimited(message: String)
    /// Box-level error `{"error","code"}`. `kept`: with `not_submitted`, the prompt is still in the agent's input box
    /// on the box (docs/API.md 4.3).
    case api(status: Int, message: String, code: String?, kept: Bool = false)
    /// 403 on `/v1/pair` (unknown/expired/used code or bad proof).
    case pairingRejected(String)
    case invalidLink(String)
    case linkExpired
    case tls(String)
    case transport(String)
    case timeout
    case protocolViolation(String)
    case decoding(String)
    case storage(String)

    public var errorDescription: String? {
        switch self {
        case .pinMismatch(let e, let a):
            return "The box presented an unexpected key (expected \(e.prefix(12)), got \(a.prefix(12))). Refusing to connect."
        case .unauthorized: return "This box no longer trusts this device. Pair again."
        case .rateLimited(let m): return m
        case .api(_, let m, _, _): return m
        case .pairingRejected(let m): return m
        case .invalidLink(let m): return "Malformed pairing link: \(m)"
        case .linkExpired: return "This pairing link has expired."
        case .tls(let m): return "TLS error: \(m)"
        case .transport(let m): return "Connection error: \(m)"
        case .timeout: return "The request timed out."
        case .protocolViolation(let m): return "Protocol error: \(m)"
        case .decoding(let m): return "Could not decode the response: \(m)"
        case .storage(let m): return "Storage error: \(m)"
        }
    }

    /// Machine code from the box (`not_found`, `session_exited`, ...) for `.api` errors.
    public var apiCode: String? {
        if case .api(_, _, let c, _) = self { return c }
        return nil
    }

    /// True if retrying with a fresh connection can plausibly help.
    public var isTransient: Bool {
        switch self {
        case .transport, .timeout: return true
        default: return false
        }
    }
}
