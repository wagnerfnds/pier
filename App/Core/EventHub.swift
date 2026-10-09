import Foundation
import PierKit

struct HubEvent: Sendable {
    let box: String
    let event: PierEvent
}

/// One event stream per box while the app is active; refreshes sessions/locations and fans events out.
@MainActor
final class EventHub {
    private var tasks: [String: Task<Void, Never>] = [:]
    private var subscribers: [UUID: AsyncStream<HubEvent>.Continuation] = [:]

    /// Typed fan-out for feature code (e.g. transcript views, the Home and the board). Cancel the consuming task to unsubscribe.
    func subscribe() -> AsyncStream<HubEvent> {
        let id = UUID()
        return AsyncStream { cont in
            subscribers[id] = cont
            cont.onTermination = { [weak self] _ in Task { @MainActor in self?.subscribers[id] = nil } }
        }
    }

    func start(_ conn: BoxConnection) {
        stop(conn.name)
        tasks[conn.name] = Task { [weak self] in
            var backoff: Double = 2
            /// The last event seen: a reconnect resumes from it (`?since=`), so a short drop loses nothing for subscribers.
            var lastSeq: Int64?
            while !Task.isCancelled {
                do {
                    for try await ev in conn.client.events(since: lastSeq) {
                        backoff = 2
                        if let seq = ev.seq { lastSeq = seq }
                        if conn.state != .online { conn.state = .online }
                        self?.dispatch(HubEvent(box: conn.name, event: ev), conn: conn)
                    }
                } catch is CancellationError {
                    return
                } catch let e as PierError {
                    switch e {
                    case .unauthorized: conn.state = .revoked; return
                    case .pinMismatch: conn.state = .pinMismatch; return
                    default: conn.state = .offline(e.localizedDescription)
                    }
                } catch {
                    conn.state = .offline(error.localizedDescription)
                }
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 30)
                await conn.connect()
            }
        }
    }

    func stop(_ box: String) {
        tasks[box]?.cancel()
        tasks[box] = nil
    }

    func stopAll() { for k in Array(tasks.keys) { stop(k) } }

    private func dispatch(_ h: HubEvent, conn: BoxConnection) {
        let t = h.event.type
        if t.hasPrefix("agent.") || t.hasPrefix("session.") || t == "task.created" {
            conn.scheduleRefresh(sessions: true)
        }
        if t.hasPrefix("worktree.") || t.hasPrefix("location.") || t == "task.created" {
            conn.scheduleRefresh(locations: true)
        }
        for c in subscribers.values { c.yield(h) }
    }
}
