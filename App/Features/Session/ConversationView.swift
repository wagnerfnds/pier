import SwiftUI
import PierKit

struct ConversationView: View {
    let vm: SessionViewModel
    @Environment(Router.self) private var router
    @State private var bottomVisible = true
    @State private var detached = false
    @State private var scrolledUp = false

    private var blocks: [ConversationBlock] { ConversationFold.blocks(vm.store.displayItems, live: vm.isRunning || vm.isWaiting) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    top(proxy)
                    ForEach(blocks) { block in
                        switch block {
                        case .item(let it):
                            TranscriptRow(vm: vm, item: it).id(it.id)
                        case .fold(let id, let steps, let live):
                            WorkFoldRow(vm: vm, id: id, steps: steps, live: live).id(id)
                        }
                    }
                    if vm.isRunning { LiveDraftRow(vm: vm).id("draft") }
                    if let card = vm.reviewCard, let (loc, wt) = vm.reviewTarget {
                        ReviewCard(changes: card.changes, uncommittedOnly: card.uncommittedOnly) {
                            router.push(ReviewRoute(box: vm.box, location: loc, worktree: wt, session: vm.name))
                        }
                        .id("review-card")
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    // Suggested replies for a finished turn (Inbox feature): only sent when the person taps one.
                    SessionNextSteps(vm: vm).id("next-steps")
                    if vm.store.displayItems.isEmpty, vm.loaded, !vm.isRunning { emptyNote }
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { bottomVisible = true; detached = false }
                        .onDisappear { bottomVisible = false }
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            .modifier(PinBottomOnGrowth())
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(DragGesture(minimumDistance: 8).onEnded { _ in
                scrolledUp = true
                Task { try? await Task.sleep(for: .milliseconds(450)); if !bottomVisible { detached = true } }
            })
            .overlay { if !vm.loaded { loading } }
            .overlay(alignment: .bottomTrailing) {
                if detached {
                    Button {
                        detached = false
                        withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down").font(.footnote.weight(.bold)).foregroundStyle(Theme.text)
                            .padding(11).background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(Theme.stroke))
                    }
                    .padding(12).transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Ir para o fim")
                }
            }
            // iOS 18+: the scroll view itself keeps the bottom pinned as content grows, only while it is at the bottom, so
            // these manual follows (which raced that and yanked a reader back down) are for iOS 17 only, without animation.
            .onChange(of: vm.store.displayItems.last?.id) { _, _ in followLegacy(proxy) }
            .onChange(of: vm.draft?.text) { _, _ in followLegacy(proxy) }
            .onChange(of: vm.session.agentState) { _, _ in followLegacy(proxy) }
            .onChange(of: vm.reviewCard?.changes) { _, _ in followLegacy(proxy) }
            .onChange(of: vm.sendTick) { _, _ in detached = false; follow(proxy) }
            .animation(.snappy, value: detached)
        }
    }

    private func follow(_ proxy: ScrollViewProxy) {
        guard !detached else { return }
        withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private func followLegacy(_ proxy: ScrollViewProxy) {
        if #available(iOS 18, *) { return }
        guard !detached else { return }
        proxy.scrollTo("bottom", anchor: .bottom)
    }

    @ViewBuilder private func top(_ proxy: ScrollViewProxy) -> some View {
        if vm.store.hasMoreBefore {
            Button {
                Task { await loadOlder(proxy) }
            } label: {
                HStack(spacing: 6) {
                    if vm.loadingOlder { ProgressView().controlSize(.small) } else { Image(systemName: "clock.arrow.circlepath").font(.caption) }
                    Text("Mensagens anteriores").font(.footnote)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .foregroundStyle(Theme.textDim)
            .onAppear { if scrolledUp { Task { await loadOlder(proxy) } } }
        } else if vm.loaded, vm.store.displayItems.count > 6 {
            HStack(spacing: 10) {
                Rectangle().fill(Theme.stroke).frame(height: 1)
                Text("Início da conversa").font(.caption2).foregroundStyle(Theme.textFaint).fixedSize()
                Rectangle().fill(Theme.stroke).frame(height: 1)
            }
            .padding(.vertical, 6)
        }
    }

    private func loadOlder(_ proxy: ScrollViewProxy) async {
        let first = vm.store.displayItems.first?.id
        await vm.loadOlder()
        if let first { proxy.scrollTo(first, anchor: .top) }
    }

    private var emptyNote: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right").font(.title2).foregroundStyle(Theme.textFaint)
            Text("Nada por aqui ainda").font(.subheadline).foregroundStyle(Theme.textDim)
            Text("As mensagens aparecem assim que o agente começar a trabalhar.").font(.caption).foregroundStyle(Theme.textFaint).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    @ViewBuilder private var loading: some View {
        if let err = vm.loadError {
            VStack(spacing: 12) {
                EmptyState(symbol: "exclamationmark.triangle", title: "Sem conversa", message: LocalizedStringKey(err))
                Button("Ver terminal") { vm.setMode(.terminal) }.buttonStyle(SecondaryButtonStyle()).frame(width: 180)
            }
        } else {
            VStack(spacing: 10) {
                ProgressView().controlSize(.large).tint(Theme.accent)
                Text("Abrindo a conversa…").font(.footnote).foregroundStyle(Theme.textDim)
            }
        }
    }
}

/// The reply being written right now and an alive "working" line: the agent's own status word (Brewing…), its current
/// step read from the screen, and the time on this turn.
struct LiveDraftRow: View {
    let vm: SessionViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let t = vm.draft?.text, !t.isEmpty { MarkdownView(text: t, draft: true) }
            HStack(spacing: 8) {
                PulsingDot()
                ShimmerText(text: word)
                if let step = vm.step, !step.isEmpty, step != StepText.thinking || vm.draft?.status == nil {
                    Text("· \(step)").font(.footnote).foregroundStyle(Theme.textFaint).lineLimit(1)
                }
                Spacer(minLength: 4)
                TimelineView(.periodic(from: .now, by: 1)) { c in
                    Text(Fmt.elapsed(since: vm.session.stateSince, now: c.date)).font(.caption.monospacedDigit()).foregroundStyle(Theme.textFaint)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var word: String {
        if let w = vm.draft?.status?.word, !w.isEmpty { return w.hasSuffix("…") ? w : w + "…" }
        return S("Trabalhando…")
    }
}

struct PulsingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Circle().fill(Theme.accent).frame(width: 8, height: 8)
            .phaseAnimator(reduceMotion ? [1.0] : [1.0, 0.35]) { v, phase in v.opacity(phase).scaleEffect(phase == 1 ? 1 : 0.8) }
                animation: { _ in .easeInOut(duration: 0.9) }
    }
}

/// Conversation-style view of an agent with no record the box can read (or a plain terminal program): the last thing on
/// its screen, rendered calmly, with a way into the terminal.
struct ConversationFallback: View {
    let vm: SessionViewModel

    private var lastMessage: String {
        MenuParser.lastMessage(TerminalText.clean(vm.screen)).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(Theme.textDim)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(vm.session.isAgent ? "Sem registro de conversa" : "Sessão de terminal").font(.footnote.weight(.semibold)).foregroundStyle(Theme.text)
                        Text(reason).font(.caption).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
                if let p = vm.session.title, !p.isEmpty, vm.session.isAgent {
                    UserBubble(item: TranscriptItem(kind: "user", id: "prompt", text: p), agent: vm.session.agentShortName)
                }
                if !lastMessage.isEmpty {
                    MarkdownView(text: lastMessage).contextMenu { CopyButton(text: lastMessage) }
                } else if vm.screenLoaded {
                    Text("A tela do agente está vazia por enquanto.").font(.footnote).foregroundStyle(Theme.textFaint)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if vm.isRunning { LiveDraftRow(vm: vm) }
                Button { vm.setMode(.terminal) } label: { Label("Ver terminal completo", systemImage: "terminal") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var reason: String {
        if !vm.session.isAgent { return S("Esta sessão roda um programa comum; abaixo está o que a tela mostra.") }
        if let r = vm.store.reason, !r.isEmpty { return S("A box não encontrou o registro deste agente (\(r)). Abaixo, a última mensagem lida da tela.") }
        return S("A box não encontrou o registro deste agente. Abaixo, a última mensagem lida da tela.")
    }
}

/// End of a finished turn that changed files: what changed, and the way into the review.
struct ReviewCard: View {
    let changes: TurnChanges
    let uncommittedOnly: Bool
    let action: () -> Void

    private var title: String {
        let n = changes.files
        if uncommittedOnly { return n == 1 ? S("\(n) arquivo com mudanças não commitadas") : S("\(n) arquivos com mudanças não commitadas") }
        return n == 1 ? S("Alterou \(n) arquivo") : S("Alterou \(n) arquivos")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass").font(.subheadline).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Theme.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                PlusMinus(added: changes.added, removed: changes.removed, size: 12)
            }
            Spacer(minLength: 6)
            Button(action: action) {
                Text("Revisar").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Theme.accent.opacity(0.15), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("review-card-button")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
    }
}

/// Keeps the bottom in view when content grows, but only if the reader is already at the bottom (iOS 18+).
private struct PinBottomOnGrowth: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.defaultScrollAnchor(.bottom, for: .sizeChanges)
        } else {
            content
        }
    }
}
