import SwiftUI
import PierKit

/// One pull request: what it is, its checks, reviews, conversation and files (each file opens the diff viewer), and what can
/// be done with it from the phone (merge, review, comment, close, mark ready, bring it into a worktree for an agent).
struct PullRequestScreen: View {
    let route: PullRequestRoute
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.openURL) private var openURL
    @State private var store: PullRequestStore
    @State private var sheet: PRSheet?
    @State private var confirm: PullRequestStore.Action?
    @State private var banner: BannerMessage?
    @State private var busy = false
    @State private var bodyExpanded = false
    @State private var checksExpanded = false
    @State private var expandedComments: Set<String> = []
    /// Set by the worktree sheet when it started an agent: opened once the sheet is gone.
    @State private var startedSession: (box: String, session: Session)?

    init(route: PullRequestRoute) {
        self.route = route
        _store = State(initialValue: PullRequestStore(route: route))
    }

    var body: some View {
        Group {
            if let pr = store.pr {
                content(pr)
            } else if store.loading {
                VStack(spacing: 12) {
                    ProgressView().tint(Theme.accent)
                    if let t = route.title { Text(t).font(.subheadline).foregroundStyle(Theme.textDim).multilineTextAlignment(.center) }
                }
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let e = store.error {
                let h = ghHint(e)
                HomeEmpty(symbol: "exclamationmark.triangle", title: h.title, hint: h.hint, color: Theme.orange)
                    .padding(24).frame(maxHeight: .infinity)
            }
        }
        .pierBackground()
        .navigationTitle(Text(verbatim: "#\(route.number)"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { open(store.pr?.url ?? "https://github.com/\(route.repo)/pull/\(route.number)") } label: {
                    Image(systemName: "safari")
                }
                .accessibilityLabel(Text("Abrir no GitHub"))
            }
        }
        .banner($banner)
        .task {
            store.bind(model)
            await store.load()
        }
        .refreshable { await store.load() }
        .sheet(item: $sheet, onDismiss: openStartedSession) { s in
            switch s {
            case .merge: PRMergeSheet(store: store, onDone: done)
            case .review(let kind): PRReviewSheet(store: store, kind: kind, onDone: done)
            case .worktree:
                PRWorktreeSheet(store: store) { box, session in startedSession = (box, session) } openWorktree: { box, loc, wt in
                    sheet = nil
                    router.push(WorktreeRoute(box: box, location: loc, worktree: wt))
                }
            }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible, presenting: confirm) { action in
            Button(action == .close ? S("Fechar PR") : S("Marcar como pronto"), role: action == .close ? .destructive : nil) {
                Task { await run(action) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: { action in
            Text(action == .close ? S("O PR é fechado sem mesclar. Dá para reabrir no GitHub.") : S("Os revisores pedidos são avisados."))
        }
    }

    private var confirmTitle: String {
        confirm == .close ? S("Fechar o PR #\(route.number)?") : S("Marcar o PR #\(route.number) como pronto para revisão?")
    }

    private func open(_ s: String) { if let u = URL(string: s) { openURL(u) } }

    private func done(_ action: PullRequestStore.Action) { banner = BannerMessage(text: action.done, kind: .success) }

    private func run(_ action: PullRequestStore.Action) async {
        busy = true
        let r = await store.run(action)
        busy = false
        banner = r.ok ? BannerMessage(text: action.done, kind: .success)
            : BannerMessage(text: r.output.isEmpty ? S("O gh falhou sem dizer por quê.") : String(r.output.suffix(300)), kind: .error)
    }

    private func openStartedSession() {
        guard let s = startedSession else { return }
        startedSession = nil
        router.push(SessionRoute(box: s.box, session: s.session))
    }

    // MARK: content

    private func content(_ pr: PRDetail) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                header(pr)
                if pr.isOpen { bringCard(pr) }
                description(pr)
                if !pr.checks.isEmpty { checks(pr) }
                reviews(pr)
                if !pr.conversation.isEmpty { conversation(pr) }
                if !pr.files.isEmpty { files(pr) }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 120)
        }
        .safeAreaInset(edge: .bottom) { if pr.isOpen { actionBar(pr) } }
    }

    private func header(_ pr: PRDetail) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(verbatim: "\(route.repo)#\(pr.number)").font(.mono(12)).foregroundStyle(Theme.textDim).lineLimit(1)
                    Spacer(minLength: 6)
                    Pill(text: stateText(pr), color: stateColor(pr))
                }
                Text(pr.title).font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .accessibilityIdentifier("pr-title")
                HStack(spacing: 6) {
                    if let a = pr.author { Text(verbatim: "@\(a.login)").font(.subheadline.weight(.medium)).foregroundStyle(Theme.text) }
                    if let d = pr.createdAt { Text(verbatim: "· \(S("aberto há \(Age.short(d))"))").font(.subheadline).foregroundStyle(Theme.textDim) }
                }
                .lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").font(.caption).foregroundStyle(Theme.textDim)
                    MonoText(pr.baseRefName, size: 12, color: Theme.text)
                    Image(systemName: "arrow.left").font(.caption2).foregroundStyle(Theme.textFaint)
                    MonoText(pr.isCrossRepository ? "\(pr.headOwner ?? "?"):\(pr.headRefName)" : pr.headRefName, size: 12, color: Theme.text)
                        .truncationMode(.middle)
                }
                .lineLimit(1)
                HStack(spacing: 10) {
                    PlusMinus(added: pr.additions, removed: pr.deletions, size: 12)
                    Text(S("\(pr.changedFiles) arquivo(s)")).font(.caption).foregroundStyle(Theme.textDim)
                    Spacer(minLength: 0)
                }
                if !pr.labels.isEmpty {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(pr.labels) { l in Pill(text: l.name, color: l.color.flatMap { UInt32($0, radix: 16) }.map { Color(tone: $0) } ?? Theme.gray) }
                    }
                }
                if pr.isOpen, let note = mergeNote(pr) {
                    Label(note.text, systemImage: note.symbol).font(.footnote).foregroundStyle(note.color)
                }
            }
        }
    }

    private func mergeNote(_ pr: PRDetail) -> (text: String, symbol: String, color: Color)? {
        if pr.mergeable == "CONFLICTING" || pr.mergeStateStatus == "DIRTY" {
            return (S("Tem conflitos com \(pr.baseRefName)."), "exclamationmark.triangle.fill", Theme.red)
        }
        switch pr.mergeStateStatus {
        case "BEHIND": return (S("Atrás de \(pr.baseRefName): atualize a branch antes de mesclar."), "arrow.down.circle", Theme.orange)
        case "BLOCKED": return (S("Bloqueado pelas regras da branch (revisões ou checks)."), "lock", Theme.orange)
        case "UNSTABLE": return (S("Dá para mesclar, mas há checks falhando."), "exclamationmark.circle", Theme.orange)
        case "CLEAN": return (S("Pronto para mesclar."), "checkmark.circle", Theme.green)
        default: return nil
        }
    }

    private func stateText(_ pr: PRDetail) -> String {
        if pr.isDraft && pr.isOpen { return S("Rascunho") }
        switch pr.state {
        case "OPEN": return S("Aberto")
        case "MERGED": return S("Mesclado")
        case "CLOSED": return S("Fechado")
        default: return pr.state
        }
    }
    private func stateColor(_ pr: PRDetail) -> Color {
        if pr.isDraft && pr.isOpen { return Theme.gray }
        switch pr.state {
        case "OPEN": return Theme.green
        case "MERGED": return Theme.purple
        default: return Theme.red
        }
    }

    private func bringCard(_ pr: PRDetail) -> some View {
        Button { sheet = .worktree } label: {
            Card(tint: Theme.accent) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.to.line.compact").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.accent)
                        .frame(width: 34, height: 34).background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Trazer para uma worktree").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                        Text(S("A branch \(pr.headRefName) na box, para continuar com um agente.")).font(.caption).foregroundStyle(Theme.textDim).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.textFaint)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pr-bring")
    }

    private func description(_ pr: PRDetail) -> some View {
        let text = PRCommands.cleanBody(pr.body)
        let long = text.count > 700
        return VStack(spacing: 8) {
            SectionHeader(title: "Descrição")
            Card {
                if text.isEmpty {
                    Text("Sem descrição.").font(.subheadline).foregroundStyle(Theme.textDim)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        MarkdownView(text: text)
                            .frame(maxHeight: long && !bodyExpanded ? 280 : nil, alignment: .top)
                            .clipped()
                        if long {
                            Button { withAnimation(.snappy) { bodyExpanded.toggle() } } label: {
                                Text(bodyExpanded ? S("Mostrar menos") : S("Mostrar tudo")).font(.footnote.weight(.semibold))
                            }
                        }
                    }
                }
            }
        }
    }

    private func checks(_ pr: PRDetail) -> some View {
        let list = pr.sortedChecks
        let shown = checksExpanded ? list : Array(list.prefix(6))
        let c = pr.checkCounts
        return VStack(spacing: 8) {
            SectionHeader(title: "Checks", count: list.count)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    checkIcon(pr.checkRollup == .fail ? .fail : pr.checkRollup == .pending ? .pending : .pass)
                    Text(checkSummary(c)).font(.subheadline.weight(.medium)).foregroundStyle(Theme.text)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                ForEach(shown) { ch in
                    Divider().overlay(Theme.stroke).padding(.leading, 44)
                    Button { if let u = ch.url { open(u) } } label: {
                        HStack(spacing: 10) {
                            checkIcon(ch.state)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(ch.name).font(.subheadline).foregroundStyle(Theme.text).lineLimit(1)
                                if let w = ch.workflow { Text(w).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1) }
                            }
                            Spacer(minLength: 6)
                            Text(checkLabel(ch)).font(.caption).foregroundStyle(Theme.textFaint)
                            if ch.url != nil { Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(Theme.textFaint) }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if list.count > shown.count {
                    Divider().overlay(Theme.stroke)
                    Button { withAnimation(.snappy) { checksExpanded = true } } label: {
                        Text(S("+\(list.count - shown.count) checks")).font(.footnote.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                    }
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
        }
    }

    private func checkSummary(_ c: [PRDetail.Check.State: Int]) -> String {
        var parts: [String] = []
        if let n = c[.fail], n > 0 { parts.append(S("\(n) com falha")) }
        if let n = c[.pending], n > 0 { parts.append(S("\(n) rodando")) }
        if let n = c[.pass], n > 0 { parts.append(S("\(n) ok")) }
        let other = (c[.skipped] ?? 0) + (c[.neutral] ?? 0)
        if other > 0 { parts.append(S("\(other) ignorado(s)")) }
        return parts.joined(separator: " · ")
    }

    private func checkLabel(_ ch: PRDetail.Check) -> String {
        switch ch.state {
        case .pass: S("passou")
        case .fail: ch.raw == "TIMED_OUT" ? S("tempo esgotado") : ch.raw == "CANCELLED" ? S("cancelado") : S("falhou")
        case .pending: S("rodando")
        case .skipped: S("ignorado")
        case .neutral: S("neutro")
        }
    }

    @ViewBuilder private func checkIcon(_ s: PRDetail.Check.State) -> some View {
        Group {
            switch s {
            case .pass: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
            case .fail: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.red)
            case .pending: Image(systemName: "circle.dotted").foregroundStyle(Theme.accent)
            case .skipped: Image(systemName: "arrow.uturn.right.circle").foregroundStyle(Theme.textFaint)
            case .neutral: Image(systemName: "minus.circle").foregroundStyle(Theme.textFaint)
            }
        }
        .font(.system(size: 15)).frame(width: 20)
    }

    private func reviews(_ pr: PRDetail) -> some View {
        let latest = pr.latestReviews
        return VStack(spacing: 8) {
            SectionHeader(title: "Revisões", count: latest.isEmpty ? nil : latest.count)
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    if let d = pr.reviewDecision {
                        HStack(spacing: 8) {
                            Pill(text: decisionText(d), color: decisionColor(d))
                            Spacer()
                        }
                    }
                    ForEach(latest) { r in
                        HStack(spacing: 10) {
                            reviewIcon(r.state)
                            Text(verbatim: "@\(r.author)").font(.subheadline.weight(.medium)).foregroundStyle(Theme.text).lineLimit(1)
                            Text(reviewStateText(r.state)).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(Age.short(r.submittedAt)).font(.caption).foregroundStyle(Theme.textFaint)
                        }
                    }
                    if !pr.reviewRequests.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "clock").font(.system(size: 13)).foregroundStyle(Theme.orange).frame(width: 20)
                            Text(S("Aguardando: \(pr.reviewRequests.map { "@" + $0 }.joined(separator: ", "))"))
                                .font(.subheadline).foregroundStyle(Theme.textDim)
                        }
                    }
                    if latest.isEmpty && pr.reviewRequests.isEmpty && pr.reviewDecision == nil {
                        Text("Nenhuma revisão ainda.").font(.subheadline).foregroundStyle(Theme.textDim)
                    }
                }
            }
        }
    }

    private func decisionText(_ d: String) -> String {
        switch d {
        case "APPROVED": S("Aprovado")
        case "CHANGES_REQUESTED": S("Mudanças pedidas")
        case "REVIEW_REQUIRED": S("Revisão pendente")
        default: d
        }
    }
    private func decisionColor(_ d: String) -> Color { d == "APPROVED" ? Theme.green : d == "CHANGES_REQUESTED" ? Theme.orange : Theme.gray }
    private func reviewStateText(_ s: String) -> String {
        switch s {
        case "APPROVED": S("aprovou")
        case "CHANGES_REQUESTED": S("pediu mudanças")
        case "DISMISSED": S("revisão descartada")
        default: S("comentou")
        }
    }
    private func reviewIcon(_ s: String) -> some View {
        let (sym, color): (String, Color) = switch s {
        case "APPROVED": ("checkmark.circle.fill", Theme.green)
        case "CHANGES_REQUESTED": ("exclamationmark.circle.fill", Theme.orange)
        case "DISMISSED": ("xmark.circle", Theme.textFaint)
        default: ("text.bubble", Theme.textDim)
        }
        return Image(systemName: sym).font(.system(size: 15)).foregroundStyle(color).frame(width: 20)
    }

    private func conversation(_ pr: PRDetail) -> some View {
        let list = pr.conversation
        return VStack(spacing: 8) {
            SectionHeader(title: "Conversa", count: list.count)
            ForEach(list) { c in
                let long = c.body.count > 500
                let open = expandedComments.contains(c.id)
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text(verbatim: "@\(c.author)").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                            Text(Age.short(c.createdAt)).font(.caption).foregroundStyle(Theme.textFaint)
                            Spacer()
                        }
                        MarkdownView(text: c.body)
                            .frame(maxHeight: long && !open ? 200 : nil, alignment: .top)
                            .clipped()
                        if long {
                            Button {
                                withAnimation(.snappy) { if open { expandedComments.remove(c.id) } else { expandedComments.insert(c.id) } }
                            } label: { Text(open ? S("Mostrar menos") : S("Mostrar tudo")).font(.footnote.weight(.semibold)) }
                        }
                    }
                }
            }
        }
    }

    private func files(_ pr: PRDetail) -> some View {
        VStack(spacing: 8) {
            SectionHeader(title: "Arquivos", count: pr.changedFiles)
            VStack(spacing: 0) {
                ForEach(Array(pr.files.enumerated()), id: \.element.id) { i, f in
                    if i > 0 { Divider().overlay(Theme.stroke).padding(.leading, 48) }
                    let file = ReviewFile(path: f.path, code: f.code, added: f.additions, removed: f.deletions)
                    NavigationLink {
                        DiffScreen(box: store.box ?? "", execLocation: store.execLocation ?? "", base: pr.baseRefName, file: file,
                                   committed: true, command: store.fileDiffCommand(f.path))
                    } label: {
                        FileRow(file: file)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
            if pr.changedFiles > pr.files.count {
                Text(S("Mostrando \(pr.files.count) de \(pr.changedFiles) arquivos; o resto está no GitHub."))
                    .font(.footnote).foregroundStyle(Theme.textDim).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
            }
        }
    }

    // MARK: actions

    private func actionBar(_ pr: PRDetail) -> some View {
        HStack(spacing: 10) {
            Menu {
                Button { sheet = .review(.comment) } label: { Label("Comentar", systemImage: "text.bubble") }
                Button { sheet = .review(.approve) } label: { Label("Aprovar", systemImage: "checkmark.circle") }
                Button { sheet = .review(.requestChanges) } label: { Label("Pedir mudanças", systemImage: "exclamationmark.bubble") }
                Divider()
                Button { sheet = .worktree } label: { Label("Trazer para uma worktree", systemImage: "arrow.down.to.line.compact") }
                if pr.isDraft {
                    Button { sheet = .merge } label: { Label("Mesclar", systemImage: "arrow.triangle.merge") }
                }
                Button { open(pr.url) } label: { Label("Abrir no GitHub", systemImage: "safari") }
                Divider()
                Button(role: .destructive) { confirm = .close } label: { Label("Fechar PR", systemImage: "xmark.circle") }
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold))
                    .frame(width: 52, height: 48)
                    .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(Theme.text)
            }
            .accessibilityLabel(Text("Mais ações"))
            .accessibilityIdentifier("pr-more")
            Button { sheet = .review(.approve) } label: { Text("Revisar") }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("pr-review")
            if pr.isDraft {
                Button { confirm = .ready } label: {
                    HStack { if busy { ProgressView().tint(.white) }; Text("Pronto p/ revisão").lineLimit(1).minimumScaleFactor(0.8) }
                }
                .buttonStyle(PrimaryButtonStyle(color: Theme.accent))
                .accessibilityIdentifier("pr-ready")
            } else {
                Button { sheet = .merge } label: {
                    HStack { if busy { ProgressView().tint(.white) }; Text("Mesclar") }
                }
                .buttonStyle(PrimaryButtonStyle(color: Theme.green))
                .accessibilityIdentifier("pr-merge")
            }
        }
        .disabled(busy)
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }
}

enum PRSheet: Identifiable, Hashable {
    case merge
    case review(PRReviewKind)
    case worktree
    var id: String {
        switch self {
        case .merge: "merge"
        case .review(let k): "review-\(k.rawValue)"
        case .worktree: "worktree"
        }
    }
}
