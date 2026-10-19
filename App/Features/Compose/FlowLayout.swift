import SwiftUI

/// Wrapping row layout (chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += lineH + lineSpacing; lineH = 0 }
            x += s.width + spacing; lineH = max(lineH, s.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += lineH + lineSpacing; lineH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; lineH = max(lineH, s.height)
        }
    }
}

/// Rounded "chip": icon + label (+ chevron) used for the composer's pickers and status tags.
struct Chip: View {
    var symbol: String? = nil
    let text: String
    var tint: Color = Theme.textDim
    var showsChevron = true
    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint) }
            Text(text).font(.subheadline.weight(.medium)).foregroundStyle(Theme.text).lineLimit(1)
            if showsChevron { Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textFaint) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.cardRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
        .contentShape(Capsule())
    }
}

/// Transient message pinned to the top of a screen.
struct BannerMessage: Equatable, Identifiable {
    enum Kind { case info, error, success }
    let id = UUID()
    let text: String
    var kind: Kind = .info
}

private struct BannerModifier: ViewModifier {
    @Binding var message: BannerMessage?
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let m = message {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: m.kind == .error ? "exclamationmark.triangle.fill" : m.kind == .success ? "checkmark.circle.fill" : "info.circle.fill")
                        .foregroundStyle(m.kind == .error ? Theme.red : m.kind == .success ? Theme.green : Theme.accent)
                    Text(m.text).font(.subheadline).foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading)
                    Button { message = nil } label: { Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Theme.textDim) }
                }
                .padding(12)
                .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
                .compositingGroup()   // one shadow for the whole thing, not one per subview
                .shadow(color: Theme.shadow, radius: 8, y: 3)
                .padding(.horizontal, 16).padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: m.id) {
                    try? await Task.sleep(for: .seconds(m.kind == .error ? 8 : 4))
                    if message?.id == m.id { message = nil }
                }
            }
        }
        .animation(.snappy, value: message)
    }
}

extension View {
    func banner(_ message: Binding<BannerMessage?>) -> some View { modifier(BannerModifier(message: message)) }
}
