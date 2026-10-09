import SwiftUI

/// Calm palette: a dark one, and a light one in the same spirit (cool neutral
/// background, white cards with a hairline, state colors deepened for contrast). Every token follows the appearance.
enum Theme {
    static let bg = Color(light: 0xF4F5F7, dark: 0x16181B)
    static let card = Color(light: 0xFFFFFF, dark: 0x1E2126)
    static let cardRaised = Color(light: 0xEDEFF2, dark: 0x252930)
    static let stroke = Color.adaptive(light: .black.opacity(0.09), dark: .white.opacity(0.07))
    static let text = Color(light: 0x1C2024, dark: 0xE6E8EB)
    static let textDim = Color(light: 0x59616B, dark: 0x8B9199)
    static let textFaint = Color(light: 0x80878F, dark: 0x5C626B)
    static let accent = Color(light: 0x0A67D0, dark: 0x4A99FA)
    static let orange = Color(light: 0xB35006, dark: 0xF5A35C)
    static let green = Color(light: 0x187A3F, dark: 0x4CC38A)
    static let gray = Color(light: 0x69707A, dark: 0x7A818B)
    static let red = Color(light: 0xC93028, dark: 0xE5675F)
    /// Merged PRs, and the purple of the glyph palettes.
    static let purple = Color(light: 0x8250DF, dark: 0xB07CE8)
    /// Text or a glyph on a filled state color (a green check square, an orange capsule).
    static let onFill = Color(light: 0xFFFFFF, dark: 0x16181B)

    /// A faint fill on a card: code block headers.
    static let wash = Color.adaptive(light: .black.opacity(0.035), dark: .white.opacity(0.03))
    /// A stronger fill: a chip under a dragged card.
    static let washStrong = Color.adaptive(light: .black.opacity(0.07), dark: .white.opacity(0.1))
    /// The board's lanes, and a lane under a dragged card.
    static let lane = Color.adaptive(light: .black.opacity(0.035), dark: .white.opacity(0.025))
    static let laneTarget = Color.adaptive(light: .black.opacity(0.07), dark: .white.opacity(0.06))
    /// Code blocks, tool output and command previews (recessed from the card).
    static let codeBg = Color.adaptive(light: Color(hex: 0xF3F4F6), dark: .black.opacity(0.3))
    /// Inline `code` in Markdown.
    static let inlineCode = Color(light: 0xA2470D, dark: 0xF0C987)
    static let inlineCodeBg = Color.adaptive(light: .black.opacity(0.06), dark: .white.opacity(0.09))
    /// The raw terminal.
    static let terminalBg = Color.adaptive(light: Color(hex: 0xFBFBFC), dark: .black.opacity(0.4))
    static let terminalText = Color(light: 0x24292F, dark: 0xD6D9DE)
    /// Diff lines.
    static let diffAdd = Color.adaptive(light: Color(hex: 0x1F9D55, opacity: 0.13), dark: Color(hex: 0x4CC38A, opacity: 0.15))
    static let diffDel = Color.adaptive(light: Color(hex: 0xD73A31, opacity: 0.11), dark: Color(hex: 0xE5675F, opacity: 0.15))
    /// Drop shadows of floating things (banners, the needs-you card, the floating button).
    static let shadow = Color.adaptive(light: .black.opacity(0.12), dark: .black.opacity(0.4))
    /// A card's lift off the background: nothing on dark (the stroke does it), a soft shadow on light.
    static let cardShadow = Color.adaptive(light: .black.opacity(0.05), dark: .clear)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

extension Font {
    /// Monospaced at `size` points, scaled with the person's Dynamic Type setting (like `.body`).
    static func mono(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: UIFontMetrics(forTextStyle: .body).scaledValue(for: size), weight: weight, design: .monospaced)
    }
}

struct MonoText: View {
    let text: String
    var size: CGFloat = 12
    var color: Color = Theme.textDim
    init(_ text: String, size: CGFloat = 12, color: Color = Theme.textDim) {
        self.text = text; self.size = size; self.color = color
    }
    var body: some View { Text(text).font(.mono(size)).foregroundStyle(color) }
}

/// Screen background applied to every root.
struct PierBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.bg.ignoresSafeArea())
            .scrollContentBackground(.hidden)
    }
}

extension View {
    func pierBackground() -> some View { modifier(PierBackground()) }
}
