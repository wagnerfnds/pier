import Foundation
import BackgroundTasks
import PierKit

/// BGAppRefreshTask: polls /v1/sessions on every paired box and notifies on new waiting/finished.
private final class TaskBox: @unchecked Sendable { let task: BGAppRefreshTask; init(task: BGAppRefreshTask) { self.task = task } }

enum BackgroundRefresh {
    /// `<bundle id>.refresh`, as listed in Info.plist (`BGTaskSchedulerPermittedIdentifiers`).
    static let identifier = Shared.appBundleID + ".refresh"

    /// iPhone/iPad only. The Mac app follows the boxes while it is open and has no app refresh (there BGTaskScheduler also
    /// blocks launch when the executable is started outside LaunchServices).
    static func register() {
        #if !targetEnvironment(macCatalyst)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            schedule()
            let box = TaskBox(task: task)
            let work = Task { await run(); box.task.setTaskCompleted(success: true) }
            box.task.expirationHandler = { work.cancel() }
        }
        #endif
    }

    static func schedule() {
        #if !targetEnvironment(macCatalyst)
        let req = BGAppRefreshTaskRequest(identifier: identifier)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        try? BGTaskScheduler.shared.submit(req)
        #endif
    }

    static func run() async {
        SharedKeychain.migrateLegacyIfNeeded()
        let kc = SharedKeychain.store()
        guard let identity = try? IdentityStore.load(from: kc),
              let records = try? BoxStore(store: kc).list() else { return }
        let snapshot = StateSnapshot.load()
        var fetches: [BoxFetch] = []
        var sources: [LiveActivitySync.Source] = []
        for rec in records {
            if Task.isCancelled { return }
            let client = ClientFactory.make(box: rec, identity: identity).api
            let sessions = try? await client.sessions()
            fetches.append(BoxFetch(record: rec, sessions: sessions))
            sources.append(LiveActivitySync.Source(box: rec.name, client: client, sessions: sessions))
            guard let sessions else { continue }
            let old = snapshot[rec.name] ?? [:]
            let pushState = PushStateStore.load()
            for s in sessions where s.isAgent && !s.exited {
                let prev = old[s.name]
                if let prev, prev != (s.agentState?.rawValue ?? "") {
                    // Skipped when pierd pushes for this box (it pushes the same transition) or the person turned it off.
                    if await PushRegistrar.shouldPostLocal(box: rec, identity: identity, state: s.agentState, prefs: pushState, probe: true) {
                        let options = s.agentState == .waiting ? await ChoiceOptions.fetch(client: client, session: s) : nil
                        await Notifications.post(box: rec.name, session: s, to: s.agentState, showBox: records.count > 1, options: options)
                    }
                }
            }
            await MainActor.run { StateSnapshot.save(box: rec.name, sessions: sessions) }
        }
        // Widgets and Live Activities follow the same fetch.
        WidgetPublisher.publish(WidgetSnapshot.make(from: fetches, prefs: SharedDisplayPrefs.load()))
        await LiveActivitySync.sync(sources, knownBoxes: Set(records.map(\.name)), refreshStep: true)
    }
}
