import SwiftUI
import PierKit

/// Colors and a cached AttributedString builder for `SyntaxHighlighter` (pure tokenizing lives in PierKit).
/// Dark: pastel on the dark code background; light: deeper hues that keep ≥ 4.5:1 on the light code background.
enum SyntaxTheme {
    private static let keyword = Color(light: 0x8E3BB0, dark: 0xC59BF5)
    private static let string = Color(light: 0x2E7A34, dark: 0x98D49A)
    private static let comment = Color(light: 0x6E7781, dark: 0x7A828E)
    private static let number = Color(light: 0xA85300, dark: 0xF2A66B)
    private static let type = Color(light: 0x0C7086, dark: 0x62CDE3)
    private static let function = Color(light: 0x2860C8, dark: 0x7DB8FA)
    private static let variable = Color(light: 0x93520F, dark: 0xE8B98B)
    private static let property = Color(light: 0x1D63A8, dark: 0x8FC4F5)
    private static let attribute = Color(light: 0x9D3489, dark: 0xE0A0D8)
    private static let tag = Color(light: 0xBE3029, dark: 0xF0807A)

    static func color(_ k: SyntaxKind, fallback: Color) -> Color {
        switch k {
        case .plain: return fallback
        case .keyword: return keyword
        case .string: return string
        case .comment: return comment
        case .number: return number
        case .type: return type
        case .literal: return number
        case .function: return function
        case .variable: return variable
        case .property: return property
        case .attribute: return attribute
        case .tag: return tag
        case .inserted: return Theme.green
        case .deleted: return Theme.red
        case .meta: return Theme.accent.opacity(0.85)
        }
    }

    private final class Box { let value: AttributedString; init(_ v: AttributedString) { value = v } }
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>(); c.countLimit = 400; c.totalCostLimit = 4_000_000; return c
    }()

    private static func key(_ text: String, _ l: SyntaxLanguage) -> NSString { "\(l.rawValue)|\(text.count)|\(text.hashValue)" as NSString }

    /// A previously highlighted block, if any.
    static func cached(_ text: String, _ l: SyntaxLanguage) -> AttributedString? { cache.object(forKey: key(text, l))?.value }

    /// Highlight (and cache). Cheap enough for short text on the main actor; long text should go through `highlightAsync`.
    @discardableResult
    static func highlight(_ text: String, _ l: SyntaxLanguage, base: Color = Theme.text) -> AttributedString {
        if let c = cached(text, l) { return c }
        let out = build(text, l, base: base)
        cache.setObject(Box(out), forKey: key(text, l), cost: text.utf8.count * 4)
        return out
    }

    static func highlightAsync(_ text: String, _ l: SyntaxLanguage, base: Color = Theme.text) async -> AttributedString {
        if let c = cached(text, l) { return c }
        let out = await Task.detached(priority: .userInitiated) { build(text, l, base: base) }.value
        cache.setObject(Box(out), forKey: key(text, l), cost: text.utf8.count * 4)
        return out
    }

    /// Short enough to highlight while building the view (no flash of plain text).
    static func isCheap(_ text: String) -> Bool { text.utf8.count <= 1500 }

    private static func build(_ text: String, _ l: SyntaxLanguage, base: Color) -> AttributedString {
        let scalars = Array(text.unicodeScalars)
        var out = AttributedString()
        for run in SyntaxHighlighter.runs(text, language: l) {
            var piece = AttributedString(String(String.UnicodeScalarView(scalars[run.start..<min(run.end, scalars.count)])))
            piece.foregroundColor = color(run.kind, fallback: base)
            if run.kind == .comment { piece.font = .mono(12.5).italic() }
            out.append(piece)
        }
        // text beyond the highlighter's cap stays plain
        if SyntaxHighlighter.maxScalars < scalars.count {
            var rest = AttributedString(String(String.UnicodeScalarView(scalars[SyntaxHighlighter.maxScalars...])))
            rest.foregroundColor = base
            out.append(rest)
        }
        return out
    }
}
