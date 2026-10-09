import AppKit

/// An agent's reply as compact rich text for the side panel: Foundation's Markdown parser (headings, paragraphs, lists,
/// code blocks, emphasis, inline code, links) styled with the panel's fonts and colors. Small on purpose: no tables or
/// images; what the parser does not know stays as text.
enum MarkdownText {
    static func render(_ markdown: String, size: CGFloat = 13, color: NSColor = PanelStyle.text) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return NSAttributedString(string: markdown, attributes: [.font: PanelStyle.font(size), .foregroundColor: color])
        }
        let out = NSMutableAttributedString()
        let body = PanelStyle.font(size)
        let mono = PanelStyle.mono(size - 1)
        var lastBlock: Int?
        var lastListItem: (ordinal: Int, list: Int)?
        for run in parsed.runs {
            var text = String(parsed[run.range].characters)
            var font = body
            var fg = color
            var bg: NSColor?
            var indent: CGFloat = 0
            var prefix = ""
            var spacingBefore: CGFloat = 0
            var blockID: Int?
            var isCode = false
            if let intent = run.presentationIntent {
                for component in intent.components {
                    switch component.kind {
                    case .header(let level):
                        font = PanelStyle.font(level <= 2 ? size + 2 : size, .bold)
                        spacingBefore = 8
                    case .codeBlock:
                        font = mono
                        bg = PanelStyle.raised
                        isCode = true
                        spacingBefore = 6
                    case .listItem(let ordinal):
                        indent = 14
                        let list = component.identity
                        if lastListItem?.list != list || lastListItem?.ordinal != ordinal {
                            prefix = intent.components.contains { if case .orderedList = $0.kind { true } else { false } } ? "\(ordinal). " : "• "
                        }
                        lastListItem = (ordinal, list)
                    case .blockQuote:
                        fg = PanelStyle.textDim
                        indent = 10
                    case .paragraph:
                        spacingBefore = max(spacingBefore, 5)
                    default: break
                    }
                }
                blockID = intent.components.first?.identity
            }
            if let inline = run.inlinePresentationIntent {
                if inline.contains(.stronglyEmphasized) { font = PanelStyle.font(font.pointSize, .bold) }
                if inline.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                if inline.contains(.code) { font = mono; bg = PanelStyle.raised }
            }
            if run.link != nil { fg = PanelStyle.accent }
            // Paragraph breaks between blocks; the parser keeps none of the source's newlines between them.
            if let blockID, let last = lastBlock, blockID != last, !out.string.isEmpty {
                out.append(NSAttributedString(string: "\n", attributes: [.font: body]))
            }
            if let blockID { lastBlock = blockID }
            if isCode { text = text.trimmingCharacters(in: .newlines) }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 1.5
            paragraph.paragraphSpacingBefore = spacingBefore
            paragraph.firstLineHeadIndent = indent
            paragraph.headIndent = indent + (prefix.isEmpty ? 0 : 0)
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg, .paragraphStyle: paragraph]
            if let bg { attrs[.backgroundColor] = bg }
            out.append(NSAttributedString(string: prefix + text, attributes: attrs))
        }
        return out
    }
}
