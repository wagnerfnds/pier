import SwiftUI
import PierKit

/// Above the composer while the agent has work running in the background (shells, monitors, subagents), so a finished turn
/// is not mistaken for the end of the work. Tap to list them.
struct BackgroundStrip: View {
    let items: [BackgroundItem]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini).tint(Theme.accent)
                    Text(items.count == 1 ? S("1 tarefa em segundo plano") : S("\(items.count) tarefas em segundo plano"))
                        .font(.footnote.weight(.medium)).foregroundStyle(Theme.textDim)
                    if !open, let first = items.first {
                        Text(first.title).font(.mono(11)).foregroundStyle(Theme.textDim).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up").font(.caption2.weight(.semibold)).foregroundStyle(Theme.textFaint)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ForEach(items) { it in
                    HStack(spacing: 8) {
                        Image(systemName: it.symbol).font(.caption).foregroundStyle(Theme.accent).frame(width: 16)
                        Text(it.title).font(.mono(11.5)).foregroundStyle(Theme.text).lineLimit(2)
                        Spacer(minLength: 4)
                        TimelineView(.periodic(from: .now, by: 1)) { c in
                            Text(Fmt.elapsed(since: it.since, now: c.date)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.textFaint)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        // A quiet tray over the composer: the spinner says it runs, no colored frame around it.
        .background(Theme.cardRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("background-strip")
    }
}
