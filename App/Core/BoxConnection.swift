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
    /// Called when the box names another relay than the record has (`GET /v1/info`): the record is updated and the
    /// box reconnected with it, so it is reachable away from its network.
    @ObservationIgnored var onRelay: ((BoxConnection, String?) -> Void)?
    @ObservationIgnored private var refreshTasks: [String: Task<Void, Never>] = [:]
    /// Refreshes whose request is on its way, and those an event asked for meanwhile (the answer may predate it).
    @ObservationIgnored private var refreshRunning: Set<String> = []
    @ObservationIgnored private var refreshAgain: Set<String> = []

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
            case .unauthorized: set(\.state, .revoked)
            case .pinMismatch: set(\.state, .pinMismatch)
            default: set(\.state, .offline(e.localizedDescription))
            }
        } else if error is CancellationError {
            return
        } else {
            set(\.state, .offline(error.localizedDescription))
        }
    }

    // MARK: loading

    func connect() async {
        if state != .online { state = .connecting }
        do {
            async let i = client.info()
            async let s = client.sessions()
            async let l = client.locations()
            set(\.info, try await i)
            applySessions(try await s)
            set(\.locations, try await l)
            set(\.state, .online)
            if info?.relay != record.relay { onRelay?(self, info?.relay) }
        } catch {
            apply(error: error)
            onChange?(self)
            return
        }
        onChange?(self)
        await refreshStats()
    }

    func refreshSessions() async {
        let was = state
        var changed = false
        do {
            let list = try await client.sessions()
            changed = Perf.interval("sessions.apply") { applySessions(list) }
            set(\.state, .online)
        } catch { apply(error: error) }
        // Widgets and Live Activities follow changes only: most refreshes find the list as it was.
        if changed || state != was { onChange?(self) }
    }

    func refreshLocations() async {
        do { set(\.locations, try await client.locations()) } catch { apply(error: error) }
    }

    func refreshStats() async {
        do { set(\.stats, try await client.stats()) } catch { if !(error is CancellationError) { /* keep old */ } }
    }

    /// Debounced refresh (events arrive in bursts).
    func scheduleRefresh(sessions: Bool = false, locations: Bool = false) {
        if sessions { schedule("sessions") { await self.refreshSessions() } }
        if locations { schedule("locations") { await self.refreshLocations() } }
    }

    private func schedule(_ key: String, _ work: @escaping @MainActor () async -> Void) {
        if refreshTasks[key] != nil {
            // Still waiting to start: it will see this change. Already asking: its answer may be from before the event,
            // so it runs once more after (an agent's new state used to wait for the next event).
            if refreshRunning.contains(key) { refreshAgain.insert(key) }
            return
        }
        refreshTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            self?.refreshRunning.insert(key)
            await work()
            guard let self else { return }
            refreshRunning.remove(key)
            refreshTasks[key] = nil
            if refreshAgain.remove(key) != nil { schedule(key, work) }
        }
    }

    /// True when the list changed.
    @discardableResult
    private func applySessions(_ new: [Session]) -> Bool {
        let old = Dictionary(uniqueKeysWithValues: sessions.map { ($0.name, $0.agentState) })
        let first = !hasLoadedSessions
        // Unchanged lists (most polls) touch nothing: every sidebar, Home, Inbox and Board reader would redraw, and the
        // snapshot's UserDefaults write wakes everything listening to UserDefaults. A terminal connecting changes only
        // `attached`, which counts as unchanged.
        guard first || !Session.sameListing(new, sessions) else { return false }
        sessions = new
        if first { hasLoadedSessions = true }
        StateSnapshot.save(box: name, sessions: new)
        guard !first else { return true }
        for s in new where s.isAgent && !s.exited {
            let before = old[s.name] ?? nil
            if before != s.agentState { onTransition?(self, s, before, s.agentState) }
        }
        return true
    }

    /// Assigns only a different value: an @Observable property invalidates its readers on every write, equal or not.
    private func set<T: Equatable>(_ key: ReferenceWritableKeyPath<BoxConnection, T>, _ value: T) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
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
        let states = Dictionary(uniqueKeysWithValues: sessions.filter { $0.isAgent && !$0.exited }
            .map { ($0.name, $0.agentState?.rawValue ?? "") })
        guard all[box] != states else { return }
        all[box] = states
        defaults.set(all, forKey: key)
    }
    static func forget(box: String) {
        var all = load(); all[box] = nil; defaults.set(all, forKey: key)
    }
}

