import SwiftUI
import PierKit

/// One session on the agents board: agent, title, project · worktree (· box), the one-line detail of its column (the ask,
/// the current step, the last reply), how long it has been in this state and the lines it changed.
struct BoardCard: View {
    @Environment(LocalPrefs.self) private var prefs
    let item: BoxSession
    let column: AgentBoard.Column
    var detail: String?
    var change: SessionSignals.LineChange?
    var archived = false
    var showBox = false

    private var title: String { item.session.title?.nilIfEmpty ?? item.worktree ?? item.session.name }
    private var place: String {
        var parts = [item.placeName(prefs)]
        if let wt = item.worktree, wt != title { parts.append(wt) }
        if showBox { parts.append(item.box) }
        return parts.joined(separator: " · ")
    }
    private var live: Bool { column == .needsYou || column == .working }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                AgentGlyph(agent: item.session.agent, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(place).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if let detail, !detail.isEmpty { detailView(detail) }
            HStack(spacing: 8) {
                status
                Spacer(minLength: 4)
                if let change, change.added + change.removed > 0 { DiffStat(add: change.added, del: change.removed) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            // The state's colour as a short bar on the left edge: the column reads at a glance in a drag preview too.
            Capsule().fill(column.color.opacity(column == .closed ? 0.35 : 0.9)).frame(width: 3, height: 22).padding(.leading, 1).padding(.top, 14)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(column == .needsYou ? Theme.orange.opacity(0.35) : Theme.stroke))
        .opacity(column == .closed ? 0.75 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private func detailView(_ text: String) -> some View {
        switch column {
        case .yourTurn:
            Text(text).font(.caption).foregroundStyle(Theme.textDim).lineLimit(3).multilineTextAlignment(.leading)
        default:
            Text(text).font(.mono(11)).foregroundStyle(column == .needsYou ? Theme.orange : Theme.accent).lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }

    /// "⏱ 3min" in the state; Encerradas says why it is there.
    private var status: some View {
        TimelineView(.periodic(from: .now, by: live ? 1 : 30)) { ctx in
            HStack(spacing: 4) {
                if column == .working {
                    ProgressView().controlSize(.mini).tint(Theme.accent).scaleEffect(0.8).frame(width: 12, height: 12)
                } else {
                    Image(systemName: column == .closed ? (archived ? "archivebox" : "power") : "clock").font(.system(size: 10))
                }
                if column == .closed {
                    Text(archived ? "Arquivada" : "Encerrada na box")
                    Text(verbatim: "· \(Age.short(item.session.stateSince ?? item.session.created, now: ctx.date))")
                } else {
                    Text(Fmt.elapsed(since: item.session.stateSince ?? item.session.created, now: ctx.date)).monospacedDigit()
                }
            }
            .font(.caption).foregroundStyle(Theme.textFaint)
        }
    }
}
