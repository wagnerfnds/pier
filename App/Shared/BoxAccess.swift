import Foundation
import PierKit

/// The result of asking one box for its sessions.
struct BoxFetch: Sendable {
    let record: BoxRecord
    /// nil: the box could not be reached in time.
    let sessions: [Session]?
}

/// Paired boxes + identity from the shared keychain, with clients built on demand. Usable from the app, the widget
/// extension and App Intents (which may run in either process).
struct BoxAccess: Sendable {
    let identity: PierIdentity
    let records: [BoxRecord]

    static func load() -> BoxAccess? {
        let kc = SharedKeychain.store()
        guard let identity = try? IdentityStore.load(from: kc),
              let records = try? BoxStore(store: kc).list(), !records.isEmpty else { return nil }
        return BoxAccess(identity: identity, records: records)
    }

    func record(named name: String) -> BoxRecord? { records.first { $0.name == name } }

    func client(for record: BoxRecord) -> any PierBoxClient {
        BoxAPI(client: BoxClient(box: record, identity: identity))
    }

    func client(box name: String) -> (any PierBoxClient)? { record(named: name).map(client(for:)) }

    /// Lists sessions on every box concurrently; boxes that do not answer within `timeout` come back with `sessions == nil`.
    func fetchSessions(timeout: Duration = .seconds(8)) async -> [BoxFetch] {
        await withTaskGroup(of: BoxFetch.self) { group in
            for rec in records {
                let client = client(for: rec)
                group.addTask {
                    let sessions = await Self.withTimeout(timeout) { try await client.sessions() }
                    return BoxFetch(record: rec, sessions: sessions)
                }
            }
            var out: [BoxFetch] = []
            for await f in group { out.append(f) }
            return records.compactMap { r in out.first { $0.record == r } }
        }
    }

    /// Runs `work` and gives up (nil) after `timeout`; errors are nil too.
    static func withTimeout<T: Sendable>(_ timeout: Duration, _ work: @escaping @Sendable () async throws -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { try? await work() }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
