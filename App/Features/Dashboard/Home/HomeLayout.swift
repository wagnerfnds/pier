import SwiftUI

/// The Home widgets.
enum HomeWidgetKind: String, CaseIterable, Codable, Identifiable {
    case needsYou, working, finished, prs, projectPRs, ci, git, services, areas, limits

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .needsYou: "Precisa de você"
        case .working: "Trabalhando agora"
        case .finished: "Sua vez"
        case .prs: "Pull requests"
        case .projectPRs: "PRs dos projetos"
        case .ci: "Falhas de CI"
        case .git: "Atividade git"
        case .services: "Serviços rodando"
        case .areas: "Áreas recentes"
        case .limits: "Limites de uso"
        }
    }
    var subtitle: LocalizedStringKey {
        switch self {
        case .needsYou: "Agentes esperando uma permissão ou resposta"
        case .working: "Cada agente trabalhando e o passo em que está"
        case .finished: "Turnos concluídos esperando você continuar; as sessões arquivadas ou encerradas ficam recolhidas"
        case .prs: "Aguardando sua revisão e os seus, com os checks"
        case .projectPRs: "Os abertos nos projetos das suas boxes, de qualquer pessoa"
        case .ci: "Execuções que falharam nas branches das suas worktrees"
        case .git: "Commits e linhas por dia nas últimas duas semanas"
        case .services: "Servidores de desenvolvimento nas suas worktrees"
        case .areas: "Worktrees em que você e seus agentes trabalharam"
        case .limits: "Quanto já foi usado das assinaturas do Claude e do Codex, por conta"
        }
    }
    var symbol: String {
        switch self {
        case .needsYou: "hand.raised.fill"
        case .working: "waveform.path.ecg"
        case .finished: "checkmark.circle"
        case .prs: "arrow.triangle.pull"
        case .projectPRs: "person.2"
        case .ci: "xmark.octagon"
        case .git: "chart.bar.xaxis"
        case .services: "dot.radiowaves.left.and.right"
        case .areas: "arrow.triangle.branch"
        case .limits: "gauge.with.dots.needle.50percent"
        }
    }
    /// Read on the box with gh/git (cached, refreshed every few minutes) rather than live from sessions.
    var isRemote: Bool { self == .prs || self == .projectPRs || self == .ci || self == .git || self == .limits }
}

/// Order and visibility of the widgets, kept on the phone (UserDefaults).
@MainActor @Observable
final class HomeLayout {
    struct Saved: Codable { var order: [HomeWidgetKind]; var hidden: Set<HomeWidgetKind> }

    private static let key = "home.layout.v1"
    static let defaultOrder: [HomeWidgetKind] = [.needsYou, .working, .finished, .limits, .prs, .projectPRs, .ci, .git, .services, .areas]

    private(set) var order: [HomeWidgetKind]
    private(set) var hidden: Set<HomeWidgetKind>
    @ObservationIgnored private let defaults: UserDefaults

    static let shared = HomeLayout()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let d = defaults.data(forKey: Self.key), let s = try? JSONDecoder().decode(Saved.self, from: d) {
            // A widget a later version adds shows up after the one it follows by default (at the end if that one is gone).
            var order = s.order
            for (i, k) in Self.defaultOrder.enumerated() where !order.contains(k) {
                if i > 0, let after = order.firstIndex(of: Self.defaultOrder[i - 1]) { order.insert(k, at: after + 1) } else { order.append(k) }
            }
            self.order = order
            hidden = s.hidden
        } else {
            order = Self.defaultOrder
            hidden = []
        }
    }

    var visible: [HomeWidgetKind] { order.filter { !hidden.contains($0) } }
    func isVisible(_ k: HomeWidgetKind) -> Bool { !hidden.contains(k) }

    func setVisible(_ visible: Bool, _ k: HomeWidgetKind) {
        if visible { hidden.remove(k) } else { hidden.insert(k) }
        save()
    }
    func move(from: IndexSet, to: Int) { order.move(fromOffsets: from, toOffset: to); save() }
    func reset() { order = Self.defaultOrder; hidden = []; save() }

    private func save() {
        if let d = try? JSONEncoder().encode(Saved(order: order, hidden: hidden)) { defaults.set(d, forKey: Self.key) }
    }
}
