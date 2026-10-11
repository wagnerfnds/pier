import SwiftUI
import PierKit

/// Alterações: the worktree's review side by side. On the left the branch against its base, the pull request, the
/// actions (Aprovar: commit / push / PR with the AI draft; ask the agent for changes; discard) and the changed files,
/// uncommitted first, then what the branch's commits changed; on the right the patch of the file picked.
struct ChangesPane: View {
    let ref: WorkspaceRef
    let store: ReviewStore
    var onOpenFile: (String) -> Void

    @Environment(\.openURL) private var openURL
    @Environment(Router.self) private var router
    @State private var picked: Picked?
    @State private var showApprove = false
    @State private var showSendBack = false
    @State private var confirmDiscard = false
    @State private var confirmDiscard2 = false
    @State private var result: ReviewStore.ActionResult?
    @State private var busy = false
    @State private var wrap = false

    struct Picked: Hashable {
        let path: String
        let committed: Bool
    }

    var body: some View {
        Group {
            if let item = store.item {
                SplitPane(key: "workspace.changes", initial: 320, minLeading: 240, minTrailing: 380) {
                    list(item)
                } trailing: {
                    diff(item)
                }
            } else if store.loading {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyState(symbol: "exclamationmark.triangle", title: "Não foi possível carregar",
                           message: store.error.map { LocalizedStringKey($0) } ?? "Tente novamente.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: store.item) { _, item in keepPick(item) }
        .onAppear { keepPick(store.item) }
        .sheet(isPresented: $showApprove) { ApproveSheet(store: store) { result = $0 } }
        .sheet(isPresented: $showSendBack) { SendBackSheet(store: store) {} }
        // Twice, as on the review screen: nothing brings the files back.
        .confirmationDialog("Descartar mudanças?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Continuar", role: .destructive) { confirmDiscard2 = true }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("Todas as alterações não commitadas deste worktree serão perdidas.") }
        .alert("Tem certeza?", isPresented: $confirmDiscard2) {
            Button("Descartar tudo", role: .destructive) {
                Task { busy = true; result = await store.discard(); busy = false }
            }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("Isso apaga arquivos novos e reverte os modificados. Não dá para desfazer.") }
    }

    /// Keep the picked file while it is still changed; otherwise the first one.
    private func keepPick(_ item: ReviewItem?) {
        guard let item else { return }
        let all = item.files.map { Picked(path: $0.path, committed: false) } + item.committed.map { Picked(path: $0.path, committed: true) }
        if let p = picked, all.contains(p) { return }
        picked = all.first
    }

    // MARK: left

    private func list(_ item: ReviewItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                summary(item)
                if let r = result { resultCard(r) }
                if let pr = store.pr { prRow(pr) }
                actions(item)
                if !item.files.isEmpty { section("Não commitadas", files: item.files, committed: false) }
                if !item.committed.isEmpty { section("Commits na branch", files: item.committed, committed: true) }
                if item.files.isEmpty && item.committed.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.seal").font(.title2).foregroundStyle(Theme.green)
                        Text("Sem mudanças").font(.headline).foregroundStyle(Theme.text)
                        Text("Esta worktree está limpa em relação a \(GitActions.baseBranch(item)).")
                            .font(.subheadline).foregroundStyle(Theme.textDim).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
                }
            }
            .padding(12)
        }
        .background(Theme.card)
        .refreshable { await store.load() }
    }

    private func summary(_ item: ReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.textDim)
                Text(item.branch ?? "—").font(.mono(Density.small + 1, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(Theme.textFaint)
                Text(GitActions.baseBranch(item)).font(.mono(Density.small + 1)).foregroundStyle(Theme.textDim).lineLimit(1)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                if item.baseAhead > 0 { Pill(text: item.baseAhead == 1 ? String(localized: "1 commit à frente") : String(localized: "\(item.baseAhead) commits à frente"), color: Theme.accent) }
                if item.ahead > 0 { Pill(text: "↑\(item.ahead)", color: Theme.green) }
                if item.behind > 0 { Pill(text: "↓\(item.behind)", color: Theme.orange) }
                if item.added + item.removed > 0 { PlusMinus(added: item.added, removed: item.removed, size: Density.small) }
            }
        }
    }

    private func actions(_ item: ReviewItem) -> some View {
        HStack(spacing: 8) {
            Button { showApprove = true } label: {
                HStack(spacing: 5) {
                    if busy { ProgressView().controlSize(.mini).tint(.white) }
                    Text("Aprovar…")
                }
                .font(.system(size: Density.text - 1, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: Density.row + 2)
                .background(store.hasWork ? Theme.green : Theme.washStrong, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .foregroundStyle(store.hasWork ? .white : Theme.textDim)
            }
            .buttonStyle(.plain)
            .disabled(!store.hasWork || busy)
            .help("Commit, enviar e abrir PR")
            .accessibilityIdentifier("changes-approve")
            Menu {
                if store.sessionName != nil {
                    Button { showSendBack = true } label: { Label("Pedir ajustes ao agente", systemImage: "arrow.uturn.backward") }
                }
                Button { Task { await store.load() } } label: { Label("Atualizar", systemImage: "arrow.clockwise") }
                Divider()
                Button(role: .destructive) { confirmDiscard = true } label: { Label("Descartar alterações…", systemImage: "trash") }
                    .disabled(item.files.isEmpty)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: Density.text - 1, weight: .semibold))
                    .frame(width: Density.row + 8, height: Density.row + 2)
                    .background(Theme.washStrong, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .foregroundStyle(Theme.text)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Mais ações")
        }
    }

    private func prRow(_ pr: PullRequest) -> some View {
        Button {
            if let u = pr.url, let ref = PRCommands.parseURL(u) {
                router.push(PullRequestRoute(box: self.ref.box, repo: ref.repo, number: ref.number, title: pr.title))
            } else if let u = pr.url, let url = URL(string: u) { openURL(url) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.pull").foregroundStyle(Theme.accent)
                Text("PR #\(pr.number)\(pr.title.map { " · " + $0 } ?? "")").font(.system(size: Density.text - 1, weight: .medium))
                    .foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func resultCard(_ r: ReviewStore.ActionResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(r.ok ? Theme.green : Theme.red)
                Text(r.ok ? "Concluído" : "Falhou").font(.system(size: Density.text - 1, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Button { result = nil } label: { Image(systemName: "xmark").font(.caption) }.buttonStyle(.borderless).foregroundStyle(Theme.textDim)
            }
            if !r.output.isEmpty {
                Text(r.output).font(.mono(11)).foregroundStyle(Theme.textDim).lineLimit(6).textSelection(.enabled)
            }
            if let u = r.prURL, let url = URL(string: u) {
                Button { openURL(url) } label: { Label("Abrir PR", systemImage: "arrow.up.right") }.buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background((r.ok ? Theme.green : Theme.red).opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func section(_ title: LocalizedStringKey, files: [ReviewFile], committed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: Density.small, weight: .semibold)).foregroundStyle(Theme.textDim)
                Text("\(files.count)").font(.system(size: Density.small - 1, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 4).padding(.bottom, 2)
            ForEach(files) { f in
                let p = Picked(path: f.path, committed: committed)
                Button { picked = p } label: { ChangedFileRow(file: f, selected: picked == p) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if f.code.trimmingCharacters(in: .whitespaces) != "D" {
                            Button { onOpenFile(f.path) } label: { Label("Abrir no editor", systemImage: "doc.text") }
                        }
                        Button { UIPasteboard.general.string = f.path } label: { Label("Copiar caminho", systemImage: "doc.on.doc") }
                    }
            }
        }
    }

    // MARK: right

    @ViewBuilder private func diff(_ item: ReviewItem) -> some View {
        let files = picked?.committed == true ? item.committed : item.files
        if let p = picked, let f = files.first(where: { $0.path == p.path }) {
            PatchView(box: ref.box, execLocation: store.execLocation,
                     command: p.committed ? GitActions.diffCommitted(f, base: store.base) : GitActions.diffUncommitted(f),
                     path: f.path, binary: f.binary == true, wrap: wrap) {
                HStack(spacing: 8) {
                    DiffHeader(badge: f.badge, path: f.from.map { "\($0) → \(f.path)" } ?? f.path, added: f.added, removed: f.removed)
                    Button { wrap.toggle() } label: { Image(systemName: wrap ? "text.alignleft" : "arrow.left.and.right.text.vertical") }
                        .buttonStyle(.borderless).help("Quebrar linhas").accessibilityLabel("Quebrar linhas")
                    if f.code.trimmingCharacters(in: .whitespaces) != "D" {
                        Button { onOpenFile(f.path) } label: { Image(systemName: "doc.text") }
                            .buttonStyle(.borderless).help("Abrir o arquivo no editor").accessibilityLabel("Abrir no editor")
                    }
                }
                .padding(.trailing, 12)
                .background(Theme.card)
            }
            .id("\(p.committed)/\(f.path)/\(f.added)/\(f.removed)")
        } else {
            Text("Escolha um arquivo").font(.subheadline).foregroundStyle(Theme.textFaint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ChangedFileRow: View {
    let file: ReviewFile
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            let b = file.badge
            Text(b.letter).font(.mono(Density.small, weight: .bold)).foregroundStyle(b.color)
                .frame(width: 18, height: 18)
                .background(b.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(file.name).font(.system(size: Density.text - 0.5)).foregroundStyle(Theme.text).lineLimit(1)
                if !file.dir.isEmpty || file.from != nil {
                    Text(file.from.map { "\($0) →" } ?? file.dir).font(.system(size: Density.small - 1)).foregroundStyle(Theme.textFaint)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if file.binary == true {
                Text("binário").font(.system(size: Density.small - 1)).foregroundStyle(Theme.textFaint)
            } else if file.added + file.removed > 0 {
                PlusMinus(added: file.added, removed: file.removed, size: Density.small - 1)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(selected ? Theme.accent.opacity(0.2) : hovering ? Theme.washStrong : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityIdentifier("changed-\(file.path)")
    }
}
