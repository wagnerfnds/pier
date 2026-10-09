import AppIntents
import CoreSpotlight
import PierKit

// MARK: - Project

/// A repo location on a paired box, named the way the phone shows it (renames honoured).
struct ProjectEntity: AppEntity, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Projeto")
    static let defaultQuery = ProjectQuery()

    /// "<box>/<location>" (`LocalPrefs.key`).
    let id: String
    let box: String
    let location: String
    let name: String
    let boxCount: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: boxCount > 1 ? "\(box)" : nil, image: .init(systemName: "folder"))
    }
}

struct ProjectQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ProjectEntity] {
        let all = try await IntentCatalog.projects()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    /// Recent projects first, then the phone's sections in order, then the rest.
    func suggestedEntities() async throws -> [ProjectEntity] {
        try await IntentCatalog.projects()
    }

    func entities(matching string: String) async throws -> [ProjectEntity] {
        let q = string.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return try await IntentCatalog.projects().filter {
            $0.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).contains(q)
                || $0.location.localizedCaseInsensitiveContains(string)
        }
    }
}

// MARK: - Session

struct SessionEntity: AppEntity, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agente")
    static let defaultQuery = SessionQuery()

    /// "<box>/<session>".
    let id: String
    let box: String
    let session: String
    let title: String
    let project: String
    let agent: String
    /// "waiting", "running", ...
    let state: String

    var stateText: String { AgentStateText.label(state) }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(project) · \(stateText)", image: .init(systemName: AgentStateText.symbol(state)))
    }
}

struct SessionQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SessionEntity] {
        let all = try await IntentCatalog.sessions()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    /// Live sessions, the ones that need the person first.
    func suggestedEntities() async throws -> [SessionEntity] {
        try await IntentCatalog.sessions()
    }

    func entities(matching string: String) async throws -> [SessionEntity] {
        try await IntentCatalog.sessions().filter {
            $0.title.localizedStandardContains(string) || $0.project.localizedStandardContains(string) || $0.session.localizedStandardContains(string)
        }
    }
}

// MARK: - Agent (claude, codex, ...)

struct AgentEntity: AppEntity, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agente de código")
    static let defaultQuery = AgentQuery()

    /// The preset id on the box: "claude", "codex", ...
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "sparkles"))
    }
}

struct AgentQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AgentEntity] {
        let all = await IntentCatalog.agents()
        return identifiers.compactMap { id in all.first { $0.id == id } ?? AgentEntity(id: id, name: id.capitalized) }
    }
    func suggestedEntities() async throws -> [AgentEntity] { await IntentCatalog.agents() }
    func entities(matching string: String) async throws -> [AgentEntity] {
        await IntentCatalog.agents().filter { $0.id.localizedCaseInsensitiveContains(string) || $0.name.localizedCaseInsensitiveContains(string) }
    }
}

// MARK: - Spotlight (iOS 18+)

@available(iOS 18.0, *)
extension ProjectEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let a = CSSearchableItemAttributeSet(contentType: .content)
        a.displayName = name
        a.contentDescription = String(localized: "Projeto no Pier · \(box)")
        a.keywords = [name, location, "pier"]
        return a
    }
}

@available(iOS 18.0, *)
extension SessionEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let a = CSSearchableItemAttributeSet(contentType: .content)
        a.displayName = title
        a.contentDescription = "\(project) · \(stateText)"
        a.keywords = [title, project, agent, "pier"]
        return a
    }
}

enum SpotlightIndexer {
    /// Re-indexes projects and live sessions (iOS 18+); best effort.
    static func reindex() async {
        guard #available(iOS 18.0, *) else { return }
        guard let projects = try? await IntentCatalog.projects(), let sessions = try? await IntentCatalog.sessions() else { return }
        let index = CSSearchableIndex.default()
        try? await index.deleteAppEntities(ofType: ProjectEntity.self)
        try? await index.deleteAppEntities(ofType: SessionEntity.self)
        try? await index.indexAppEntities(projects)
        try? await index.indexAppEntities(sessions)
    }
}
