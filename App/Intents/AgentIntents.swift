import AppIntents
import SwiftUI
import PierKit

// MARK: - Nova tarefa

struct CreateTaskIntent: AppIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Nova tarefa"
    static let description = IntentDescription("Cria uma tarefa em um projeto: um novo worktree com um agente trabalhando no seu pedido.",
                                               categoryName: "Agentes")
    static let openAppWhenRun = false

    @Parameter(title: "Projeto", requestValueDialog: "Em qual projeto?")
    var project: ProjectEntity

    @Parameter(title: "Pedido", requestValueDialog: "O que o agente deve fazer?")
    var prompt: String

    @Parameter(title: "Agente", description: "Padrão: o último usado.")
    var agent: AgentEntity?

    @Parameter(title: "Modelo")
    var model: String?

    @Parameter(title: "Abrir no app", default: false)
    var openInApp: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Nova tarefa em \(\.$project): \(\.$prompt)") {
            \.$agent
            \.$model
            \.$openInApp
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<SessionEntity> {
        let snaps = try await HeadlessBoxes.snapshots()
        guard let snap = snaps.first(where: { $0.box.name == project.box }),
              let loc = snap.locations.first(where: { $0.name == project.location }) else {
            throw HeadlessError.boxNotFound(project.box)
        }
        let prefs = LocalPrefs()
        let c = try await TaskCreator.create(box: snap.box, info: snap.info, location: loc, prompt: prompt, agent: agent?.id, model: model, prefs: prefs)
        let entity = SessionEntity(id: "\(c.box)/\(c.session.name)", box: c.box, session: c.session.name, title: c.session.displayTitle,
                                   project: project.name, agent: c.agent, state: c.session.agentState?.rawValue ?? "running")
        if openInApp {
            PendingDeepLink.set(Shared.sessionURL(box: c.box, name: c.session.name))
            try await requestToContinueInForeground()
        }
        return .result(value: entity, dialog: "Tarefa criada em \(project.name)")
    }
}

// MARK: - O que meus agentes estão fazendo?

struct AgentsStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Status dos agentes"
    static let description = IntentDescription("Resume o que os seus agentes estão fazendo, em todas as boxes.", categoryName: "Agentes")
    static let openAppWhenRun = false

    @MainActor
    static func gather() async throws -> (items: [SessionEntity], counts: AgentCounts, text: String) {
        let rows = try await HeadlessBoxes.sessions()
        let items = IntentCatalog.entities(from: rows, prefs: LocalPrefs())
        let counts = AgentCounts(items: items.map(\.state))
        return (items, counts, counts.summary(IntentCatalog.language))
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let g = try await Self.gather()
        return .result(dialog: IntentDialog(stringLiteral: g.text), view: AgentsSnippetView(items: g.items, counts: g.counts))
    }
}

// MARK: - Faxina

/// Updates every project's main and removes what nobody uses any more, on every box: only the steps that lose nothing
/// (the app's Faxina screen shows the rest). Meant for a daily Shortcuts automation.
struct HousekeepingIntent: AppIntent {
    static let title: LocalizedStringResource = "Faxina nas boxes"
    static let description = IntentDescription("Atualiza a main de cada projeto e remove worktrees, serviços e sessões que sobraram, só o que não perde trabalho.", categoryName: "Agentes")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let boxes = try HeadlessBoxes.all().map { (name: $0.name, client: $0.client) }
        let r = await Housekeeper.runSafe(boxes)
        let left = r.plans.flatMap(\.steps).filter { !$0.safe }.count
        var text = Housekeeper.summary(r.outcomes)
        if left > 0 { text += String(localized: ". \(left) item(ns) com trabalho não enviado ficaram para você decidir no app.") }
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: - Mandar mensagem

struct SendMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Mandar mensagem para o agente"
    static let description = IntentDescription("Envia uma mensagem a um agente; ela chega quando ele estiver livre.", categoryName: "Agentes")
    static let openAppWhenRun = false

    @Parameter(title: "Agente", requestValueDialog: "Para qual agente?")
    var session: SessionEntity

    @Parameter(title: "Mensagem", requestValueDialog: "O que você quer dizer?")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Mandar \(\.$text) para \(\.$session)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await SessionActions.send(box: session.box, session: session.session, text: text, when: .idle) {
        case .success:
            return .result(dialog: "Mensagem enviada para \(session.title)")
        case .failure(let f):
            throw IntentFailure(f.message)
        }
    }
}

struct IntentFailure: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

// MARK: - Snippet

struct AgentsSnippetView: View {
    let items: [SessionEntity]
    let counts: AgentCounts
    private let limit = 6

    private func color(_ state: String) -> Color {
        switch state {
        case "waiting": Theme.orange
        case "running": Theme.accent
        case "finished": Theme.green
        default: Theme.gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if items.isEmpty {
                Text("Nenhum agente ativo.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(items.prefix(limit), id: \.id) { e in
                HStack(spacing: 10) {
                    Image(systemName: AgentStateText.symbol(e.state)).foregroundStyle(color(e.state)).frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text("\(e.project) · \(e.stateText)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            if items.count > limit {
                Text("+\(items.count - limit) outros").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - App Shortcuts

struct PierShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateTaskIntent(),
            phrases: [
                "Nova tarefa no \(.applicationName)",
                "Criar tarefa no \(.applicationName)",
                "Criar tarefa no \(.applicationName) em \(\.$project)",
                "Nova tarefa em \(\.$project) no \(.applicationName)",
            ],
            shortTitle: "Nova tarefa", systemImageName: "plus.bubble")
        AppShortcut(
            intent: AgentsStatusIntent(),
            phrases: [
                "Status dos agentes no \(.applicationName)",
                "O que os agentes do \(.applicationName) estão fazendo",
                "O que meus agentes estão fazendo no \(.applicationName)",
                "Meus agentes no \(.applicationName)",
            ],
            shortTitle: "Status dos agentes", systemImageName: "person.2.wave.2")
        AppShortcut(
            intent: SendMessageIntent(),
            phrases: [
                "Mandar mensagem para o agente no \(.applicationName)",
                "Mandar mensagem para \(\.$session) no \(.applicationName)",
            ],
            shortTitle: "Mensagem ao agente", systemImageName: "paperplane")
        AppShortcut(
            intent: AllowAgentRequestIntent(),
            phrases: [
                "Permitir o pedido do agente no \(.applicationName)",
                "Permitir o agente no \(.applicationName)",
            ],
            shortTitle: "Permitir pedido", systemImageName: "checkmark.shield")
        AppShortcut(
            intent: DenyAgentRequestIntent(),
            phrases: [
                "Negar o pedido do agente no \(.applicationName)",
                "Negar o agente no \(.applicationName)",
            ],
            shortTitle: "Negar pedido", systemImageName: "xmark.shield")
        AppShortcut(
            intent: HousekeepingIntent(),
            phrases: [
                "Faxina no \(.applicationName)",
                "Limpar as boxes no \(.applicationName)",
            ],
            shortTitle: "Faxina", systemImageName: "sparkles")
    }
}

// MARK: - Permitir / negar o pedido do agente (Siri, Atalhos)

/// Picks the session to answer: the given one, else the only agent waiting on a permission; asks when there are several.
private func permissionTarget(_ chosen: SessionEntity?) async throws -> (box: String, session: String, title: String) {
    if let chosen { return (chosen.box, chosen.session, chosen.title) }
    let waiting = try await IntentCatalog.sessions().filter { $0.state == "waiting" }
    guard let first = waiting.first else { throw IntentFailure(String(localized: "Nenhum agente está esperando por você.")) }
    guard waiting.count == 1 else { throw IntentFailure(String(localized: "Mais de um agente precisa de você. Diga qual.")) }
    return (first.box, first.session, first.title)
}

struct AllowAgentRequestIntent: AppIntent {
    static let title: LocalizedStringResource = "Permitir o pedido do agente"
    static let description = IntentDescription("Permite a ação que um agente está pedindo (sem argumento: o único agente esperando).", categoryName: "Agentes")
    static let openAppWhenRun = false
    /// Allowing runs code on the box: unlock first.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Agente")
    var session: SessionEntity?

    static var parameterSummary: some ParameterSummary { Summary("Permitir o pedido de \(\.$session)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let t = try await permissionTarget(session)
        if case .failure(let f) = await SessionActions.answerPermission(box: t.box, session: t.session, .allow) { throw IntentFailure(f.message) }
        return .result(dialog: "Permitido: \(t.title)")
    }
}

struct DenyAgentRequestIntent: AppIntent {
    static let title: LocalizedStringResource = "Negar o pedido do agente"
    static let description = IntentDescription("Nega a ação que um agente está pedindo (sem argumento: o único agente esperando).", categoryName: "Agentes")
    static let openAppWhenRun = false

    @Parameter(title: "Agente")
    var session: SessionEntity?

    static var parameterSummary: some ParameterSummary { Summary("Negar o pedido de \(\.$session)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let t = try await permissionTarget(session)
        if case .failure(let f) = await SessionActions.answerPermission(box: t.box, session: t.session, .deny) { throw IntentFailure(f.message) }
        return .result(dialog: "Negado: \(t.title)")
    }
}
