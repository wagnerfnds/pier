import Foundation
import PierKit

/// What the car and Siri read from the boxes, without the app's window (the phone can be locked in a pocket while
/// CarPlay or Siri runs the app in the background): the conversations `CarDigest` lists, from every paired box, and the
/// words of each, made to be heard.
enum CarFeed {
    /// The car's rows: waiting agents, ended turns not archived, agents at work (`CarDigest.rows`).
    static func rows(limit: Int = 8) async -> [CarDigest.Row] {
        guard let items = try? await HeadlessBoxes.sessions() else { return [] }
        let marks = await LocalPrefs.savedClosedMarks()
        return CarDigest.rows(items, archived: { LocalPrefs.isClosed(marks, box: $0, session: $1) }, limit: limit)
    }

    /// What the boxes said this time: the sessions of those that answered, the names of those that did not, and whether
    /// any box is paired at all (a box out of reach is not "nothing waiting").
    struct Report: Sendable {
        var sessions: [String: [Session]] = [:]
        var offline: [String] = []
        var paired = true
    }

    static func report() async -> Report {
        guard let boxes = try? HeadlessBoxes.all(), !boxes.isEmpty else { return Report(paired: false) }
        return await withTaskGroup(of: (String, [Session]?).self) { g in
            for b in boxes { g.addTask { (b.name, try? await b.client.sessions()) } }
            var r = Report()
            for await (name, s) in g {
                if let s { r.sessions[name] = s } else { r.offline.append(name) }
            }
            r.offline.sort()
            return r
        }
    }

    /// The rows from boxes' sessions (`CarDigest.rows`, archived turns left out).
    static func rows(_ sessions: [String: [Session]], limit: Int) async -> [CarDigest.Row] {
        let marks = await LocalPrefs.savedClosedMarks()
        let items = sessions.keys.sorted().flatMap { box in sessions[box]!.map { (box: box, session: $0) } }
        return CarDigest.rows(items, archived: { LocalPrefs.isClosed(marks, box: $0, session: $1) }, limit: limit)
    }

    /// The row for a conversation id, read fresh from its box.
    static func row(for id: String) async -> CarDigest.Row? {
        guard let (box, name) = CarDigest.parse(id), let client = try? HeadlessBoxes.box(box).client,
              let s = try? await client.sessions().first(where: { $0.name == name }) else { return nil }
        let kind: CarDigest.Kind = s.needsYou ? .needsYou : s.agentState == .running ? .working : .yourTurn
        return CarDigest.Row(box: box, session: s, kind: kind)
    }

    /// What Siri reads for a conversation: a waiting agent's request or question, the reply that ended a turn (its words
    /// only, `CarDigest.spoken`), or that it is still at work.
    static func words(for row: CarDigest.Row) async -> String {
        switch row.kind {
        case .needsYou:
            return ask(row.session)
        case .working:
            return String(localized: "Ainda está trabalhando.")
        case .yourTurn:
            guard let client = try? HeadlessBoxes.box(row.box).client else { return String(localized: "Terminou.") }
            let name = row.session.name
            let reply: String? = await BoxAccess.withTimeout(.seconds(4)) {
                SessionSignals.lastReplyMarkdown(try await client.transcriptBefore(session: name, before: 0, limit: 40))
            } ?? nil
            guard let reply, !reply.isEmpty else { return String(localized: "Terminou.") }
            return CarDigest.spoken(reply, codePlaceholder: String(localized: "(código)"))
        }
    }

    /// "Quer permissão para Bash: rm -rf build", or the agent's question.
    static func ask(_ s: Session) -> String {
        guard let a = s.ask else { return String(localized: "Precisa de você.") }
        if Ask.classify(a) == .permission {
            let what = [a.tool, a.input].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
            return what.isEmpty ? String(localized: "Pede uma permissão.") : String(localized: "Quer permissão para \(what)")
        }
        // The question in its own words; the hook's message ("Claude needs your permission") only when there is none.
        if let q = a.input?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty { return CarDigest.spoken(q, limit: 300) }
        if let m = a.message?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty { return CarDigest.spoken(m, limit: 300) }
        return String(localized: "Tem uma pergunta para você.")
    }
}
