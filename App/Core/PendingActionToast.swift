import SwiftUI

/// The bottom toast of `PendingActions`: "Enviando…" over what is about to go out, "Desfazer", and a bar that shrinks
/// until it is sent. Esc and ⌘Z undo too (iPad / Mac keyboards). Lifted above the tab bar and the session composer.
struct PendingActionToast: View {
    @State private var pending = PendingActions.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            if let item = pending.items.last {
                card(item, more: pending.items.count - 1)
                    .id(item.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
        }
        .frame(maxWidth: 460)
        .padding(.horizontal, 12)
        .padding(.bottom, Self.lift)
        .animation(.snappy(duration: 0.28), value: pending.items.map(\.id))
    }

    /// Clears the iPhone tab bar and the session composer (both ~50–60 pt above the safe area).
    static let lift: CGFloat = 66

    private func card(_ item: PendingActions.Item, more: Int) -> some View {
        HStack(spacing: 12) {
            // The ring is a button too: Esc lands here (a hidden button's shortcut never fires), ⌘Z on Desfazer.
            Button { pending.undoLatest() } label: { Countdown(item: item) }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(more > 0 ? S("Enviando… (+\(more))") : S("Enviando…"))
                    .font(.caption.weight(.medium)).foregroundStyle(Theme.textDim)
                Text(item.label)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { pending.undoLatest() } label: {
                Text("Desfazer")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Theme.accent.opacity(0.14), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("z", modifiers: .command)
            .accessibilityIdentifier("undo-button")
            .accessibilityHint("Cancela o envio")
        }
        .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 10)
        .background {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.cardRaised)
                Shrinking(item: item)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.09)))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("undo-toast")
    }
}

/// The time left as a ring around the action's symbol.
private struct Countdown: View {
    let item: PendingActions.Item
    var body: some View {
        TimelineView(.animation) { ctx in
            let left = max(0, item.deadline.timeIntervalSince(ctx.date) / item.duration)
            ZStack {
                Circle().fill(Theme.accent.opacity(0.14))
                Circle().trim(from: 0, to: left)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(1)
                Image(systemName: item.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            .frame(width: 32, height: 32)
        }
        .accessibilityHidden(true)
    }
}

/// The bar along the bottom edge that shrinks to nothing when the action goes out.
private struct Shrinking: View {
    let item: PendingActions.Item
    var body: some View {
        TimelineView(.animation) { ctx in
            let left = max(0, item.deadline.timeIntervalSince(ctx.date) / item.duration)
            GeometryReader { g in
                Rectangle().fill(Theme.accent.opacity(0.85))
                    .frame(width: g.size.width * left, height: 3)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
