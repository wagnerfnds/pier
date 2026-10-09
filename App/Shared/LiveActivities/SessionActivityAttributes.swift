import Foundation
#if !targetEnvironment(macCatalyst)
import ActivityKit
#endif
import PierKit

/// Where a tracked session is, for the Live Activity.
enum ActivityPhase: String, Codable, Hashable, Sendable {
    case starting, running, waiting, finished, ended

    init(_ s: Session) {
        if s.exited { self = .ended; return }
        switch s.agentState {
        case .waiting: self = .waiting
        case .running: self = .running
        case .finished: self = .finished
        case .idle, .none, .unknown: self = .starting
        }
    }

    /// Unknown strings from a newer server decode as `.running` instead of failing the whole push.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ActivityPhase(rawValue: raw) ?? .running
    }

    var isFinal: Bool { self == .finished || self == .ended }

    var title: String {
        switch self {
        case .starting: String(localized: "Iniciando")
        case .running: String(localized: "Trabalhando")
        case .waiting: String(localized: "Precisa de você")
        case .finished: String(localized: "Sua vez")
        case .ended: String(localized: "Encerrada")
        }
    }
}

/// Live Activity for one agent session. The attributes are fixed for the activity's life; `ContentState` changes.
///
/// Push payload shape (sent by pierd): see docs/PUSH.md, "iOS expectations".
/// Mac Catalyst has no ActivityKit: there the type is plain data (see the conformance at the end of the file).
struct SessionActivityAttributes: Codable {
    struct ContentState: Codable, Hashable, Sendable {
        var phase: ActivityPhase
        /// When the phase began (drives the timer).
        var since: Date
        /// What the agent is doing, e.g. "Rodando pnpm test…".
        var step: String?
        /// What the agent asks permission for, e.g. "Bash  rm -rf build".
        var ask: String?
        /// A numbered permission menu is on screen, so Permitir/Negar can answer it.
        var hasMenu: Bool
        var added: Int?
        var removed: Int?
        /// The agent's last reply, a few lines (finished).
        var reply: String?
        /// How many choices the question offers (waiting), when they could be read; the island shows the count.
        var choices: Int?

        enum CodingKeys: String, CodingKey { case phase, since, step, ask, hasMenu, added, removed, reply, choices }

        init(phase: ActivityPhase, since: Date, step: String? = nil, ask: String? = nil, hasMenu: Bool, added: Int? = nil, removed: Int? = nil, reply: String? = nil, choices: Int? = nil) {
            self.phase = phase; self.since = since; self.step = step; self.ask = ask
            self.hasMenu = hasMenu; self.added = added; self.removed = removed; self.reply = reply; self.choices = choices
        }

        /// Hand-written so the wire format is stable and server friendly (docs/PUSH.md "iOS expectations"):
        /// `since` is seconds since 1970; only `phase` and `since` are required.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            phase = try c.decode(ActivityPhase.self, forKey: .phase)
            since = try c.decode(ActivityDate.Wire.self, forKey: .since).date
            step = try c.decodeIfPresent(String.self, forKey: .step)
            ask = try c.decodeIfPresent(String.self, forKey: .ask)
            hasMenu = try c.decodeIfPresent(Bool.self, forKey: .hasMenu) ?? false
            added = try c.decodeIfPresent(Int.self, forKey: .added)
            removed = try c.decodeIfPresent(Int.self, forKey: .removed)
            reply = try c.decodeIfPresent(String.self, forKey: .reply)
            choices = try c.decodeIfPresent(Int.self, forKey: .choices)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(phase, forKey: .phase)
            try c.encode(since.timeIntervalSince1970, forKey: .since)
            try c.encodeIfPresent(step, forKey: .step)
            try c.encodeIfPresent(ask, forKey: .ask)
            try c.encode(hasMenu, forKey: .hasMenu)
            try c.encodeIfPresent(added, forKey: .added)
            try c.encodeIfPresent(removed, forKey: .removed)
            try c.encodeIfPresent(reply, forKey: .reply)
            try c.encodeIfPresent(choices, forKey: .choices)
        }
    }

    var box: String
    var session: String
    var title: String
    var project: String
    var agent: String?

    var id: String { "\(box)/\(session)" }
    var url: URL { Shared.sessionURL(box: box, name: session) }
}

#if !targetEnvironment(macCatalyst)
extension SessionActivityAttributes: ActivityAttributes {}
#endif

extension SessionActivityAttributes.ContentState {
    /// Content derived from a session alone (no network): phase, timer and ask summary.
    static func base(from s: Session, previous: Self? = nil) -> Self {
        let phase = ActivityPhase(s)
        var ask: String?
        if phase == .waiting, let a = s.ask {
            let t = [a.tool, a.input ?? a.message ?? a.why].compactMap { $0 }.joined(separator: "  ")
            ask = t.isEmpty ? nil : t
        }
        let since = s.stateSince ?? previous?.since ?? s.created
        var c = Self(phase: phase, since: since, step: nil, ask: ask, hasMenu: false, added: nil, removed: nil)
        if let p = previous {
            c.step = phase == .running || phase == .starting ? p.step : nil
            c.hasMenu = phase == .waiting && p.since == since ? p.hasMenu : false
            c.choices = phase == .waiting && p.since == since ? p.choices : nil
            if phase.isFinal && p.since == since { c.added = p.added; c.removed = p.removed; c.reply = p.reply }
        }
        return c
    }
}

extension SessionActivityAttributes.ContentState {
    /// A reply for the activity: markdown marks dropped, whitespace folded, clipped (same as pierd's push `text.Excerpt`).
    static func excerpt(_ reply: String?, limit: Int = 280) -> String? {
        guard var r = reply?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else { return nil }
        for m in ["**", "__", "`", "#"] { r = r.replacingOccurrences(of: m, with: "") }
        r = r.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return r.count > limit ? String(r.prefix(limit - 1)) + "…" : r
    }
}
