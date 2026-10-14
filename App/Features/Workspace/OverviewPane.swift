import SwiftUI
import PierKit

/// Visão geral: the project (where it lives on the box, its remote, its default branch), its worktrees with their git
/// state (a click switches the workspace to one) and the sessions running in the worktree on screen.
struct OverviewPane: View {
    let project: Location
    let worktree: Worktree
    let ref: WorkspaceRef
    let status: WorktreeStatus?
    let sessions: [Session]
    var onNewWorktree: () -> Void
    var onRemove: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(LocalPrefs.self) private var prefs
    @State private var statuses: [WorktreeStatus] = []
    @State private var removingProject = false

    private var name: String { prefs.displayName(box: ref.box, location: project.name) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                actions
                block("Sessões nesta worktree", count: sessions.count) {
                    if sessions.isEmpty {
                        Text("Nenhuma sessão rodando aqui.").font(.system(size: Density.text - 1)).foregroundStyle(Theme.textDim).padding(12)
                    }
                    ForEach(sessions) { s in sessionRow(s) }
                }
                block("Worktrees", count: project.worktrees?.count ?? 0) {
                    ForEach(project.worktrees ?? []) { w in worktreeRow(w) }
                }
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.card)
        .task { await loadStatuses() }
        .refreshable { await loadStatuses() }
        .sheet(isPresented: $removingProject) {
            RemoveProjectSheet(box: ref.box, location: project.name) { router.select(.tab(.projects)) }
                .environment(model).environment(prefs)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ProjectGlyph(name: name, size: 46)
            VStack(alignment: .leading, spacing: 5) {
                Text(name).font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
                if let slug = project.slug { Text(slug).font(.subheadline).foregroundStyle(Theme.textDim) }
                VStack(alignment: .leading, spacing: 3) {
                    if let remote = project.remote { info("link", remote) }
                    if let d = project.defaultBranch { info("arrow.triangle.branch", String(localized: "branch padrão: \(d)")) }
                    info("folder", worktree.path)
                    if model.boxes.count > 1 { info("shippingbox", ref.box) }
                }
                .padding(.top, 2)
                if let e = status?.error, !e.isEmpty {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: Density.small)).foregroundStyle(Theme.red).textSelection(.enabled)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
            CountPills(counts: model.connection(for: ref.box)?.agentCounts(location: project.name) ?? [:])
        }
    }

    private func info(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol).font(.caption).foregroundStyle(Theme.textFaint).frame(width: 15)
            Text(text).font(.mono(11.5)).foregroundStyle(Theme.textDim).textSelection(.enabled)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { newTask(in: worktree) } label: { Label("Nova tarefa aqui", systemImage: "plus.bubble.fill") }
                .buttonStyle(.borderedProminent)
            Button(action: onNewWorktree) { Label("Nova worktree", systemImage: "arrow.triangle.branch") }
                .buttonStyle(.bordered)
            if project.repo, model.connection(for: ref.box)?.info?.has("environments") == true {
                NavigationLink(value: ProjectEnvironmentRoute(box: ref.box, location: project.name)) {
                    Label("Ambiente", systemImage: "shippingbox.and.arrow.backward")
                }
                .buttonStyle(.bordered)
            }
            if worktree.main != true {
                Button(role: .destructive, action: onRemove) { Label("Remover worktree", systemImage: "archivebox") }
                    .buttonStyle(.bordered)
                    .tint(Theme.red)
            } else if project.repo, model.connection(for: ref.box)?.info?.has("projects") == true {
                Button(role: .destructive) { removingProject = true } label: { Label("Remover projeto do disco", systemImage: "externaldrive.badge.minus") }
                    .buttonStyle(.bordered)
                    .tint(Theme.red)
            }
        }
        .controlSize(Platform.isMac ? .regular : .large)
    }

    private func block<C: View>(_ title: LocalizedStringKey, count: Int, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: Density.small, weight: .semibold)).foregroundStyle(Theme.textDim)
                Text("\(count)").font(.system(size: Density.small - 1, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textFaint)
            }
            VStack(alignment: .leading, spacing: 0) { content() }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
        }
    }

    private func sessionRow(_ s: Session) -> some View {
        Button { router.select(.session(WorktreeRoute(box: ref.box, location: project.name, worktree: worktree.name), name: s.name), session: s) } label: {
            HStack(spacing: 10) {
                AgentGlyph(agent: DisplayNames.agent(of: s), size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(DisplayNames.sessionName(s, among: model.connection(for: ref.box)?.sessions ?? [])).font(.system(size: Density.text)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(DisplayNames.agent(of: s).map(DisplayNames.agentLabel) ?? String(localized: "Terminal")).font(.system(size: Density.small)).foregroundStyle(Theme.textDim)
                }
                Spacer()
                if let st = DashState(s) { StateBadge(state: st, compact: Platform.isMac) }
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func worktreeRow(_ w: Worktree) -> some View {
        let st = statuses.first { $0.path == w.path } ?? statuses.first { $0.name == w.name }
        let ref = project.ref(w)
        let count = (model.connection(for: self.ref.box)?.sessions ?? []).filter { !$0.exited && $0.location == ref }.count
        return Button {
            if w.main == true { router.select(.project(ProjectRoute(box: self.ref.box, location: project.name))) }
            else { router.select(.worktree(WorktreeRoute(box: self.ref.box, location: project.name, worktree: w.name))) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: w.name == worktree.name ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(w.name == worktree.name ? Theme.accent : Theme.textFaint)
                WorktreeRow(wt: w, status: st, sessions: count)
                Spacer()
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { newTask(in: w) } label: { Label("Iniciar agente aqui", systemImage: "sparkles") }
            Button { UIPasteboard.general.string = w.path } label: { Label("Copiar caminho", systemImage: "doc.on.doc") }
        }
    }

    private func newTask(in w: Worktree) {
        router.select(.tab(.home))
        router.push(ComposeRoute(box: ref.box, location: project.name, worktree: w.main == true ? nil : w.name))
    }

    private func loadStatuses() async {
        guard let client = model.client(for: ref.box) else { return }
        if let s = try? await client.worktreeStatuses(location: project.name) { statuses = s }
    }
}
