import SwiftUI
import PierKit

// Widgets driven by live sessions: Needs you, Working now, Recently finished, Recent areas.

/// One compact session row inside a widget card.
struct HomeSessionRow: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalPrefs.self) private var prefs
    let item: BoxSession
    let state: DashState
    var detail: String? = nil
    var detailColor: Color = Theme.accent
    var trailing: AnyView? = nil

    private var title: String { item.session.title?.nilIfEmpty ?? item.worktree ?? item.session.name }
    private var project: String {
        var parts = [item.placeName(prefs)]
        if let wt = item.worktree, wt != title { parts.append(wt) }
        if model.boxes.count > 1 { parts.append(item.box) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        NavigationLink(value: item.route) {
            HStack(alignment: .top, spacing: 11) {
                AgentGlyph(agent: item.session.agent, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(project).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.mono(11)).foregroundStyle(detailColor).lineLimit(2).padding(.top, 1)
                    }
                }
                Spacer(minLength: 6)
                if let trailing { trailing } else {
                    TimelineView(.periodic(from: .now, by: state == .working ? 1 : 30)) { ctx in
                        Text(Fmt.elapsed(since: item.session.stateSince ?? item.session.created, now: ctx.date))
                            .font(.caption.monospacedDigit()).foregroundStyle(Theme.textFaint)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct NeedsYouWidget: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let items = model.sessionsStore.group(.needsYou).reversed() as [BoxSession]   // oldest first: the longest wait on top
        HomeCard(kind: .needsYou, count: items.count, urgent: !items.isEmpty) {
            if items.isEmpty {
                HomeEmpty(symbol: "checkmark.seal", title: model.boxes.allSatisfy(\.hasLoadedSessions) ? "Nada esperando por você" : "Carregando…")
            } else {
                VStack(spacing: 12) {
                    ForEach(items) { item in
                        HomeSessionRow(item: item, state: .needsYou, detail: Self.ask(item), detailColor: Theme.orange)
                    }
                }
            }
        }
    }

    static func ask(_ item: BoxSession) -> String? {
        guard let a = item.session.ask else { return nil }
        let s = [a.tool, a.input ?? a.message ?? a.why].compactMap { $0 }.joined(separator: "  ")
        return s.isEmpty ? nil : s
    }
}

struct WorkingWidget: View {
    @Environment(AppModel.self) private var model
    let home: HomeStore
    var body: some View {
        // A finished turn with work still running in the background counts as working.
        let items = model.sessionsStore.group(.working) + model.sessionsStore.group(.done).filter { home.background[$0.id] != nil }
        HomeCard(kind: .working, count: items.count) {
            if items.isEmpty {
                HomeEmpty(symbol: "moon.zzz", title: "Nenhum agente trabalhando")
            } else {
                VStack(spacing: 12) {
                    ForEach(items) { item in
                        HomeSessionRow(item: item, state: .working, detail: detail(item), detailColor: Theme.accent)
                    }
                }
            }
        }
    }

    private func detail(_ item: BoxSession) -> String {
        if let bg = home.background[item.id], item.session.agentState != .running {
            let what = bg.first.map { " · \($0.title)" } ?? ""
            return (bg.count == 1 ? S("Em segundo plano") : S("\(bg.count) em segundo plano")) + what
        }
        return home.steps[item.id] ?? "…"
    }
}

/// "Sua vez": finished turns the agent waits on you to continue (you have not closed them), then the closed ones folded:
/// archived here or in the session, or exited on the box. A new turn brings an archived session back by itself.
struct FinishedWidget: View {
    @Environment(AppModel.self) private var model
    let home: HomeStore
    @State private var all = false
    @State private var showClosed = false
    var body: some View {
        let items = model.sessionsStore.yourTurn.filter { home.background[$0.id] == nil }
        let closed = model.sessionsStore.closed
        let shown = all ? items : Array(items.prefix(4))
        HomeCard(kind: .finished, count: items.count) {
            VStack(spacing: 12) {
                if items.isEmpty {
                    HomeEmpty(symbol: "tray", title: "Nada esperando você continuar")
                } else {
                    ForEach(shown) { item in
                        row(item, archived: false)
                    }
                    if items.count > 4 {
                        Button { withAnimation(.snappy) { all.toggle() } } label: {
                            Group { if all { HText("Ver menos") } else { HText("Ver todos (\(items.count))") } }
                                .font(.caption.weight(.medium)).foregroundStyle(Theme.accent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if !closed.isEmpty {
                    Button { withAnimation(.snappy) { showClosed.toggle() } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "archivebox").font(.caption)
                            HText("Encerradas (\(closed.count))").font(.caption.weight(.medium))
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).rotationEffect(.degrees(showClosed ? 90 : 0))
                        }
                        .foregroundStyle(Theme.textDim)
                        .padding(.top, items.isEmpty ? 0 : 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showClosed {
                        ForEach(closed.prefix(8)) { item in
                            row(item, archived: true).opacity(0.7)
                        }
                    }
                }
            }
        }
    }

    private func row(_ item: BoxSession, archived: Bool) -> some View {
        let change = home.changes["\(item.box)/\(item.session.location ?? "")"]
        return HomeSessionRow(item: item, state: .done, trailing: AnyView(trailing(item, change)))
            .contextMenu {
                if !item.session.exited {
                    Button {
                        withAnimation(.snappy) { model.prefs.setClosed(!archived, box: item.box, session: item.session.name) }
                    } label: {
                        archived ? Label("Voltar para “Sua vez”", systemImage: "tray.and.arrow.up")
                                 : Label("Arquivar (terminei aqui)", systemImage: "archivebox")
                    }
                }
            }
    }

    private func trailing(_ item: BoxSession, _ change: HomeStore.LineChange?) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            if let change, change.added + change.removed > 0 { DiffStat(add: change.added, del: change.removed) }
            Text(Age.short(item.session.stateSince ?? item.session.created)).font(.caption).foregroundStyle(Theme.textFaint)
        }
    }
}

struct AreasWidget: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalPrefs.self) private var prefs

    private struct Area: Identifiable {
        let box: String, location: String, worktree: String, ref: String
        var latest: Date
        var states: [DashState]
        var id: String { "\(box)/\(ref)" }
    }

    private var areas: [Area] {
        var by: [String: Area] = [:]
        for s in model.sessionsStore.all {
            guard let ref = s.session.location, let st = DashState(s.session) else { continue }
            let key = "\(s.box)/\(ref)"
            let when = s.session.stateSince ?? s.session.created
            if var a = by[key] {
                a.latest = max(a.latest, when); a.states.append(st); by[key] = a
            } else {
                let wt = s.worktree ?? model.connection(for: s.box)?.location(named: s.location)?.worktrees?.first { $0.main == true }?.name ?? s.location
                by[key] = Area(box: s.box, location: s.location, worktree: wt, ref: ref, latest: when, states: [st])
            }
        }
        return by.values.sorted { $0.latest > $1.latest }
    }

    var body: some View {
        let list = areas
        HomeCard(kind: .areas) {
            if list.isEmpty {
                HomeEmpty(symbol: "arrow.triangle.branch", title: "Nenhuma área recente", hint: HL("As worktrees em que há agentes aparecem aqui."))
            } else {
                VStack(spacing: 12) {
                    ForEach(list.prefix(5)) { a in
                        NavigationLink(value: WorktreeRoute(box: a.box, location: a.location, worktree: a.worktree)) {
                            HStack(spacing: 11) {
                                Image(systemName: "arrow.triangle.branch").font(.system(size: 13)).foregroundStyle(Theme.textDim)
                                    .frame(width: 30, height: 30).background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.worktree == a.location ? prefs.displayName(box: a.box, location: a.location) : a.worktree)
                                        .font(.subheadline.weight(.medium)).foregroundStyle(Theme.text).lineLimit(1)
                                    Text(a.worktree == a.location ? a.box : prefs.displayName(box: a.box, location: a.location))
                                        .font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                HStack(spacing: 3) {
                                    ForEach(Array(a.states.sorted { $0.rank < $1.rank }.prefix(4).enumerated()), id: \.offset) { _, st in
                                        Circle().fill(st.color).frame(width: 7, height: 7)
                                    }
                                }
                                Text(Age.short(a.latest)).font(.caption).foregroundStyle(Theme.textFaint).frame(minWidth: 34, alignment: .trailing)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private extension DashState {
    var rank: Int { switch self { case .needsYou: 0; case .working: 1; case .done: 2; case .ready: 3 } }
}
