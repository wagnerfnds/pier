import Foundation

/// The small rules of the code editor: where the caret is (line and column for the status bar), what a Return or a Tab
/// types (keeping the line's indentation in the file's own style), and how a file's lines end. Pure over strings, so
/// the editor view stays a thin UITextView.
public enum EditorText {
    /// 1-based line and column of a UTF-16 offset (the text view's selection), the column counted in characters.
    public static func lineColumn(in text: String, utf16Offset: Int) -> (line: Int, column: Int) {
        let ns = text as NSString
        let offset = max(0, min(utf16Offset, ns.length))
        var line = 1
        var lineStart = 0
        var i = 0
        while i < offset {
            if ns.character(at: i) == 0x0A {
                line += 1
                lineStart = i + 1
            }
            i += 1
        }
        let column = ns.substring(with: NSRange(location: lineStart, length: offset - lineStart)).count + 1
        return (line, column)
    }

    /// How many lines an editor numbers: one more than the text's line breaks.
    public static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 1 }
        return text.utf8.reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) }
    }

    /// The file's indentation unit: a tab when most indented lines start with one, else the most common step between
    /// space indents (2, 4 or 8), 4 when nothing tells.
    public static func indentUnit(of text: String) -> String {
        var tabs = 0, spaced = 0
        var steps: [Int: Int] = [:]
        var previous = 0
        // By isNewline: "\r\n" is one Character, which a split on "\n" would never find.
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).prefix(2000) {
            guard let first = line.first, first == " " || first == "\t" else {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { previous = 0 }
                continue
            }
            if first == "\t" { tabs += 1; continue }
            let n = line.prefix { $0 == " " }.count
            guard n < line.count else { continue }   // a blank line of spaces
            spaced += 1
            let step = abs(n - previous)
            if step > 0 { steps[step, default: 0] += 1 }
            previous = n
        }
        if tabs > spaced { return "\t" }
        let best = [2, 4, 8].max { (steps[$0] ?? 0, -$0) < (steps[$1] ?? 0, -$1) } ?? 4
        return spaced == 0 || (steps[best] ?? 0) == 0 ? String(repeating: " ", count: 4) : String(repeating: " ", count: best)
    }

    /// What Return types after `lineBefore` (the current line up to the caret): a line break, the line's indentation and
    /// one more `unit` after an opening bracket (or a colon in Python and YAML).
    public static func newline(after lineBefore: String, unit: String, language: SyntaxLanguage? = nil) -> String {
        let indent = String(lineBefore.prefix { $0 == " " || $0 == "\t" })
        let trimmed = lineBefore.trimmingCharacters(in: .whitespaces)
        var opens = trimmed.hasSuffix("{") || trimmed.hasSuffix("(") || trimmed.hasSuffix("[")
        if language == .python || language == .yaml, trimmed.hasSuffix(":") { opens = true }
        return "\n" + indent + (opens ? unit : "")
    }

    /// The line break the file uses ("\r\n" when most of its line ends have one).
    public static func lineEnding(of text: String) -> String {
        var crlf = 0, lf = 0
        var prev: UInt8 = 0
        for b in text.utf8.prefix(200_000) {
            if b == 0x0A { if prev == 0x0D { crlf += 1 } else { lf += 1 } }
            prev = b
        }
        return crlf > lf ? "\r\n" : "\n"
    }
}
