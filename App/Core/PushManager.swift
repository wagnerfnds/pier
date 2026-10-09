import Foundation
import UIKit
import WidgetKit
import PierKit

extension Notification.Name {
    /// userInfo: "token" (hex String) or "error" (String).
    static let pierDeviceTokenChanged = Notification.Name("pier.deviceToken")
}

/// Remote push: device token, registration with each box's push routes (pierd, docs/PUSH.md), test and per-box status.
@MainActor @Observable
final class PushManager {
    @ObservationIgnored weak var model: AppModel?

    private(set) var deviceToken: String?
    private(set) var status: [String: BoxPushStatus] = [:]
    /// `registerForRemoteNotifications` failed (e.g. simulator without push, missing entitlement).
    private(set) var registrationError: String?
    /// Last "Enviar notificação de teste" outcome per box.
    private(set) var testResult: [String: TestOutcome] = [:]
    private(set) var testing: Set<String> = []

    enum TestOutcome: Equatable { case sent, failed(String) }

    var events: PushEvents {
        didSet {
            guard events != oldValue else { return }
            PushStateStore.update { $0.events = events }
            scheduleRegister()
        }
    }

    @ObservationIgnored private var clients: [String: PushClient] = [:]
    @ObservationIgnored private var registerTask: Task<Void, Never>?
    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    /// Seconds until the next automatic retry while a box's push routes do not answer (doubles up to 10 min).
    @ObservationIgnored private var retryDelay: Double = 30

    init() {
        let s = PushStateStore.load()
        deviceToken = s.deviceToken
        events = s.events
    }

    // MARK: lifecycle

    func begin() {
        UIApplication.shared.registerForRemoteNotifications()
        observer?.cancel()
        observer = Task { [weak self] in
            for await n in NotificationCenter.default.notifications(named: .pierDeviceTokenChanged) {
                guard let self else { return }
                if let t = n.userInfo?["token"] as? String { self.setDeviceToken(t) }
                else if let e = n.userInfo?["error"] as? String { self.registrationError = e }
            }
        }
        deviceToken = PushStateStore.load().deviceToken
        scheduleRegister(delay: .zero)
    }

    /// Foreground: refresh the OS token (cheap, Apple recommends calling it on every launch) and re-register everywhere.
    func foreground() {
        UIApplication.shared.registerForRemoteNotifications()
        for c in clients.values { Task { await c.reset() } }
        retryDelay = 30
        scheduleRegister(delay: .zero)
    }

    /// The app went to the background: no point retrying until it is back.
    func background() {
        retryTask?.cancel(); retryTask = nil
    }

    private func setDeviceToken(_ hex: String) {
        registrationError = nil
        guard hex != deviceToken else { return }
        deviceToken = hex
        PushStateStore.update { $0.deviceToken = hex }
        scheduleRegister()
    }

    /// The paired boxes changed (pair / unpair).
    func boxesChanged() {
        let names = Set(model?.boxes.map(\.name) ?? [])
        for k in status.keys where !names.contains(k) { status[k] = nil }
        clients = clients.filter { names.contains($0.key) }
        PushStateStore.update { s in s.registered = s.registered.filter { names.contains($0.key) } }
        scheduleRegister()
    }

    func scheduleRegister(delay: Duration = .milliseconds(800)) {
        registerTask?.cancel()
        registerTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.registerAll()
        }
    }

    // MARK: registration

    private func client(for conn: BoxConnection) -> PushClient? {
        let key = conn.name
        if let c = clients[key] { return c }
        guard let identity = model?.identity else { return nil }
        let c = PushClient(box: conn.record, identity: identity)
        clients[key] = c
        return c
    }

    func registerAll() async {
        guard let model else { return }
        await Self.pullWidgetToken()
        let state = PushStateStore.load()
        deviceToken = state.deviceToken
        guard state.deviceToken != nil else { return }
        let conns = model.boxes
        for c in conns where !(status[c.name]?.isRegistered ?? false) { status[c.name] = .registering }
        let work: [(String, PushClient)] = conns.compactMap { c in client(for: c).map { (c.name, $0) } }
        await withTaskGroup(of: (String, BoxPushStatus).self) { g in
            for (name, client) in work {
                g.addTask {
                    let st = await PushRegistrar.register(client: client, box: name, state: state)
                    if case .registered = st { await Self.resendActivityTokens(box: name, client: client) }
                    return (name, st)
                }
            }
            for await (name, st) in g {
                guard !Task.isCancelled else { return }
                status[name] = st
                PushRegistrar.record([name: st])
            }
        }
        scheduleRetryIfNeeded()
    }

    /// A box whose push routes are unreachable (push not set up yet, phone off the network) is tried again with a growing delay
    /// while the app is in front, so a restart on the box does not need an app relaunch to get push working.
    private func scheduleRetryIfNeeded() {
        retryTask?.cancel(); retryTask = nil
        let transient = status.values.contains { st in
            if case .unreachable = st { return true }
            if case .failed(let why) = st { return why.hasPrefix("5") }   // 5xx: the service is up but unwell
            return false
        }
        guard transient, model?.isActive == true else { retryDelay = 30; return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 600)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.model?.isActive == true else { return }
            for c in self.clients.values { await c.reset() }
            await self.registerAll()
        }
    }

    /// After (re)registering, re-send the Live Activity tokens we hold for that box (the server may have lost its state).
    nonisolated private static func resendActivityTokens(box: String, client: PushClient) async {
        for e in PushTokenStore.entries() where e.box == box {
            try? await client.putActivity(box: e.box, session: e.session, .init(token: e.token, env: PushRegistrar.env))
        }
    }

    /// iOS 26+: the widgets' push token (`WidgetCenter.currentPushInfo`); the extension's handler also writes it to the App Group.
    nonisolated private static func pullWidgetToken() async {
        if #available(iOS 26.0, *) {
            if let info = await WidgetCenter.shared.currentPushInfo {
                let hex = pushTokenHex(info.token)
                PushStateStore.update { $0.widgetToken = hex }
            }
        }
    }

    // MARK: push-to-start / activities

    func pushToStartTokenChanged(_ hex: String) {
        guard PushStateStore.load().pushToStartToken != hex else { return }
        PushStateStore.update { $0.pushToStartToken = hex }
        scheduleRegister()
    }

    func activityToken(box: String, session: String, token: Data) {
        guard let conn = model?.connection(for: box), let c = client(for: conn), deviceToken != nil else { return }
        let hex = pushTokenHex(token)
        Task { try? await c.putActivity(box: box, session: session, .init(token: hex, env: PushRegistrar.env)) }
    }

    func activityEnded(box: String, session: String) {
        guard let conn = model?.connection(for: box), let c = client(for: conn), deviceToken != nil else { return }
        Task { try? await c.deleteActivity(box: box, session: session) }
    }

    // MARK: test / unregister

    func sendTest(box: String) async {
        guard let conn = model?.connection(for: box), let c = client(for: conn) else { return }
        testing.insert(box); testResult[box] = nil
        defer { testing.remove(box) }
        do {
            let r = try await PushRegistrar.deadline(.seconds(15)) { try await c.test() }
            testResult[box] = r.sent ? .sent : .failed("not sent")
        } catch {
            let st = PushRegistrar.classify(error)
            if st == .unreachable { status[box] = .unreachable }
            testResult[box] = .failed((error as? PierError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Best effort, before a box is forgotten.
    func unregister(_ conn: BoxConnection) async {
        guard let c = client(for: conn) else { return }
        _ = try? await PushRegistrar.deadline(.seconds(4)) { try await c.deleteDevice() }
        PushStateStore.update { $0.registered[conn.name] = nil }
        status[conn.name] = nil
        clients[conn.name] = nil
    }

    /// True when push on `box` is registered (in memory: foreground use, e.g. to hold back duplicate banners).
    func covers(box: String) -> Bool { status[box]?.isRegistered ?? false }
}
