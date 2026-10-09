import Foundation

/// A compiled regular expression shared across threads (NSRegularExpression is immutable after init).
struct Rx: @unchecked Sendable {
    let re: NSRegularExpression
    init(_ pattern: String, ignoreCase: Bool = false, dotAll: Bool = false, multiline: Bool = false) {
        var o: NSRegularExpression.Options = []
        if ignoreCase { o.insert(.caseInsensitive) }
        if dotAll { o.insert(.dotMatchesLineSeparators) }
        if multiline { o.insert(.anchorsMatchLines) }
        // The patterns are literals in this module; a typo is a programmer error caught by tests.
        re = try! NSRegularExpression(pattern: pattern, options: o)
    }

    func test(_ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Capture groups of the first match (index 0 is the whole match); nil if no match. Unmatched groups are nil.
    func match(_ s: String) -> [String?]? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: s).map { String(s[$0]) }
        }
    }

    func replacing(_ s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}

@inline(__always) private func asciiWhitespace(_ b: UInt8) -> Bool {
    b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0B || b == 0x0C
}

extension String {
    /// JavaScript `trimEnd()` / `.replace(/\s+$/, "")`. ASCII whitespace is cut on bytes first (screen lines end in ~70
    /// spaces, and `Substring.last` does grapheme breaking per step: this was most of the screen parsing time).
    var trimmedEnd: String {
        let u = utf8
        var end = u.endIndex
        while end > u.startIndex, asciiWhitespace(u[u.index(before: end)]) { end = u.index(before: end) }
        var s = self[..<end]
        while let last = s.last, last.isWhitespace || last == "\u{FEFF}" { s = s.dropLast() }
        return String(s)
    }

    /// JavaScript `trimStart()`.
    var trimmedStart: String {
        let u = utf8
        var start = u.startIndex
        while start < u.endIndex, asciiWhitespace(u[start]) { start = u.index(after: start) }
        return String(self[start...].drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" }))
    }

    /// JavaScript `trim()`.
    var jsTrimmed: String { trimmedStart.trimmedEnd }

    var isBlank: Bool { utf8.allSatisfy(asciiWhitespace) || jsTrimmed.isEmpty }
}
