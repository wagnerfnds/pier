import SwiftUI
import PierKit

/// Registered in Destinations.swift under its original placeholder name.
typealias ReviewScreenPlaceholder = ReviewScreen

struct ReviewScreen: View {
    let route: ReviewRoute
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(Router.self) private var router
    @State private var store: ReviewStore
    @State private var commitsOpen = false
    @State private var showApprove = false
    @State private var showSendBack = false
    @State private var confirmDiscard = false
    @State private var confirmDiscard2 = false
    @State private var banner: ReviewStore.ActionResult?
    @State private var busy = false
    @State private var diffFile: ReviewFile?

    init(route: ReviewRoute) {
        self.route = route
        _store = State(initialValue: ReviewStore(route: route))
    }

    var body: some View {
        Group {
            if let item = store.item {
                content(item)
            } else if store.loading {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyState(symbol: "exclamationmark.triangle", title: "Não foi possível carregar",
                           message: store.error.map { LocalizedStringKey($0) } ?? "Tente novamente.")
                    .frame(maxHeight: .infinity)
            }
        }
        .pierBackground()
        .navigationTitle(route.worktree)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $diffFile) { f in
            DiffScreen(box: route.box, execLocation: store.execLocation, base: store.base, file: f, committed: false)
        }
        .task {
            store.bind(model)
            await store.load()
            #if DEBUG
            let d = UserDefaults.standard
            try? await Task.sleep(for: .seconds(1))
            if let n = d.string(forKey: "dbgDiff").flatMap(Int.init), let f = store.item?.files[safe: n] { diffFile = f }
            if let a = d.string(forKey: "dbgAct") {
                busy = true
                switch a {
                case "commit": banner = await store.approve(message: "Add hello and notes", push: false, openPR: nil)
                case "push": banner = await store.approve(message: "x", push: true, openPR: nil)
                case "pr": banner = await store.approve(message: "x", push: true, openPR: ("Titulo", "Corpo", "main"))
                default: banner = await store.discard()
                }
                busy = false
            }
            if let n = d.string(forKey: "dbgSheet") { if n == "approve" { showApprove = true } else if n == "back" { showSendBack = true } }
            #endif
        }
        .task {
            // Live: refresh when the agent or worktree changes.
            for await h in model.hub.subscribe() where h.box == route.box {
                let t = h.event.type
                if t.hasPrefix("agent.") || t.hasPrefix("worktree.") { await store.load() }
            }
        }
        .refreshable { await store.load() }
        .sheet(isPresented: $showApprove) {
            ApproveSheet(store: store) { res in
                banner = res
            }
        }
        .sheet(isPresented: $showSendBack) {
            SendBackSheet(store: store) { dismiss() }
        }
        .confirmationDialog("Descartar mudanças?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Continuar", role: .destructive) { confirmDiscard2 = true }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Todas as alterações não commitadas deste worktree serão perdidas.")
        }
        .alert("Tem certeza?", isPresented: $confirmDiscard2) {
            Button("Descartar tudo", role: .destructive) {
                Task {
                    busy = true
                    banner = await store.discard()
                    busy = false
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Isso apaga arquivos novos e reverte os modificados. Não dá para desfazer.")
        }
    }

    // MARK: content

    private func content(_ item: ReviewItem) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                if let banner { resultBanner(banner) }
                summary(item)
                if let pr = store.pr { prCard(pr) }
                if !item.commits.isEmpty { commits(item) }
                if !item.files.isEmpty {
                    fileSection("Alterações não commitadas", files: item.files, committed: false, item: item)
                }
                if !item.committed.isEmpty {
                    fileSection("Commits na branch", files: item.committed, committed: true, item: item)
                }
                if item.files.isEmpty && item.committed.isEmpty {
                    EmptyState(symbol: "checkmark.seal", title: "Sem mudanças",
                               message: "Este worktree está limpo em relação a \(GitActions.baseBranch(item)).")
                }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 120)
        }
        .safeAreaInset(edge: .bottom) { actionBar(item) }
    }

    private func summary(_ item: ReviewItem) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if !item.agent.isEmpty { AgentGlyph(agent: item.agent, size: 34) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(item.location) / \(item.worktree)").font(.headline).foregroundStyle(Theme.text)
                        if !item.agent.isEmpty {
                            Text(DisplayNames.agentLabel(item.agent)).font(.footnote).foregroundStyle(Theme.textDim)
                        }
                    }
                    Spacer()
                    if item.added + item.removed > 0 { PlusMinus(added: item.added, removed: item.removed) }
                }
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").font(.caption).foregroundStyle(Theme.textDim)
                    MonoText(item.branch ?? "—", size: 13, color: Theme.text)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(Theme.textFaint)
                    MonoText(GitActions.baseBranch(item), size: 13)
                }
                .lineLimit(1)
                HStack(spacing: 8) {
                    if item.baseAhead > 0 { Pill(text: "\(item.baseAhead) commit\(item.baseAhead == 1 ? "" : "s") à frente", color: Theme.accent) }
                    if item.ahead > 0 { Pill(text: "↑\(item.ahead)", color: Theme.green) }
                    if item.behind > 0 { Pill(text: "↓\(item.behind)", color: Theme.orange) }
                    if !item.files.isEmpty { Pill(text: "\(item.files.count) arquivo\(item.files.count == 1 ? "" : "s") pendente\(item.files.count == 1 ? "" : "s")", color: Theme.gray) }
                }
            }
        }
    }

    private func prCard(_ pr: PullRequest) -> some View {
        Button {
            // The PR screen (checks, reviews, merge…); without a parsable URL, the browser.
            if let u = pr.url, let ref = PRCommands.parseURL(u) {
                router.push(PullRequestRoute(box: route.box, repo: ref.repo, number: ref.number, title: pr.title))
            } else if let u = pr.url, let url = URL(string: u) { openURL(url) }
        } label: {
            Card(tint: Theme.accent) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.pull").foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("PR #\(pr.number)\(pr.title.map { " · " + $0 } ?? "")").font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text).lineLimit(2)
                        HStack(spacing: 6) {
                            Pill(text: prState(pr), color: prColor(pr))
                            if let d = pr.reviewDecision, !d.isEmpty { Pill(text: reviewDecision(d), color: d == "APPROVED" ? Theme.green : Theme.orange) }
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.textFaint)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func prState(_ pr: PullRequest) -> String {
        if pr.isDraft == true { return String(localized: "Rascunho") }
        switch pr.state {
        case "OPEN": return String(localized: "Aberto")
        case "MERGED": return String(localized: "Mesclado")
        case "CLOSED": return String(localized: "Fechado")
        default: return pr.state
        }
    }
    private func prColor(_ pr: PullRequest) -> Color {
        if pr.isDraft == true { return Theme.gray }
        switch pr.state {
        case "OPEN": return Theme.green
        case "MERGED": return Theme.purple
        default: return Theme.red
        }
    }
    private func reviewDecision(_ d: String) -> String {
        switch d {
        case "APPROVED": String(localized: "Aprovado")
        case "CHANGES_REQUESTED": String(localized: "Ajustes pedidos")
        case "REVIEW_REQUIRED": String(localized: "Revisão pendente")
        default: d
        }
    }

    private func commits(_ item: ReviewItem) -> some View {
        Card(padding: 0) {
            DisclosureGroup(isExpanded: $commitsOpen) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(item.commits) { c in
                        Divider().overlay(Theme.stroke)
                        HStack(alignment: .top, spacing: 10) {
                            MonoText(String(c.sha.prefix(7)), size: 12, color: Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.subject).font(.subheadline).foregroundStyle(Theme.text).lineLimit(2)
                                Text("\(c.author) · \(c.when.formatted(.relative(presentation: .named)))")
                                    .font(.caption).foregroundStyle(Theme.textDim)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                    }
                }
            } label: {
                HStack {
                    Label("Commits", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    Text("\(item.commits.count)").font(.footnote.monospacedDigit()).foregroundStyle(Theme.textFaint)
                }
            }
            .tint(Theme.textDim)
            .padding(14)
        }
    }

    private func fileSection(_ title: LocalizedStringKey, files: [ReviewFile], committed: Bool, item: ReviewItem) -> some View {
        VStack(spacing: 8) {
            SectionHeader(title: title, count: files.count)
            VStack(spacing: 0) {
                ForEach(Array(files.enumerated()), id: \.element.id) { i, f in
                    if i > 0 { Divider().overlay(Theme.stroke).padding(.leading, 48) }
                    NavigationLink {
                        DiffScreen(box: route.box, execLocation: store.execLocation, base: store.base, file: f, committed: committed)
                    } label: {
                        FileRow(file: f)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
        }
    }

    // MARK: actions

    private func resultBanner(_ r: ReviewStore.ActionResult) -> some View {
        Card(tint: r.ok ? Theme.green : Theme.red) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(r.ok ? Theme.green : Theme.red)
                    Text(r.ok ? "Concluído" : "Falhou").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    Button { banner = nil } label: { Image(systemName: "xmark").font(.footnote) }
                        .foregroundStyle(Theme.textDim)
                }
                if !r.output.isEmpty {
                    ScrollView(.horizontal) { MonoText(r.output, size: 11, color: Theme.text).textSelection(.enabled) }
                }
                if let u = r.prURL, let url = URL(string: u) {
                    Button { openURL(url) } label: { Label("Abrir PR", systemImage: "arrow.up.right") }
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    private func actionBar(_ item: ReviewItem) -> some View {
        HStack(spacing: 10) {
            Menu {
                if store.sessionName != nil {
                    Button { showSendBack = true } label: { Label("Pedir ajustes ao agente", systemImage: "arrow.uturn.backward") }
                }
                Button(role: .destructive) { confirmDiscard = true } label: { Label("Descartar mudanças", systemImage: "trash") }
                    .disabled(item.files.isEmpty)
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold))
                    .frame(width: 52, height: 48)
                    .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(Theme.text)
            }
            Button { showApprove = true } label: {
                HStack {
                    if busy { ProgressView().tint(.white) }
                    Text("Aprovar")
                }
            }
            .buttonStyle(PrimaryButtonStyle(color: Theme.green))
            .disabled(!store.hasWork || busy)
            .opacity(store.hasWork ? 1 : 0.4)
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }
}

// MARK: small components

struct PlusMinus: View {
    let added: Int
    let removed: Int
    var size: CGFloat = 13
    var body: some View {
        HStack(spacing: 6) {
            Text("+\(added)").foregroundStyle(Theme.green)
            Text("−\(removed)").foregroundStyle(Theme.red)
        }
        .font(.mono(size, weight: .medium))
    }
}

struct Pill: View {
    let text: String
    var color: Color = Theme.gray
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct FileRow: View {
    let file: ReviewFile
    var body: some View {
        HStack(spacing: 12) {
            let b = file.badge
            Text(b.letter).font(.mono(12, weight: .bold)).foregroundStyle(b.color)
                .frame(width: 24, height: 24)
                .background(b.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).font(.subheadline.weight(.medium)).foregroundStyle(Theme.text).lineLimit(1)
                if !file.dir.isEmpty || file.from != nil {
                    Text(file.from.map { "\($0) → " } ?? file.dir).font(.caption).foregroundStyle(Theme.textDim)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 6)
            if file.binary == true {
                Text("binário").font(.caption).foregroundStyle(Theme.textDim)
            } else if file.added + file.removed > 0 {
                PlusMinus(added: file.added, removed: file.removed, size: 12)
            }
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
