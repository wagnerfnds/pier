import Foundation
import PierKit

/// The dashboard state of a session, as the app groups it.
enum WState: String, Codable, Sendable, Hashable, CaseIterable {
    case needsYou, working, done, ready

    init?(_ s: Session) {
        guard s.isAgent, !s.exited else { return nil }
        switch s.agentState {
        case .waiting: self = .needsYou
        case .running: self = .working
        case .finished: self = .done
        case .idle, .none, .unknown: self = .ready
        }
    }

    /// Lower sorts first on a widget.
    var rank: Int {
        switch self {
        case .needsYou: 0
        case .working: 1
        case .done: 2
        case .ready: 3
        }
    }
}

/// One agent session, with everything a widget row shows already resolved (display names baked in).
struct WSession: Codable, Sendable, Hashable, Identifiable {
    var box: String
    var name: String
    var title: String
    var project: String
    var agent: String?
    var state: WState
    var since: Date
    /// e.g. "Bash  rm -rf node_modules" while the agent waits for permission.
    var ask: String?

    var id: String { "\(box)/\(name)" }
    var url: URL { Shared.sessionURL(box: box, name: name) }
}

struct WBox: Codable, Sendable, Hashable {
    var name: String
    var online: Bool
}

/// Compact picture of the boxes, written by the app to the App Group on every refresh and read by the widgets.
struct WidgetSnapshot: Codable, Sendable, Hashable {
    var updated: Date
    var boxes: [WBox]
    var sessions: [WSession]

    static let empty = WidgetSnapshot(updated: .distantPast, boxes: [], sessions: [])

    func count(_ s: WState) -> Int { sessions.filter { $0.state == s }.count }
    var needsYou: Int { count(.needsYou) }
    var working: Int { count(.working) }
    var done: Int { count(.done) }
    var isEmpty: Bool { needsYou + working + done == 0 }
    var allOffline: Bool { !boxes.isEmpty && boxes.allSatisfy { !$0.online } }

    /// Needs-you first, then working, then recently finished; newest first inside each group. Idle ("ready") ones are left out.
    var ranked: [WSession] {
        sessions.filter { $0.state != .ready }
            .sorted { a, b in
                if a.state.rank != b.state.rank { return a.state.rank < b.state.rank }
                return a.since > b.since
            }
    }

    /// Same content, ignoring the timestamp (used to skip pointless widget reloads).
    func sameContent(as o: WidgetSnapshot) -> Bool { boxes == o.boxes && sessions == o.sessions }

    // MARK: building

    static func make(from fetches: [BoxFetch], prefs: SharedDisplayPrefs, now: Date = Date()) -> WidgetSnapshot {
        var boxes: [WBox] = []
        var out: [WSession] = []
        for f in fetches {
            boxes.append(WBox(name: f.record.name, online: f.sessions != nil))
            for s in f.sessions ?? [] {
                guard let st = WState(s) else { continue }
                let (loc, wt) = Self.split(s.location)
                if !loc.isEmpty, prefs.isHidden(box: f.record.name, location: loc) { continue }
                let title = nonEmpty(s.title) ?? wt ?? s.name
                var project = s.chat ? String(localized: "Conversa")
                    : loc.isEmpty ? (s.dir.split(separator: "/").last.map(String.init) ?? s.name) : prefs.displayName(box: f.record.name, location: loc)
                if let wt, wt != title { project += " · \(wt)" }
                var ask: String?
                if st == .needsYou, let a = s.ask {
                    let t = [a.tool, a.input ?? a.message ?? a.why].compactMap { $0 }.joined(separator: "  ")
                    ask = t.isEmpty ? nil : t
                }
                out.append(WSession(box: f.record.name, name: s.name, title: title, project: project, agent: s.agent,
                                    state: st, since: s.stateSince ?? s.created, ask: ask))
            }
        }
        return WidgetSnapshot(updated: now, boxes: boxes, sessions: out)
    }

    /// "loc/wt" -> ("loc", "wt"); "loc" -> ("loc", nil).
    static func split(_ location: String?) -> (String, String?) {
        guard let l = location, !l.isEmpty else { return ("", nil) }
        guard let i = l.firstIndex(of: "/") else { return (l, nil) }
        return (String(l[..<i]), String(l[l.index(after: i)...]))
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}

/// Reads and writes the snapshot file in the App Group.
enum SnapshotStore {
    private static var url: URL { Shared.fileURL("widget-snapshot.json") }

    static func read() -> WidgetSnapshot? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? Shared.decoder().decode(WidgetSnapshot.self, from: d)
    }

    /// Writes the file and returns whether the content changed compared with what was there.
    @discardableResult
    static func write(_ snap: WidgetSnapshot) -> Bool {
        let changed = !(read()?.sameContent(as: snap) ?? false)
        if let d = try? Shared.encoder().encode(snap) { try? d.write(to: url, options: .atomic) }
        return changed
    }
}
