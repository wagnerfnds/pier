import SwiftUI
import PierKit

/// One project: repo info, its worktrees with git status, and actions.
struct ProjectScreenPlaceholder: View {
    let route: ProjectRoute
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(LocalPrefs.self) private var prefs
    @State private var statuses: [WorktreeStatus] = []
    @State private var loaded = false
    @State private var newWorktree = false
    @State private var removing: Worktree?
    @State private var message: BannerMessage?

    private var conn: BoxConnection? { model.connection(for: route.box) }
    private var location: Location? { conn?.location(named: route.location) }
    private var name: String { prefs.displayName(box: route.box, location: route.location) }

    var body: some View {
        List {
            if let loc = location {
                Section { header(loc) }.listRowBackground(Theme.card)
                Section {
                    Button { router.push(ComposeRoute(box: route.box, location: route.location)) } label: {
                        Label("Nova tarefa aqui", systemImage: "plus.bubble.fill").font(.body.weight(.semibold))
                    }
                    Button { newWorktree = true } label: { Label("Nova worktree", systemImage: "arrow.triangle.branch") }
                }.listRowBackground(Theme.card)
                Section {
                    ForEach(loc.worktrees ?? []) { wt in
                        NavigationLink(value: WorktreeRoute(box: route.box, location: route.location, worktree: wt.name)) {
                            WorktreeRow(wt: wt, status: status(wt), sessions: sessionCount(loc, wt))
                        }
                        .listRowBackground(Theme.card)
                        .swipeActions(edge: .trailing) {
                            if wt.main != true {
                                Button(role: .destructive) { removing = wt } label: { Label("Remover", systemImage: "archivebox") }
                            }
                        }
                        .contextMenu {
                            Button { router.push(ComposeRoute(box: route.box, location: route.location, worktree: wt.name)) } label: { Label("Iniciar agente aqui", systemImage: "sparkles") }
                            if wt.main != true { Button(role: .destructive) { removing = wt } label: { Label("Remover worktree", systemImage: "archivebox") } }
                        }
                    }
                } header: { SectionHeader(title: "Worktrees", count: loc.worktrees?.count) }
            } else {
                EmptyState(symbol: "folder", title: "Projeto não encontrado").listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await reload() }
        .pierBackground()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .banner($message)
        .task { await reload() }
        .onChange(of: location?.worktrees) { Task { await reload() } }
        .onChange(of: conn?.sessions) { Task { await reload() } }
        .sheet(isPresented: $newWorktree) {
            if let loc = location {
                NewWorktreeSheet(box: route.box, location: loc) { wt in
                    message = BannerMessage(text: String(localized: "Worktree “\(wt.name)” criada."), kind: .success)
                }
            }
        }
        .sheet(item: $removing) { wt in
            RemoveWorktreeSheet(box: route.box, location: route.location, worktree: wt.name,
                                changes: status(wt).map { $0.changed + $0.untracked } ?? 0,
                                sessions: location.map { sessionCount($0, wt) } ?? 0) { msg in
                message = msg
                Task { await reload() }
            }
        }
    }

    private func status(_ wt: Worktree) -> WorktreeStatus? { statuses.first { $0.path == wt.path } ?? statuses.first { $0.name == wt.name } }

    private func sessionCount(_ loc: Location, _ wt: Worktree) -> Int {
        guard let conn else { return 0 }
        let ref = loc.ref(wt)
        return conn.sessions.filter { !$0.exited && $0.location == ref }.count
    }

    private func reload() async {
        guard let conn else { return }
        if let s = try? await conn.client.worktreeStatuses(location: route.location) { statuses = s }
        loaded = true
    }

    @ViewBuilder private func header(_ loc: Location) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ProjectGlyph(name: name, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
                    if let slug = loc.slug { Text(slug).font(.subheadline).foregroundStyle(Theme.textDim) }
                }
            }
            if let remote = loc.remote { infoLine("link", remote) }
            if let d = loc.defaultBranch { infoLine("arrow.triangle.branch", String(localized: "branch padrão: \(d)")) }
            infoLine("folder", loc.path)
            if route.box.isEmpty == false, model.boxes.count > 1 { infoLine("shippingbox", route.box) }
            CountPills(counts: conn?.agentCounts(location: loc.name) ?? [:])
        }
        .padding(.vertical, 4)
    }

    private func infoLine(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.caption).foregroundStyle(Theme.textFaint).frame(width: 16)
            Text(text).font(.mono(12)).foregroundStyle(Theme.textDim).textSelection(.enabled)
        }
    }
}


struct WorktreeRow: View {
    let wt: Worktree
    let status: WorktreeStatus?
    let sessions: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(wt.name).font(.body.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                if wt.main == true { Text("principal").font(.caption2.weight(.semibold)).foregroundStyle(Theme.textDim)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.cardRaised, in: Capsule()) }
            }
            if let b = wt.branch ?? status?.branch { MonoText(b, size: 12) }
            WorktreeIndicators(status: status, worktree: wt, sessions: sessions)
        }
        .padding(.vertical, 3)
    }
}
