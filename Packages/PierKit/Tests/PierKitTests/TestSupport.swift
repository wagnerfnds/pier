import Foundation
import NIOConcurrencyHelpers

@testable import PierKit

enum Fixture {
    static var dir: URL { Bundle.module.resourceURL!.appendingPathComponent("Fixtures") }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: dir.appendingPathComponent(name))
    }

    static func decode<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder.pier.decode(T.self, from: data(name))
    }

    static func screen(_ name: String) throws -> String {
        struct S: Decodable { let screen: String }
        return try JSONDecoder().decode(S.self, from: data(name)).screen
    }

    static func text(_ name: String) throws -> String { String(decoding: try data(name), as: UTF8.self) }

    static var allJSON: [String] {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return all.filter { $0.hasSuffix(".json") }.sorted()
    }
}

/// A scripted `PierTransport`: request handler + a queue of event-stream connections.
final class MockTransport: PierTransport, @unchecked Sendable {
    struct Request: Equatable { let method: String; let path: String; let body: String? }

    enum End { case finish, fail(Error), hang }
    struct Connection {
        var chunks: [Data]
        var end: End
    }

    private let lock = NSLock()
    private var _requests: [Request] = []
    private var _streamPaths: [String] = []
    private var connections: [Connection]
    private var _resets = 0
    var handler: @Sendable (BoxClient.Method, String, Data?) throws -> (Int, Data)

    init(connections: [Connection] = [], handler: @escaping @Sendable (BoxClient.Method, String, Data?) throws -> (Int, Data) = { _, _, _ in (200, Data("{}".utf8)) }) {
        self.connections = connections
        self.handler = handler
    }

    var requests: [Request] { lock.withLock { _requests } }
    var streamPaths: [String] { lock.withLock { _streamPaths } }
    var resets: Int { lock.withLock { _resets } }

    func send(_ method: BoxClient.Method, path: String, body: Data?) async throws -> (status: Int, data: Data) {
        lock.withLock { _requests.append(Request(method: method.rawValue, path: path, body: body.map { String(decoding: $0, as: UTF8.self) })) }
        let (s, d) = try handler(method, path, body)
        return (s, d)
    }

    func stream(path: String) -> AsyncThrowingStream<Data, Error> {
        let conn: Connection = lock.withLock {
            _streamPaths.append(path)
            return connections.isEmpty ? Connection(chunks: [], end: .hang) : connections.removeFirst()
        }
        return AsyncThrowingStream { c in
            for ch in conn.chunks { c.yield(ch) }
            switch conn.end {
            case .finish: c.finish()
            case .fail(let e): c.finish(throwing: e)
            case .hang: break
            }
        }
    }

    func reset() async { lock.withLock { _resets += 1 } }
}

func line(_ seq: Int, _ type: String = "agent.started") -> Data {
    Data("{\"seq\":\(seq),\"type\":\"\(type)\",\"time\":\"2026-10-07T21:00:0\(seq % 10).5Z\"}\n".utf8)
}
