import SwiftUI

/// Block-level Markdown for the agent's replies: headings, paragraphs, lists (nested, numbered, tasks), quotes, tables,
/// rules and fenced code (with a language label, Copy, and sideways scrolling). Inline styling via AttributedString.
struct MarkdownView: View {
    let text: String
    /// A reply still being written (draft): quieter, with a caret at the end.
    var draft = false

    var body: some View {
        let blocks = MarkdownBlock.cachedParse(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
                render(b, last: i == blocks.count - 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(draft ? 0.86 : 1)
    }

    @ViewBuilder private func render(_ b: MarkdownBlock, last: Bool) -> some View {
        switch b {
        case .heading(let level, let t):
            Text(MarkdownBlock.inline(t))
                .font(level <= 1 ? .title3.weight(.bold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .foregroundStyle(Theme.text)
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .paragraph(let t):
            paragraph(t, caret: draft && last)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        marker(it)
                        Text(MarkdownBlock.inline(it.text)).font(.body).lineSpacing(2).foregroundStyle(it.checked == true ? Theme.textDim : Theme.text)
                            .strikethrough(it.checked == true, color: Theme.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(.leading, CGFloat(it.indent) * 16)
                }
            }
        case .quote(let t):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.textFaint).frame(width: 3)
                Text(MarkdownBlock.inline(t)).font(.body).lineSpacing(2).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        case .code(let lang, let code):
            CodeBlock(text: code, language: lang, copyable: !draft)
        case .table(let rows):
            MarkdownTable(rows: rows)
        case .rule:
            Divider().overlay(Theme.stroke).padding(.vertical, 2)
        }
    }

    @ViewBuilder private func marker(_ it: MarkdownBlock.Item) -> some View {
        if let c = it.checked {
            Image(systemName: c ? "checkmark.square.fill" : "square").font(.subheadline)
                .foregroundStyle(c ? Theme.green : Theme.textFaint).frame(minWidth: 16)
        } else {
            Text(it.marker).font(.body.monospacedDigit()).foregroundStyle(Theme.textDim).frame(minWidth: 14, alignment: .trailing)
        }
    }

    private func paragraph(_ t: String, caret: Bool) -> some View {
        var a = MarkdownBlock.inline(t)
        if caret {
            var c = AttributedString(" ▍")
            c.foregroundColor = Theme.textDim
            a.append(c)
        }
        return Text(a).font(.body).lineSpacing(2.5).foregroundStyle(Theme.text)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// A simple table: header row in a tint, cells in a monospaced-digit body font, scrolls sideways when wide.
struct MarkdownTable: View {
    let rows: [[String]]

    var body: some View {
        let cols = rows.map(\.count).max() ?? 0
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    GridRow {
                        ForEach(0..<cols, id: \.self) { c in
                            Text(MarkdownBlock.inline(c < row.count ? row[c] : ""))
                                .font(r == 0 ? .footnote.weight(.semibold) : .footnote.monospacedDigit())
                                .foregroundStyle(r == 0 ? Theme.textDim : Theme.text)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .gridColumnAlignment(.leading)
                        }
                    }
                    .background(r == 0 ? Theme.cardRaised : (r % 2 == 0 ? Theme.card.opacity(0.5) : .clear))
                    if r == 0 { Divider().overlay(Theme.stroke) }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
    }
}

enum MarkdownBlock {
    struct Item { var marker: String; var text: String; var indent: Int; var checked: Bool? = nil }
    case heading(Int, String)
    case paragraph(String)
    case bullet([Item])
    case quote(String)
    case code(String, String)
    case table([[String]])
    case rule

    /// Parsed blocks per text: a reply is parsed once, not on every redraw of the conversation.
    private final class Parsed { let blocks: [MarkdownBlock]; init(_ b: [MarkdownBlock]) { blocks = b } }
    private final class Styled { let value: AttributedString; init(_ v: AttributedString) { value = v } }
    nonisolated(unsafe) private static let parsedCache: NSCache<NSString, Parsed> = { let c = NSCache<NSString, Parsed>(); c.countLimit = 300; return c }()
    nonisolated(unsafe) private static let inlineCache: NSCache<NSString, Styled> = { let c = NSCache<NSString, Styled>(); c.countLimit = 1500; return c }()

    static func cachedParse(_ text: String) -> [MarkdownBlock] {
        let k = text as NSString
        if let p = parsedCache.object(forKey: k) { return p.blocks }
        let b = parse(text)
        parsedCache.setObject(Parsed(b), forKey: k)
        return b
    }

    static func inline(_ s: String) -> AttributedString {
        let k = s as NSString
        if let a = inlineCache.object(forKey: k) { return a.value }
        let a = styledInline(s)
        inlineCache.setObject(Styled(a), forKey: k)
        return a
    }

    private static func styledInline(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var a = (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
        for run in a.runs where run.inlinePresentationIntent?.contains(.code) == true {
            a[run.range].font = .system(.callout, design: .monospaced)
            a[run.range].backgroundColor = Theme.inlineCodeBg
            a[run.range].foregroundColor = Theme.inlineCode
        }
        for run in a.runs where run.link != nil {
            a[run.range].foregroundColor = Theme.accent
            a[run.range].underlineStyle = .single
        }
        return a
    }

    static func parse(_ text: String) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        var para: [String] = []
        var list: [Item] = []
        func flushPara() { if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] } }
        func flushList() { if !list.isEmpty { out.append(.bullet(list)); list = [] } }
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                flushPara(); flushList()
                let fence = String(t.prefix(3))
                let lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { code.append(lines[i]); i += 1 }
                out.append(.code(lang, dedent(code).joined(separator: "\n")))
                i += 1; continue
            }
            if t.isEmpty { flushPara(); flushList(); i += 1; continue }
            if t.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }), t.count >= 3, Set(t).count == 1 {
                flushPara(); flushList(); out.append(.rule); i += 1; continue
            }
            if let h = t.firstIndex(where: { $0 != "#" }), t.hasPrefix("#"), t[h] == " ", t.distance(from: t.startIndex, to: h) <= 6 {
                flushPara(); flushList()
                out.append(.heading(t.distance(from: t.startIndex, to: h), String(t[t.index(after: h)...])))
                i += 1; continue
            }
            if t.hasPrefix(">") {
                flushPara(); flushList()
                var q = [String(t.dropFirst()).trimmingCharacters(in: .whitespaces)]
                while i + 1 < lines.count, lines[i + 1].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    i += 1; q.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                }
                out.append(.quote(q.joined(separator: "\n")))
                i += 1; continue
            }
            if t.hasPrefix("|"), t.hasSuffix("|"), i + 1 < lines.count, isTableRule(lines[i + 1]) {
                flushPara(); flushList()
                var rows = [cells(t)]
                i += 2
                while i < lines.count {
                    let r = lines[i].trimmingCharacters(in: .whitespaces)
                    guard r.hasPrefix("|") else { break }
                    rows.append(cells(r)); i += 1
                }
                out.append(.table(rows))
                continue
            }
            let lead = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
            if let m = bulletMarker(t) {
                flushPara()
                var item = Item(marker: m.0, text: m.1, indent: lead / 2)
                if item.text.hasPrefix("[ ] ") { item.checked = false; item.text = String(item.text.dropFirst(4)) }
                else if item.text.lowercased().hasPrefix("[x] ") { item.checked = true; item.text = String(item.text.dropFirst(4)) }
                list.append(item)
                i += 1; continue
            }
            if !list.isEmpty, lead > 0 {  // continuation of a list item
                list[list.count - 1].text += "\n" + t
                i += 1; continue
            }
            flushList()
            para.append(t)
            i += 1
        }
        flushPara(); flushList()
        return out
    }

    private static func dedent(_ lines: [String]) -> [String] {
        let indents = lines.filter { !$0.allSatisfy(\.isWhitespace) }.map { $0.prefix(while: { $0 == " " }).count }
        guard let m = indents.min(), m > 0 else { return lines }
        return lines.map { String($0.dropFirst(min(m, $0.prefix(while: { $0 == " " }).count))) }
    }

    private static func isTableRule(_ l: String) -> Bool {
        let t = l.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") && t.contains("-") && t.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ row: String) -> [String] {
        var r = row
        if r.hasPrefix("|") { r.removeFirst() }
        if r.hasSuffix("|") { r.removeLast() }
        return r.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func bulletMarker(_ t: String) -> (String, String)? {
        for p in ["- ", "* ", "+ ", "• "] where t.hasPrefix(p) { return ("•", String(t.dropFirst(2))) }
        let digits = t.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3 {
            let rest = t.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return ("\(digits).", String(rest.dropFirst(2))) }
        }
        return nil
    }

    /// Plain words (for copying a reply as text or searching).
    static func plain(_ s: String) -> String { String(inline(s).characters) }
}
