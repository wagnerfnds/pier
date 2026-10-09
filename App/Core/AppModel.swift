import SwiftUI
import Network
import UIKit
import PierKit

struct PairOutcome {
    var paired: [BoxRecord] = []
    var failures: [(name: String, error: Error)] = []
}

struct InAppBanner: Identifiable, Equatable {
    let id = UUID()
    let box: String
    let session: String
    let title: String
    let body: String
    let finished: Bool
}

struct AppToast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let symbol: String
}

@MainActor @Observable
final class AppModel {
    let keychain = SharedKeychain.store()
    let router = Router()
    let prefs = LocalPrefs()
    let hub = EventHub()
    let sessionsStore = SessionsStore()
    let notifications = Notifications()
    let liveActivities = LiveActivityManager()
    let push = PushManager()

    private(set) var identity: PierIdentity?
    private(set) var boxes: [BoxConnection] = []
    var isActive = false
    /// The in-app banner shown at the top while the app is in the foreground.
    var banner: InAppBanner?
    var loadError: String?
    /// A short message at the top of the app (a deep link to a session that is gone, for example).
    var toast: AppToast?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    #if DEBUG
    /// `-uiTestOnboarding 1`: the mock box, waiting to be "paired" from the onboarding.
    @ObservationIgnored private var mockUnpaired: BoxConnection?
    #endif

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var lastPath: String?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    init() {
        sessionsStore.model = self
        liveActivities.model = self
        push.model = self
        notifications.isCovered = { [weak self] box in self?.isForegroundCovered(box: box) ?? false }
        notifications.onOpen = { [weak self] box, session in self?.openSession(box: box, name: session) }
        router.onOpenSession = { [weak self] box, name in self?.openSession(box: box, name: name) }
        router.onOpenReview = { [weak self] box, name in self?.openSession(box: box, name: name, review: true) }
        notifications.onReview = { [weak self] box, session, location in
            guard let self else { return }
            if location?.contains("/") == true { self.router.openReview(box: box, session: session, location: location) } else { self.openSession(box: box, name: session) }
        }
        // A notification button answered an agent: show the new state without waiting for the box's event.
        notifications.onAnswered = { [weak self] box, _ in
            self?.connection(for: box)?.scheduleRefresh(sessions: true)
            SessionSignals.shared.invalidate()
            InboxStore.shared.noteActed(box: box)
        }
    }

    /// Deep link to a session (notification tap, banner tap, widget, intent, Live Activity). After a cold launch the box or
    /// its sessions may not be loaded yet: wait for them (bounded). A session that no longer exists is not a silent no-op:
    /// its worktree opens when it still exists, otherwise a toast says it is gone. `review`: the Review of its worktree
    /// instead of the chat (the Live Activity's "Revisar"); a session without one opens as usual.
    func openSession(box: String, name: String, review: Bool = false) {
        openTask?.cancel()
        openTask = Task { [weak self] in
            let deadline = ContinuousClock.now + .seconds(10)
            while !Task.isCancelled {
                guard let self else { return }
                let conn = self.boxes.first(where: { $0.name == box })
                if let s = conn?.sessions.first(where: { $0.name == name }) {
                    self.banner = nil
                    self.show(box: box, session: s, review: review)
                    return
                }
                if let conn, conn.hasLoadedSessions {
                    // The list is loaded and the session is not in it: refresh once to be sure (events may lag), then give up.
                    await conn.refreshSessions()
                    if let s = conn.sessions.first(where: { $0.name == name }) { self.show(box: box, session: s, review: review); return }
                    self.sessionIsGone(conn, name: name)
                    return
                }
                if let conn, case .offline = conn.state { self.showToast(S("A box não respondeu. Tente de novo em instantes."), symbol: "wifi.slash"); return }
                if conn?.state == .revoked || conn?.state == .pinMismatch { return }
                if ContinuousClock.now >= deadline {
                    self.showToast(conn == nil ? S("Essa box não está mais pareada.") : S("A box demorou a responder. Tente de novo em instantes."), symbol: "exclamationmark.triangle")
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func show(box: String, session s: Session, review: Bool) {
        if review, s.location?.contains("/") == true { router.openReview(box: box, session: s.name, location: s.location) }
        else { router.openSession(box: box, session: s) }
    }

    private func sessionIsGone(_ conn: BoxConnection, name: String) {
        banner = nil
        if let (loc, wt) = SessionLookup.worktree(forSessionName: name, in: conn.locations) {
            router.openWorktree(box: conn.name, location: loc, worktree: wt)
            showToast(S("Essa sessão já terminou"), symbol: "checkmark.circle")
        } else {
            showToast(S("Essa sessão já terminou e não está mais na box."), symbol: "checkmark.circle")
        }
    }

    func showToast(_ text: String, symbol: String = "info.circle") {
        let t = AppToast(text: text, symbol: symbol)
        toast = t
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.toast?.id == t.id { self?.toast = nil }
        }
    }

    var hasBoxes: Bool { !boxes.isEmpty }
    var boxStore: BoxStore { BoxStore(store: keychain) }

    // MARK: lifecycle

    func start() {
        SharedKeychain.migrateLegacyIfNeeded()
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "testKeychainMigration") { SharedKeychain.debugSelfTest() }
        #endif
        #if DEBUG
        if UITestMock.enabled { startMock(); return }
        #endif
        do {
            identity = try IdentityStore.loadOrCreate(in: keychain)
            try reloadBoxes()
        } catch {
            loadError = error.localizedDescription
        }
        startPathMonitor()
        liveActivities.begin()
        push.begin()
        Task { await notifications.refreshStatus() }
        #if DEBUG
        // Test hook: `-debugBanner 1` shows an in-app banner for the first session after a few seconds.
        if UserDefaults.standard.bool(forKey: "debugBanner") {
            Task {
                try? await Task.sleep(for: .seconds(6))
                if let c = boxes.first, let s = c.sessions.first(where: { $0.isAgent }) { transition(c, s, .waiting) }
            }
        }
        if UserDefaults.standard.bool(forKey: "debugStartActivity") {
            // Test hook: follow every running/waiting agent session with a Live Activity.
            Task {
                try? await Task.sleep(for: .seconds(5))
                for c in boxes { for s in c.sessions where s.isAgent && !s.exited && s.agentState != .finished { await liveActivities.start(box: c.name, session: s.name) } }
            }
        }
        if UserDefaults.standard.bool(forKey: "openCompose") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                if let c = boxes.first { router.push(ComposeRoute(box: c.name)) }
            }
        }
        if let name = UserDefaults.standard.string(forKey: "openSession") {
            // Test hook: `-openSession <name>` opens that session on the first box.
            Task {
                try? await Task.sleep(for: .seconds(3))
                if let c = boxes.first { openSession(box: c.name, name: name) }
            }
        }
        if UserDefaults.standard.bool(forKey: "openFirstSession") {
            Task {
                try? await Task.sleep(for: .seconds(4))
                if let c = boxes.first, let s = c.sessions.first(where: { $0.isAgent }) { openSession(box: c.name, name: s.name) }
            }
        }
        // Screenshot hooks: `-openTalk 1` the Falar sheet (with `-talkText "…"` typed and routed), `-openPalette 1` the
        // ⌘K palette (iPad, Mac), `-openFaxina 1` the Faxina screen.
        if UserDefaults.standard.bool(forKey: "openTalk") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                let text = UserDefaults.standard.string(forKey: "talkText") ?? ""
                TalkCenter.shared.open(text: text, listen: false, autoRoute: UserDefaults.standard.bool(forKey: "talkRoute"))
            }
        }
        if UserDefaults.standard.bool(forKey: "openPalette") {
            Task { try? await Task.sleep(for: .seconds(3)); router.showPalette = true }
        }
        if UserDefaults.standard.bool(forKey: "openFaxina") {
            Task { try? await Task.sleep(for: .seconds(3)); router.push(HousekeepingRoute()) }
        }
        #endif
    }

    #if DEBUG
    /// `-uiTestMock 1`: one in-memory box with fixture data; no keychain, pairing, push or network.
    private func startMock() {
        let conn = UITestMock.makeConnection()
        conn.onTransition = { [weak self] c, s, _, to in self?.transition(c, s, to) }
        conn.onChange = { [weak self] _ in self?.sessionsChanged() }
        // `-uiTestOnboarding 1`: start with no box (the onboarding shows); pairing any link "pairs" the mock box.
        if UserDefaults.standard.bool(forKey: "uiTestOnboarding") { mockUnpaired = conn; isActive = true; return }
        boxes = [conn]
        isActive = true
        activate(conn)
        // `-openSession <name>` works with the mock too (sessions the Home does not list, e.g. an idle agent).
        if let name = UserDefaults.standard.string(forKey: "openSession") { openSession(box: conn.name, name: name) }
    }
    #endif

    func clientName() -> String {
        #if targetEnvironment(macCatalyst)
        // UIDevice says just "Mac" here: the host name tells the person's Macs apart ("mac-de-octocats-macbook-pro").
        let host = ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
        return PierName.fromHostname(host.isEmpty ? "mac" : "mac-de-\(host)", fallback: "mac")
        #elseif targetEnvironment(simulator)
        return PierName.fromHostname("simulador-ios", fallback: "iphone")
        #else
        let raw = UIDevice.current.name
        let generic = ["iPhone", "iPad"]
        let base = generic.contains(raw) ? "iphone" : "iphone-de-\(raw)"
        return PierName.fromHostname(base, fallback: "iphone")
        #endif
    }

    func reloadBoxes() throws {
        let records = try boxStore.list()
        var next: [BoxConnection] = []
        for rec in records {
            if let existing = boxes.first(where: { $0.record == rec }) { next.append(existing); continue }
            guard let identity else { continue }
            let made = ClientFactory.make(box: rec, identity: identity)
            let conn = BoxConnection(record: rec, client: made.api, raw: made.raw)
            conn.onTransition = { [weak self] c, s, _, to in self?.transition(c, s, to) }
            conn.onChange = { [weak self] _ in self?.sessionsChanged() }
            next.append(conn)
            if isActive { activate(conn) }
        }
        for gone in boxes where !next.contains(where: { $0 === gone }) { hub.stop(gone.name) }
        boxes = next
        sessionsChanged()
        push.boxesChanged()
    }

    // MARK: widgets & Live Activities

    @ObservationIgnored private var publishTask: Task<Void, Never>?

    /// Sessions or connection state changed: refresh the widget snapshot (debounced) and follow Live Activities.
    func sessionsChanged() {
        liveActivities.sessionsChanged()
        guard publishTask == nil else { return }
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.publishTask = nil
            self.publishSnapshot()
        }
    }

    private func publishSnapshot() {
        // Wait until every box has answered once, so a cold launch does not blank the widgets.
        guard boxes.allSatisfy({ $0.hasLoadedSessions || $0.state != .connecting }) else { return }
        let fetches = boxes.map { BoxFetch(record: $0.record, sessions: $0.hasLoadedSessions && $0.state.isOnline ? $0.sessions : nil) }
        let display = SharedDisplayPrefs(renames: prefs.data.renames, hidden: prefs.data.hidden)
        WidgetPublisher.publish(WidgetSnapshot.make(from: fetches, prefs: display))
    }

    private func transition(_ c: BoxConnection, _ s: Session, _ to: AgentState?) {
        guard !isActive else {
            // Foreground: a banner (and a haptic) unless the person is already looking at that session.
            guard router.visibleSession != "\(c.name)/\(s.name)",
                  let t = Notifications.text(box: c.name, session: s, to: to, showBox: boxes.count > 1) else { return }
            banner = InAppBanner(box: c.name, session: s.name, title: t.title, body: t.body, finished: to == .finished)
            if to == .waiting { Haptic.warning() } else { Haptic.success() }
            return
        }
        // Background (events still flowing for a moment): pierd pushes this one when it has push set up.
        guard let identity else { return }
        let (rec, count) = (c.record, boxes.count)
        Task { [notifications] in
            if await PushRegistrar.shouldPostLocal(box: rec, identity: identity, state: to, probe: false) {
                // A question's choices become the notification's buttons (read now, while the agent still asks).
                let options = to == .waiting ? await ChoiceOptions.fetch(client: c.client, session: s) : nil
                await notifications.notifyTransition(box: rec.name, session: s, to: to, boxCount: count, options: options)
            }
        }
    }

    /// The foreground already shows a banner for this box's transitions (live event stream), so a system banner for the
    /// same push would be a duplicate.
    func isForegroundCovered(box: String) -> Bool {
        isActive && (connection(for: box)?.state.isOnline ?? false)
    }

    private func activate(_ conn: BoxConnection, reset: Bool = false) {
        Task {
            if reset { await conn.raw.reset() }
            await conn.connect(); hub.start(conn)
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active, .inactive:
            if let url = PendingDeepLink.take() { router.handle(url: url) }
            guard !isActive else { return }
            isActive = true
            reconnectAll()
            startStatsLoop()
            push.foreground()
            Task { await notifications.refreshStatus() }
        case .background:
            isActive = false
            hub.stopAll()
            statsTask?.cancel()
            push.background()
            BackgroundRefresh.schedule()
        @unknown default:
            break
        }
    }

    /// Restart streams and refresh everything (foreground, network change, pull to refresh).
    func reconnectAll() {
        for c in boxes { activate(c, reset: true) }
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { g in
            for c in boxes { g.addTask { await c.connect() } }
        }
    }

    private func startStatsLoop() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self else { return }
                for c in self.boxes where c.state.isOnline { await c.refreshStats() }
            }
        }
    }

    private func startPathMonitor() {
        // Runs on the monitor's queue: not main-actor isolated (Swift 6 traps a main-actor closure called elsewhere).
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let sig = "\(path.status)-\(path.availableInterfaces.map(\.name).joined(separator: ","))"
            Task { @MainActor in
                guard let self else { return }
                defer { self.lastPath = sig }
                guard self.lastPath != nil, self.lastPath != sig, path.status == .satisfied, self.isActive else { return }
                self.reconnectTask?.cancel()
                self.reconnectTask = Task {
                    try? await Task.sleep(for: .seconds(1))
                    if !Task.isCancelled { self.reconnectAll() }
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "pier.path"))
    }

    func client(for box: String) -> (any PierBoxClient)? {
        boxes.first { $0.name == box }?.client
    }
    func connection(for box: String) -> BoxConnection? { boxes.first { $0.name == box } }

    // MARK: pairing

    func pair(_ link: PairingLink) async throws -> PairOutcome {
        #if DEBUG
        if let conn = mockUnpaired {
            try? await Task.sleep(for: .milliseconds(600))
            mockUnpaired = nil
            boxes = [conn]
            activate(conn)
            return PairOutcome(paired: [conn.record])
        }
        #endif
        guard let identity else { throw PierError.storage(loadError ?? "no identity") }
        var out = PairOutcome()
        switch link {
        case .box(let l):
            out.paired.append(try await pairOne(l, identity: identity))
        case .join(let j):
            if j.isExpired() { throw PierError.linkExpired }
            for b in j.boxes {
                do {
                    out.paired.append(try await pairOne(try b.pairingLink(), identity: identity))
                } catch {
                    out.failures.append((b.name, error))
                }
            }
            if out.paired.isEmpty, let f = out.failures.first { throw f.error }
        }
        try reloadBoxes()
        return out
    }

    private func pairOne(_ link: BoxPairingLink, identity: PierIdentity) async throws -> BoxRecord {
        let name = clientName()
        let rec = try await Pairing.pair(link: link, clientName: name, identity: identity, boxes: boxStore)
        UserDefaults.standard.set(name, forKey: "clientName.\(rec.fingerprint.description)")
        return rec
    }

    /// Forget a box locally; also asks the box to drop this client when it allows it (best effort).
    func unpair(_ conn: BoxConnection) async {
        hub.stop(conn.name)
        await push.unregister(conn)
        if identity != nil, let name = UserDefaults.standard.string(forKey: "clientName.\(conn.record.fingerprint.description)") {
            _ = try? await conn.raw.send(.delete, path: "/v1/clients/\(name)", body: nil)
            await conn.raw.reset()
        }
        try? boxStore.remove(fingerprint: conn.record.fingerprint)
        StateSnapshot.forget(box: conn.name)
        try? reloadBoxes()
        if boxes.isEmpty { WidgetPublisher.publish(.empty, minInterval: 0) }
    }
}

enum PairingErrorText {
    static func message(_ error: Error) -> String {
        guard let e = error as? PierError else { return error.localizedDescription }
        switch e {
        case .linkExpired:
            return String(localized: "Este link expirou. Gere um novo com “pierd pair” na box.")
        case .pairingRejected:
            return String(localized: "A box recusou o código: ele expirou ou já foi usado. Gere um novo link com “pierd pair”.")
        case .pinMismatch:
            return String(localized: "A chave da box não confere com a do link. Por segurança, a conexão foi recusada.")
        case .rateLimited:
            return String(localized: "Muitas tentativas de pareamento. Aguarde um minuto e tente de novo.")
        case .invalidLink:
            return String(localized: "Link inválido. Use um link pier:// gerado por “pierd pair”.")
        case .transport, .timeout, .tls:
            return String(localized: "Não foi possível alcançar a box. Confirme que o celular está na mesma rede (ou no Tailscale) e que o pierd está rodando.")
        case .unauthorized:
            return String(localized: "A box não reconhece mais este aparelho. Pareie novamente.")
        default:
            return e.localizedDescription
        }
    }
}
