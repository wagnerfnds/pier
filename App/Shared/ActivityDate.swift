import Foundation

/// How a Live Activity `ContentState` carries its dates on the wire (push payloads and ActivityKit's own storage).
///
/// ActivityKit decodes a push's `content-state` with a plain `JSONDecoder()` (default strategies; there is no hook to
/// change it), so a synthesized `Date` would be *seconds since 2001-01-01* (the reference date), which no server wants
/// to emit. `SessionActivityAttributes.ContentState` therefore encodes/decodes `since` by hand:
///
/// - encode: a JSON number, **seconds since 1970** (Unix epoch, fractional allowed).
/// - decode: that, but also tolerates a number below 1e9 as seconds-since-2001 (what a default `JSONEncoder` produced
///   for activities persisted by earlier builds) and an ISO 8601 string.
enum ActivityDate {
    /// Unix seconds below this are really reference-date seconds (1e9 s since 1970 is September 2001).
    static let referenceCutoff: Double = 1_000_000_000

    struct Wire: Decodable {
        let date: Date
        init(from decoder: Decoder) throws { date = try ActivityDate.decode(try decoder.singleValueContainer()) }
    }

    static func decode(_ c: any SingleValueDecodingContainer) throws -> Date {
        if let n = try? c.decode(Double.self) { return date(fromNumber: n) }
        let s = try c.decode(String.self)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date \(s)")
    }

    static func date(fromNumber n: Double) -> Date {
        n < referenceCutoff ? Date(timeIntervalSinceReferenceDate: n) : Date(timeIntervalSince1970: n)
    }
}
