import SwiftUI
import PierKit

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var home = HomeStore()
    @State private var layout = HomeLayout()
    @State private var customizing = false
    @State private var web: IdentifiedURL?
    @State private var unsupported: URL?

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 14) {
                BoxesHeader()
                // A dot per live agent (App/Features/Dots); with the sidebar (iPad, Mac) its own strip already shows them.
                if sizeClass != .regular { AgentDotStrip(style: .home) }
                let kinds = layout.visible
                if kinds.isEmpty {
                    HomeEmpty(symbol: "square.grid.2x2", title: "Nenhum widget visível", hint: HL("Toque em Personalizar para escolher o que aparece no início."))
                        .padding(.vertical, 30)
                } else if sizeClass == .regular {
                    // Two independent columns (widgets alternate, in the person's order): each card is as tall as its
                    // content, with no gap reserved by a taller neighbour as a grid row would.
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(0..<2, id: \.self) { c in
                            VStack(spacing: 14) {
                                ForEach(Array(kinds.enumerated()).filter { $0.offset % 2 == c }, id: \.element) { widget($0.element).id($0.element) }
                            }
                            .frame(maxWidth: .infinity, alignment: .top)
                        }
                    }
                } else {
                    LazyVStack(spacing: 14) { ForEach(kinds) { widget($0).id($0) } }
                }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
        }
        #if targetEnvironment(macCatalyst)
        .scrollIndicators(.never)   // with a mouse the Mac keeps the bar on screen; the wheel and trackpad still scroll
        #endif
        .task {
            #if DEBUG
            // Test hooks: `-homeScrollTo ci` scrolls a widget to the top, `-homeCustomize 1` opens the sheet,
            // `-openPR owner/name#123` a pull request.
            if let pr = UserDefaults.standard.string(forKey: "openPR"), let i = pr.lastIndex(of: "#"), let n = Int(pr[pr.index(after: i)...]) {
                router.homePath.append(PullRequestRoute(repo: String(pr[..<i]), number: n))
            }
            if let k = UserDefaults.standard.string(forKey: "homeScrollTo"), let kind = HomeWidgetKind(rawValue: k) {
                try? await Task.sleep(for: .seconds(14))
                withAnimation { proxy.scrollTo(kind, anchor: .top) }
            }
            if UserDefaults.standard.bool(forKey: "homeCustomize") { try? await Task.sleep(for: .seconds(8)); customizing = true }
            #endif
        }
        }
        .refreshable {
            async let a: Void = model.refreshAll()
            async let b: Void = home.refreshAll()
            _ = await (a, b)
        }
        .pierBackground()
        .navigationTitle("Início")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { TalkCenter.shared.open() } label: { Image(systemName: "waveform") }
                    .accessibilityLabel("Falar")
                    .accessibilityHint("Diga ou escreva um pedido; o Pier escolhe o agente")
                    .accessibilityIdentifier("talk-button")
                Button(action: openCompose) { Image(systemName: "plus").fontWeight(.semibold) }
                    .accessibilityLabel("Nova tarefa")
                    .accessibilityHint("Abre o formulário de nova tarefa")
                    .accessibilityIdentifier("new-task-button")
                Button { customizing = true } label: { HText("Personalizar") }
            }
        }
        .safeAreaInset(edge: .bottom) { if showsHoldMic { holdMic } }
        .task { await home.run(model: model) }
        .task { await home.listen(model: model) }
        .sheet(isPresented: $customizing) { HomeCustomizeSheet(layout: layout) }
        .sheet(item: $web) { SafariView(url: $0.url).ignoresSafeArea() }
        .environment(\.openURL, OpenURLAction { url in
            #if targetEnvironment(macCatalyst)
            return .systemAction    // the Mac opens pages in the default browser
            #else
            guard ["http", "https"].contains(url.scheme?.lowercased()) else { return .systemAction }
            web = IdentifiedURL(url: url)
            return .handled
            #endif
        })
    }

    @ViewBuilder private func widget(_ kind: HomeWidgetKind) -> some View {
        switch kind {
        case .needsYou: NeedsYouWidget()
        case .working: WorkingWidget(home: home)
        case .finished: FinishedWidget(home: home)
        case .prs: PullRequestsWidget(home: home)
        case .ci: CIFailuresWidget(home: home)
        case .git: GitActivityWidget(home: home)
        case .services: ServicesWidget(home: home)
        case .areas: AreasWidget()
        }
    }

    /// The iPhone's hold-to-talk mic floats over the list; small phones (SE, mini) and large Dynamic Type have no room for it
    /// (Falar stays in the toolbar).
    private var showsHoldMic: Bool {
        guard sizeClass != .regular, UIDevice.current.userInterfaceIdiom == .phone else { return false }
        let s = UIScreen.main.bounds.size
        return min(s.width, s.height) > 375 && max(s.width, s.height) > 700 && typeSize < .xxxLarge
    }

    private func openCompose() {
        guard let box = model.boxes.first(where: { $0.state.isOnline }) ?? model.boxes.first else { return }
        Haptic.impact(.light)
        router.homePath.append(ComposeRoute(box: box.name))
    }

    /// The hold-to-talk mic (Falar), bottom right: a bottom safe-area inset, so the list always scrolls clear of it (never
    /// over the last row), with the live transcript above while it is held.
    private var holdMic: some View {
        HStack {
            Spacer()
            TalkHoldButton()
        }
        // Above the mic without growing the inset (the list does not jump while it is held).
        .overlay(alignment: .bottom) {
            if TalkCenter.shared.holding {
                TalkHoldOverlay()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 74)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: TalkCenter.shared.holding)
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 8)
    }
}

struct BoxesHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.boxes.count == 1, let only = model.boxes.first {
            BoxChip(conn: only, fullWidth: true)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.boxes) { BoxChip(conn: $0) }
                }
            }
            .scrollClipDisabled()
        }
    }
}

struct BoxChip: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    let conn: BoxConnection
    var fullWidth = false

    /// What the box's doctor wants done (BoxHealthStore): a line here, the cards in the Inbox.
    private var toFix: Int { BoxHealthStore.shared.cards(model: model).filter { $0.box == conn.name && $0.issue.kind != .unreachable }.count }

    var color: Color {
        switch conn.state {
        case .online: Theme.green
        case .connecting: Theme.accent
        case .offline: Theme.red
        case .revoked, .pinMismatch: Theme.orange
        }
    }
    var statusText: LocalizedStringKey {
        switch conn.state {
        case .online: "online"
        case .connecting: "conectando…"
        case .offline: "offline"
        case .revoked: "acesso revogado"
        case .pinMismatch: "chave diferente"
        }
    }

    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(conn.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    Text(statusText).font(.caption).foregroundStyle(Theme.textDim)
                }
                if let s = conn.stats, conn.state.isOnline {
                    let cpu = min(1, (s.load?.first ?? 0) / Double(max(s.cpus, 1)))
                    let mem = s.memory.total > 0 ? Double(s.memory.used) / Double(s.memory.total) : 0
                    let disk = s.disks.first.map { $0.total > 0 ? Double($0.used) / Double($0.total) : 0 } ?? 0
                    HStack(spacing: 14) {
                        UsageMeter(label: String(localized: "CPU"), value: cpu)
                        UsageMeter(label: String(localized: "Memória"), value: mem)
                        UsageMeter(label: String(localized: "Disco"), value: disk)
                    }
                    .padding(.top, 2)
                    MonoText(String(localized: "\(s.cpus) CPUs · \(Fmt.bytes(s.memory.total))"), size: 11, color: Theme.textFaint)
                } else if case .offline(let m) = conn.state {
                    Text(m).font(.caption2).foregroundStyle(Theme.textFaint).lineLimit(2).frame(maxWidth: 180, alignment: .leading)
                }
                if toFix > 0 {
                    Button { router.select(.tab(.inbox)) } label: {
                        Label(toFix == 1 ? S("1 coisa para resolver na box") : S("\(toFix) coisas para resolver na box"), systemImage: "wrench.and.screwdriver")
                            .font(.caption.weight(.medium)).foregroundStyle(Theme.orange)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Abre o Inbox")
                    .accessibilityIdentifier("box-health-line")
                }
            }
        }
        .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
        .fixedSize(horizontal: !fullWidth, vertical: true)
    }
}

struct UsageMeter: View {
    let label: String
    let value: Double

    var tint: Color { value > 0.85 ? Theme.red : value > 0.6 ? Theme.orange : Theme.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption2).foregroundStyle(Theme.textDim)
                Spacer(minLength: 4)
                MonoText("\(Int((value * 100).rounded()))%", size: 10, color: Theme.textFaint)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.stroke)
                    Capsule().fill(tint).frame(width: max(3, geo.size.width * value))
                }
            }
            .frame(height: 4)
        }
        .frame(minWidth: 70)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(Int((value * 100).rounded()))%")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
