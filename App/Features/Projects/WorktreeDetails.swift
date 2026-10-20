import SwiftUI
import PierKit

/// "Detalhes" of a worktree: what runs there and how to see it.
/// - **Preparação**: whether its setup script and autostart services ran, or how its setup agent is doing, with its
///   conversation a tap away (a worktree made without them, for a quick fix, is prepared from here, by script or by a
///   setup agent; `…/prepare`, capabilities `prepare`, `prepare.agent`);
/// - **Visualização**: the worktree's preview (`…/preview`, capability `preview`: the page to open at its public link,
///   the app's test login), then the dev servers listening in the worktree (`GET /v1/services`), each as a link to the
///   box's address and port, checked from this device (a box reached only through a relay has no page to open from here);
/// - **Serviços**: the project's services in this worktree (`GET …/services`), with their command, to start, stop or restart;
/// - **Ambiente**: branch, base, ports ($PIER_PORT…), folder, setup script and sessions.
/// Read again every few seconds while on screen, and when a service event arrives.
struct WorktreeDetailsRoute: Hashable {
    let box: String
    let location: String
    let worktree: String
}

@MainActor @Observable
final class WorktreeDetailsStore {
    let box: String
    let location: String
    let worktree: String
    private(set) var services: [WorktreeServiceDetail] = []
    private(set) var servers: [BoxService] = []
    private(set) var reachable: [Int: Bool] = [:]
    private(set) var status: WorktreeStatus?
    private(set) var loaded = false
    private(set) var busy: Set<String> = []
    private(set) var links: [PublicLink] = []
    private(set) var prepare: PrepareStatus?
    /// The worktree's preview: the page, its public link, the app's test login.
    private(set) var preview: WorktreePreview?
    var error: String?
    var prepareError: String?

    init(box: String, location: String, worktree: String) {
        self.box = box; self.location = location; self.worktree = worktree
    }

    /// Reads it all again; `previewOnly` (the session's inspector) reads the preview and the dev servers, not the
    /// services, the git state or the preparation.
    func load(model: AppModel, previewOnly: Bool = false) async {
        guard let conn = model.connection(for: box), let wt = conn.location(named: location)?.worktrees?.first(where: { $0.name == worktree }) else { return }
        let api = BoxAPI(transport: conn.raw)
        async let all = try? api.services()
        if conn.info?.has("preview") == true, let p = try? await api.preview(location: location, worktree: worktree), p != preview { preview = p }
        if !previewOnly {
            async let svc = try? api.worktreeServiceDetails(location: location, worktree: worktree)
            async let st = try? conn.client.worktreeStatuses(location: location)
            if let s = await svc, s != services { services = s }
            if let s = await st, let mine = s.first(where: { $0.name == worktree }), mine != status { status = mine }
            if conn.info?.has("prepare") == true, let p = try? await api.prepareStatus(location: location, worktree: worktree), p != prepare { prepare = p }
        }
        // The session's inspector shows a server's public link before its address on the box, so these come every time.
        if conn.info?.has("shares") == true, let all = try? await api.publicLinks() {
            let mine = all.filter { $0.location == location && $0.worktree == worktree }
            if mine != links { links = mine }
        }
        if let a = await all { let v = Projects.devServers(a, location: location, worktree: wt); if v != servers { servers = v } }
        if !loaded { loaded = true }
        let host = conn.record.host
        var probes: [Int: Bool] = [:]
        let ports = Set(servers.map(\.port) + (preview?.port.map { [$0] } ?? []))
        await withTaskGroup(of: (Int, Bool).self) { g in
            for p in ports { g.addTask { (p, await PortProbe.reachable(host: host, port: p)) } }
            for await (p, ok) in g { probes[p] = ok }
        }
        if probes != reachable { reachable = probes }
    }

    /// Publishes a port at a public link (24 hours) through the box's relay.
    func publish(port: Int, model: AppModel) async -> PublicLink? {
        guard let conn = model.connection(for: box) else { return nil }
        busy.insert("link-\(port)")
        defer { busy.remove("link-\(port)") }
        do {
            let l = try await BoxAPI(transport: conn.raw).createPublicLink(location: location, worktree: worktree, port: port)
            links.append(l)
            error = nil
            return l
        } catch { self.error = ComposeErrorText.message(error); return nil }
    }

    func unpublish(_ l: PublicLink, model: AppModel) async {
        guard let conn = model.connection(for: box) else { return }
        do { try await BoxAPI(transport: conn.raw).removePublicLink(name: l.name); links.removeAll { $0.name == l.name } }
        catch { self.error = ComposeErrorText.message(error) }
    }

    /// Prepares it in the background on the box: by `with` (a setup agent or the setup script), or nil, the project's
    /// default way.
    func runPrepare(model: AppModel, with: PrepareMode? = nil) async {
        guard let conn = model.connection(for: box) else { return }
        busy.insert("prepare")
        defer { busy.remove("prepare") }
        do {
            prepare = try await BoxAPI(transport: conn.raw).prepare(location: location, worktree: worktree, with: with)
            prepareError = nil
            // The setup agent's session is new: the sidebar and Agentes list it.
            if with == .agent || prepare?.byAgent == true { conn.scheduleRefresh(sessions: true) }
        } catch { prepareError = ComposeErrorText.message(error) }
    }

    func act(_ action: String, on service: String, model: AppModel) async {
        guard let conn = model.connection(for: box) else { return }
        busy.insert(service)
        defer { busy.remove(service) }
        do {
            try await BoxAPI(transport: conn.raw).serviceAction(location: location, worktree: worktree, service: service, action)
            error = nil
        } catch { self.error = ComposeErrorText.message(error) }
        try? await Task.sleep(for: .milliseconds(action == "stop" ? 300 : 1200))
        await load(model: model)
    }
}

/// The details as a screen of their own (the iPhone, from the worktree's screen).
struct WorktreeDetailsScreen: View {
    let route: WorktreeDetailsRoute
    var body: some View {
        WorktreeDetailsView(box: route.box, location: route.location, worktree: route.worktree)
            .navigationTitle("Detalhes")
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct WorktreeDetailsView: View {
    let box: String
    let location: String
    let worktree: String

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var store: WorktreeDetailsStore
    /// A setup agent asked for in a project that has not allowed them: the consent sheet is up.
    @State private var askingConsent = false

    init(box: String, location: String, worktree: String) {
        self.box = box; self.location = location; self.worktree = worktree
        _store = State(initialValue: WorktreeDetailsStore(box: box, location: location, worktree: worktree))
    }

    private var conn: BoxConnection? { model.connection(for: box) }
    private var project: Location? { conn?.location(named: location) }
    private var wt: Worktree? { project?.worktrees?.first { $0.name == worktree } }
    private var host: String { conn?.record.host ?? "" }
    private var sessions: [Session] {
        guard let project, let wt else { return [] }
        let ref = project.ref(wt)
        return (conn?.sessions ?? []).filter { !$0.exited && $0.location == ref }
    }

    var body: some View {
        List {
            // Also where only a setup agent could prepare it (a project without a recipe that has not allowed them yet).
            if let p = store.prepare, p.hasAnything || (p.prepareWith != nil && canPrepareWithAgent) { prepareSection(p) }
            preview
            servicesSection
            environment
            if let project { ProjectAccountsSection(box: box, location: project) }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .pierBackground()
        .refreshable { await store.load(model: model) }
        // A setup agent asked for in a project that has not allowed them: asked once, then it runs.
        .sheet(isPresented: $askingConsent) {
            SetupAgentConsentSheet(box: box, location: location) { Task { await store.runPrepare(model: model, with: .agent) } }.environment(model)
        }
        .task { await AccountsCache.shared.load(box: box, model: model) }
        .task {
            while !Task.isCancelled {
                await store.load(model: model)
                // The box's events bring changes at once (services, setup, preparation); this only catches the rest.
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .task {
            for await h in model.hub.subscribe() where h.box == box {
                let t = h.event.type
                if t.hasPrefix("service.") || t.hasPrefix("worktree.setup") || t.hasPrefix("worktree.prepare") || t.hasPrefix("preview.") || t.hasPrefix("share.") {
                    await store.load(model: model)
                }
            }
        }
    }

    // MARK: preparation

    private func prepareSection(_ p: PrepareStatus) -> some View {
        let running = p.state == .running || store.busy.contains("prepare")
        // The session the setup agent works in, while the box still has it.
        let agentSession = p.byAgent ? p.session.flatMap { name in conn?.sessions.first { $0.name == name } } : nil
        return Section {
            HStack(spacing: 8) {
                if running { ProgressView().controlSize(.small) } else {
                    Circle().fill(prepareColor(p.state)).frame(width: 8, height: 8)
                }
                Text(prepareTitle(p)).font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                if let since = p.since, !running {
                    Text(since, format: .relative(presentation: .named)).font(.caption).foregroundStyle(Theme.textFaint)
                }
                Spacer(minLength: 4)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("prepare-state")
            if p.byAgent {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.accent).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.waiting && p.state == .running ? "O agente de preparação precisa de você" : "Agente de preparação")
                            .font(.subheadline).foregroundStyle(p.waiting && p.state == .running ? Theme.orange : Theme.textDim)
                        if let s = p.session { Text(s).font(.mono(11)).foregroundStyle(Theme.textFaint).lineLimit(1).truncationMode(.middle) }
                    }
                    Spacer(minLength: 4)
                    if let s = agentSession {
                        Button { model.openSession(box: box, name: s.name) } label: {
                            Label("Abrir conversa", systemImage: "bubble.left.and.text.bubble.right").font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("prepare-open-agent")
                    }
                }
            }
            if let setup = p.setup, !setup.isEmpty { MonoText(setup, size: 11, color: Theme.textFaint).lineLimit(3).textSelection(.enabled) }
            if !p.services.isEmpty {
                Text("Depois sobem: \(p.services.joined(separator: ", "))").font(.caption).foregroundStyle(Theme.textDim)
            }
            if let base = p.base { BaseReportLines(base: base) }
            if p.state == .failed, let e = p.error, !e.isEmpty {
                Text(e).font(.mono(11)).foregroundStyle(Theme.red).lineLimit(8).textSelection(.enabled)
            }
            if let e = store.prepareError { Text(e).font(.caption).foregroundStyle(Theme.red) }
            if !running {
                // The project's default way first (a setup agent while a project that allowed them has no recipe), the
                // other beside it; a script with nothing to run is no way at all where a setup agent is offered.
                let byAgent = p.prepareWith == .agent || (p.prepareWith == nil && p.byAgent)
                let again = p.state == .ready || p.state == .failed
                let agentToo = p.prepareWith == .script && canPrepareWithAgent
                HStack(spacing: 16) {
                    if byAgent || p.hasWork || !agentToo {
                        Button { Task { await store.runPrepare(model: model) } } label: {
                            Label(byAgent ? (again ? "Preparar com agente de novo" : "Preparar com agente") : (again ? "Preparar de novo" : "Preparar ambiente"),
                                  systemImage: byAgent ? "sparkles" : "hammer")
                                .font(.subheadline.weight(.semibold))
                        }
                        .accessibilityIdentifier("prepare-run")
                    }
                    if agentToo {
                        Button { prepareWithAgent() } label: {
                            Label("Preparar com agente", systemImage: "sparkles").font(.subheadline.weight(p.hasWork ? .regular : .semibold))
                        }
                        .accessibilityIdentifier("prepare-agent")
                    } else if byAgent, p.hasWork {
                        Button { Task { await store.runPrepare(model: model, with: .script) } } label: {
                            Label("Rodar o script", systemImage: "hammer").font(.subheadline)
                        }
                        .accessibilityIdentifier("prepare-script")
                    }
                }
                .buttonStyle(.borderless)
            }
        } header: {
            Text("Preparação")
        } footer: {
            if p.state == .skipped { Text("Esta worktree foi criada só com o código. Prepare quando precisar rodar o projeto ou a visualização.") }
            else if p.byAgent && running { Text("Um agente instala o que falta, sobe o servidor e cria um login de teste; no fim salva a receita, e as próximas worktrees a repetem sem agente.") }
        }
        .listRowBackground(Theme.card)
    }

    /// A setup agent can prepare it: the box has them, and Claude Code.
    private var canPrepareWithAgent: Bool {
        conn?.info?.has("prepare.agent") == true && (conn?.info?.agents.contains { $0.id == "claude" } ?? false)
    }

    /// Prepares it with a setup agent, once the project allowed them: the first time, the person is asked.
    private func prepareWithAgent() {
        if PrepareChoice.asksConsent(.agent, allowed: project?.setupAgent ?? true) {
            askingConsent = true
        } else {
            Task { await store.runPrepare(model: model, with: .agent) }
        }
    }

    private func prepareTitle(_ p: PrepareStatus) -> String {
        switch p.state {
        case .running:
            switch p.step {
            case "carry": String(localized: "Copiando as pastas da base…")
            case "setup": String(localized: "Rodando a receita…")
            case "services": String(localized: "Subindo os serviços…")
            default: p.byAgent ? String(localized: "O agente está preparando…") : String(localized: "Preparando…")
            }
        case .ready: String(localized: "Ambiente pronto")
        case .failed: p.byAgent ? String(localized: "A preparação não terminou") : String(localized: "O setup falhou")
        case .skipped: String(localized: "Ambiente não preparado")
        case .unknown: p.prepareWith != nil ? String(localized: "Nada registrado sobre a preparação") : String(localized: "Sem registro desde que a box reiniciou")
        }
    }

    private func prepareColor(_ s: PrepareStatus.State) -> Color {
        switch s {
        case .ready: Theme.green
        case .failed: Theme.red
        case .skipped: Theme.orange
        case .running, .unknown: Theme.textFaint
        }
    }

    // MARK: preview

    @ViewBuilder private var preview: some View {
        Section {
            if let p = store.preview, !p.isEmpty {
                WorktreePreviewBlock(preview: p, host: host, reachable: p.port.flatMap { store.reachable[$0] },
                                     place: WorktreeDetailsRoute(box: box, location: location, worktree: worktree))
                    .id("\(box)/\(location)/\(worktree)")
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("worktree-preview")
            }
            if store.servers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.loaded ? "Nada escutando nesta worktree agora." : "Procurando servidores…")
                        .font(.subheadline).foregroundStyle(Theme.textDim)
                    if let port = wt?.port, let url = Projects.previewURL(host: host, port: port) {
                        Text("Quando o servidor de desenvolvimento subir em $PIER_PORT, a página fica em:").font(.caption).foregroundStyle(Theme.textFaint)
                        linkLine(url, reachable: nil)
                    }
                }
                .padding(.vertical, 2)
            }
            ForEach(store.servers) { s in serverRow(s) }
        } header: {
            SectionHeader(title: "Visualização", count: store.servers.count)
        } footer: {
            if conn?.record.relay != nil && store.reachable.values.contains(false) {
                Text("A box é alcançada por um relay: as páginas abrem só na mesma rede dela (ou por VPN).")
            }
        }
        .listRowBackground(Theme.card)
    }

    @ViewBuilder private func serverRow(_ s: BoxService) -> some View {
        let url = Projects.previewURL(host: host, port: s.port)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "globe").foregroundStyle(Theme.accent)
                Text(verbatim: ":\(s.port)").font(.body.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.text)
                    .accessibilityIdentifier("preview-\(s.port)")
                if let p = s.process { Text(p).font(.mono(11)).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.middle) }
                Spacer(minLength: 0)
            }
            if let url { linkLine(url, reachable: store.reachable[s.port]) }
            // The preview above already shows this port's public link.
            if store.preview?.share == nil || store.preview?.port != s.port { publicLinkLine(port: s.port) }
        }
        .padding(.vertical, 2)
    }

    /// The port's public link, or the button that makes one (boxes with a relay that serves links).
    @ViewBuilder private func publicLinkLine(port: Int) -> some View {
        if let l = store.links.first(where: { $0.port == port }), let url = URL(string: l.url) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: "globe.americas.fill").foregroundStyle(Theme.green).font(.caption)
                    Text(l.url).font(.mono(11)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer(minLength: 4)
                    PreviewOpenButton(box: box, location: location, worktree: worktree, url: url)
                    Button { openURL(url) } label: { Image(systemName: "safari") }.buttonStyle(.borderless)
                    Button { UIPasteboard.general.string = l.url } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).accessibilityLabel("Copiar link público")
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }.buttonStyle(.borderless)
                    Button(role: .destructive) { Task { await store.unpublish(l, model: model) } } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).tint(Theme.red).accessibilityLabel("Tirar do ar")
                }
                if let e = l.expires { Text("Público até \(e.formatted(date: .abbreviated, time: .shortened)): qualquer pessoa com o link vê a página.").font(.caption2).foregroundStyle(Theme.textFaint) }
                Text("Não publique servidores com console de depuração ligado (web-console, debug toolbar): quem tem o link chega a eles.").font(.caption2).foregroundStyle(Theme.orange)
            }
            .accessibilityIdentifier("public-link-\(port)")
        } else if conn?.info?.has("shares") == true {
            Button {
                Task { if let l = await store.publish(port: port, model: model) { UIPasteboard.general.string = l.url; model.toast = AppToast(text: String(localized: "Link público copiado. Vale por 24 horas."), symbol: "globe") } }
            } label: {
                HStack(spacing: 6) {
                    if store.busy.contains("link-\(port)") { ProgressView().controlSize(.mini) } else { Image(systemName: "globe") }
                    Text("Criar link público")
                }
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .disabled(store.busy.contains("link-\(port)"))
            .accessibilityIdentifier("public-link-create-\(port)")
        }
    }

    private func linkLine(_ url: URL, reachable: Bool?) -> some View {
        HStack(spacing: 8) {
            Circle().fill(reachable == true ? Theme.green : reachable == false ? Theme.orange : Theme.textFaint).frame(width: 7, height: 7)
            Text(url.absoluteString).font(.mono(12)).foregroundStyle(Theme.textDim).textSelection(.enabled).lineLimit(1)
            Spacer(minLength: 4)
            PreviewOpenButton(box: box, location: location, worktree: worktree, url: url)
            Button { openURL(url) } label: { Image(systemName: "safari") }.buttonStyle(.borderless).accessibilityLabel("Abrir")
            Button { UIPasteboard.general.string = url.absoluteString } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                .accessibilityLabel("Copiar link")
            ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }.buttonStyle(.borderless)
        }
        .font(.subheadline)
    }

    // MARK: services

    @ViewBuilder private var servicesSection: some View {
        Section {
            if store.services.isEmpty {
                Text(store.loaded ? "Este projeto não tem serviços configurados." : "Carregando…")
                    .font(.subheadline).foregroundStyle(Theme.textDim)
            }
            ForEach(store.services) { s in serviceRow(s) }
            if let e = store.error { Text(e).font(.caption).foregroundStyle(Theme.red) }
        } header: {
            SectionHeader(title: "Serviços", count: store.services.count)
        } footer: {
            if !store.services.isEmpty { Text("Cada serviço roda na box com o ambiente e as portas desta worktree, e volta se cair.") }
        }
        .listRowBackground(Theme.card)
    }

    private func serviceRow(_ s: WorktreeServiceDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(s.isRunning ? Theme.green : Theme.textFaint).frame(width: 8, height: 8)
                Text(s.name).font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                Text(stateLabel(s.state)).font(.caption).foregroundStyle(s.isRunning ? Theme.green : Theme.textDim)
                if s.autostart { Text("auto").font(.caption2.weight(.semibold)).foregroundStyle(Theme.textDim)
                    .padding(.horizontal, 5).padding(.vertical, 1).background(Theme.cardRaised, in: Capsule()) }
                Spacer(minLength: 4)
                if store.busy.contains(s.name) {
                    ProgressView().controlSize(.small)
                } else if s.isRunning {
                    Button { Task { await store.act("restart", on: s.name, model: model) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).accessibilityLabel("Reiniciar \(s.name)")
                    Button { Task { await store.act("stop", on: s.name, model: model) } } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(.borderless).tint(Theme.red).accessibilityLabel("Parar \(s.name)")
                } else {
                    Button { Task { await store.act("start", on: s.name, model: model) } } label: { Image(systemName: "play.fill") }
                        .buttonStyle(.borderless).accessibilityLabel("Iniciar \(s.name)")
                }
            }
            if !s.run.isEmpty { MonoText(s.run, size: 11, color: Theme.textFaint).lineLimit(2).textSelection(.enabled) }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("service-\(s.name)")
    }

    private func stateLabel(_ state: String) -> String {
        switch state {
        case "running": String(localized: "rodando")
        case "stopped", "inactive": String(localized: "parado")
        case "failed": String(localized: "falhou")
        case "activating": String(localized: "iniciando")
        default: state
        }
    }

    // MARK: environment

    @ViewBuilder private var environment: some View {
        Section {
            if let b = store.status?.branch ?? wt?.branch { row("arrow.triangle.branch", "Branch", b) }
            if let base = store.status?.base { row("arrow.turn.down.right", "Base", base) }
            if let ports = Projects.portBlock(store.status?.port ?? wt?.port) { row("network", "Portas", ports) }
            if let p = wt?.path { row("folder", "Pasta", p) }
            if let setup = project?.scripts?.setup, !setup.isEmpty { row("hammer", "Setup", setup) }
            if project?.repo == true, conn?.info?.has("environments") == true {
                NavigationLink(value: ProjectEnvironmentRoute(box: box, location: location)) {
                    HStack(spacing: 10) {
                        Image(systemName: "shippingbox.and.arrow.backward").font(.caption).foregroundStyle(Theme.textFaint).frame(width: 16)
                        Text("Ambiente isolado").font(.subheadline).foregroundStyle(Theme.textDim)
                        Spacer(minLength: 8)
                        Text(project?.isolated == true ? "configurado" : "não").font(.mono(12)).foregroundStyle(Theme.text)
                    }
                }
            }
            if project?.repo == true, conn?.info?.has("base") == true {
                NavigationLink(value: ProjectBaseRoute(box: box, location: location)) {
                    HStack(spacing: 10) {
                        Image(systemName: "square.stack.3d.down.right").font(.caption).foregroundStyle(Theme.textFaint).frame(width: 16)
                        Text("Base do projeto").font(.subheadline).foregroundStyle(Theme.textDim)
                        Spacer(minLength: 8)
                    }
                }
                .accessibilityIdentifier("details-base")
            }
            row("terminal", "Sessões", "\(sessions.count)")
            if model.boxes.count > 1 { row("shippingbox", "Box", box) }
        } header: { Text("Ambiente") }
        .listRowBackground(Theme.card)
    }

    private func row(_ symbol: String, _ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).font(.caption).foregroundStyle(Theme.textFaint).frame(width: 16)
            Text(title).font(.subheadline).foregroundStyle(Theme.textDim)
            Spacer(minLength: 8)
            Text(value).font(.mono(12)).foregroundStyle(Theme.text).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}
