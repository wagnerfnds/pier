import SwiftUI
import PierKit

/// The boxes' doctor reports (`GET /v1/doctor`), read every 10 minutes while a box is online (at once on pull-to-refresh),
/// as Inbox cards: what the box needs the person to do, with the command to run there. A box that cannot be reached is a
/// card too. The words for each kind of problem are `HealthWords`; the rules are `BoxHealth` (PierKit, tested).
@MainActor @Observable
final class BoxHealthStore {
    static let shared = BoxHealthStore()

    struct Card: Identifiable, Hashable {
        let box: String
        let issue: BoxHealth.Issue
        var id: String { "health/\(box)/\(issue.id)" }
    }

    /// Box -> the issues its last report named.
    private(set) var reports: [String: [BoxHealth.Issue]] = [:]
    /// Cards on their way out ("Ignorar por hoje" waiting the undo window).
    private(set) var hidden: Set<String> = []
    @ObservationIgnored private var readAt: [String: Date] = [:]
    @ObservationIgnored private var busy: Set<String> = []

    /// Reads the report of every online box whose last one is older than 10 minutes (every one with `force`).
    func refresh(model: AppModel, force: Bool = false) async {
        let due = model.boxes.filter { c in
            c.state.isOnline && !busy.contains(c.name) && (force || Date().timeIntervalSince(readAt[c.name] ?? .distantPast) >= 600)
        }
        guard !due.isEmpty else { return }
        for c in due { busy.insert(c.name) }
        defer { for c in due { busy.remove(c.name) } }
        let found: [(String, [BoxHealth.Issue]?)] = await withTaskGroup(of: (String, [BoxHealth.Issue]?).self) { g in
            for c in due {
                let (name, client) = (c.name, c.client)
                g.addTask { (name, (try? await client.doctor()).map(BoxHealth.issues(in:))) }
            }
            var out: [(String, [BoxHealth.Issue]?)] = []
            for await r in g { out.append(r) }
            return out
        }
        for (box, issues) in found {
            readAt[box] = Date()
            // A failed read keeps the last report (and is tried again on the next tick, 10 minutes on).
            if let issues, issues != reports[box] { withAnimation(.snappy) { reports[box] = issues } }
        }
    }

    /// The cards, in the boxes' order: a box out of reach first, then what its report named; snoozed ones left out.
    func cards(model: AppModel) -> [Card] {
        var out: [Card] = []
        for c in model.boxes {
            switch c.state {
            case .offline(let why):
                out.append(Card(box: c.name, issue: BoxHealth.Issue(id: "box/unreachable", kind: .unreachable, severity: .fail, name: "unreachable", detail: why)))
            case .revoked:
                out.append(Card(box: c.name, issue: BoxHealth.Issue(id: "box/revoked", kind: .revoked, severity: .fail, name: "revoked", fix: "pierd pair")))
            case .pinMismatch:
                out.append(Card(box: c.name, issue: BoxHealth.Issue(id: "box/key", kind: .keyChanged, severity: .fail, name: "key")))
            case .online:
                for i in reports[c.name] ?? [] { out.append(Card(box: c.name, issue: i)) }
            case .connecting:
                break
            }
        }
        return out.filter { !hidden.contains($0.id) && !model.prefs.isHealthSnoozed($0.id) }
    }

    /// "Ignorar por hoje": out of the Inbox until tomorrow, after the undo window (the card leaves at once; "Desfazer"
    /// brings it back). The box is not changed by this.
    func snooze(_ card: Card, model: AppModel) {
        Haptic.impact(.light)
        withAnimation(.snappy) { _ = hidden.insert(card.id) }
        PendingActions.shared.schedule(label: S("Ignorar por hoje · \(HealthWords.title(card))"), symbol: "clock.badge.xmark", perform: { [weak self] in
            model.prefs.snoozeHealth(card.id, until: Date().addingTimeInterval(86400))
            self?.hidden.remove(card.id)
        }, onUndo: { [weak self] in
            withAnimation(.snappy) { _ = self?.hidden.remove(card.id) }
        })
    }
}

/// The person's words for what a box's doctor reports, one title and one line each (the raw detail stays as a second line
/// where it says more than the title). Commands come from pierd as they are.
enum HealthWords {
    static func title(_ c: BoxHealthStore.Card) -> String {
        let box = c.box
        switch c.issue.kind {
        case .agentSignIn(let agent): return S("\(agent) não está autenticado em \(box)")
        case .agentHooks(let agent): return S("Hooks do \(agent) não instalados em \(box)")
        case .noAgents: return S("Nenhum agente instalado em \(box)")
        case .tool(let name): return S("\(name) não está instalado em \(box)")
        case .service: return S("O pierd não inicia com a box \(box)")
        case .lingering: return S("O pierd para quando você sai da box \(box)")
        case .listening: return S("O pierd em \(box) responde em todas as interfaces")
        case .location(let name): return S("O projeto \(name) sumiu da box \(box)")
        case .events(let name): return S("Eventos perdidos em \(box) (\(name))")
        case .unreachable: return S("A box \(box) está fora de alcance")
        case .revoked: return S("O acesso à box \(box) foi revogado")
        case .keyChanged: return S("A chave da box \(box) mudou")
        case .other(_, let name): return S("\(name) precisa de atenção em \(box)")
        }
    }

    /// What it means for the person, in one line; nil when the title says it all.
    static func body(_ c: BoxHealthStore.Card) -> String? {
        switch c.issue.kind {
        case .agentSignIn: return S("Uma sessão nova pararia na tela de login do agente.")
        case .agentHooks: return S("Sem eles, o Pier não sabe quando o agente termina ou precisa de você.")
        case .noAgents: return S("Instale o Claude Code ou o Codex na box para criar tarefas.")
        case .service: return S("Se a box reiniciar, o Pier perde o contato até alguém rodar o pierd de novo.")
        case .lingering: return S("Com o lingering ligado, o pierd continua depois do logout.")
        case .listening: return S("Melhor ouvir só no endereço da tailnet: pierd install faz isso.")
        case .location: return S("O pierd ainda lista a pasta; remova ou mova o projeto de volta.")
        case .unreachable: return S("Confira a rede ou a VPN; o app tenta de novo sozinho.")
        case .revoked: return S("Pareie de novo a partir da box, ou de um aparelho que ainda tem acesso.")
        case .keyChanged: return S("Se foi você quem reinstalou o pierd, despareie e pareie de novo; se não, desconfie.")
        case .tool, .events, .other: return nil
        }
    }

    /// The raw line from the report, when it adds something the words above do not say.
    static func detail(_ c: BoxHealthStore.Card) -> String? {
        switch c.issue.kind {
        case .agentSignIn, .agentHooks, .noAgents, .service, .lingering, .revoked, .keyChanged: return nil
        default: return c.issue.detail
        }
    }

    /// "Na box:" for a command, nothing for a sentence (pierd's fixes are commands unless they start with a capital).
    static func fixIsCommand(_ fix: String) -> Bool {
        guard let f = fix.first else { return false }
        return !f.isUppercase && !fix.hasPrefix("http")
    }
}
