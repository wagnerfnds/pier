import Foundation
#if !targetEnvironment(macCatalyst)
import ActivityKit
#endif
import PierKit

extension Notification.Name {
    /// Posted when a task/session was created from the phone. userInfo: "box" (String), "session" (String).
    static let pierTaskCreated = Notification.Name("pier.taskCreated")
}

#if targetEnvironment(macCatalyst)
/// Mac: ActivityKit is unavailable in Mac Catalyst, so there are no Live Activities. Same surface as the iOS manager, never
/// enabled (the session menu hides its toggle) and doing nothing.
@MainActor @Observable
final class LiveActivityManager {
    @ObservationIgnored weak var model: AppModel?
    let areEnabled = false
    var autoStart: Bool { get { false } set {} }
    func isTracking(box: String, session: String) -> Bool { false }
    func begin() {}
    func start(box: String, session name: String) async {}
    func stop(box: String, session: String) {}
    func toggle(box: String, session: String) {}
    func sessionsChanged() {}
}
#else

/// Starts, stops and follows Live Activities for agent sessions while the app runs. Background updates go through
/// `LiveActivitySync` directly (see `BackgroundRefresh`).
@MainActor @Observable
final class LiveActivityManager {
    @ObservationIgnored weak var model: AppModel?

    /// "box/session" of every session with a running activity.
    private(set) var tracked: Set<String> = []
    @ObservationIgnored private var tokenTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var createdTask: Task<Void, Never>?
    @ObservationIgnored private var pushToStartTask: Task<Void, Never>?
    @ObservationIgnored private var stateTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var startedByPushTask: Task<Void, Never>?

    static let autoStartKey = "liveActivities.autoStart"

    /// Cached: `ActivityAuthorizationInfo()` is a system query, and the session menu read this on every render.
    private(set) var areEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
    @ObservationIgnored private var enablementTask: Task<Void, Never>?
    var autoStart: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoStartKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoStartKey) }
    }

    func isTracking(box: String, session: String) -> Bool { tracked.contains("\(box)/\(session)") }

    // MARK: lifecycle

    /// At launch: adopt activities that survived (observe their push tokens, drop orphans) and listen for new tasks.
    func begin() {
        enablementTask = Task { [weak self] in
            for await on in ActivityAuthorizationInfo().activityEnablementUpdates { self?.areEnabled = on }
        }
        endDuplicates()
        refreshTracked()
        for a in Activity<SessionActivityAttributes>.activities { observeToken(a) }
        if #available(iOS 17.2, *) { observePushToStart() }
        observeStartedByPush()
        createdTask?.cancel()
        createdTask = Task { [weak self] in
            for await n in NotificationCenter.default.notifications(named: .pierTaskCreated) {
                guard let self, self.autoStart,
                      let box = n.userInfo?["box"] as? String, let name = n.userInfo?["session"] as? String else { continue }
                await self.start(box: box, session: name)
            }
        }
    }

    private static func isLive(_ a: Activity<SessionActivityAttributes>) -> Bool { a.activityState == .active || a.activityState == .stale }

    /// One activity per session: a push-to-start that raced the app's own start (or an older build) can leave two.
    /// Keeps the first one found and ends the rest.
    private func endDuplicates() {
        var kept = Set<String>(), extra = Set<String>()
        for a in Activity<SessionActivityAttributes>.activities where Self.isLive(a) {
            if !kept.insert(a.attributes.id).inserted { extra.insert(a.id) }
        }
        guard !extra.isEmpty else { return }
        Task { await Self.end(activityIDs: extra) }
    }

    private static func end(activityIDs: Set<String>) async {
        for a in Activity<SessionActivityAttributes>.activities where activityIDs.contains(a.id) {
            await a.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func refreshTracked() {
        tracked = Set(Activity<SessionActivityAttributes>.activities
            .filter { $0.activityState == .active || $0.activityState == .stale }
            .map { $0.attributes.id })
    }

    // MARK: start / stop

    /// Starts an activity for a session (waits briefly for the session to show up in the box's list).
    func start(box: String, session name: String) async {
        guard areEnabled else { NSLog("LiveActivity: activities disabled"); return }
        guard let model, !isTracking(box: box, session: name),
              !Activity<SessionActivityAttributes>.activities.contains(where: { Self.isLive($0) && $0.attributes.id == "\(box)/\(name)" }) else { return }
        var found: Session?
        for _ in 0..<20 {
            found = model.connection(for: box)?.sessions.first { $0.name == name }
            if found != nil { break }
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard let s = found, s.isAgent, !s.exited else { return }
        let (loc, wt) = WidgetSnapshot.split(s.location)
        let title = (s.title?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? wt ?? s.name
        var project = s.chat ? BoxSession.chatPlace : loc.isEmpty ? s.name : model.prefs.displayName(box: box, location: loc)
        if let wt, wt != title { project += " · \(wt)" }
        let attrs = SessionActivityAttributes(box: box, session: s.name, title: title, project: project, agent: s.agent)
        let state = SessionActivityAttributes.ContentState.base(from: s)
        let content = ActivityContent(state: state, staleDate: nil, relevanceScore: 50)
        let activity: Activity<SessionActivityAttributes>
        do {
            activity = try Activity.request(attributes: attrs, content: content, pushType: .token)
        } catch {
            NSLog("LiveActivity push request failed: %@", String(describing: error))
            // Without the Push Notifications entitlement the token request fails: follow the session without push.
            do { activity = try Activity.request(attributes: attrs, content: content, pushType: nil) } catch {
                NSLog("LiveActivity request failed: %@", String(describing: error)); return
            }
        }
        tracked.insert(attrs.id)
        observeToken(activity)
        syncNow(refreshStep: true)
    }

    func stop(box: String, session: String) {
        let id = "\(box)/\(session)"
        Task {
            for a in Activity<SessionActivityAttributes>.activities where a.attributes.id == id {
                await a.end(nil, dismissalPolicy: .immediate)
            }
        }
        tracked.remove(id)
        tokenTasks[id]?.cancel(); tokenTasks[id] = nil
        stateTasks[id]?.cancel(); stateTasks[id] = nil
        PushTokenStore.remove(activityID: id)
        model?.push.activityEnded(box: box, session: session)
    }

    func toggle(box: String, session: String) {
        if isTracking(box: box, session: session) { stop(box: box, session: session) }
        else { Task { await start(box: box, session: session) } }
    }

    // MARK: following

    /// Called whenever sessions changed (events, refresh, launch).
    func sessionsChanged() {
        refreshTracked()
        guard !tracked.isEmpty else { pollTask?.cancel(); pollTask = nil; return }
        syncNow(refreshStep: false)
        if pollTask == nil {
            // Steps are not events: poll the screen of running sessions while the app is in front.
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    guard let self else { return }
                    guard self.model?.isActive == true, !self.tracked.isEmpty else {
                        if self.tracked.isEmpty { self.pollTask = nil; return }
                        continue
                    }
                    await self.runSync(refreshStep: true)
                }
            }
        }
    }

    private func syncNow(refreshStep: Bool) {
        Task { await runSync(refreshStep: refreshStep) }
    }

    private func runSync(refreshStep: Bool) async {
        guard let model else { return }
        let sources = model.boxes.map { LiveActivitySync.Source(box: $0.name, client: $0.client, sessions: $0.hasLoadedSessions ? $0.sessions : nil) }
        await LiveActivitySync.sync(sources, knownBoxes: Set(model.boxes.map(\.name)), refreshStep: refreshStep)
        refreshTracked()
    }

    // MARK: push tokens (uploaded to pierd, which updates the activity by push: docs/PUSH.md)

    private func observeToken(_ activity: Activity<SessionActivityAttributes>) {
        let id = activity.attributes.id
        guard tokenTasks[id] == nil else { return }
        let attrs = activity.attributes
        tokenTasks[id] = Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                PushTokenStore.save(activityID: attrs.id, box: attrs.box, session: attrs.session, token: data)
                self?.model?.push.activityToken(box: attrs.box, session: attrs.session, token: data)
            }
        }
        // An activity that ends by itself (finished, dismissed by the person, ended by a push) tells the box to forget its token.
        stateTasks[id] = Task { [weak self] in
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                guard let self else { return }
                self.tracked.remove(id)
                self.tokenTasks[id]?.cancel(); self.tokenTasks[id] = nil
                self.stateTasks[id] = nil
                PushTokenStore.remove(activityID: id)
                self.model?.push.activityEnded(box: attrs.box, session: attrs.session)
                return
            }
        }
    }

    /// Activities the system started from a push-to-start (the app may not even have been running): follow them like our own.
    private func observeStartedByPush() {
        guard startedByPushTask == nil else { return }
        startedByPushTask = Task { [weak self] in
            for await activity in Activity<SessionActivityAttributes>.activityUpdates {
                guard let self else { return }
                guard Self.isLive(activity) else { continue }
                // Already following this session with another activity: this one is a duplicate.
                if Activity<SessionActivityAttributes>.activities.contains(where: { $0.id != activity.id && Self.isLive($0) && $0.attributes.id == activity.attributes.id }) {
                    await Self.end(activityIDs: [activity.id])
                    continue
                }
                self.tracked.insert(activity.attributes.id)
                self.observeToken(activity)
                self.sessionsChanged()
            }
        }
    }

    @available(iOS 17.2, *)
    private func observePushToStart() {
        guard pushToStartTask == nil else { return }
        pushToStartTask = Task { [weak self] in
            guard let self else { return }
            for await data in Activity<SessionActivityAttributes>.pushToStartTokenUpdates {
                PushTokenStore.savePushToStart(data)
                self.model?.push.pushToStartTokenChanged(pushTokenHex(data))
            }
        }
    }
}
#endif

/// Live Activity push tokens in the App Group (`live-activity-tokens.json`), keyed by "box/session".
enum PushTokenStore {
    struct Entry: Codable, Sendable {
        var box: String
        var session: String
        var token: String
        var updated: Date
    }
    struct File: Codable, Sendable {
        var activities: [String: Entry] = [:]
        var pushToStart: String?
    }

    private static var url: URL { Shared.fileURL("live-activity-tokens.json") }
    private static func load() -> File {
        guard let d = try? Data(contentsOf: url), let f = try? Shared.decoder().decode(File.self, from: d) else { return File() }
        return f
    }
    private static func store(_ f: File) {
        if let d = try? Shared.encoder().encode(f) { try? d.write(to: url, options: .atomic) }
    }
    private static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    static func save(activityID: String, box: String, session: String, token: Data) {
        var f = load()
        f.activities[activityID] = Entry(box: box, session: session, token: hex(token), updated: Date())
        store(f)
    }
    static func savePushToStart(_ token: Data) { var f = load(); f.pushToStart = hex(token); store(f) }
    static func entries() -> [Entry] { Array(load().activities.values) }
    static func remove(activityID: String) { var f = load(); f.activities[activityID] = nil; store(f) }
}
