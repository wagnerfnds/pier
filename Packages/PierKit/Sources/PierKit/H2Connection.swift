import Foundation
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOPosix

/// One pinned, mutually authenticated HTTP/2 connection to a box. One stream per request.
final class H2Connection: Sendable {
    typealias Stream = NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>

    let channel: Channel
    let multiplexer: NIOHTTP2Handler.AsyncStreamMultiplexer<Void>
    let authority: String

    var isActive: Bool { channel.isActive }

    private init(channel: Channel, multiplexer: NIOHTTP2Handler.AsyncStreamMultiplexer<Void>, authority: String) {
        self.channel = channel
        self.multiplexer = multiplexer
        self.authority = authority
    }

    static func dial(box: BoxRecord, identity: PierIdentity, group: EventLoopGroup) async throws -> H2Connection {
        let link = try PairingLink.splitHostPort(box.address)
        // The multiplexer is created inside the channel initializer so no frame can arrive unhandled.
        let muxBox = MuxBox()
        let watcher = PingWatcher()
        // Default windows are 64 KB shared per RTT: a transcript page or a 300-line screen took several round trips on
        // a slow link. 4 MB lets a whole answer arrive in one.
        var cfg = NIOHTTP2Handler.Configuration()
        cfg.stream.targetWindowSize = 4 << 20
        cfg.connection.initialSettings = nioDefaultSettings.filter { $0.parameter != .initialWindowSize }
            + [HTTP2Setting(parameter: .initialWindowSize, value: 4 << 20)]
        let config = cfg
        let dial = try await TLSDial.connect(
            host: link.0, port: link.1, identity: identity, pin: box.fingerprint, alpn: ["h2"], group: group
        ) { ops in
            let mux = try ops.configureAsyncHTTP2Pipeline(mode: .client, configuration: config) { channel in
                channel.eventLoop.makeSucceededVoidFuture()
            }
            try ops.addHandler(watcher)
            muxBox.set(mux)
        }
        guard dial.negotiatedProtocol == "h2" else {
            dial.channel.close(promise: nil)
            throw PierError.protocolViolation("box did not negotiate h2 (got \(dial.negotiatedProtocol ?? "none"))")
        }
        let channel = dial.channel
        // Keep NAT/idle timeouts at bay: HTTP/2 PING every 15 s. Two unanswered PINGs mean the socket is a zombie (network
        // change, box rebooted without RST): close it so the next request re-dials instead of hanging until its deadline.
        let ping = channel.eventLoop.scheduleRepeatedTask(initialDelay: .seconds(15), delay: .seconds(15)) { task in
            guard channel.isActive else { task.cancel(); return }
            if watcher.outstanding >= 2 { channel.close(promise: nil); task.cancel(); return }
            watcher.outstanding += 1
            channel.writeAndFlush(
                HTTP2Frame(streamID: .rootStream, payload: .ping(HTTP2PingData(withInteger: 0), ack: false)), promise: nil)
        }
        channel.closeFuture.whenComplete { _ in ping.cancel() }
        return H2Connection(channel: channel, multiplexer: muxBox.get(), authority: box.address)
    }

    func close() { channel.close(promise: nil) }

    // MARK: requests

    private func head(method: String, path: String, extra: [(String, String)], bodyLength: Int?) -> HTTPRequestHead {
        var headers = HTTPHeaders()
        headers.add(name: "host", value: authority)
        for (k, v) in extra { headers.add(name: k, value: v) }
        if let n = bodyLength {
            headers.add(name: "content-type", value: "application/json")
            headers.add(name: "content-length", value: String(n))
        }
        return HTTPRequestHead(version: .http2, method: HTTPMethod(rawValue: method), uri: path, headers: headers)
    }

    private func openStream() async throws -> Stream {
        do {
            return try await multiplexer.openStream { streamChannel in
                streamChannel.eventLoop.makeCompletedFuture {
                    try streamChannel.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https))
                    return try Stream(wrappingChannelSynchronously: streamChannel)
                }
            }
        } catch {
            throw StreamOpenError(underlying: error)
        }
    }

    /// A buffered answer larger than this is a broken (or hostile) box, not something to hold in memory: the biggest
    /// legitimate ones (a transcript page, a screen with history) are a few MB.
    static let maxResponseBytes = 32 << 20
    /// The body of a non-2xx answer is only read for its `{"error","code"}` message.
    static let maxErrorBytes = 1 << 20

    /// Buffered request. Throws ``StreamOpenError`` if nothing was sent.
    func roundTrip(method: String, path: String, headers: [(String, String)], body: Data?) async throws -> (status: Int, body: Data) {
        let stream = try await openStream()
        let head = head(method: method, path: path, extra: headers, bodyLength: body?.count)
        return try await stream.executeThenClose { inbound, outbound in
            try await outbound.write(.head(head))
            if let body, !body.isEmpty {
                var buf = ByteBufferAllocator().buffer(capacity: body.count)
                buf.writeBytes(body)
                try await outbound.write(.body(.byteBuffer(buf)))
            }
            try await outbound.write(.end(nil))
            var status = 0
            var data = Data()
            for try await part in inbound {
                switch part {
                case .head(let h): status = Int(h.status.code)
                case .body(let b):
                    guard data.count + b.readableBytes <= Self.maxResponseBytes else {
                        throw PierError.protocolViolation("response larger than \(Self.maxResponseBytes >> 20) MB")
                    }
                    data.append(contentsOf: b.readableBytesView)
                case .end: return (status, data)
                }
            }
            // A cancelled caller ends the inbound sequence early: that is cancellation, not a broken connection.
            try Task.checkCancellation()
            throw PierError.transport("stream closed before the response completed")
        }
    }

    /// Long-lived GET: yields body chunks of a 2xx response; non-2xx / failures finish the sequence with an error.
    func streamingGET(path: String, headers: [(String, String)]) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let stream = try await self.openStream()
                    let head = self.head(method: "GET", path: path, extra: headers, bodyLength: nil)
                    try await stream.executeThenClose { inbound, outbound in
                        try await outbound.write(.head(head))
                        try await outbound.write(.end(nil))
                        var status = 0
                        var errBody = Data()
                        for try await part in inbound {
                            switch part {
                            case .head(let h): status = Int(h.status.code)
                            case .body(let b):
                                if (200..<300).contains(status) {
                                    continuation.yield(Data(b.readableBytesView))
                                } else if errBody.count < Self.maxErrorBytes {
                                    errBody.append(contentsOf: b.readableBytesView.prefix(Self.maxErrorBytes - errBody.count))
                                }
                            case .end:
                                if !(200..<300).contains(status) { throw mapHTTPError(status: status, body: errBody) }
                                return
                            }
                        }
                    }
                    continuation.finish()
                } catch let e as StreamOpenError {
                    continuation.finish(throwing: PierError.transport("\(e.underlying)"))
                } catch let e as PierError {
                    continuation.finish(throwing: e)
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: PierError.transport("\(error)"))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct StreamOpenError: Error { let underlying: Error }

private final class MuxBox: @unchecked Sendable {
    private var mux: NIOHTTP2Handler.AsyncStreamMultiplexer<Void>?
    func set(_ m: NIOHTTP2Handler.AsyncStreamMultiplexer<Void>) { mux = m }
    func get() -> NIOHTTP2Handler.AsyncStreamMultiplexer<Void> { mux! }
}

/// `{"error","code"}` -> typed error. 401 means revoked, 429 rate limited.
func mapHTTPError(status: Int, body: Data) -> PierError {
    struct Payload: Decodable { let error: String?; let code: String? }
    let p = try? JSONDecoder().decode(Payload.self, from: body)
    let message = p?.error ?? (String(data: body.prefix(200), encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }) ?? "HTTP \(status)"
    switch status {
    case 401: return .unauthorized
    case 429 where p?.code == nil || p?.code == "too_many": return .rateLimited(message: message)
    default: return .api(status: status, message: message, code: p?.code)
    }
}

/// Counts PINGs sent without an ACK. Lives on the connection's event loop (handler callbacks and the repeated task).
private final class PingWatcher: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTP2Frame
    var outstanding = 0

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .ping(_, ack: true) = unwrapInboundIn(data).payload { outstanding = 0 }
        context.fireChannelRead(data)
    }
}
