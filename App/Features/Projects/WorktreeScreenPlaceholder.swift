import SwiftUI
import PierKit

/// One worktree: git status, its sessions, and actions (agent here, review, remove).
struct WorktreeScreenPlaceholder: View {
    let route: WorktreeRoute
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var status: WorktreeStatus?
    @State private var removing = false
    @State private var message: BannerMessage?

    private var conn: BoxConnection? { model.connection(for: route.box) }
    private var location: Location? { conn?.location(named: route.location) }
    private var worktree: Worktree? { location?.worktrees?.first { $0.name == route.worktree } }
    private var ref: String { worktree.flatMap { location?.ref($0) } ?? "\(route.location)/\(route.worktree)" }
    private var sessions: [Session] {
        (conn?.sessions ?? []).filter { !$0.exited && $0.location == ref }
            .sorted { ($0.isAgent ? 0 : 1, $1.created) < ($1.isAgent ? 0 : 1, $0.created) }
    }
    private var isMain: Bool { worktree?.main == true }

    var body: some View {
        List {
            if worktree == nil && conn?.locations.isEmpty == false {
                EmptyState(symbol: "arrow.triangle.branch", title: "Worktree não encontrada").listRowBackground(Color.clear)
            } else {
                Section { statusCard }.listRowBackground(Theme.card)
                Section {
                    Button { router.push(ComposeRoute(box: route.box, location: route.location, worktree: route.worktree)) } label: {
                        Label("Iniciar agente aqui", systemImage: "sparkles").font(.body.weight(.semibold))
                    }
                    Button { router.push(ReviewRoute(box: route.box, location: route.location, worktree: route.worktree)) } label: {
                        Label("Revisar mudanças", systemImage: "doc.text.magnifyingglass")
                    }
                    if !isMain {
                        Button(role: .destructive) { removing = true } label: { Label("Remover worktree", systemImage: "archivebox").foregroundStyle(Theme.red) }
                    }
                }.listRowBackground(Theme.card)
                Section {
                    if sessions.isEmpty {
                        Text("Nenhuma sessão rodando aqui.").font(.subheadline).foregroundStyle(Theme.textDim)
                    }
                    ForEach(sessions) { s in
                        NavigationLink(value: SessionRoute(box: route.box, session: s)) { sessionRow(s) }
                    }
                } header: { SectionHeader(title: "Sessões", count: sessions.count) }.listRowBackground(Theme.card)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await reload() }
        .pierBackground()
        .navigationTitle(route.worktree)
        .navigationBarTitleDisplayMode(.inline)
        .banner($message)
        .task {
            await reload()
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "worktreeRemove") { removing = true }
            #endif
        }
        .onChange(of: conn?.sessions) { Task { await reload() } }
        .sheet(isPresented: $removing) {
            RemoveWorktreeSheet(box: route.box, location: route.location, worktree: route.worktree,
                                changes: status.map { $0.changed + $0.untracked } ?? 0, sessions: sessions.count) { msg in
                // The worktree is gone (or archiving): leave this screen.
                if case .success = msg.kind { router.popTop() } else { message = msg }
            }
        }
    }

    private func reload() async {
        guard let conn else { return }
        if let all = try? await conn.client.worktreeStatuses(location: route.location),
           let s = all.first(where: { $0.name == route.worktree }) { status = s }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.accent)
                MonoText(status?.branch ?? worktree?.branch ?? route.worktree, size: 15, color: Theme.text)
                Spacer()
                if isMain { Text("principal").font(.caption2.weight(.semibold)).foregroundStyle(Theme.textDim)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.cardRaised, in: Capsule()) }
            }
            if let b = status?.base { Text("base: \(b)").font(.caption).foregroundStyle(Theme.textDim) }
            WorktreeIndicators(status: status, worktree: worktree, sessions: sessions.count)
            if let c = status?.lastCommit {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.subject).font(.subheadline).foregroundStyle(Theme.text).lineLimit(2)
                    Text([c.short, c.author].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.textFaint)
                }
            }
            if let e = status?.error, !e.isEmpty { Text(e).font(.caption).foregroundStyle(Theme.red) }
            if let p = worktree?.path { MonoText(p, size: 11, color: Theme.textFaint).textSelection(.enabled) }
        }
        .padding(.vertical, 4)
    }

    private func sessionRow(_ s: Session) -> some View {
        HStack(spacing: 12) {
            AgentGlyph(agent: DisplayNames.agent(of: s), size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(DisplayNames.sessionName(s, among: conn?.sessions ?? [])).foregroundStyle(Theme.text).lineLimit(1)
                Text(DisplayNames.agent(of: s).map(DisplayNames.agentLabel) ?? String(localized: "Terminal")).font(.caption).foregroundStyle(Theme.textDim)
            }
            Spacer()
            if let st = DashState(s) { StateBadge(state: st) }
        }
    }
}
