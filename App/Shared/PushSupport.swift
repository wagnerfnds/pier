import Foundation
import PierKit

/// Push state shared by the app, the widget extension and background refresh (App Group file `push-state.json`).
struct PushState: Codable, Sendable, Equatable {
    var deviceToken: String?
    var widgetToken: String?
    var pushToStartToken: String?
    var events = PushEvents()
    /// Box name -> when `PUT /v1/push/device` last succeeded. A box in here pushes itself, so local notifications stand down.
    var registered: [String: Date] = [:]

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceToken = try c.decodeIfPresent(String.self, forKey: .deviceToken)
        widgetToken = try c.decodeIfPresent(String.self, forKey: .widgetToken)
        pushToStartToken = try c.decodeIfPresent(String.self, forKey: .pushToStartToken)
        events = try c.decodeIfPresent(PushEvents.self, forKey: .events) ?? PushEvents()
        registered = try c.decodeIfPresent([String: Date].self, forKey: .registered) ?? [:]
    }
}

enum PushStateStore {
    private static var url: URL { Shared.fileURL("push-state.json") }
    private static let lock = NSLock()

    static func load() -> PushState {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    /// Read-modify-write (serialized inside this process; the file is small and writes are atomic).
    @discardableResult
    static func update(_ change: (inout PushState) -> Void) -> PushState {
        lock.lock(); defer { lock.unlock() }
        var s = read()
        change(&s)
        if let d = try? Shared.encoder().encode(s) { try? d.write(to: url, options: .atomic) }
        return s
    }

    private static func read() -> PushState {
        guard let d = try? Data(contentsOf: url), let s = try? Shared.decoder().decode(PushState.self, from: d) else { return PushState() }
        return s
    }
}

/// What the app knows about one box's push routes (pierd).
enum BoxPushStatus: Sendable, Equatable {
    case unknown
    case registering
    case registered(Date)
    /// The box's push routes do not answer (push not set up in pierd, box down, firewall).
    case unreachable
    /// The push routes answered but refused or failed (not authorised, pin mismatch, wrong service...).
    case failed(String)

    var isRegistered: Bool { if case .registered = self { return true }; return false }
}

enum PushRegistrar {
    /// The APNs environment this build's token belongs to. The signed `aps-environment` entitlement decides it, and it is
    /// not always what the configuration suggests (a Release build installed from Xcode is signed with the development
    /// profile). So: read it from the embedded profile when there is one (development / ad hoc builds:
    /// `embedded.mobileprovision` on iOS, `Contents/embedded.provisionprofile` on the Mac, whose key is
    /// `com.apple.developer.aps-environment`); a build without a profile is App Store / TestFlight, hence production.
    /// Debug/Release only matters as a last fallback.
    static var env: PushEnvironment { detectedEnv }

    private static let detectedEnv: PushEnvironment = {
        let profiles = [Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
                        Bundle.main.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile")]
        if let data = profiles.lazy.compactMap({ $0.flatMap { try? Data(contentsOf: $0) } }).first {
            let text = String(decoding: data, as: UTF8.self)
            if let r = text.range(of: "aps-environment</key>"),
               let open = text.range(of: "<string>", range: r.upperBound..<text.endIndex),
               let close = text.range(of: "</string>", range: open.upperBound..<text.endIndex) {
                return text[open.upperBound..<close.lowerBound] == "production" ? .production : .development
            }
            return .development
        }
        #if DEBUG || targetEnvironment(simulator)
        return .development
        #else
        return .production
        #endif
    }()

    /// The language the app itself runs in (honours the per-app language set in iOS Settings), so pushes match the UI.
    static var locale: String { Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "pt-BR" }

    static func registration(state: PushState, box: String) -> PushDeviceRegistration? {
        guard let token = state.deviceToken else { return nil }
        return PushDeviceRegistration(deviceToken: token, env: env, locale: locale, events: state.events,
                                      widgetToken: state.widgetToken, pushToStartToken: state.pushToStartToken, boxName: box)
    }

    static func deadline<T: Sendable>(_ d: Duration, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { g in
            g.addTask { try await op() }
            g.addTask { try await Task.sleep(for: d); throw PierError.timeout }
            defer { g.cancelAll() }
            return try await g.next()!
        }
    }

    static func classify(_ error: Error) -> BoxPushStatus {
        guard let e = error as? PierError else { return .failed(error.localizedDescription) }
        switch e {
        case .transport, .timeout, .tls: return .unreachable
        case .unauthorized: return .failed("unauthorized")
        case .pinMismatch: return .failed("pin")
        case .api(let status, let message, _): return .failed("\(status) \(message)")
        default: return .failed(e.localizedDescription)
        }
    }

    /// Checks the box's push routes (`info`) and registers this device. Never throws; the answer is the status.
    static func register(client: PushClient, box: String, state: PushState, timeout: Duration = .seconds(8)) async -> BoxPushStatus {
        guard let reg = registration(state: state, box: box) else { return .unknown }
        do {
            _ = try await deadline(timeout) { try await client.info() }
            try await deadline(timeout) { try await client.putDevice(reg) }
            return .registered(Date())
        } catch {
            return classify(error)
        }
    }

    /// Registers with every box in `access`; records successes (and clears failures) in `PushState.registered`.
    static func registerAll(access: BoxAccess) async -> [String: BoxPushStatus] {
        let state = PushStateStore.load()
        guard state.deviceToken != nil else { return [:] }
        var out: [String: BoxPushStatus] = [:]
        await withTaskGroup(of: (String, BoxPushStatus).self) { g in
            for rec in access.records {
                g.addTask {
                    let client = PushClient(box: rec, identity: access.identity)
                    return (rec.name, await register(client: client, box: rec.name, state: state))
                }
            }
            for await (name, st) in g { out[name] = st }
        }
        record(out)
        return out
    }

    static func record(_ statuses: [String: BoxPushStatus]) {
        PushStateStore.update { s in
            for (name, st) in statuses {
                if case .registered(let d) = st { s.registered[name] = d } else if st != .registering && st != .unknown { s.registered[name] = nil }
            }
        }
    }

    // MARK: local-notification dedupe

    /// Local fallback notification gate for a transition into `state`. False when the person turned that kind off, or when
    /// push on that box is registered and still answering (it sends the push, so a local one would be a duplicate).
    static func shouldPostLocal(box: BoxRecord, identity: PierIdentity, state agent: AgentState?, prefs: PushState = PushStateStore.load(),
                                probe: Bool) async -> Bool {
        switch agent {
        case .waiting: if !prefs.events.waiting { return false }
        case .finished: if !prefs.events.finished { return false }
        default: break
        }
        guard prefs.deviceToken != nil, prefs.registered[box.name] != nil else { return true }
        guard probe else { return false }
        let client = PushClient(box: box, identity: identity)
        return (try? await deadline(.seconds(4)) { try await client.info() }) == nil
    }
}
