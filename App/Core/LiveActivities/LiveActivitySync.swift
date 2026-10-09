import Foundation
#if !targetEnvironment(macCatalyst)
import ActivityKit
#endif
import PierKit

/// Keeps running Live Activities in step with the boxes. Pure over `[Source]`, so it works from the app (events, polling)
/// and from the background refresh alike.
enum LiveActivitySync {
    struct Source: Sendable {
        let box: String
        let client: any PierBoxClient
        /// nil: the box did not answer; its activities are left as they are.
        let sessions: [Session]?
    }

    static let finalDismissal: TimeInterval = 3600

    /// When this process first saw each activity (for the grace period before an unknown session counts as gone).
    private enum FirstSeen {
        nonisolated(unsafe) private static var seen: [String: Date] = [:]
        private static let lock = NSLock()
        static func age(of id: String) -> TimeInterval {
            lock.lock(); defer { lock.unlock() }
            let d = seen[id] ?? Date()
            seen[id] = d
            return Date().timeIntervalSince(d)
        }
    }

    /// No Live Activities on the Mac (ActivityKit is unavailable in Mac Catalyst): nothing to keep in step.
    static func sync(_ sources: [Source], knownBoxes: Set<String>, refreshStep: Bool) async {
        #if !targetEnvironment(macCatalyst)
        for activity in Activity<SessionActivityAttributes>.activities where activity.activityState == .active || activity.activityState == .stale {
            let attrs = activity.attributes
            let current = activity.content.state
            if !knownBoxes.contains(attrs.box) {      // box unpaired: nothing to follow
                await activity.end(nil, dismissalPolicy: .immediate)
                continue
            }
            guard let src = sources.first(where: { $0.box == attrs.box }), let sessions = src.sessions else { continue }

            var next: SessionActivityAttributes.ContentState
            var session = sessions.first { $0.name == attrs.session }
            // A session the app has not heard of yet (push-to-start) keeps its activity; only a confirmed absence ends it.
            var decision = ActivityReconcile.decide(sessionKnown: session != nil, sessionExited: session?.exited ?? false, listLoaded: true, age: FirstSeen.age(of: attrs.id))
            if decision == .verifyWithFreshFetch {
                if let fresh = try? await src.client.sessions() {
                    session = fresh.first { $0.name == attrs.session }
                    decision = ActivityReconcile.decide(sessionKnown: session != nil, sessionExited: session?.exited ?? false, listLoaded: true,
                                                        age: FirstSeen.age(of: attrs.id), freshFetchLacksSession: session == nil)
                } else { decision = .keep }
            }
            if decision == .keep { continue }
            if let session {
                next = .base(from: session, previous: current)
                switch next.phase {
                case .waiting where !next.hasMenu:
                    if let screen = try? await src.client.screen(session: session.name, history: 0) {
                        next.hasMenu = MenuParser.actions(in: screen) != nil
                    }
                    // A question: how many choices it offers (the island's compact side shows the count).
                    if !next.hasMenu, next.choices == nil, let options = await ChoiceOptions.fetch(client: src.client, session: session) {
                        next.choices = options.count
                    }
                case .running, .starting:
                    if refreshStep, let screen = try? await src.client.screen(session: session.name, history: 0) {
                        next.step = StepText.from(screen: screen) ?? next.step
                    }
                case .finished:
                    // Signals only (`since` past the end: no items), then just the tail for the reply.
                    let signals = try? await src.client.transcript(session: session.name, since: 2_000_000_000, gen: nil)
                    if let job = signals.flatMap({ BackgroundWork.running(signals: $0.signals, crew: $0.crew ?? []).first }) {
                        // The turn ended but work runs on in the background: not done yet (the agent speaks again after it).
                        next.phase = .running; next.step = "⏳ \(job.title)"; next.added = nil; next.removed = nil; next.reply = nil
                        break
                    }
                    if next.added == nil { (next.added, next.removed) = await changeCounts(src.client, session) }
                    if next.reply == nil, let tail = try? await src.client.transcriptBefore(session: session.name, before: 0, limit: 40) {
                        next.reply = lastReply(tail)
                    }
                default: break
                }
            } else {
                next = current
                next.phase = .ended; next.ask = nil; next.hasMenu = false; next.step = nil
            }

            if next.phase == .ended {
                await activity.end(ActivityContent(state: next, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(600)))
                continue
            }
            guard next != current else { continue }
            // A finished turn stays an update, as pierd pushes it ("finished" with a stale date an hour out): the agent
            // can run again on the person's next words, and the same activity follows it. Only an exit ends it.
            let stale: Date? = next.phase == .finished ? Date().addingTimeInterval(finalDismissal) : nil
            let content = ActivityContent(state: next, staleDate: stale, relevanceScore: next.phase == .waiting ? 100 : 50)
            // pierd already pushes the alert for this box; a second one from the activity would double the banner.
            if next.phase == .waiting && current.phase != .waiting && PushStateStore.load().registered[attrs.box] == nil {
                let alert = AlertConfiguration(title: "\(attrs.title)", body: "Precisa de você", sound: .default)
                await activity.update(content, alertConfiguration: alert)
            } else {
                await activity.update(content)
            }
        }
        #endif
    }

    /// The agent's last plain-text reply of the current turn, as an activity excerpt.
    static func lastReply(_ page: TranscriptPage) -> String? {
        for item in page.items.reversed() {
            if item.kind == "user" { return nil }
            if item.kind == "text", let t = SessionActivityAttributes.ContentState.excerpt(item.text) { return t }
        }
        return nil
    }

    /// Sum of lines added/removed by this session's touched files (falls back to all touched files in the worktree).
    static func changeCounts(_ client: any PierBoxClient, _ s: Session) async -> (Int?, Int?) {
        let (loc, wt) = WidgetSnapshot.split(s.location)
        guard !loc.isEmpty, let files = try? await client.touched(location: loc, worktree: wt ?? loc) else { return (nil, nil) }
        let mine = files.filter { $0.session == s.name }
        let use = mine.isEmpty ? files : mine
        return (use.reduce(0) { $0 + $1.added }, use.reduce(0) { $0 + $1.removed })
    }
}
