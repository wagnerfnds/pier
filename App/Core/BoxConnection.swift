import Foundation
import PierKit

enum ConnState: Equatable {
    case connecting
    case online
    case offline(String)
    case revoked
    case pinMismatch

    var isOnline: Bool { self == .online }
}

/// One paired box: its client, connection state and cached resources.
@MainActor @Observable
final class BoxConnection: Identifiable {
    nonisolated var id: String { record.name }
    let record: BoxRecord
    let client: any PierBoxClient
    let raw: any PierTransport

    var state: ConnState = .connecting
    var info: BoxInfo?
    var stats: BoxStats?
    var locations: [Location] = []
    var sessions: [Session] = []
    var hasLoadedSessions = false

    /// Called when a session's agent state changes (not on first load).
    @ObservationIgnored var onTransition: ((BoxConnection, Session, AgentState?, AgentState?) -> Void)?
    /// Called after sessions or the connection state changed (feeds widgets and Live Activities).
    @ObservationIgnored var onChange: ((BoxConnection) -> Void)?
    @ObservationIgnored private var refreshTasks: [String: Task<Void, Never>] = [:]

    init(record: BoxRecord, client: any PierBoxClient, raw: any PierTransport) {
        self.record = record
        self.client = client
        self.raw = raw
    }

    var name: String { record.name }

    // MARK: classification

    private func apply(error: Error) {
        if let e = error as? PierError {
            switch e {
            case .unauthorized: state = .revoked
            case .pinMismatch: state = .pinMismatch
            default: state = .offline(e.localizedDescription)
            }
        } else if error is CancellationError {
            return
        } else {
            state = .offline(error.localizedDescription)
        }
    }

    // MARK: loading

    func connect() async {
        if state != .online { state = .connecting }
        do {
            async let i = client.info()
            async let s = client.sessions()
            async let l = client.locations()
            info = try await i
            applySessions(try await s)
            locations = try await l
            state = .online
        } catch {
            apply(error: error)
            onChange?(self)
            return
        }
        onChange?(self)
        await refreshStats()
    }

    func refreshSessions() async {
        do {
            applySessions(try await client.sessions())
            state = .online
        } catch { apply(error: error) }
        onChange?(self)
    }

    func refreshLocations() async {
        do { locations = try await client.locations() } catch { apply(error: error) }
    }

    func refreshStats() async {
        do { stats = try await client.stats() } catch { if !(error is CancellationError) { /* keep old */ } }
    }

    /// Debounced refresh (events arrive in bursts).
    func scheduleRefresh(sessions: Bool = false, locations: Bool = false) {
        if sessions { schedule("sessions") { await self.refreshSessions() } }
        if locations { schedule("locations") { await self.refreshLocations() } }
    }

    private func schedule(_ key: String, _ work: @escaping @MainActor () async -> Void) {
        if refreshTasks[key] != nil { return }
        refreshTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            await work()
            self?.refreshTasks[key] = nil
        }
    }

    private func applySessions(_ new: [Session]) {
        let old = Dictionary(uniqueKeysWithValues: sessions.map { ($0.name, $0.agentState) })
        let first = !hasLoadedSessions
        sessions = new
        hasLoadedSessions = true
        StateSnapshot.save(box: name, sessions: new)
        guard !first else { return }
        for s in new where s.isAgent && !s.exited {
            let before = old[s.name] ?? nil
            if before != s.agentState { onTransition?(self, s, before, s.agentState) }
        }
    }

    // MARK: lookups

    func location(named n: String) -> Location? { locations.first { $0.name == n } }
}

/// Last seen agent states per box, so background refresh can tell what changed while the app was away.
enum StateSnapshot {
    private static let key = "stateSnapshot.v1"
    private static var defaults: UserDefaults { .standard }

    static func load() -> [String: [String: String]] {
        (defaults.dictionary(forKey: key) as? [String: [String: String]]) ?? [:]
    }
    static func save(box: String, sessions: [Session]) {
        var all = load()
        all[box] = Dictionary(uniqueKeysWithValues: sessions.filter { $0.isAgent && !$0.exited }
            .map { ($0.name, $0.agentState?.rawValue ?? "") })
        defaults.set(all, forKey: key)
    }
    static func forget(box: String) {
        var all = load(); all[box] = nil; defaults.set(all, forKey: key)
    }
}

