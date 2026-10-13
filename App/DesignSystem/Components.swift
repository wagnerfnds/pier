import SwiftUI
import PierKit

enum DashState: CaseIterable, Hashable {
    case needsYou, working, done, ready

    var title: LocalizedStringKey {
        switch self {
        case .needsYou: "Precisa de você"
        case .working: "Trabalhando"
        case .done: "Sua vez"
        case .ready: "Pronto"
        }
    }
    var color: Color {
        switch self {
        case .needsYou: Theme.orange
        case .working: Theme.accent
        case .done: Theme.green
        case .ready: Theme.gray
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

    init?(_ s: Session) {
        guard s.isAgent, !s.exited else { return nil }
        switch s.agentState {
        case .waiting: self = .needsYou
        case .running: self = .working
        case .finished: self = .done
        case .idle, .none, .unknown: self = .ready
        }
    }
}

/// Small state badge: orange needs-you, blue spinner working, green done, gray ready.
struct StateBadge: View {
    let state: DashState
    var compact = false
    var body: some View {
        HStack(spacing: 5) {
            if state == .working {
                ProgressView().controlSize(.mini).tint(state.color)
            } else {
                Image(systemName: state.symbol).font(.system(size: 11, weight: .semibold))
            }
            if !compact { Text(state.title).font(.caption.weight(.semibold)) }
        }
        .foregroundStyle(state.color)
        .padding(.horizontal, compact ? 6 : 9).padding(.vertical, 4)
        .background(state.color.opacity(0.14), in: Capsule())
    }
}

struct AgentGlyph: View {
    let agent: String?
    var size: CGFloat = 34

    private var style: (letter: String, color: Color) {
        switch (agent ?? "").lowercased() {
        case "claude": ("C", Color(tone: 0xD9855B))
        case "codex": ("X", Color(tone: 0x10A37F))
        case "gemini": ("G", Color(tone: 0x6C8EF5))
        case "opencode": ("O", Color(tone: 0xB07CE8))
        case "aider": ("A", Color(tone: 0xE0C050))
        case let a where !a.isEmpty: (String(a.prefix(1)).uppercased(), Theme.gray)
        default: ("?", Theme.gray)
        }
    }
    var body: some View {
        Text(style.letter)
            .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
            .foregroundStyle(style.color)
            .frame(width: size, height: size)
            .background(style.color.opacity(0.15), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityLabel(agent.map(DisplayNames.agentLabel) ?? String(localized: "Terminal"))
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 14
    var tint: Color? = nil
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card)
                .shadow(color: Theme.cardShadow, radius: 2, y: 1))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint?.opacity(0.35) ?? Theme.stroke, lineWidth: 1))
    }
}

struct SectionHeader: View {
    let title: LocalizedStringKey
    var count: Int? = nil
    var color: Color = Theme.textDim
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.footnote.weight(.semibold)).textCase(.uppercase).tracking(0.6).foregroundStyle(color)
            if let count {
                Text("\(count)").font(.footnote.monospacedDigit()).foregroundStyle(Theme.textFaint)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: LocalizedStringKey
    var message: LocalizedStringKey? = nil
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(Theme.textFaint)
            Text(title).font(.headline).foregroundStyle(Theme.text)
            if let message {
                Text(message).font(.subheadline).foregroundStyle(Theme.textDim).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 24)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = Theme.accent
    var foreground: Color = .white
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(color.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// The primary action at its own size (a form's end on the Mac and the iPad): filled with the accent when it can run,
/// a quiet outline with readable text when it can't yet.
struct CompactPrimaryButtonStyle: ButtonStyle {
    var enabled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Platform.isMac ? .callout.weight(.semibold) : .body.weight(.semibold))
            .foregroundStyle(enabled ? Color.white : Theme.textDim)
            .padding(.horizontal, Platform.isMac ? 16 : 20).padding(.vertical, Platform.isMac ? 8 : 12)
            .background(enabled ? Theme.accent.opacity(configuration.isPressed ? 0.8 : 1) : Theme.cardRaised,
                        in: RoundedRectangle(cornerRadius: Platform.isMac ? 9 : 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Platform.isMac ? 9 : 12, style: .continuous).strokeBorder(enabled ? .clear : Theme.stroke))
            .contentShape(RoundedRectangle(cornerRadius: Platform.isMac ? 9 : 12, style: .continuous))
    }
}

/// One option of a set, as a capsule: the chosen one in the accent's tint, the rest quiet. `quiet` draws a softer
/// action chip ("Outro…").
struct ChoiceChip: View {
    let title: String
    let selected: Bool
    var quiet = false
    let action: () -> Void

    /// Vertical padding of the text inside the capsule (labels beside a row of chips line up with it).
    static var vPad: CGFloat { Platform.isMac ? 4 : 6 }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.accent : quiet ? Theme.textDim : Theme.text)
                .lineLimit(1)
                .padding(.horizontal, Platform.isMac ? 10 : 12).padding(.vertical, Self.vPad)
                .background(selected ? Theme.accent.opacity(0.13) : quiet ? Color.clear : Theme.cardRaised, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Theme.accent.opacity(0.55) : Theme.stroke, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension View {
    /// A menu drawn as its own label: on the Mac a SwiftUI `Menu` otherwise becomes a grey pop-up button as wide as
    /// its row, without the label's value.
    func plainMenu() -> some View {
        menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(Theme.cardRaised.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

enum Fmt {
    static func elapsed(since date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)min" }
        if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)min" }
        return "\(s / 86400)d"
    }
    static func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .memory)
    }
}
