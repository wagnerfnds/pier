import Foundation

/// The seam between the typed API and the wire. `BoxClient` is the production conformance;
/// tests plug in a scripted one.
public protocol PierTransport: Sendable {
    /// One request/response. `path` starts with `/v1/` and already carries any query string.
    /// A non-2xx answer throws (`PierError.api` / `.unauthorized` / `.rateLimited`).
    func send(_ method: BoxClient.Method, path: String, body: Data?) async throws -> (status: Int, data: Data)
    /// One connection's worth of a long-lived GET (NDJSON events): body chunks until the response ends or fails.
    func stream(path: String) -> AsyncThrowingStream<Data, Error>
    /// Drop the connection (foreground / network change); the next call re-dials.
    func reset() async
}

extension BoxClient: PierTransport {
    public func send(_ method: Method, path: String, body: Data?) async throws -> (status: Int, data: Data) {
        try await requestStatus(method, path: path, jsonBody: body)
    }

    public nonisolated func stream(path: String) -> AsyncThrowingStream<Data, Error> { chunks(path: path) }
}
