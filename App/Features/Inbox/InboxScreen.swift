import SwiftUI
import PierKit

/// The Inbox: every agent's questions and finished work across the paired boxes, in one list, keyboard first.
///
/// Cards: agents waiting for the person (permissions, menus, questions; each answer numbered, "Recomendado" when the agent
/// says so) oldest first, then finished turns not archived (the reply, line changes, Revisar, suggested next steps and a reply
/// field) newest first. Keys (hardware keyboard, iPad and Mac): J / K or ↓ / ↑ move the focus, 1–9 answer the focused card
/// (on a finished turn 1 / 2 send a suggested next step), E archives a finished turn or dismisses a question, Return opens
/// the session, R goes to the reply field (Esc leaves it). iPhone: the same cards with taps and swipes.
struct InboxScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(LocalPrefs.self) private var prefs
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var focused: String?
    @State private var focusedIndex: Int?
    /// A key was pressed: compact width shows the focus ring from then on.
    @State private var keyboardUsed = false
    @State private var visible = false
    /// What Copiar last put on the clipboard (the UI tests read it from a hidden label; they cannot read the clipboard).
    @State private var lastCopied = ""
    @FocusState private var replyFocus: String?
    private let store = InboxStore.shared
    private let signals = SessionSignals.shared

    private var regular: Bool { sizeClass == .regular }
    private let health = BoxHealthStore.shared

    var body: some View {
        let items = store.items(model: model)
        let healthCards = health.cards(model: model)
        // The keyboard's order: the boxes' cards first (a box out of reach blocks its agents), then the agents'.
        let entries = healthCards.map(InboxEntry.box) + items.map(InboxEntry.agent)
        ScrollViewReader { proxy in
            List {
                if regular, !entries.isEmpty { KeyLegend().listRowBackground(Color.clear).listRowSeparator(.hidden) }
                healthSection(healthCards)
                section(items.filter { $0.kind == .needsYou }, title: "Perguntas e permissões", color: Theme.orange)
                section(items.filter { $0.kind == .finished }, title: "Trabalho terminado", color: Theme.green)
            }
            .listStyle(.plain)
            .listSectionSpacing(.compact)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .overlay { if entries.isEmpty { empty } }
            .onChange(of: focused) { _, id in
                guard let id else { return }
                withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(id, anchor: nil) }
            }
        }
        .background { shortcuts(entries) }
        #if DEBUG
        // UI tests: which card has the keyboard focus, and `-inboxResetArchive 1` undoes archive marks a run left behind.
        .overlay(alignment: .bottomLeading) {
            Text(focused ?? "-").font(.system(size: 1)).foregroundStyle(.clear).frame(width: 2, height: 2)
                .accessibilityIdentifier("inbox-focus")
        }
        .overlay(alignment: .bottomTrailing) {
            Text(lastCopied.isEmpty ? "-" : lastCopied).font(.system(size: 1)).foregroundStyle(.clear).frame(width: 2, height: 2)
                .accessibilityIdentifier("inbox-last-copied")
        }
        .task {
            guard UserDefaults.standard.bool(forKey: "inboxResetArchive") else { return }
            prefs.resetInboxMarks()   // seen, dismissed and snoozed health cards from an earlier run
            for _ in 0..<40 where !model.boxes.allSatisfy(\.hasLoadedSessions) { try? await Task.sleep(for: .milliseconds(250)) }
            for c in model.boxes { for s in c.sessions where prefs.isClosed(box: c.name, session: s) { prefs.setClosed(false, box: c.name, session: s.name) } }
        }
        #endif
        .pierBackground()
        .navigationTitle("Inbox")
        .refreshable {
            await model.refreshAll()
            await signals.refreshBoard(model: model, force: true)
            await health.refresh(model: model, force: true)
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: entries.map(\.id), initial: true) { _, ids in
            focused = InboxRules.focus(after: focused, oldIndex: focusedIndex, in: ids)
            focusedIndex = focused.flatMap { ids.firstIndex(of: $0) }
        }
        .task {
            while !Task.isCancelled {
                await store.followUp(model: model)
                await signals.refreshBoard(model: model)
                await health.refresh(model: model)
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .task {
            for await h in model.hub.subscribe() {
                let t = h.event.type
                if t.hasPrefix("agent.") || t.hasPrefix("session.") { signals.invalidate() }
            }
        }
    }

    // MARK: list

    /// "A box precisa de você": what a box's doctor reports, each with the command to run there (BoxHealthStore).
    @ViewBuilder private func healthSection(_ cards: [BoxHealthStore.Card]) -> some View {
        if !cards.isEmpty {
            let color = cards.contains { $0.issue.severity == .fail } ? Theme.red : Theme.orange
            Section {
                ForEach(cards) { c in
                    let on = focused == c.id
                    InboxHealthCard(card: c, copy: { copyFix(c) }, snooze: { health.snooze(c, model: model) })
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Theme.accent, lineWidth: 2)
                                .opacity(on && (regular || keyboardUsed) ? 1 : 0)
                        }
                        .simultaneousGesture(TapGesture().onEnded { focused = c.id })
                        .accessibilityElement(children: .contain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityIdentifier(c.testID)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                        .id(c.id)
                        .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button { health.snooze(c, model: model) } label: { Label("Ignorar por hoje", systemImage: "clock.badge.xmark") }.tint(Theme.gray)
                        }
                }
            } header: {
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text("A box precisa de você").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textDim)
                    Text("\(cards.count)").font(.footnote.monospacedDigit()).foregroundStyle(Theme.textFaint)
                    Spacer()
                }
                .frame(maxWidth: 760).frame(maxWidth: .infinity)
                .padding(.horizontal, 4).padding(.vertical, 6)
            }
        }
    }

    /// The fix to the clipboard (a command to paste in a terminal on the box).
    private func copyFix(_ c: BoxHealthStore.Card) {
        guard let fix = c.issue.fix else { return }
        UIPasteboard.general.string = fix
        lastCopied = fix
        Haptic.impact(.light)
    }

    @ViewBuilder private func section(_ list: [InboxItem], title: LocalizedStringKey, color: Color) -> some View {
        if !list.isEmpty {
            Section {
                ForEach(list) { i in
                    card(i)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                        .id(i.id)
                        .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if i.kind == .finished {
                                Button { store.archive(i, model: model) } label: { Label("Arquivar", systemImage: "archivebox") }.tint(Theme.gray)
                            } else {
                                Button { store.dismiss(i, model: model) } label: { Label("Dispensar", systemImage: "eye.slash") }.tint(Theme.gray)
                            }
                        }
                }
            } header: {
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Theme.textDim)
                    Text("\(list.count)").font(.footnote.monospacedDigit()).foregroundStyle(Theme.textFaint)
                    Spacer()
                }
                .frame(maxWidth: 760).frame(maxWidth: .infinity)
                .padding(.horizontal, 4).padding(.vertical, 6)   // its own height: the plain list gives headers none
            }
        }
    }

    @ViewBuilder private func card(_ i: InboxItem) -> some View {
        let on = focused == i.id
        Group {
            switch i.kind {
            case .needsYou:
                InboxNeedsYouCard(entry: i, screen: signals.screens[i.id], busy: store.busy.contains(i.id),
                                  open: { open(i) }, act: { o in act(.option(o), i) })
            case .finished:
                // The reply is this turn's only once `replies` names the same turn: a session that finished again shows a
                // placeholder, never the previous turn's words (nor next steps written for them).
                let fresh = signals.replies[i.id]?.since == i.since
                InboxFinishedCard(entry: i, reply: fresh ? (signals.replyTexts[i.id] ?? signals.replies[i.id]?.text) : nil, replyPending: !fresh,
                                  change: signals.changes["\(i.item.box)/\(i.item.session.location ?? "")"],
                                  seen: prefs.isSeen(box: i.item.box, session: i.item.session),
                                  busy: store.busy.contains(i.id), replyFocus: $replyFocus,
                                  open: { open(i) }, review: review(i).map { r in { router.push(r) } },
                                  archive: { store.archive(i, model: model) }, send: { text in act(.send(text), i) },
                                  onSeen: { prefs.markSeen(box: i.item.box, session: i.item.session.name) })
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 2)
                .opacity(on && (regular || keyboardUsed) ? 1 : 0)
        }
        .simultaneousGesture(TapGesture().onEnded { focused = i.id })
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("inbox-card-\(i.kind == .needsYou ? "needs" : "done")-\(i.item.session.name)")
    }

    private var empty: some View {
        let loading = !model.boxes.allSatisfy { $0.hasLoadedSessions || $0.state != .connecting }
        return VStack(spacing: 10) {
            Image(systemName: loading ? "tray" : "checkmark.seal").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.textFaint)
            Text(loading ? "Carregando…" : "Nenhum agente esperando você").font(.headline).foregroundStyle(Theme.text)
            if !loading {
                Text("Perguntas e trabalho terminado de todos os agentes aparecem aqui.").font(.subheadline).foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("inbox-empty")
    }

    // MARK: actions

    private func open(_ i: InboxItem) {
        focused = i.id
        if i.kind == .finished { prefs.markSeen(box: i.item.box, session: i.item.session.name) }
        router.push(i.item.route)
    }

    private func act(_ a: InboxAction, _ i: InboxItem) {
        focused = i.id
        Task { await store.perform(a, on: i, model: model) }
    }

    /// The worktree to review: the session's own, or the project's main worktree for a main-checkout session.
    private func review(_ i: InboxItem) -> ReviewRoute? {
        let item = i.item
        guard !item.location.isEmpty else { return nil }
        let wt = item.worktree ?? model.connection(for: item.box)?.location(named: item.location)?.worktrees?.first { $0.main == true }?.name ?? item.location
        return ReviewRoute(box: item.box, location: item.location, worktree: wt, session: item.session.name)
    }

    // MARK: keyboard

    /// Plain-key shortcuts (hardware keyboard). Off while the reply field has the keys or another screen is on top.
    private func shortcuts(_ entries: [InboxEntry]) -> some View {
        let enabled = visible && replyFocus == nil && !entries.isEmpty
        return ZStack {
            key("j") { move(+1, entries) }
            key("k") { move(-1, entries) }
            // ↓ / ↑: the List takes arrows before a SwiftUI shortcut sees them; a key command with priority does not.
            ArrowKeys(active: enabled) { d in move(d, entries) }
            ForEach(1..<10, id: \.self) { n in
                key(KeyEquivalent(Character("\(n)"))) { pick(n, entries) }
            }
            key("e") { clear(entries) }
            key(.return) {
                switch current(entries) {
                case .agent(let i)?: open(i)
                case .box(let c)?: keyboardUsed = true; focused = c.id; copyFix(c)
                case nil: break
                }
            }
            key("r") {
                keyboardUsed = true
                if case .agent(let i)? = current(entries), i.kind == .finished { replyFocus = i.id }
            }
        }
        .disabled(!enabled)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func key(_ k: KeyEquivalent, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { EmptyView() }.keyboardShortcut(k, modifiers: [])
    }

    private func current(_ entries: [InboxEntry]) -> InboxEntry? { entries.first { $0.id == focused } ?? entries.first }

    private func move(_ d: Int, _ entries: [InboxEntry]) {
        keyboardUsed = true
        guard !entries.isEmpty else { return }
        let at = entries.firstIndex { $0.id == focused } ?? (d > 0 ? -1 : entries.count)
        let next = min(max(at + d, 0), entries.count - 1)
        focused = entries[next].id
        focusedIndex = next
        Haptic.selection()
    }

    /// 1–9: an answer on a waiting card, a suggested next step on a finished one; nothing on a box's card.
    private func pick(_ n: Int, _ entries: [InboxEntry]) {
        keyboardUsed = true
        guard case .agent(let i)? = current(entries), !store.busy.contains(i.id) else { return }
        focused = i.id
        switch i.kind {
        case .needsYou:
            guard let o = InboxStore.options(for: i.item.session, screen: signals.screens[i.id]).first(where: { $0.number == n }) else { return }
            act(.option(o), i)
        case .finished:
            guard let since = i.item.session.stateSince,
                  case .ready(let replies)? = NextStepsStore.shared.phase(NextSteps.Key(box: i.item.box, session: i.item.session.name, since: since)),
                  replies.indices.contains(n - 1) else { return }
            act(.send(replies[n - 1]), i)
        }
    }

    /// E: archive a finished turn, dismiss a question, ignore a box's card for today.
    private func clear(_ entries: [InboxEntry]) {
        keyboardUsed = true
        guard let e = current(entries) else { return }
        focusedIndex = entries.firstIndex { $0.id == e.id }
        switch e {
        case .agent(let i): if i.kind == .finished { store.archive(i, model: model) } else { store.dismiss(i, model: model) }
        case .box(let c): health.snooze(c, model: model)
        }
    }
}

/// One row of the Inbox, in the keyboard's order: a box's health card or an agent's card.
private enum InboxEntry: Identifiable {
    case box(BoxHealthStore.Card)
    case agent(InboxItem)
    var id: String {
        switch self {
        case .box(let c): c.id
        case .agent(let i): i.id
        }
    }
}

extension BoxHealthStore.Card {
    /// For the UI tests: "inbox-health-Agents.Codex-sign-in".
    var testID: String { "inbox-health-" + issue.id.replacingOccurrences(of: "/", with: ".").replacingOccurrences(of: " ", with: "-") }
}

/// What a box needs from the person: the problem in plain words, the command to run there (with Copiar) and a way to put
/// it off for a day. Red for what blocks the box, amber for what weakens it.
private struct InboxHealthCard: View {
    let card: BoxHealthStore.Card
    let copy: () -> Void
    let snooze: () -> Void
    @State private var copied = false

    private var tint: Color { card.issue.severity == .fail ? Theme.red : Theme.orange }

    var body: some View {
        InboxCardShell(tint: tint) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: card.issue.severity == .fail ? "exclamationmark.octagon.fill" : "wrench.and.screwdriver.fill")
                        .font(.body).foregroundStyle(tint).frame(width: 30, height: 30)
                        .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(HealthWords.title(card)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        if let body = HealthWords.body(card) {
                            Text(body).font(.footnote).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                        }
                        if let detail = HealthWords.detail(card) {
                            Text(detail).font(.caption).foregroundStyle(Theme.textFaint).lineLimit(3)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if let fix = card.issue.fix {
                    HStack(alignment: .center, spacing: 8) {
                        if HealthWords.fixIsCommand(fix) {
                            Text(fix).font(.mono(12.5)).foregroundStyle(Theme.text).lineLimit(3).textSelection(.enabled)
                                .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        } else {
                            Text(fix).font(.footnote).foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button {
                            copy()
                            withAnimation(.snappy) { copied = true }
                            Task { try? await Task.sleep(for: .seconds(1.6)); withAnimation(.snappy) { copied = false } }
                        } label: {
                            Label(copied ? "Copiado" : "Copiar", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(InboxPillStyle(color: copied ? Theme.green : Theme.accent))
                        .accessibilityValue(copied ? fix : "")   // what went to the clipboard (the UI tests cannot read it)
                        .accessibilityIdentifier("inbox-health-copy")
                    }
                }
                HStack(spacing: 8) {
                    Button(action: snooze) { Label("Ignorar por hoje", systemImage: "clock.badge.xmark") }
                        .buttonStyle(InboxPillStyle(color: Theme.textDim))
                        .accessibilityIdentifier("inbox-health-snooze")
                    Spacer(minLength: 0)
                    Text(card.box).font(.caption.monospacedDigit()).foregroundStyle(Theme.textFaint)
                }
            }
        }
    }
}

/// "J K mover · 1 2 3 responder · E arquivar · ↩ abrir · R escrever", above the cards on a wide screen.
private struct KeyLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            hint(["J", "K"], "mover")
            hint(["1", "2", "3"], "responder")
            hint(["E"], "arquivar")
            hint(["↩"], "abrir")
            hint(["R"], "escrever")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 760).frame(maxWidth: .infinity)
        .padding(.horizontal, 18).padding(.top, 2)
        .accessibilityHidden(true)
    }

    private func hint(_ keys: [String], _ what: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { k in KeyCap(text: k) }
            Text(what).font(.caption).foregroundStyle(Theme.textFaint).padding(.leading, 2)
        }
        .fixedSize()
    }
}

/// A key drawn like a keycap ("1", "J").
struct KeyCap: View {
    let text: String
    var tint: Color = Theme.textDim
    var body: some View {
        Text(text).font(.mono(11, weight: .bold)).foregroundStyle(tint)
            .frame(minWidth: 18, minHeight: 18).padding(.horizontal, 2)
            .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.stroke))
    }
}

// MARK: cards

/// The top of every card: agent, title, project · worktree (· box), the time in this state; a tap opens the session.
private struct InboxCardHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalPrefs.self) private var prefs
    let entry: InboxItem
    var trailing: AnyView? = nil
    let open: () -> Void

    private var s: Session { entry.item.session }
    private var title: String { s.title?.nilIfEmpty ?? entry.item.worktree ?? s.name }
    private var place: String {
        var parts = [entry.item.placeName(prefs)]
        if let wt = entry.item.worktree, wt != title { parts.append(wt) }
        if model.boxes.count > 1 { parts.append(entry.item.box) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Button(action: open) {
                HStack(alignment: .top, spacing: 11) {
                    AgentGlyph(agent: s.agent, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(place).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Abre a sessão")
            .accessibilityIdentifier("inbox-open-\(s.name)")
            if let trailing { trailing }
            TimelineView(.periodic(from: .now, by: 30)) { c in
                Text(Fmt.elapsed(since: entry.since, now: c.date)).font(.caption.monospacedDigit()).foregroundStyle(Theme.textFaint)
            }
        }
    }
}

private struct InboxCardShell<Content: View>: View {
    let tint: Color
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tint.opacity(0.32), lineWidth: 1))
    }
}

/// A waiting agent: what it wants and every answer, numbered (the key that picks it).
private struct InboxNeedsYouCard: View {
    let entry: InboxItem
    let screen: String?
    let busy: Bool
    let open: () -> Void
    let act: (InboxOption) -> Void

    private var s: Session { entry.item.session }

    var body: some View {
        let options = InboxStore.options(for: s, screen: screen)
        let wording = PermissionWording.headline(agent: s.agentShortName, tool: s.ask?.tool)
        InboxCardShell(tint: Theme.orange) {
            VStack(alignment: .leading, spacing: 11) {
                InboxCardHeader(entry: entry, open: open)
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle().fill(Theme.orange).frame(width: 7, height: 7).offset(y: -1)
                    Text(s.needsYouKind == .question ? S("\(s.agentShortName) tem uma pergunta") : wording.text)
                        .font(.footnote.weight(.semibold)).foregroundStyle(Theme.orange)
                }
                if let input = s.ask?.input, !input.isEmpty {
                    if wording.mono && s.needsYouKind != .question {
                        Text(input).font(.mono(12.5)).foregroundStyle(Theme.text).lineLimit(4)
                            .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        Text(input).font(.subheadline).foregroundStyle(Theme.text).lineLimit(5).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let why = s.ask?.why, !why.isEmpty, s.needsYouKind != .question {
                    Text(why).font(.footnote).foregroundStyle(Theme.textDim).lineLimit(3)
                }
                if busy {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Enviando resposta…").font(.subheadline).foregroundStyle(Theme.textDim) }
                        .padding(.vertical, 4)
                } else if options.isEmpty {
                    HStack(spacing: 10) {
                        if screen == nil { ProgressView().controlSize(.small) }
                        Text(screen == nil ? "Lendo as opções na tela…" : "Responda na sessão.").font(.footnote).foregroundStyle(Theme.textDim)
                        Spacer(minLength: 4)
                        Button("Abrir sessão", action: open).font(.footnote.weight(.semibold)).buttonStyle(.borderless)
                    }
                } else {
                    VStack(spacing: 6) {
                        ForEach(options) { o in row(o) }
                    }
                }
            }
        }
    }

    private func row(_ o: InboxOption) -> some View {
        let color: Color = switch o.role {
        case .allow, .always: Theme.green
        case .deny: Theme.red
        case .plain: Theme.text
        }
        return Button { act(o) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                KeyCap(text: "\(o.number)", tint: o.role == .plain ? Theme.accent : color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(o.title).font(.subheadline.weight(.medium)).foregroundStyle(color).multilineTextAlignment(.leading)
                    if let d = o.detail, !d.isEmpty, d != o.title {
                        Text(d).font(.caption).foregroundStyle(Theme.textDim).lineLimit(2).multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 6)
                if o.recommended {
                    Text("Recomendado").font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.15), in: Capsule())
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(o.recommended ? Theme.accent.opacity(0.45) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(o.recommended ? "\(o.title), recomendado" : o.title))
        .accessibilityHint(o.detail ?? "")
        .accessibilityIdentifier("inbox-option-\(o.number)")
    }
}

/// A finished turn: the reply (folded), the line changes, Revisar, the suggested next steps and a reply field.
private struct InboxFinishedCard: View {
    @Environment(AppModel.self) private var model
    let entry: InboxItem
    let reply: String?
    /// The reply of this turn has not been read yet (a placeholder, not the previous turn's words).
    var replyPending = false
    let change: SessionSignals.LineChange?
    /// Looked at already (the session, or the reply opened here): the badge no longer counts it.
    var seen = false
    let busy: Bool
    var replyFocus: FocusState<String?>.Binding
    let open: () -> Void
    let review: (() -> Void)?
    let archive: () -> Void
    let send: (String) -> Void
    /// The person opened the reply: it counts as seen.
    var onSeen: () -> Void = {}
    @State private var expanded = false
    @State private var text = ""

    private var s: Session { entry.item.session }
    private var long: Bool { (reply?.count ?? 0) > 320 || (reply?.split(separator: "\n").count ?? 0) > 6 }

    private var trailing: AnyView? {
        guard change != nil || seen else { return nil }
        return AnyView(HStack(spacing: 8) {
            if let change { PlusMinus(added: change.added, removed: change.removed, size: 12) }
            if seen {
                Image(systemName: "eye").font(.caption2).foregroundStyle(Theme.textFaint)
                    .accessibilityLabel("Visto")
                    .accessibilityIdentifier("inbox-seen")
            }
        })
    }

    var body: some View {
        InboxCardShell(tint: Theme.green) {
            VStack(alignment: .leading, spacing: 12) {
                InboxCardHeader(entry: entry, trailing: trailing, open: open)
                replyView
                if let since = s.stateSince, !replyPending {
                    NextStepChips(key: NextSteps.Key(box: entry.item.box, session: s.name, since: since), place: s.execPlace, reply: reply,
                                  task: s.title, client: model.client(for: entry.item.box), numbered: true, disabled: busy,
                                  heading: "Próximos passos", recipient: s.agentShortName) { text in send(text); return nil }
                }
                replyField
                HStack(spacing: 8) {
                    if let review {
                        Button(action: review) { Label("Revisar", systemImage: "doc.text.magnifyingglass") }
                            .buttonStyle(InboxPillStyle(color: Theme.accent))
                            .accessibilityIdentifier("inbox-review")
                    }
                    Button(action: archive) { Label("Arquivar", systemImage: "archivebox") }
                        .buttonStyle(InboxPillStyle(color: Theme.textDim))
                        .accessibilityIdentifier("inbox-archive")
                    Spacer(minLength: 0)
                    if busy { ProgressView().controlSize(.small) }
                }
            }
        }
    }

    @ViewBuilder private var replyView: some View {
        if let reply, !reply.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                MarkdownView(text: reply)
                    .font(.subheadline)
                    .frame(maxHeight: expanded || !long ? nil : 118, alignment: .top)
                    .clipped()
                    .mask {
                        if expanded || !long { Rectangle() } else {
                            LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.62), .init(color: .clear, location: 1)],
                                           startPoint: .top, endPoint: .bottom)
                        }
                    }
                if long {
                    Button {
                        withAnimation(.snappy) { expanded.toggle() }
                        if expanded { onSeen() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(expanded ? "Mostrar menos" : "Mostrar mais")
                            Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 180 : 0))
                        }
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("inbox-expand")
                }
            }
        } else if replyPending {
            ShimmerText(text: S("Lendo a resposta…"), font: .subheadline)
                .accessibilityIdentifier("inbox-reply-pending")
        } else {
            Text("Terminou a vez.").font(.subheadline).foregroundStyle(Theme.textDim)
        }
    }

    private var replyField: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField(S("Responder a \(s.agentShortName)…"), text: $text, axis: .vertical)
                .lineLimit(1...5)
                .font(.subheadline)
                .focused(replyFocus, equals: entry.id)
                .submitLabel(.send)
                .onSubmit { submit() }
                .onKeyPress(.escape) { replyFocus.wrappedValue = nil; return .handled }
                .padding(.leading, 12).padding(.vertical, 8)
                .accessibilityIdentifier("inbox-reply-field")
            Button(action: submit) {
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(canSend ? Theme.accent : Theme.textFaint, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .padding(4)
            .accessibilityLabel("Enviar")
            .accessibilityIdentifier("inbox-reply-send")
        }
        .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(replyFocus.wrappedValue == entry.id ? Theme.accent.opacity(0.45) : Theme.stroke))
    }

    private var canSend: Bool { !busy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func submit() {
        guard canSend else { return }
        let t = text
        text = ""
        replyFocus.wrappedValue = nil
        send(t)
    }
}

private struct InboxPillStyle: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(color.opacity(configuration.isPressed ? 0.22 : 0.13), in: Capsule())
            .contentShape(Capsule())
    }
}

/// ↓ / ↑ for the Inbox: a key command that asks for priority over the system's own use of the arrows (list focus and
/// keyboard scrolling), on a hidden view that holds the first responder while the Inbox has the keys.
private struct ArrowKeys: UIViewRepresentable {
    var active: Bool
    let onArrow: (Int) -> Void

    func makeUIView(context: Context) -> ArrowKeyView { ArrowKeyView() }

    func updateUIView(_ v: ArrowKeyView, context: Context) {
        v.onArrow = onArrow
        v.active = active
        if active, v.window != nil, !v.isFirstResponder {
            Task { @MainActor in v.becomeFirstResponder() }
        } else if !active, v.isFirstResponder {
            v.resignFirstResponder()
        }
    }
}

final class ArrowKeyView: UIView {
    var onArrow: ((Int) -> Void)?
    var active = false
    override var canBecomeFirstResponder: Bool { active }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if active, window != nil { becomeFirstResponder() }
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand.inputDownArrow, UIKeyCommand.inputUpArrow].map { k in
            let c = UIKeyCommand(input: k, modifierFlags: [], action: #selector(arrow(_:)))
            c.wantsPriorityOverSystemBehavior = true
            return c
        }
    }

    @objc private func arrow(_ c: UIKeyCommand) { onArrow?(c.input == UIKeyCommand.inputDownArrow ? 1 : -1) }
}
