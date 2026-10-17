import SwiftUI
import PierKit

/// Block-level Markdown for the agent's replies (`MarkdownBlocks` in PierKit reads the structure): headings, paragraphs,
/// lists (nested, numbered, tasks, with code or more paragraphs under an item), quotes, tables, rules and fenced code
/// (with a language label, Copy, and sideways scrolling). Inline styling via AttributedString.
struct MarkdownView: View {
    let text: String
    /// A reply still being written (draft): quieter, with a caret at the end.
    var draft = false
    /// Text selection on the iPhone and the iPad too (the Mac always has it). The conversation turns it off: a long press
    /// there opens the message's own menu (Copiar), and selection only cost time each time a reply first showed.
    var touchSelection = true

    var body: some View {
        MarkdownBlocksView(blocks: MarkdownStyle.blocks(text), depth: 0, caret: draft, draft: draft)
            .environment(\.markdownSelectable, touchSelection || Platform.isMac)
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(draft ? 0.86 : 1)
    }
}

/// Blocks drawn one under the other; lists and quotes draw their own blocks with this view again, one level deeper.
private struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    let depth: Int
    /// Draw the caret after the last block's words.
    let caret: Bool
    let draft: Bool
    @Environment(\.markdownSelectable) private var selectable

    var body: some View {
        VStack(alignment: .leading, spacing: depth == 0 ? 10 : 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
                render(b, caret: caret && i == blocks.count - 1)
            }
        }
    }

    @ViewBuilder private func render(_ b: MarkdownBlock, caret: Bool) -> some View {
        switch b {
        case .heading(let level, let t):
            Text(MarkdownStyle.inline(t))
                .font(level <= 1 ? .title3.weight(.bold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .foregroundStyle(Theme.text)
                .padding(.top, depth == 0 ? 4 : 0)
                .fixedSize(horizontal: false, vertical: true)
                .selectable(selectable)
        case .paragraph(let t):
            paragraph(t, caret: caret)
        case .list(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        marker(it)
                        Group {
                            // Most items are a line of words: drawn as one, without a nested stack of blocks.
                            if it.blocks.count == 1, case .paragraph(let t) = it.blocks[0] {
                                paragraph(t, caret: caret && i == items.count - 1)
                            } else {
                                AnyView(MarkdownBlocksView(blocks: it.blocks, depth: depth + 1, caret: caret && i == items.count - 1, draft: draft))
                            }
                        }
                        .foregroundStyle(it.checked == true ? Theme.textDim : Theme.text)
                    }
                }
            }
        case .quote(let inner):
            AnyView(MarkdownBlocksView(blocks: inner, depth: depth + 1, caret: caret, draft: draft))
                .foregroundStyle(Theme.textDim)
                .padding(.leading, 13)
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(Theme.textFaint).frame(width: 3) }
        case .code(let lang, let code):
            CodeBlock(text: code, language: lang, copyable: !draft)
        case .table(let header, let alignments, let rows):
            MarkdownTable(header: header, alignments: alignments, rows: rows)
        case .rule:
            Divider().overlay(Theme.stroke).padding(.vertical, 2)
        }
    }

    @ViewBuilder private func marker(_ it: MarkdownBlock.ListItem) -> some View {
        if let c = it.checked {
            Image(systemName: c ? "checkmark.square.fill" : "square").font(.subheadline)
                .foregroundStyle(c ? Theme.green : Theme.textFaint).frame(minWidth: 16)
        } else if it.ordered {
            Text(it.marker).font(.body.monospacedDigit()).foregroundStyle(Theme.textDim).frame(minWidth: 14, alignment: .trailing)
        } else {
            // •, then ◦ and ▪ for the nested levels, as documents draw them.
            Text(["•", "◦", "▪"][depth % 3]).font(.body).foregroundStyle(Theme.textDim).frame(minWidth: 14, alignment: .trailing)
        }
    }

    private func paragraph(_ t: String, caret: Bool) -> some View {
        var a = MarkdownStyle.inline(t)
        if caret {
            var c = AttributedString(" ▍")
            c.foregroundColor = Theme.textDim
            a.append(c)
        }
        return Text(a).font(.body).lineSpacing(2.5)
            .fixedSize(horizontal: false, vertical: true)
            .selectable(selectable)
    }
}

/// A GFM table: the header in a tint, cells in the body font with monospaced digits, each column as wide as its
/// longest cell up to a cap (longer text wraps inside it), the whole table scrolling sideways when wider than the reply.
struct MarkdownTable: View {
    let header: [String]
    let alignments: [MarkdownBlock.Alignment]
    let rows: [[String]]
    @Environment(\.markdownSelectable) private var selectable

    /// The widest a column grows before its text wraps.
    private static var columnCap: CGFloat { Platform.isMac ? 340 : 260 }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            TableGridLayout(columns: header.count, cap: Self.columnCap) {
                ForEach(Array(([header] + rows).enumerated()), id: \.offset) { r, row in
                    ForEach(Array(row.enumerated()), id: \.offset) { c, cell in
                        tableCell(cell, row: r, column: c)
                    }
                }
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
    }

    /// Keep the cell's style decisions outside the nested builders so Swift can type-check the table independently.
    private func tableCell(_ text: String, row: Int, column: Int) -> some View {
        let align: MarkdownBlock.Alignment = column < alignments.count ? alignments[column] : .leading
        let font: Font = row == 0 ? .footnote.weight(.semibold) : .footnote.monospacedDigit()
        let foreground: Color = row == 0 ? Theme.textDim : Theme.text
        let textAlignment: TextAlignment = align == .trailing ? .trailing : align == .center ? .center : .leading
        let frameAlignment: SwiftUI.Alignment = align == .trailing ? .topTrailing : align == .center ? .top : .topLeading
        let background: Color = row == 0 ? Theme.cardRaised : (row % 2 == 0 ? Theme.card.opacity(0.5) : .clear)

        return Text(MarkdownStyle.inline(text))
            .font(font)
            .foregroundStyle(foreground)
            .multilineTextAlignment(textAlignment)
            .selectable(selectable)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
            // A plain rectangle: a style alone took the rounded shape the table's background is drawn in.
            .background { Rectangle().fill(background) }
            .overlay(alignment: .bottom) { if row == 0 { Rectangle().fill(Theme.stroke).frame(height: 1) } }
    }
}

/// Rows of cells (row-major subviews): a column takes its widest cell's ideal width, at most `cap`, so a long cell
/// wraps instead of stretching the table; a row is as tall as its tallest cell.
private struct TableGridLayout: Layout {
    let columns: Int
    let cap: CGFloat

    struct Cache { var widths: [CGFloat] = []; var heights: [CGFloat] = [] }

    func makeCache(subviews: Subviews) -> Cache { measure(subviews) }

    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = measure(subviews) }

    private func measure(_ subviews: Subviews) -> Cache {
        guard columns > 0 else { return Cache() }
        var widths = Array(repeating: CGFloat(0), count: columns)
        for (i, s) in subviews.enumerated() {
            widths[i % columns] = max(widths[i % columns], min(cap, ceil(s.sizeThatFits(.unspecified).width)))
        }
        let rowCount = (subviews.count + columns - 1) / columns
        var heights = Array(repeating: CGFloat(0), count: rowCount)
        for (i, s) in subviews.enumerated() {
            let h = s.sizeThatFits(ProposedViewSize(width: widths[i % columns], height: nil)).height
            heights[i / columns] = max(heights[i / columns], ceil(h))
        }
        return Cache(widths: widths, heights: heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        CGSize(width: cache.widths.reduce(0, +), height: cache.heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard columns > 0 else { return }
        var y = bounds.minY
        for row in 0..<cache.heights.count {
            var x = bounds.minX
            for col in 0..<columns {
                let i = row * columns + col
                guard i < subviews.count else { break }
                subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                  proposal: ProposedViewSize(width: cache.widths[col], height: cache.heights[row]))
                x += cache.widths[col]
            }
            y += cache.heights[row]
        }
    }
}

extension EnvironmentValues {
    /// Whether `MarkdownView`'s text can be selected (`MarkdownView.touchSelection`).
    @Entry var markdownSelectable = true
}

extension View {
    @ViewBuilder fileprivate func selectable(_ on: Bool) -> some View {
        if on { textSelection(.enabled) } else { self }
    }
}

/// Parsing and inline styling, cached: a reply is parsed and styled once, not on every redraw of the conversation.
enum MarkdownStyle {
    private final class Parsed { let blocks: [MarkdownBlock]; init(_ b: [MarkdownBlock]) { blocks = b } }
    private final class Styled { let value: AttributedString; init(_ v: AttributedString) { value = v } }
    nonisolated(unsafe) private static let parsedCache: NSCache<NSString, Parsed> = { let c = NSCache<NSString, Parsed>(); c.countLimit = 300; return c }()
    nonisolated(unsafe) private static let inlineCache: NSCache<NSString, Styled> = { let c = NSCache<NSString, Styled>(); c.countLimit = 1500; return c }()

    static func blocks(_ text: String) -> [MarkdownBlock] {
        let k = text as NSString
        if let p = parsedCache.object(forKey: k) { return p.blocks }
        let b = MarkdownBlocks.parse(text)
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
        // An image can't be drawn inside a line of text: its alt text becomes a link to it.
        for run in a.runs where run.imageURL != nil && run.link == nil {
            a[run.range].link = run.imageURL
        }
        for run in a.runs where run.link != nil {
            a[run.range].foregroundColor = Theme.accent
            a[run.range].underlineStyle = .single
        }
        return a
    }
}
