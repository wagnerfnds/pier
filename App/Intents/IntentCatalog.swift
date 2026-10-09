import Foundation
import PierKit

/// pt-BR/en labels for agent states, shared by entities, snippets and dialogs.
enum AgentStateText {
    static func label(_ state: String) -> String {
        switch state {
        case "waiting": String(localized: "precisa de você")
        case "running": String(localized: "trabalhando")
        case "finished": String(localized: "terminou")
        case "idle": String(localized: "parado")
        default: state
        }
    }
    static func symbol(_ state: String) -> String {
        switch state {
        case "waiting": "exclamationmark.bubble.fill"
        case "running": "gearshape.2.fill"
        case "finished": "checkmark.circle.fill"
        default: "pause.circle"
        }
    }
    /// Sort rank: needs you first.
    static func rank(_ state: String) -> Int {
        switch state { case "waiting": 0; case "running": 1; case "finished": 2; default: 3 }
    }
}

/// Reads boxes without the UI and turns the result into entities (honouring the phone's renames, sections and hidden projects).
enum IntentCatalog {
    static var language: AgentCounts.Language { Locale.current.language.languageCode?.identifier == "pt" ? .pt : .en }

    @MainActor private static func prefs() -> LocalPrefs { LocalPrefs() }

    static func projects() async throws -> [ProjectEntity] {
        let snaps = try await HeadlessBoxes.snapshots()
        return await MainActor.run {
            let prefs = prefs()
            var all: [ProjectEntity] = []
            for s in snaps {
                for l in s.locations where l.repo && !prefs.isHidden(box: s.box.name, location: l.name) {
                    all.append(ProjectEntity(id: LocalPrefs.key(box: s.box.name, location: l.name), box: s.box.name, location: l.name,
                                             name: prefs.displayName(box: s.box.name, location: l.name), boxCount: snaps.count))
                }
            }
            // Recent, then the sections in the user's order, then alphabetical.
            var rank: [String: Int] = [:]
            for (i, k) in prefs.recentProjects.enumerated() { rank[k] = i }
            var next = 1000
            for sec in prefs.sections { for k in sec.projects where rank[k] == nil { rank[k] = next; next += 1 } }
            return all.sorted { a, b in
                let ra = rank[a.id] ?? Int.max, rb = rank[b.id] ?? Int.max
                return ra != rb ? ra < rb : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    @MainActor
    static func entities(from rows: [(box: String, session: Session)], prefs: LocalPrefs) -> [SessionEntity] {
        rows.compactMap { box, s -> SessionEntity? in
            guard s.isAgent, !s.exited else { return nil }
            let bs = BoxSession(box: box, session: s)
            if !bs.location.isEmpty, prefs.isHidden(box: box, location: bs.location) { return nil }
            return SessionEntity(id: bs.id, box: box, session: s.name, title: s.displayTitle,
                                 project: s.chat ? BoxSession.chatPlace : bs.location.isEmpty ? s.name : prefs.displayName(box: box, location: bs.location),
                                 agent: s.agent ?? "", state: s.agentState?.rawValue ?? "idle")
        }
        .sorted { (AgentStateText.rank($0.state), $0.title) < (AgentStateText.rank($1.state), $1.title) }
    }

    static func sessions() async throws -> [SessionEntity] {
        let rows = try await HeadlessBoxes.sessions()
        return await MainActor.run { entities(from: rows, prefs: prefs()) }
    }

    static func agents() async -> [AgentEntity] {
        var seen = Set<String>()
        var out: [AgentEntity] = []
        for s in (try? await HeadlessBoxes.snapshots(withLocations: false)) ?? [] {
            for a in s.info?.agents ?? [] where seen.insert(a.id).inserted {
                out.append(AgentEntity(id: a.id, name: a.name.isEmpty ? a.id.capitalized : a.name))
            }
        }
        if out.isEmpty { out = [AgentEntity(id: "claude", name: "Claude"), AgentEntity(id: "codex", name: "Codex")] }
        return out
    }
}
