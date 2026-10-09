import SwiftUI
import PierKit

/// ⌘K / ⌘P: one search over what the app can do and where it can go — actions, agent sessions, projects, worktrees.
/// Arrows move, Return opens, Esc closes. Ranking: title prefix, then a word start, then anywhere, then the letters in order.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(LocalPrefs.self) private var prefs
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        enum Kind: Int { case action, session, project, worktree, request }
        let id: String
        let kind: Kind
        let title: String
        let subtitle: String?
        let symbol: String
        var shortcut: String? = nil
        var tint: Color = Theme.textDim
        let run: @MainActor () -> Void
    }

    var body: some View {
        let results = ranked()
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textDim)
                TextField("Ir para projeto, worktree, sessão ou ação…", text: $query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($focused)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .onSubmit { open(results) }
                    // The focused field gets the keys first: arrows move the selection, Esc closes.
                    .onKeyPress(.escape) { dismiss(); return .handled }
                    .onKeyPress(.downArrow) { selected = min(selected + 1, max(results.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                    .accessibilityIdentifier("palette-field")
                // Esc closes (the focused field swallows the key otherwise); the chip is also a close button.
                Button { dismiss() } label: {
                    Text("esc").font(.caption.monospaced()).foregroundStyle(Theme.textFaint)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.stroke))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Fechar")
                // ⌘Return: the query is a request for the agents, not a search (Falar routes it).
                Button { handToTalk(query) } label: { EmptyView() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .frame(width: 0, height: 0).opacity(0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            Divider().overlay(Theme.stroke)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if results.isEmpty {
                            Text("Nada encontrado").font(.subheadline).foregroundStyle(Theme.textDim).padding(16)
                        }
                        ForEach(Array(results.enumerated()), id: \.element.id) { i, item in
                            if i == 0 || results[i - 1].kind != item.kind { header(item.kind) }
                            row(item, on: i == selected)
                                .onTapGesture { selected = i; open(results) }
                        }
                    }
                    .padding(8)
                }
                .scrollIndicators(.never)
                .onChange(of: selected) { _, i in if results.indices.contains(i) { proxy.scrollTo(results[i].id) } }
            }
        }
        .frame(minWidth: 320, idealWidth: 620, maxWidth: 720, minHeight: 300, idealHeight: 460)
        .background(Theme.card)
        .onAppear { focused = true }
        .onChange(of: query) { selected = 0 }
        .onKeyPress(.downArrow) { selected = min(selected + 1, max(results.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .presentationDetents([.large])
        .presentationBackground(Theme.card)
        .presentationCornerRadius(16)
    }

    private func header(_ k: Item.Kind) -> some View {
        Text(k == .action ? "Ações" : k == .session ? "Sessões" : k == .project ? "Projetos" : k == .request ? "Falar" : "Worktrees")
            .font(.caption.weight(.semibold)).foregroundStyle(Theme.textFaint).textCase(.uppercase)
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 2)
    }

    private func row(_ item: Item, on: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbol).font(.body).foregroundStyle(item.tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.body).foregroundStyle(Theme.text).lineLimit(1)
                if let s = item.subtitle { Text(s).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if let k = item.shortcut { Text(k).font(.caption.monospaced()).foregroundStyle(Theme.textFaint) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(on ? Theme.accent.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("palette-item-\(item.id)")
    }

    private func open(_ results: [Item]) {
        guard results.indices.contains(selected) else { return }
        let item = results[selected]
        dismiss()
        // After the sheet is gone, so the navigation lands on the visible stack.
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(250)); item.run() }
    }

    // MARK: items

    private func items() -> [Item] {
        var out = PaletteActions.all(router: router, box: model.prefs.lastBox ?? model.boxes.first?.name).map { a in
            Item(id: "action-\(a.id)", kind: .action, title: a.title, subtitle: nil, symbol: a.symbol, shortcut: a.shortcut, tint: Theme.accent, run: a.run)
        }
        let multi = model.boxes.count > 1
        for c in model.boxes {
            let all = c.sessions
            for s in all where s.isAgent && !s.exited {
                guard let st = DashState(s) else { continue }
                let bs = BoxSession(box: c.name, session: s)
                var sub = [bs.placeName(prefs)]
                if let wt = bs.worktree { sub.append(wt) }
                sub.append(PaletteActions.word(st))
                if multi { sub.append(c.name) }
                let box = c.name
                out.append(Item(id: "session-\(box)/\(s.name)", kind: .session, title: DisplayNames.sessionName(s, among: all),
                                subtitle: sub.joined(separator: " · "), symbol: st.symbol, tint: st.color,
                                run: { router.openSession(box: box, session: s) }))
            }
            for l in c.locations {
                let name = prefs.displayName(box: c.name, location: l.name)
                let route = ProjectRoute(box: c.name, location: l.name)
                let box = c.name
                out.append(Item(id: "project-\(box)/\(l.name)", kind: .project, title: name,
                                subtitle: multi ? c.name : (l.name == name ? nil : l.name), symbol: "folder",
                                run: { router.select(.project(route)) }))
                out.append(Item(id: "compose-\(box)/\(l.name)", kind: .project, title: String(localized: "Nova tarefa em \(name)"),
                                subtitle: nil, symbol: "plus.bubble", tint: Theme.accent,
                                run: { router.select(.tab(.home)); router.push(ComposeRoute(box: box, location: l.name)) }))
                for w in l.worktrees ?? [] where w.main != true {
                    let wr = WorktreeRoute(box: c.name, location: l.name, worktree: w.name)
                    out.append(Item(id: "worktree-\(box)/\(l.name)/\(w.name)", kind: .worktree, title: w.name,
                                    subtitle: [name, w.branch].compactMap { $0 }.filter { $0 != w.name }.joined(separator: " · "),
                                    symbol: "arrow.triangle.branch", run: { router.select(.worktree(wr)) }))
                }
            }
        }
        return out
    }

    // MARK: Falar

    /// "> corrige o login" (or ⌘Return): the text goes to Falar, which picks the agent and asks before sending.
    private func requestItem(_ text: String) -> Item {
        Item(id: "request", kind: .request, title: String(localized: "Pedir aos agentes: “\(text)”"),
             subtitle: String(localized: "O Pier escolhe o agente e mostra antes de enviar"), symbol: "waveform", shortcut: "⌘↩",
             tint: Theme.accent, run: {
                Task { @MainActor in try? await Task.sleep(for: .milliseconds(250)); TalkCenter.shared.open(text: text, autoRoute: true) }
             })
    }

    private func handToTalk(_ raw: String) {
        var t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix(">") { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
        dismiss()
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(450)); TalkCenter.shared.open(text: t, autoRoute: !t.isEmpty) }
    }

    /// Empty query: the actions and the agents (needs you first). Otherwise the best matches, grouped by kind.
    /// A query starting with ">" is a request (only Falar); one of several words also offers Falar at the end.
    private func ranked() -> [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.hasPrefix(">") {
            let text = String(q.dropFirst()).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? [] : [requestItem(text)]
        }
        let all = items()
        if q.isEmpty {
            let sessions = all.filter { $0.kind == .session }.sorted { $0.symbol < $1.symbol }
            return all.filter { $0.kind == .action } + sessions
        }
        let scored = all.compactMap { item -> (Item, Int)? in
            let best = max(PaletteMatch.score(q, item.title), PaletteMatch.score(q, item.subtitle ?? "") / 2)
            // "Nova tarefa em …" only when its project is what was typed.
            if item.id.hasPrefix("compose-"), PaletteMatch.score(q, item.title) < 40 { return nil }
            return best > 0 ? (item, best) : nil
        }
        // Groups stay together, ordered by their best match (typing a worktree's name puts Worktrees first).
        var best: [Item.Kind: Int] = [:]
        for (item, score) in scored { best[item.kind] = max(best[item.kind] ?? 0, score) }
        return scored.sorted { a, b in
            if a.0.kind != b.0.kind {
                let (x, y) = (best[a.0.kind] ?? 0, best[b.0.kind] ?? 0)
                return x != y ? x > y : a.0.kind.rawValue < b.0.kind.rawValue
            }
            return a.1 != b.1 ? a.1 > b.1 : a.0.title < b.0.title
        }.prefix(60).map(\.0) + (q.split(separator: " ").count >= 3 ? [requestItem(q)] : [])
    }
}

/// The palette's (and the menu bar's) navigation actions.
@MainActor enum PaletteActions {
    struct Action { let id, title, symbol: String; let shortcut: String?; let run: @MainActor () -> Void }

    static func all(router: Router, box: String?) -> [Action] {
        var list: [Action] = []
        if let box {
            list.append(Action(id: "compose", title: String(localized: "Nova tarefa"), symbol: "plus.bubble", shortcut: "⌘N") { newTask(router, box: box) })
            list.append(Action(id: "chat", title: String(localized: "Nova conversa"), symbol: "bubble.left.and.text.bubble.right", shortcut: "⇧⌘N") { newChat(router, box: box) })
        }
        return list + [
            Action(id: "home", title: String(localized: "Início"), symbol: "square.grid.2x2", shortcut: "⌘1") { router.select(.tab(.home)) },
            Action(id: "inbox", title: String(localized: "Inbox"), symbol: "tray", shortcut: "⌘2") { router.select(.tab(.inbox)) },
            Action(id: "board", title: String(localized: "Quadro de agentes"), symbol: "rectangle.split.3x1", shortcut: "⌘3") { router.select(.tab(.board)) },
            Action(id: "projects", title: String(localized: "Projetos"), symbol: "folder", shortcut: "⌘4") { router.select(.tab(.projects)) },
            Action(id: "talk", title: String(localized: "Falar com os agentes…"), symbol: "waveform", shortcut: "⇧⌘Space") {
                // After the palette's own sheet is gone: two sheets on the same view cannot overlap.
                Task { @MainActor in try? await Task.sleep(for: .milliseconds(250)); TalkCenter.shared.open() }
            },
            Action(id: "faxina", title: String(localized: "Faxina"), symbol: "sparkles", shortcut: nil) { open(HousekeepingRoute(), router) },
            Action(id: "settings", title: String(localized: "Ajustes"), symbol: "gearshape", shortcut: "⌘,") { router.select(.tab(.settings)) },
            Action(id: "addbox", title: String(localized: "Adicionar box"), symbol: "plus.circle", shortcut: nil) {
                router.select(.tab(.settings)); router.showAddBox = true
            },
        ]
    }

    static func newTask(_ router: Router, box: String) { router.select(.tab(.home)); router.push(ComposeRoute(box: box)) }
    /// The New task screen set to a chat: an agent tied to no project.
    static func newChat(_ router: Router, box: String) { router.select(.tab(.home)); router.push(ComposeRoute(box: box, chat: true)) }

    static func word(_ s: DashState) -> String {
        switch s {
        case .needsYou: String(localized: "Precisa de você")
        case .working: String(localized: "Trabalhando")
        case .done: String(localized: "Sua vez")
        case .ready: String(localized: "Pronto")
        }
    }
    static func open<R: Hashable>(_ route: R, _ router: Router) { router.select(.tab(.home)); router.push(route) }
}

enum PaletteMatch {
    /// 0 = no match. Prefix 100, word start 70, substring 40, letters in order 10 (+ closeness).
    static func score(_ q: String, _ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let t = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let q = q.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        if t.hasPrefix(q) { return 100 }
        if let r = t.range(of: q) {
            let before = r.lowerBound == t.startIndex ? " " : t[t.index(before: r.lowerBound)]
            return " -_/·.".contains(before) ? 70 : 40
        }
        var i = t.startIndex, gaps = 0
        for ch in q {
            guard let f = t[i...].firstIndex(of: ch) else { return 0 }
            gaps += t.distance(from: i, to: f); i = t.index(after: f)
        }
        return max(1, 10 - gaps / 4)
    }
}
