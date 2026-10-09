import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS

/// Completes once the TLS handshake finished (or fails with the first error). Passes everything through.
final class HandshakeWaiter: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    private let promise: EventLoopPromise<String?>
    private var done = false

    init(promise: EventLoopPromise<String?>) { self.promise = promise }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted(let proto) = event, !done {
            done = true
            promise.succeed(proto)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !done {
            done = true
            promise.fail(error)
        }
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !done {
            done = true
            promise.fail(ChannelError.ioOnClosedChannel)
        }
        context.fireChannelInactive()
    }
}

/// Dials `host:port`, TLS 1.3, presents our Ed25519 client cert, and pins the server key by SPKI hash.
enum TLSDial {
    struct Result {
        let channel: Channel
        let negotiatedProtocol: String?
    }

    static func connect(
        host: String,
        port: Int,
        identity: PierIdentity,
        pin: Fingerprint,
        alpn: [String],
        group: EventLoopGroup,
        timeout: TimeAmount = .seconds(15),
        configure: @escaping @Sendable (ChannelPipeline.SynchronousOperations) throws -> Void
    ) async throws -> Result {
        let context = try sslContext(identity: identity, alpn: alpn)
        return try await dial(host: host, port: port, context: context, pin: pin, group: group, timeout: timeout, configure: configure)
    }

    /// The TLS context depends only on our identity and ALPN: built once (key parsing, BoringSSL setup), not per dial.
    private static let contexts = NIOLockedValueBox<[String: NIOSSLContext]>([:])

    private static func sslContext(identity: PierIdentity, alpn: [String]) throws -> NIOSSLContext {
        let key = "\(identity.fingerprint)|\(alpn.joined(separator: ","))"
        if let c = contexts.withLockedValue({ $0[key] }) { return c }
        var config = TLSConfiguration.makeClientConfiguration()
        config.minimumTLSVersion = .tlsv13
        config.maximumTLSVersion = .tlsv13
        // The default chain/hostname validation is replaced by the pin check below.
        config.certificateVerification = .noHostnameVerification
        config.applicationProtocols = alpn
        // BoringSSL does NOT advertise ed25519 in signature_algorithms by default; pierd only has an
        // Ed25519 certificate, so without this the server answers handshake_failure.
        config.verifySignatureAlgorithms = [.ed25519]
        let creds = try identity.tlsCredentials()
        config.certificateChain = creds.chain
        config.privateKey = creds.key
        let context: NIOSSLContext
        do { context = try NIOSSLContext(configuration: config) } catch { throw PierError.tls("\(error)") }
        contexts.withLockedValue { $0[key] = context }
        return context
    }

    private static func dial(
        host: String, port: Int, context: NIOSSLContext, pin: Fingerprint, group: EventLoopGroup, timeout: TimeAmount,
        configure: @escaping @Sendable (ChannelPipeline.SynchronousOperations) throws -> Void
    ) async throws -> Result {

        let actualFP = NIOLockedValueBox<Fingerprint?>(nil)
        let handshake = group.next().makePromise(of: String?.self)

        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(timeout)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssl = try NIOSSLClientHandler(
                        context: context,
                        serverHostname: nil,
                        customVerificationCallback: { certs, promise in
                            guard let leaf = certs.first,
                                let spki = try? leaf.extractPublicKey().toSPKIBytes()
                            else { return promise.succeed(.failed) }
                            let fp = Fingerprint(spki: spki)
                            if fp == pin {
                                promise.succeed(.certificateVerified)
                            } else {
                                actualFP.withLockedValue { $0 = fp }
                                promise.succeed(.failed)
                            }
                        })
                    let ops = channel.pipeline.syncOperations
                    try ops.addHandler(ssl)
                    try ops.addHandler(HandshakeWaiter(promise: handshake))
                    try configure(ops)
                }
            }

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            handshake.fail(error)
            _ = try? await handshake.futureResult.get()
            throw map(error, pin: actualFP.withLockedValue { $0 }, expected: pin)
        }

        let timer = channel.eventLoop.scheduleTask(in: timeout) { handshake.fail(PierError.timeout) }
        do {
            let proto = try await handshake.futureResult.get()
            timer.cancel()
            return Result(channel: channel, negotiatedProtocol: proto)
        } catch {
            timer.cancel()
            try? await channel.close().get()
            throw map(error, pin: actualFP.withLockedValue { $0 }, expected: pin)
        }
    }

    static func map(_ error: Error, pin actual: Fingerprint?, expected: Fingerprint) -> PierError {
        if let actual { return .pinMismatch(expected: expected.description, actual: actual.description) }
        if let e = error as? PierError { return e }
        if error is NIOSSLError || error is BoringSSLError { return .tls("\(error)") }
        if let e = error as? NIOConnectionError { return .transport("\(e)") }
        return .transport("\(error)")
    }
}
