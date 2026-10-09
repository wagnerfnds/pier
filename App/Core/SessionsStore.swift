import Foundation
import PierKit

struct BoxSession: Identifiable, Hashable {
    let box: String
    let session: Session
    var id: String { "\(box)/\(session.name)" }

    /// "loc/wt" -> ("loc", "wt"); a main worktree is just "loc".
    var location: String { session.location.map { String($0.split(separator: "/", maxSplits: 1).first ?? "") } ?? "" }
    var worktree: String? {
        guard let l = session.location, let i = l.firstIndex(of: "/") else { return nil }
        return String(l[l.index(after: i)...])
    }
    var route: SessionRoute { SessionRoute(box: box, session: session) }

    /// The project's name as the person calls it; "Conversa" for a chat, which belongs to none.
    @MainActor func placeName(_ prefs: LocalPrefs) -> String {
        session.chat ? BoxSession.chatPlace : prefs.displayName(box: box, location: location)
    }

    /// What a chat shows where a session shows its project.
    static var chatPlace: String { String(localized: "Conversa") }
}

/// Sessions merged across boxes, grouped by dashboard state.
@MainActor @Observable
final class SessionsStore {
    @ObservationIgnored weak var model: AppModel?

    var all: [BoxSession] {
        guard let model else { return [] }
        return model.boxes.flatMap { b in b.sessions.map { BoxSession(box: b.name, session: $0) } }
            .filter { s in
                guard DashState(s.session) != nil else { return false }
                return !model.prefs.isHidden(box: s.box, location: s.location)
            }
    }

    func group(_ state: DashState) -> [BoxSession] {
        all.filter { DashState($0.session) == state }
            .sorted { ($0.session.stateSince ?? $0.session.created) > ($1.session.stateSince ?? $1.session.created) }
    }

    var needsYouCount: Int { group(.needsYou).count }

    /// Finished turns the person has not closed: the agent waits for them to carry on (not blocked like needs-you).
    var yourTurn: [BoxSession] {
        guard let prefs = model?.prefs else { return group(.done) }
        return group(.done).filter { !prefs.isClosed(box: $0.box, session: $0.session) }
    }

    /// Finished turns marked as over, plus agent sessions that exited on the box, newest first.
    var closed: [BoxSession] {
        guard let model else { return [] }
        let marked = group(.done).filter { model.prefs.isClosed(box: $0.box, session: $0.session) }
        let exited = model.boxes.flatMap { b in b.sessions.map { BoxSession(box: b.name, session: $0) } }
            .filter { $0.session.isAgent && $0.session.exited && !model.prefs.isHidden(box: $0.box, location: $0.location) }
        return (marked + exited).sorted { ($0.session.stateSince ?? $0.session.created) > ($1.session.stateSince ?? $1.session.created) }
    }
}
