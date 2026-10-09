import SwiftUI
import UIKit

/// Colors and small building blocks copied from the app's design system so the extension looks the same (calm; a dark
/// and a light palette). Every token follows the appearance: widgets and Live Activities the system's.
enum BTheme {
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
    /// A faint fill for rows and chips on a card (white on dark, black on light).
    static let wash = Color.adaptive(light: .black.opacity(0.04), dark: .white.opacity(0.04))
    /// Behind a widget and a Live Activity: white on light (like the system's widgets), the app's background on dark.
    static let surface = Color(light: 0xFFFFFF, dark: 0x16181B)
    /// Text on a filled state color (orange / green capsules).
    static let onFill = Color(light: 0xFFFFFF, dark: 0x16181B)
}

extension Color {
    init(sharedHex hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    /// One color per appearance, resolved by the trait collection (so `.preferredColorScheme` and the system both reach it).
    static func adaptive(light: Color, dark: Color) -> Color {
        let l = UIColor(light), d = UIColor(dark)
        return Color(UIColor { $0.userInterfaceStyle == .dark ? d : l })
    }

    init(light: UInt32, dark: UInt32) {
        self = .adaptive(light: Color(sharedHex: light), dark: Color(sharedHex: dark))
    }

    /// A brand or label color: as given on dark; on light darkened until it reads as text on white (contrast ≥ 4.5).
    init(tone hex: UInt32) {
        self.init(light: Self.readableOnWhite(hex), dark: hex)
    }

    private static func readableOnWhite(_ hex: UInt32) -> UInt32 {
        var r = Double((hex >> 16) & 0xFF), g = Double((hex >> 8) & 0xFF), b = Double(hex & 0xFF)
        func lin(_ c: Double) -> Double { let c = c / 255; return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func contrast() -> Double { 1.05 / (0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b) + 0.05) }
        var steps = 0
        while contrast() < 4.5, steps < 40 { r *= 0.94; g *= 0.94; b *= 0.94; steps += 1 }
        return UInt32(r.rounded()) << 16 | UInt32(g.rounded()) << 8 | UInt32(b.rounded())
    }
}

extension WState {
    var color: Color {
        switch self {
        case .needsYou: BTheme.orange
        case .working: BTheme.accent
        case .done: BTheme.green
        case .ready: BTheme.gray
        }
    }
    var title: String {
        switch self {
        case .needsYou: String(localized: "Precisa de você")
        case .working: String(localized: "Trabalhando")
        case .done: String(localized: "Sua vez")
        case .ready: String(localized: "Pronto")
        }
    }
    var symbol: String {
        switch self {
        case .needsYou: "exclamationmark.bubble.fill"
        case .working: "circle.dotted"
        case .done: "checkmark.circle.fill"
        case .ready: "circle"
        }
    }
}

/// The agent's letter in its brand color (same as the app's `AgentGlyph`).
struct SharedAgentGlyph: View {
    let agent: String?
    var size: CGFloat = 28

    private var style: (letter: String, color: Color) {
        switch (agent ?? "").lowercased() {
        case "claude": ("C", Color(tone: 0xD9855B))
        case "codex": ("X", Color(tone: 0x10A37F))
        case "gemini": ("G", Color(tone: 0x6C8EF5))
        case "opencode": ("O", Color(tone: 0xB07CE8))
        case "aider": ("A", Color(tone: 0xE0C050))
        case let a where !a.isEmpty: (String(a.prefix(1)).uppercased(), BTheme.gray)
        default: ("?", BTheme.gray)
        }
    }

    var body: some View {
        Text(style.letter)
            .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
            .foregroundStyle(style.color)
            .frame(width: size, height: size)
            .background(style.color.opacity(0.16), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}
