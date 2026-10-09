import Foundation

/// A local notification derived from a box event (docs/API.md, "Notifications").
public struct PierNotification: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case waiting, finished, setupFailed, serviceFailed, notify, guardActed
    }
    public var kind: Kind
    public var title: String
    public var body: String
    /// De-duplication / replacement key, e.g. `waiting|devbox|sandbox-subtract-claude-6s1`.
    public var key: String
    public var box: String?
    /// The session to open on tap.
    public var session: String?
    /// The worktree path, when no session could be matched.
    public var path: String?
    /// Permission buttons only make sense for these.
    public var offersActions: Bool
}

public enum NotificationText {
    /// Events spooled while the box was away carry the time the hook ran; the box's own notifier drops anything older than this.
    public static let staleAfter: TimeInterval = 10 * 60

    /// Turn an event into a notification, or nil when it does not concern the person
    /// (interrupted turns, stale spooled events, chatter such as `transcript.changed`).
    /// - Parameters:
    ///   - box: the paired box's name (shown in the body).
    ///   - sessions/locations: the latest known lists, to name the agent and place.
    public static func make(
        for e: PierEvent, box: String, sessions: [Session], locations: [Location], now: Date = Date()
    ) -> PierNotification? {
        switch e.type {
        case "agent.waiting", "agent.finished":
            let waiting = e.type == "agent.waiting"
            if !waiting, e.str("source") == "interrupt" { return nil }
            if e.bool("spooled") == true, now.timeIntervalSince(e.time) > staleAfter { return nil }
            let who = describe(e, sessions: sessions, locations: locations, box: box)
            let title: String
            var body = who.place
            if waiting {
                title = stateTitle("✋ Needs you", who.agent)
                if let ask = who.session?.ask, !ask.summary.isEmpty { body += body.isEmpty ? ask.summary : "\n\(ask.summary)" }
            } else if e.str("status") == "error" {
                title = stateTitle("⚠️ Failed", who.agent)
            } else {
                title = stateTitle("✅ Done", who.agent)
            }
            let k = who.session?.name ?? who.path ?? who.agent
            return PierNotification(
                kind: waiting ? .waiting : .finished, title: title, body: body, key: "\(waiting ? "waiting" : "finished")|\(box)|\(k)",
                box: box, session: who.session?.name, path: who.path,
                offersActions: waiting && who.session.map { Ask.classify($0.ask) == .permission } == true)
        case "worktree.setup.failed", "worktree.archive.failed":
            let what = e.type == "worktree.archive.failed" ? "Archiving" : "Setup"
            let name = e.str("name") ?? "a worktree"
            return PierNotification(
                kind: .setupFailed, title: "\(what) failed for \(name)", body: e.error ?? "", key: "\(e.type)|\(box)|\(e.str("path") ?? name)",
                box: box, session: nil, path: e.str("path"), offersActions: false)
        case "service.failed":
            return PierNotification(
                kind: .serviceFailed, title: "Service failed", body: e.error ?? e.str("name") ?? "", key: "service|\(box)|\(e.str("name") ?? "")",
                box: box, session: nil, path: e.str("path"), offersActions: false)
        case "notify":
            guard let title = e.str("title") else { return nil }
            return PierNotification(
                kind: .notify, title: title, body: e.str("body") ?? "", key: "notify|\(box)|\(e.seq ?? 0)",
                box: box, session: nil, path: e.str("path"), offersActions: false)
        case "guard.acted":
            return PierNotification(
                kind: .guardActed, title: "Pier freed memory", body: e.str("action") ?? e.error ?? "Paused or stopped something on \(box)",
                key: "guard|\(box)|\(e.seq ?? 0)", box: box, session: nil, path: nil, offersActions: false)
        default:
            return nil
        }
    }

    /// "✅ Done · Fix the login": the state leads, so a glance says what happened (mirrors pierd's push `text.Title`).
    static func stateTitle(_ head: String, _ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return head }
        return head + " · " + (n.count <= 48 ? n : String(n.prefix(47)) + "…")
    }

    /// Which session an agent event belongs to: `data.session`, else the agent session whose `dir == data.path`.
    public static func session(for e: PierEvent, in sessions: [Session]) -> Session? {
        let path = e.str("path")
        if let named = e.str("session"), let s = sessions.first(where: { $0.name == named }) { return s }
        let kind = e.str("agent") ?? e.origin
        let here = sessions.filter { $0.dir == path && !$0.exited }
        let agents = here.filter { s in
            guard let a = DisplayNames.agent(of: s) else { return false }
            guard let kind, !kind.isEmpty else { return true }
            return a == kind || (kind == "cursor" && a == "cursor-agent")
        }
        return agents.count == 1 ? agents[0] : (here.count == 1 ? here[0] : nil)
    }

    private static func describe(_ e: PierEvent, sessions: [Session], locations: [Location], box: String)
        -> (agent: String, place: String, session: Session?, path: String?)
    {
        let path = e.str("path")
        let session = session(for: e, in: sessions)
        let kind = e.str("agent") ?? e.origin
        let raw = session.flatMap(DisplayNames.agent(of:)) ?? kind ?? "an agent"
        let where_ = session?.chat == true ? DisplayNames.chatPlace : DisplayNames.place(forPath: path, in: locations)
        let place = [session.map(DisplayNames.sessionAgent), where_, box].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let agent = session.map { DisplayNames.sessionName($0, among: sessions) } ?? DisplayNames.agentLabel(raw)
        return (agent, place, session, path)
    }
}
