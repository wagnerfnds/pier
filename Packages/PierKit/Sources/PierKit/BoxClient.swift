import Foundation
import NIOCore
import NIOPosix

/// A paired box's decoded event (`GET /v1/events`).
public struct BoxEvent: Decodable, Sendable {
    public let seq: Int64
    public let type: String
    public let time: String?
    public let box: String?
    public let origin: String?
    public let error: String?
    public let data: JSONValue?

    public var date: Date? { time.flatMap(PierJSON.parseDate) }
}

/// Async HTTP/2 client for one box: mutual TLS 1.3, SPKI pinning, one reused connection.
///
/// Typed endpoints belong in extensions in the app layer; they all funnel through
/// ``request(_:path:body:)`` / ``requestData(_:path:body:)``.
public actor BoxClient {
    public enum Method: String, Sendable { case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE" }

    public let box: BoxRecord
    private let identity: PierIdentity
    private let group: EventLoopGroup
    private let origin: String
    private let decoder = PierJSON.makeDecoder()
    private let encoder = PierJSON.makeEncoder()
    /// Per-request limit for buffered calls (pierd's client uses 3 minutes for response headers).
    public var requestTimeout: Duration = .seconds(180)

    private var connection: H2Connection?
    private var connecting: Task<H2Connection, Error>?

    /// - Parameter origin: `X-Pier-Origin` label (`[a-z0-9][a-z0-9-]{0,31}`), shown in events/hooks.
    public init(
        box: BoxRecord,
        identity: PierIdentity,
        origin: String = "ios",
        group: EventLoopGroup = NIOSingletons.posixEventLoopGroup
    ) {
        self.box = box
        self.identity = identity
        self.origin = origin
        self.group = group
    }

    // MARK: connection management

    private func current() async throws -> H2Connection {
        if let c = connection, c.isActive { return c }
        connection = nil
        if let t = connecting { return try await t.value }
        let (box, identity, group) = (self.box, self.identity, self.group)
        let t = Task { try await H2Connection.dial(box: box, identity: identity, group: group) }
        connecting = t
        defer { connecting = nil }
        let c = try await t.value
        connection = c
        return c
    }

    /// Drop the connection (call on foreground / network change). The next call re-dials.
    public func reset() {
        connection?.close()
        connection = nil
    }

    private func invalidate(_ c: H2Connection) {
        c.close()
        if connection === c { connection = nil }
    }

    // MARK: requests

    private nonisolated var headers: [(String, String)] { [("x-pier-origin", origin)] }

    /// Raw response body of a successful (2xx) call.
    public func requestData(_ method: Method = .get, path: String, body: (any Encodable & Sendable)? = nil) async throws -> Data {
        let payload: Data? = try body.map { try encoder.encode(AnyEncodable($0)) }
        return try await requestStatus(method, path: path, jsonBody: payload).data
    }

    /// Like ``requestData(_:path:body:)`` with an already-encoded JSON body, and the HTTP status of the
    /// 2xx answer (some calls answer 200 or 202). Non-2xx throws.
    public func requestStatus(_ method: Method = .get, path: String, jsonBody payload: Data?) async throws -> (status: Int, data: Data) {
        var attempt = 0
        while true {
            attempt += 1
            // Never dial on behalf of a caller that has gone away (a screen closed, a deadline passed).
            try Task.checkCancellation()
            let conn = try await current()
            do {
                // Reads answer fast or not at all (a zombie socket): 45 s at most. Writes (exec, task create) keep the long limit.
                let limit = method == .get ? min(requestTimeout, .seconds(45)) : requestTimeout
                let (status, data) = try await withTimeout(limit) {
                    try await conn.roundTrip(method: method.rawValue, path: path, headers: self.headers, body: payload)
                }
                guard (200..<300).contains(status) else { throw mapHTTPError(status: status, body: data) }
                return (status, data)
            } catch is CancellationError {
                // Only this request's stream was reset; the connection (and the event stream on it) is fine.
                throw CancellationError()
            } catch let e as StreamOpenError {
                // Nothing was sent: safe to re-dial once for any method.
                invalidate(conn)
                if attempt < 2 { continue }
                throw PierError.transport("\(e.underlying)")
            } catch let e as PierError {
                if Task.isCancelled { throw CancellationError() }
                if case .transport = e, !conn.isActive {
                    invalidate(conn)
                    if attempt < 2 && method == .get { continue }
                }
                if case .timeout = e { invalidate(conn) }
                throw e
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if !conn.isActive {
                    invalidate(conn)
                    if attempt < 2 && method == .get { continue }
                }
                throw PierError.transport("\(error)")
            }
        }
    }

    /// Decoded response of a successful call.
    public func request<T: Decodable & Sendable>(
        _ method: Method = .get, path: String, body: (any Encodable & Sendable)? = nil
    ) async throws -> T {
        let data = try await requestData(method, path: path, body: body)
        if T.self == EmptyResponse.self { return EmptyResponse() as! T }
        do { return try decoder.decode(T.self, from: data) } catch {
            throw PierError.decoding("\(error)")
        }
    }

    /// `GET /v1/ping`: box name; throws ``PierError/unauthorized`` if this client was revoked.
    public func ping() async throws -> String {
        struct R: Decodable, Sendable { let name: String }
        let r: R = try await request(.get, path: "/v1/ping")
        return r.name
    }

    // MARK: streams

    /// NDJSON stream over `GET /v1/events?since=`. Blank keepalive lines are ignored. With `reconnect`
    /// (default) the stream survives drops: it re-dials with backoff and resumes from the last `seq`.
    /// Terminal errors (revoked, pin mismatch, HTTP errors) end the sequence by throwing.
    public nonisolated func events(since: Int64? = nil, reconnect: Bool = true) -> AsyncThrowingStream<BoxEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var last = since
                var backoff: Double = 1
                let trace = ProcessInfo.processInfo.environment["PIERKIT_TRACE"] != nil
                let decoder = JSONDecoder()
                while !Task.isCancelled {
                    do {
                        let conn = try await self.current()
                        let path = "/v1/events" + (last.map { "?since=\($0)" } ?? "")
                        var buffer = Data()
                        for try await chunk in conn.streamingGET(path: path, headers: self.headers) {
                            backoff = 1
                            if trace { FileHandle.standardError.write(Data("[pierkit] events chunk \(chunk.count) bytes\n".utf8)) }
                            buffer.append(chunk)
                            if buffer.count > EventStreamPolicy.maxLineBytes, !buffer.contains(0x0a) { buffer.removeAll(keepingCapacity: false) }
                            while let nl = buffer.firstIndex(of: 0x0a) {
                                let line = buffer[buffer.startIndex..<nl]
                                buffer.removeSubrange(buffer.startIndex...nl)
                                guard line.contains(where: { $0 != 0x20 && $0 != 0x0d && $0 != 0x09 }) else { continue }
                                guard let ev = try? decoder.decode(BoxEvent.self, from: line) else { continue }
                                last = max(last ?? ev.seq, ev.seq)
                                continuation.yield(ev)
                            }
                        }
                        if Task.isCancelled { break }
                        if !reconnect { continuation.finish(); return }
                    } catch let e as PierError {
                        if !e.isTransient || !reconnect { continuation.finish(throwing: e); return }
                        await self.dropIfDead()
                    } catch {
                        continuation.finish(throwing: PierError.transport("\(error)"))
                        return
                    }
                    try? await Task.sleep(for: .seconds(backoff))
                    backoff = min(backoff * 2, 30)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One connection's worth of an NDJSON/chunked GET (no reconnect, no parsing): chunks until the
    /// server ends the response or the connection fails. Used by the typed events stream, which owns
    /// reconnection.
    public nonisolated func chunks(path: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let conn = try await self.current()
                    for try await chunk in conn.streamingGET(path: path, headers: self.headers) { continuation.yield(chunk) }
                    continuation.finish()
                } catch let e as PierError {
                    if e.isTransient { await self.dropIfDead() }
                    continuation.finish(throwing: e)
                } catch {
                    continuation.finish(throwing: PierError.transport("\(error)"))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func dropIfDead() {
        if let c = connection, !c.isActive { invalidate(c) }
    }
}

private struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ v: any Encodable) { value = v }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

func withTimeout<T: Sendable>(_ d: Duration, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(for: d)
            throw PierError.timeout
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
