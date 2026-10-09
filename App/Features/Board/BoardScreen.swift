import SwiftUI
import PierKit

extension AgentBoard.Column {
    var title: LocalizedStringKey {
        switch self {
        case .needsYou: "Precisa de você"
        case .working: "Trabalhando"
        case .yourTurn: "Sua vez"
        case .ready: "Pronto"
        case .closed: "Encerradas"
        }
    }
    var symbol: String {
        switch self {
        case .needsYou: "hand.raised.fill"
        case .working: "waveform.path.ecg"
        case .yourTurn: "checkmark.circle"
        case .ready: "pause.circle"
        case .closed: "archivebox"
        }
    }
    var color: Color {
        switch self {
        case .needsYou: Theme.orange
        case .working: Theme.accent
        case .yourTurn: Theme.green
        case .ready: Theme.gray
        case .closed: Theme.textDim
        }
    }
    var emptyTitle: LocalizedStringKey {
        switch self {
        case .needsYou: "Nada esperando por você"
        case .working: "Nenhum agente trabalhando"
        case .yourTurn: "Nada esperando você continuar"
        case .ready: "Nenhum agente ocioso"
        case .closed: "Arraste um card para cá para arquivar"
        }
    }
}

/// The agents board (the Quadro tab / sidebar section): every agent session of every paired box in a column by state
/// (`AgentBoard`, PierKit). Live from the sessions store; the steps, background work, replies and menus come from
/// `SessionSignals`, shared with the Home. A card opens its session; its menu reviews, archives, ends or answers a
/// permission; dragging it to Encerradas archives it (and back brings it to "Sua vez").
///
/// Compact width: one column per page (~86% wide, the next one peeking) with a bar to jump between them; the bar's chips
/// also take drops. Regular width: all columns side by side, Encerradas folded to a strip until opened.
struct BoardScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalPrefs.self) private var prefs
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var filter = AgentBoard.Filter()
    @State private var page: AgentBoard.Column?
    /// The column was picked by the board (not the person): it may follow the cards as they load.
    @State private var autoPage = true
    @State private var autoChoice: AgentBoard.Column?
    @State private var closedOpen = false
    @State private var target: AgentBoard.Column?
    @State private var ending: EndTarget?
    private let signals = SessionSignals.shared

    struct EndTarget: Identifiable {
        let vm: SessionViewModel
        let title: String
        var id: String { "\(vm.box)/\(vm.name)" }
    }

    // MARK: data

    /// Every agent session (exited ones too), minus hidden projects.
    private var items: [AgentBoard.Item] {
        model.boxes.flatMap { b in b.sessions.map { AgentBoard.Item(box: b.name, session: $0) } }
            .filter { $0.session.isAgent && !prefs.isHidden(box: $0.box, location: $0.location) }
    }

    private func board(_ items: [AgentBoard.Item]) -> [AgentBoard.Column: [BoxSession]] {
        AgentBoard.build(items, filter: filter,
                         archived: { prefs.isClosed(box: $0.box, session: $0.session) },
                         background: Set(signals.background.keys),
                         names: { [prefs.displayName(box: $0.box, location: $0.location)] })
            .mapValues { $0.map { BoxSession(box: $0.box, session: $0.session) } }
    }

    private var multiBox: Bool { model.boxes.count > 1 }

    var body: some View {
        let all = items
        let cols = board(all)
        GeometryReader { geo in
            // Side by side needs room for four lanes of ~220 pt; a portrait iPad pages two lanes at a time instead.
            if sizeClass == .regular && geo.size.width >= 960 {
                regular(cols)
            } else {
                compact(cols, fraction: sizeClass == .regular ? 0.47 : 0.86)
            }
        }
        .pierBackground()
        .navigationTitle("Quadro")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter.text, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Buscar agentes"))
        .toolbar { ToolbarItem(placement: .topBarTrailing) { filterMenu(all) } }
        .onChange(of: filter) {
            // A filter that empties the column on screen moves to the first one with a match.
            let now = board(items)
            guard let p = page, (now[p] ?? []).isEmpty,
                  let next = AgentBoard.Column.allCases.first(where: { !(now[$0] ?? []).isEmpty }) else { return }
            withAnimation(.snappy) { page = next }
        }
        .onChange(of: AgentBoard.Column.allCases.map { cols[$0]?.count ?? 0 }) {
            // Sessions arrive after the board opens (launch, a box reconnecting): land on the first column with cards,
            // until the person picks one.
            guard autoPage, let p = page, (cols[p] ?? []).isEmpty,
                  let next = AgentBoard.Column.allCases.first(where: { !(cols[$0] ?? []).isEmpty && $0 != .closed }) else { return }
            autoChoice = next
            page = next
        }
        .onChange(of: page) { _, new in if new != autoChoice { autoPage = false } }
        .task {
            if page == nil {
                autoChoice = AgentBoard.Column.allCases.first { !(cols[$0] ?? []).isEmpty && $0 != .closed } ?? .needsYou
                page = autoChoice
            }
            while !Task.isCancelled {
                await signals.refreshBoard(model: model)
                try? await Task.sleep(for: .seconds(4))
            }
        }
        .task {
            for await h in model.hub.subscribe() {
                let t = h.event.type
                if t.hasPrefix("agent.") || t.hasPrefix("session.") { signals.invalidate() }
            }
        }
        .sheet(item: $ending) { t in
            EndSessionSheet(vm: t.vm, title: t.title) { note in
                if let note { model.showToast(note, symbol: "sparkles") }
            }
            .environment(model)
        }
    }

    // MARK: layouts

    private func compact(_ cols: [AgentBoard.Column: [BoxSession]], fraction: CGFloat) -> some View {
        VStack(spacing: 10) {
            filterChips
            ColumnBar(counts: cols.mapValues(\.count), page: $page, target: $target) { ids, c in drop(ids, on: c, cols) }
                .padding(.horizontal, 16)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(AgentBoard.Column.allCases) { c in
                        lane(c, cols[c] ?? [], cols)
                            .containerRelativeFrame(.horizontal) { w, _ in w * fraction }
                            .id(c)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $page)
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollIndicators(.hidden)
        }
        .padding(.top, 4)
        .sensoryFeedback(.selection, trigger: page)
    }

    private func regular(_ cols: [AgentBoard.Column: [BoxSession]]) -> some View {
        VStack(spacing: 12) {
            filterChips
            GeometryReader { geo in
                let folded: CGFloat = closedOpen ? 0 : 64
                let open = closedOpen ? 5.0 : 4.0
                let width = max(200, (geo.size.width - 32 - folded - 12 * (open - (closedOpen ? 1 : 0))) / open)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(AgentBoard.Column.allCases) { c in
                            if c == .closed && !closedOpen {
                                foldedLane(cols[c]?.count ?? 0, cols)
                            } else {
                                lane(c, cols[c] ?? [], cols, foldable: true).frame(width: width)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(minWidth: geo.size.width, alignment: .leading)
                    .frame(height: geo.size.height)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.top, 4)
    }

    // MARK: lanes

    private func lane(_ c: AgentBoard.Column, _ list: [BoxSession], _ cols: [AgentBoard.Column: [BoxSession]], foldable: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: c.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(c.color)
                Text(c.title).font(.footnote.weight(.semibold)).foregroundStyle(c == .needsYou && !list.isEmpty ? Theme.orange : Theme.text)
                BoardCount(count: list.count, color: c.color, urgent: c == .needsYou && !list.isEmpty)
                Spacer(minLength: 4)
                if c == .closed && foldable {
                    Button { withAnimation(.snappy) { closedOpen = false } } label: {
                        Image(systemName: "chevron.right.2").font(.caption.weight(.semibold)).foregroundStyle(Theme.textDim)
                    }
                    .accessibilityLabel("Recolher Encerradas")
                }
            }
            .padding(.horizontal, 4)
            ScrollView(.vertical) {
                LazyVStack(spacing: 10) {
                    if list.isEmpty {
                        EmptyLane(column: c, filtered: filter.isActive && c != .closed)
                    } else {
                        ForEach(c == .closed ? Array(list.prefix(40)) : list) { item in
                            card(item, in: c)
                        }
                        if c == .closed && list.count > 40 {
                            Text("e mais \(list.count - 40)").font(.caption).foregroundStyle(Theme.textFaint)
                        }
                    }
                }
                .padding(.bottom, 24)
                .animation(.snappy, value: list.map(\.id))
            }
            .scrollIndicators(.hidden)
            .refreshable { await refresh() }
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(target == c ? Theme.laneTarget : Theme.lane, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(target == c ? c.color.opacity(0.7) : Theme.stroke, lineWidth: target == c ? 1.5 : 1))
        .dropDestination(for: String.self) { ids, _ in drop(ids, on: c, cols) } isTargeted: { on in setTarget(c, on) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board-column-\(c.rawValue)")
    }

    /// Encerradas folded on wide screens: a narrow strip (count, tap to open) that still takes drops.
    private func foldedLane(_ count: Int, _ cols: [AgentBoard.Column: [BoxSession]]) -> some View {
        Button { withAnimation(.snappy) { closedOpen = true } } label: {
            VStack(spacing: 10) {
                Image(systemName: AgentBoard.Column.closed.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textDim)
                Text("\(count)").font(.footnote.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.textDim)
                Text("Encerradas").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textDim)
                    .fixedSize().rotationEffect(.degrees(90)).frame(width: 20, height: 90)
                Spacer()
            }
            .padding(.top, 14)
            .frame(width: 64)
            .frame(maxHeight: .infinity)
            .background(target == .closed ? Theme.laneTarget : Theme.lane, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(target == .closed ? Theme.textDim : Theme.stroke, lineWidth: target == .closed ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dropDestination(for: String.self) { ids, _ in drop(ids, on: .closed, cols) } isTargeted: { on in setTarget(.closed, on) }
        .accessibilityLabel(Text("Encerradas (\(count))"))
        .accessibilityHint("Mostra as sessões encerradas")
        .accessibilityIdentifier("board-column-closed")
    }

    private func card(_ item: BoxSession, in c: AgentBoard.Column) -> some View {
        NavigationLink(value: item.route) {
            BoardCard(item: item, column: c, detail: detail(item, c), change: signals.changes["\(item.box)/\(item.session.location ?? "")"],
                      archived: c == .closed && !item.session.exited, showBox: multiBox)
        }
        .buttonStyle(.plain)
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu { menu(item, c) }
        .draggable(item.id)
        .accessibilityIdentifier("board-card-\(c.rawValue)-\(item.session.name)")
    }

    private func detail(_ item: BoxSession, _ c: AgentBoard.Column) -> String? {
        switch c {
        case .needsYou: NeedsYouWidget.ask(item)
        case .working: signals.workingDetail(item)
        case .yourTurn: signals.replies[item.id]?.text
        case .ready, .closed: nil
        }
    }

    // MARK: actions

    @ViewBuilder private func menu(_ item: BoxSession, _ c: AgentBoard.Column) -> some View {
        Button { router.push(item.route) } label: { Label("Abrir sessão", systemImage: "bubble.left.and.text.bubble.right") }
        if let r = review(item) {
            Button { router.push(r) } label: { Label("Revisar alterações", systemImage: "doc.text.magnifyingglass") }
        }
        if c == .needsYou && signals.menus.contains(item.id) {
            Section {
                // Both wait the undo window ("Enviando… Desfazer"); nothing on the card changes until they go out.
                Button { scheduleAnswer(item, .allow) } label: { Label("Permitir", systemImage: "checkmark") }
                Button(role: .destructive) { scheduleAnswer(item, .deny) } label: { Label("Negar", systemImage: "xmark") }
            }
        }
        if AgentBoard.move(item.session, from: c, to: .closed) != nil {
            Button { setArchived(true, item) } label: { Label("Arquivar (terminei aqui)", systemImage: "archivebox") }
        } else if c == .closed, AgentBoard.move(item.session, from: .closed, to: .yourTurn) != nil {
            Button { setArchived(false, item) } label: { Label("Voltar para “Sua vez”", systemImage: "tray.and.arrow.up") }
        }
        if !item.session.exited, let client = model.client(for: item.box) {
            Section {
                Button(role: .destructive) {
                    let title = item.session.title?.nilIfEmpty ?? item.worktree ?? item.session.name
                    ending = EndTarget(vm: SessionViewModel(box: item.box, session: item.session, client: client, model: model), title: title)
                } label: { Label("Encerrar sessão…", systemImage: "stop.circle") }
            }
        }
    }

    /// The worktree to review: the session's own, or the project's main worktree for a main-checkout session.
    private func review(_ item: BoxSession) -> ReviewRoute? {
        guard !item.location.isEmpty else { return nil }
        let wt = item.worktree ?? model.connection(for: item.box)?.location(named: item.location)?.worktrees?.first { $0.main == true }?.name ?? item.location
        return ReviewRoute(box: item.box, location: item.location, worktree: wt, session: item.session.name)
    }

    private func setArchived(_ on: Bool, _ item: BoxSession) {
        withAnimation(.snappy) { prefs.setClosed(on, box: item.box, session: item.session.name) }
        Haptic.impact(.light)
    }

    private func setTarget(_ c: AgentBoard.Column, _ on: Bool) {
        withAnimation(.easeOut(duration: 0.15)) {
            if on { target = c } else if target == c { target = nil }
        }
    }

    /// A card dropped on a column: archive or bring back; anything else is refused (the agent decides the other moves).
    private func drop(_ ids: [String], on to: AgentBoard.Column, _ cols: [AgentBoard.Column: [BoxSession]]) -> Bool {
        defer { target = nil }
        guard let id = ids.first,
              let (from, item) = cols.lazy.compactMap({ c, list in list.first { $0.id == id }.map { (c, $0) } }).first,
              let move = AgentBoard.move(item.session, from: from, to: to) else { return false }
        setArchived(move == .archive, item)
        return true
    }

    private func scheduleAnswer(_ item: BoxSession, _ a: PermissionAnswer) {
        let word = a == .allow ? S("Permitir") : S("Negar")
        PendingActions.shared.schedule(label: "\(word) · \(item.session.displayTitle)", symbol: "hand.tap.fill") {
            await answer(item, a)
        }
    }

    /// Allow / Deny from the card's menu: the digit the screen's menu assigns (read fresh, never a guess).
    private func answer(_ item: BoxSession, _ a: PermissionAnswer) async {
        guard let c = model.client(for: item.box) else { return }
        do {
            let screen = try await c.screen(session: item.session.name, history: 0)
            let key = (MenuParser.actions(in: screen) ?? []).compactMap { act -> String? in
                switch (a, act) {
                case (.allow, .allow(let k)), (.deny, .deny(let k)): k
                default: nil
                }
            }.first
            guard let key else { model.showToast(SessionActions.Failure.menuChanged.message, symbol: "exclamationmark.triangle"); return }
            _ = try await c.send(session: item.session.name, .key(key))
            Haptic.success()
            signals.invalidate()
            model.connection(for: item.box)?.scheduleRefresh(sessions: true)
        } catch {
            model.showToast(SessionActions.describe(error), symbol: "exclamationmark.triangle")
        }
    }

    private func refresh() async {
        await model.refreshAll()
        await signals.refreshBoard(model: model, force: true)
    }

    // MARK: filters

    private func filterMenu(_ all: [AgentBoard.Item]) -> some View {
        Menu {
            if multiBox {
                Picker(selection: $filter.box) {
                    Text("Todas as boxes").tag(String?.none)
                    ForEach(model.boxes) { b in Text(b.name).tag(Optional(b.name)) }
                } label: { Label("Box", systemImage: "server.rack") }
                .pickerStyle(.menu)
            }
            Picker(selection: $filter.project) {
                Text("Todos os projetos").tag(String?.none)
                ForEach(AgentBoard.projects(all).filter { filter.box == nil || $0.box == filter.box }, id: \.location) { p in
                    Text(projectLabel(p.box, p.location)).tag(Optional("\(p.box)/\(p.location)"))
                }
            } label: { Label("Projeto", systemImage: "folder") }
            .pickerStyle(.menu)
            if filter.box != nil || filter.project != nil {
                Button(role: .destructive) { withAnimation(.snappy) { filter.box = nil; filter.project = nil } } label: {
                    Label("Limpar filtros", systemImage: "xmark.circle")
                }
            }
        } label: {
            Image(systemName: filter.box != nil || filter.project != nil ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filtrar")
        .accessibilityIdentifier("board-filter")
    }

    private func projectLabel(_ box: String, _ location: String) -> String {
        let name = prefs.displayName(box: box, location: location)
        return multiBox ? "\(name) · \(box)" : name
    }

    @ViewBuilder private var filterChips: some View {
        if filter.box != nil || filter.project != nil {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if let b = filter.box {
                        FilterChip(symbol: "server.rack", text: b) { withAnimation(.snappy) { filter.box = nil } }
                    }
                    if let p = filter.project, let i = p.firstIndex(of: "/") {
                        FilterChip(symbol: "folder", text: projectLabel(String(p[..<i]), String(p[p.index(after: i)...]))) {
                            withAnimation(.snappy) { filter.project = nil }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .transition(.opacity)
        }
    }
}

// MARK: pieces

/// The compact board's column switcher: one chip per column (symbol and count; the current one also shows its name).
/// Each chip takes drops, so a card can be archived without scrolling to Encerradas.
private struct ColumnBar: View {
    let counts: [AgentBoard.Column: Int]
    @Binding var page: AgentBoard.Column?
    @Binding var target: AgentBoard.Column?
    let onDrop: ([String], AgentBoard.Column) -> Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AgentBoard.Column.allCases) { c in
                let on = page == c
                let n = counts[c] ?? 0
                Button { withAnimation(.snappy) { page = c } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: c.symbol).font(.system(size: 12, weight: .semibold))
                        // The current column shows its name (its count is in the lane's header); the others their count.
                        if on { Text(c.title).font(.caption.weight(.semibold)).lineLimit(1).fixedSize() }
                        else { Text("\(n)").font(.caption.weight(.semibold).monospacedDigit()) }
                    }
                    .foregroundStyle(on ? c.color : (c == .needsYou && n > 0 ? Theme.orange : Theme.textDim))
                    .padding(.horizontal, 10).frame(height: 32)
                    .frame(maxWidth: on ? nil : .infinity)
                    .background(on ? c.color.opacity(0.16) : (target == c ? Theme.washStrong : Theme.card), in: Capsule())
                    .overlay(Capsule().strokeBorder(target == c ? c.color : (on ? c.color.opacity(0.35) : Theme.stroke), lineWidth: target == c ? 1.5 : 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .dropDestination(for: String.self) { ids, _ in onDrop(ids, c) } isTargeted: { t in
                    withAnimation(.easeOut(duration: 0.15)) { if t { target = c } else if target == c { target = nil } }
                }
                .accessibilityLabel(Text(c.title))
                .accessibilityValue(Text("\(n)"))
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("board-tab-\(c.rawValue)")
            }
        }
    }
}

private struct BoardCount: View {
    let count: Int
    var color: Color = Theme.textDim
    var urgent = false
    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(urgent ? Theme.orange : Theme.textDim)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background((urgent ? Theme.orange : Theme.textFaint).opacity(0.18), in: Capsule())
            .accessibilityIdentifier("board-count")
    }
}

private struct FilterChip: View {
    let symbol: String
    let text: String
    let clear: () -> Void
    var body: some View {
        Button(action: clear) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.caption2)
                Text(text).font(.caption.weight(.medium)).lineLimit(1)
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textDim)
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.accent.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Remove o filtro")
    }
}

private struct EmptyLane: View {
    let column: AgentBoard.Column
    var filtered = false
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: filtered ? "line.3.horizontal.decrease.circle" : column.symbol)
                .font(.system(size: 18)).foregroundStyle(Theme.textFaint)
            Group { if filtered { Text("Nada com este filtro") } else { Text(column.emptyTitle) } }
                .font(.footnote).foregroundStyle(Theme.textDim).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 26).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("board-empty-\(column.rawValue)")
    }
}
