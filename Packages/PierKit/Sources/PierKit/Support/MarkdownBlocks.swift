import Foundation

/// A block of an agent's reply as the chat draws it. The structure follows CommonMark (with GFM's tables and task
/// lists) for what agents write; inline Markdown (emphasis, `code`, links) stays in the text for
/// `AttributedString(markdown:)`. A paragraph keeps its line breaks: a single newline in a reply is drawn as one (the
/// chat's convention), not folded into a space.
public indirect enum MarkdownBlock: Sendable, Equatable {
    public struct ListItem: Sendable, Equatable {
        /// What is drawn before the item: "•" for a bullet, the number for an ordered item ("3.", "2)").
        public var marker: String
        public var ordered: Bool
        /// A task list's box: nil for an ordinary item.
        public var checked: Bool?
        /// The item's content: usually a paragraph, then whatever is indented under it (code, more paragraphs, a list).
        public var blocks: [MarkdownBlock]

        public init(marker: String, ordered: Bool, checked: Bool? = nil, blocks: [MarkdownBlock]) {
            self.marker = marker
            self.ordered = ordered
            self.checked = checked
            self.blocks = blocks
        }
    }

    public enum Alignment: Sendable, Equatable { case leading, center, trailing }

    case heading(level: Int, text: String)
    case paragraph(String)
    case list([ListItem])
    case quote([MarkdownBlock])
    case code(language: String, text: String)
    /// Every row has as many cells as the header.
    case table(header: [String], alignments: [Alignment], rows: [[String]])
    case rule
}

public enum MarkdownBlocks {
    /// Lists and quotes deeper than this read as text (no reply nests this far; a hostile one must not exhaust the stack).
    static let maxDepth = 12

    public static func parse(_ text: String) -> [MarkdownBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return blocks(normalized.components(separatedBy: "\n").map(Line.init), depth: 0)
    }

    /// The text of a reply without its Markdown block syntax, for length checks and comparisons.
    public static func plainText(_ blocks: [MarkdownBlock]) -> String {
        var out: [String] = []
        for b in blocks {
            switch b {
            case .heading(_, let t), .paragraph(let t): out.append(t)
            case .code(_, let t): out.append(t)
            case .list(let items): out.append(contentsOf: items.map { plainText($0.blocks) })
            case .quote(let inner): out.append(plainText(inner))
            case .table(let header, _, let rows): out.append(([header] + rows).map { $0.joined(separator: " ") }.joined(separator: "\n"))
            case .rule: break
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: lines

    /// One source line: its text with tabs as spaces to the next multiple of 4 (CommonMark's tab stops) and its indent.
    struct Line: Equatable {
        let raw: String
        let indent: Int
        let isBlank: Bool

        init(_ s: String) {
            var expanded = s
            if s.utf8.contains(9) {
                expanded = ""
                var col = 0
                for ch in s {
                    if ch == "\t" {
                        let n = 4 - col % 4
                        expanded += String(repeating: " ", count: n)
                        col += n
                    } else {
                        expanded.append(ch)
                        col += 1
                    }
                }
            }
            raw = expanded
            indent = expanded.utf8.prefix(while: { $0 == 32 }).count
            isBlank = expanded.utf8.allSatisfy { $0 == 32 }
        }

        /// The text after the indent.
        var text: Substring { raw.dropFirst(indent) }

        /// The line with `n` columns removed from its start (fewer when it has less indent).
        func dropping(_ n: Int) -> Line { Line(String(raw.dropFirst(min(n, indent)))) }
    }

    // MARK: blocks

    private static func blocks(_ lines: [Line], depth: Int) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var para: [String] = []
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] }
        }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.isBlank { flush(); i += 1; continue }
            let t = line.text
            if line.indent < 4 || !para.isEmpty {
                // An HTML comment (a pull request template's notes): a page never shows it, nor does the chat.
                if line.indent < 4, t.hasPrefix("<!--") {
                    flush()
                    while i < lines.count, !lines[i].raw.contains("-->") { i += 1 }
                    i += 1
                    continue
                }
                if line.indent < 4, let f = fence(t) {
                    flush()
                    var code: [Line] = []
                    i += 1
                    while i < lines.count, !closes(lines[i], f) { code.append(lines[i].dropping(line.indent)); i += 1 }
                    out.append(.code(language: f.language, text: code.map(\.raw).joined(separator: "\n")))
                    i += 1
                    continue
                }
                if line.indent < 4, let h = atxHeading(t) { flush(); out.append(.heading(level: h.0, text: h.1)); i += 1; continue }
                // "Title" over "===" or "---" is a heading; "---" anywhere else is a rule.
                if line.indent < 4, !para.isEmpty, let level = setextLevel(t) {
                    out.append(.heading(level: level, text: para.joined(separator: "\n")))
                    para = []
                    i += 1
                    continue
                }
                if line.indent < 4, isRule(t) { flush(); out.append(.rule); i += 1; continue }
                if line.indent < 4, t.hasPrefix(">") {
                    flush()
                    var inner: [Line] = []
                    var lastWasText = false
                    while i < lines.count {
                        let l = lines[i]
                        if l.indent < 4, l.text.hasPrefix(">") {
                            var rest = l.text.dropFirst()
                            if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                            let q = Line(String(rest))
                            inner.append(q)
                            // Only a paragraph continues lazily, however deep the quote nests.
                            let core = Line(String(q.text.drop(while: { $0 == ">" || $0 == " " })))
                            lastWasText = !core.isBlank && !startsBlock(core)
                        } else if lastWasText, !l.isBlank, !startsBlock(l) {
                            inner.append(l)   // a lazy continuation of the quote's paragraph
                        } else {
                            break
                        }
                        i += 1
                    }
                    out.append(depth < maxDepth ? .quote(blocks(inner, depth: depth + 1)) : .paragraph(inner.map { String($0.text) }.joined(separator: "\n")))
                    continue
                }
                if line.indent < 4, i + 1 < lines.count, let table = table(lines, at: i) {
                    flush()
                    out.append(table.block)
                    i = table.end
                    continue
                }
                if line.indent < 4, let m = listMarker(line), para.isEmpty || m.interruptsParagraph {
                    flush()
                    let list = self.list(lines, at: i, depth: depth)
                    out.append(list.block)
                    i = list.end
                    continue
                }
                para.append(String(t).trimmingCharacters(in: .whitespaces))
                i += 1
                continue
            }
            // Indented four or more with no paragraph open: indented code, to the last line indented as much.
            var code: [Line] = []
            while i < lines.count, lines[i].isBlank || lines[i].indent >= 4 { code.append(lines[i].dropping(4)); i += 1 }
            while code.last?.isBlank == true { code.removeLast() }
            out.append(.code(language: "", text: code.map(\.raw).joined(separator: "\n")))
        }
        flush()
        return out
    }

    /// Whether a line would start a block of its own (so it cannot continue a paragraph lazily).
    private static func startsBlock(_ l: Line) -> Bool {
        guard l.indent < 4 else { return false }
        let t = l.text
        return fence(t) != nil || atxHeading(t) != nil || isRule(t) || t.hasPrefix(">") || listMarker(l) != nil
    }

    // MARK: fences

    struct Fence { let char: Character; let length: Int; let language: String }

    static func fence(_ t: Substring) -> Fence? {
        guard let c = t.first, c == "`" || c == "~" else { return nil }
        let run = t.prefix(while: { $0 == c }).count
        guard run >= 3 else { return nil }
        let info = t.dropFirst(run).trimmingCharacters(in: .whitespaces)
        if c == "`", info.contains("`") { return nil }
        let language = info.split(separator: " ").first.map(String.init) ?? ""
        return Fence(char: c, length: run, language: language)
    }

    private static func closes(_ l: Line, _ f: Fence) -> Bool {
        guard l.indent < 4 else { return false }
        let t = l.text
        let run = t.prefix(while: { $0 == f.char }).count
        return run >= f.length && t.dropFirst(run).allSatisfy { $0 == " " }
    }

    // MARK: headings and rules

    static func atxHeading(_ t: Substring) -> (Int, String)? {
        let level = t.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let rest = t.dropFirst(level)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // "## Title ##": the closing run goes when a space stands before it.
        let closing = text.reversed().prefix(while: { $0 == "#" }).count
        if closing > 0 {
            let head = text.dropLast(closing)
            if head.isEmpty { text = "" } else if head.last == " " { text = head.trimmingCharacters(in: .whitespaces) }
        }
        return (level, text)
    }

    private static func setextLevel(_ t: Substring) -> Int? {
        let s = t.trimmingCharacters(in: .whitespaces)
        guard let c = s.first, c == "=" || c == "-", s.allSatisfy({ $0 == c }) else { return nil }
        return c == "=" ? 1 : 2
    }

    static func isRule(_ t: Substring) -> Bool {
        guard let c = t.first, c == "-" || c == "*" || c == "_" else { return false }
        var n = 0
        for ch in t {
            if ch == c { n += 1 } else if ch != " " { return false }
        }
        return n >= 3
    }

    // MARK: lists

    struct Marker {
        let ordered: Bool
        /// "-", "*", "+" or the number with its delimiter ("12." / "3)").
        let text: String
        let number: Int?
        /// Where the item's content starts, in columns from the line's start.
        let contentColumn: Int
        let rest: Substring
        /// CommonMark: an empty item, or an ordered one not starting at 1, cannot interrupt a paragraph.
        let interruptsParagraph: Bool
    }

    static func listMarker(_ l: Line) -> Marker? {
        let t = l.text
        var ordered = false
        var mark: Substring
        var number: Int?
        if let c = t.first, c == "-" || c == "*" || c == "+" || c == "•" {
            mark = t.prefix(1)
        } else {
            let digits = t.prefix(while: \.isASCIINumber)
            guard (1...9).contains(digits.count) else { return nil }
            let after = t.dropFirst(digits.count)
            guard let d = after.first, d == "." || d == ")" else { return nil }
            mark = t.prefix(digits.count + 1)
            ordered = true
            number = Int(digits)
        }
        let after = t.dropFirst(mark.count)
        if after.isEmpty {
            return Marker(ordered: ordered, text: String(mark), number: number, contentColumn: l.indent + mark.count + 1,
                          rest: "", interruptsParagraph: false)
        }
        guard after.first == " " else { return nil }
        // A marker alone on a rule line ("- - -", "* * *") is the rule.
        if isRule(t) { return nil }
        let spaces = after.prefix(while: { $0 == " " }).count
        // Five or more spaces: the content is indented code starting one column after the marker.
        let width = spaces > 4 ? 1 : spaces
        let rest = after.dropFirst(width)
        let interrupts = !rest.allSatisfy({ $0 == " " }) && (!ordered || number == 1)
        return Marker(ordered: ordered, text: String(mark), number: number, contentColumn: l.indent + mark.count + width,
                      rest: rest, interruptsParagraph: interrupts)
    }

    /// A list from `start`: its items while they keep coming at this level. Returns the line after the list.
    private static func list(_ lines: [Line], at start: Int, depth: Int) -> (block: MarkdownBlock, end: Int) {
        guard let first = listMarker(lines[start]) else { return (.paragraph(String(lines[start].text)), start + 1) }
        var items: [MarkdownBlock.ListItem] = []
        var number = first.number ?? 1
        var i = start
        while i < lines.count, let m = listMarker(lines[i]), m.ordered == first.ordered, lines[i].indent < 4 {
            // The item's lines: its first line's content, then everything indented under it (and lazy continuations).
            var body: [Line] = [Line(String(m.rest))]
            var j = i + 1
            var lastWasText = !m.rest.allSatisfy { $0 == " " }
            var pendingBlanks: [Line] = []
            while j < lines.count {
                let l = lines[j]
                if l.isBlank {
                    pendingBlanks.append(Line(""))
                    j += 1
                    continue
                }
                if l.indent >= m.contentColumn {
                    body.append(contentsOf: pendingBlanks)
                    pendingBlanks = []
                    body.append(l.dropping(m.contentColumn))
                    lastWasText = true
                    j += 1
                    continue
                }
                // Less indented: a lazy continuation of the item's paragraph, or the end of the item.
                if pendingBlanks.isEmpty, lastWasText, !startsBlock(l), !(l.indent < 4 && table(lines, at: j) != nil) {
                    body.append(Line(String(l.text)))
                    j += 1
                    continue
                }
                break
            }
            var content = depth < maxDepth ? blocks(body, depth: depth + 1) : [.paragraph(body.map { String($0.text) }.joined(separator: "\n"))]
            var checked: Bool?
            if case .paragraph(let p)? = content.first {
                let lower = p.lowercased()
                if lower.hasPrefix("[ ] ") || lower == "[ ]" { checked = false } else if lower.hasPrefix("[x] ") || lower == "[x]" { checked = true }
                if checked != nil {
                    let rest = String(p.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    content[0] = .paragraph(rest)
                }
            }
            let marker = first.ordered ? "\(number)\(m.text.last ?? ".")" : "•"
            items.append(.init(marker: marker, ordered: first.ordered, checked: checked, blocks: content))
            number += 1
            i = j
            // Blank lines before the next item keep the list going; anything else ends it.
            if !pendingBlanks.isEmpty {
                guard i < lines.count, lines[i].indent < 4, let next = listMarker(lines[i]), next.ordered == first.ordered else {
                    return (.list(items), i)
                }
            }
        }
        return (.list(items), i)
    }

    // MARK: tables

    /// A GFM table at `start`: a header row, then a delimiter row with as many cells. Returns the line after it.
    static func table(_ lines: [Line], at start: Int) -> (block: MarkdownBlock, end: Int)? {
        guard start + 1 < lines.count else { return nil }
        let headerLine = lines[start], delimiter = lines[start + 1]
        guard headerLine.text.contains("|") || delimiter.text.contains("|"), delimiter.indent < 4,
              let alignments = delimiterRow(delimiter.text) else { return nil }
        let header = cells(headerLine.text)
        guard header.count == alignments.count else { return nil }
        var rows: [[String]] = []
        var i = start + 2
        while i < lines.count {
            let l = lines[i]
            guard !l.isBlank, l.indent < 4, !startsBlock(l) || l.text.hasPrefix("|") else { break }
            var row = cells(l.text)
            if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
            rows.append(Array(row.prefix(header.count)))
            i += 1
        }
        return (.table(header: header, alignments: alignments, rows: rows), i)
    }

    private static func delimiterRow(_ t: Substring) -> [MarkdownBlock.Alignment]? {
        let parts = cells(t)
        guard !parts.isEmpty else { return nil }
        var out: [MarkdownBlock.Alignment] = []
        for p in parts {
            let left = p.hasPrefix(":"), right = p.hasSuffix(":")
            let dashes = p.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            out.append(left && right ? .center : right ? .trailing : .leading)
        }
        return out
    }

    /// A row's cells: split at pipes not escaped with a backslash; outer pipes are optional; `\|` is a pipe in a cell.
    static func cells(_ row: Substring) -> [String] {
        var s = row.trimmingCharacters(in: .whitespaces)[...]
        if s.hasPrefix("|") { s = s.dropFirst() }
        if s.hasSuffix("|"), !s.hasSuffix("\\|") { s = s.dropLast() }
        var out: [String] = []
        var cell = ""
        var escaped = false
        for ch in s {
            if escaped {
                if ch != "|" { cell.append("\\") }
                cell.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                out.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(ch)
            }
        }
        if escaped { cell.append("\\") }
        out.append(cell.trimmingCharacters(in: .whitespaces))
        return out
    }
}

private extension Character {
    var isASCIINumber: Bool { ("0"..."9").contains(self) }
}
