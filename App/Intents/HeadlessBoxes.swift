import Foundation
import PierKit

/// A paired box with a ready client, built without the UI (Siri, Shortcuts, notification actions run the app in the background).
struct HeadlessBox: Sendable {
    let name: String
    let client: any PierBoxClient
}

/// What an intent sees of one box: sessions, locations and the box's agent presets.
struct HeadlessSnapshot: Sendable {
    let box: HeadlessBox
    var info: BoxInfo?
    var sessions: [Session]
    var locations: [Location]
}

enum HeadlessError: LocalizedError {
    case notPaired
    case boxNotFound(String)
    case sessionNotFound(String)

    var errorDescription: String? {
        switch self {
        case .notPaired: String(localized: "Nenhuma box pareada. Abra o Pier e pareie com “pierd pair”.")
        case .boxNotFound(let b): String(localized: "A box “\(b)” não está pareada.")
        case .sessionNotFound(let s): String(localized: "Não encontrei a sessão “\(s)”.")
        }
    }
}

enum HeadlessBoxes {
    /// Every paired box (shared keychain via `BoxAccess`), with a client each.
    static func all() throws -> [HeadlessBox] {
        #if DEBUG
        // `-uiTestMock 1`: the one in-memory box the app runs against (no keychain), so notification actions and intents
        // reach the same scripted state the screens show.
        if UITestMock.enabled, let mock = UITestMock.headless { return [HeadlessBox(name: mock.name, client: mock.client)] }
        #endif
        guard let access = BoxAccess.load() else { throw HeadlessError.notPaired }
        return access.records.map { HeadlessBox(name: $0.name, client: access.client(for: $0)) }
    }

    static func box(_ name: String) throws -> HeadlessBox {
        guard let b = try all().first(where: { $0.name == name }) else { throw HeadlessError.boxNotFound(name) }
        return b
    }

    /// Sessions of every box in parallel; boxes that fail are skipped.
    static func sessions() async throws -> [(box: String, session: Session)] {
        let boxes = try all()
        return await withTaskGroup(of: (Int, [Session]).self) { g in
            for (i, b) in boxes.enumerated() { g.addTask { (i, (try? await b.client.sessions()) ?? []) } }
            var by: [Int: [Session]] = [:]
            for await (i, s) in g { by[i] = s }
            return boxes.indices.flatMap { i in (by[i] ?? []).map { (boxes[i].name, $0) } }
        }
    }

    static func snapshots(withLocations: Bool = true) async throws -> [HeadlessSnapshot] {
        let boxes = try all()
        return await withTaskGroup(of: (Int, HeadlessSnapshot).self) { g in
            for (i, b) in boxes.enumerated() {
                g.addTask {
                    async let info = try? await b.client.info()
                    async let sessions = try? await b.client.sessions()
                    async let locations: [Location]? = withLocations ? (try? await b.client.locations()) : nil
                    return (i, HeadlessSnapshot(box: b, info: await info, sessions: await sessions ?? [], locations: await locations ?? []))
                }
            }
            var by: [Int: HeadlessSnapshot] = [:]
            for await (i, s) in g { by[i] = s }
            return boxes.indices.compactMap { by[$0] }
        }
    }
}
