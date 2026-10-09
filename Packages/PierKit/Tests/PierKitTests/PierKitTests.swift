import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
import Testing

@testable import PierKit

// RFC 8032 test vector 1.
let rfcSeed = Array(hex: "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")

extension Array where Element == UInt8 {
    init(hex: String) {
        var out = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        self = out
    }
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

@Suite struct FingerprintTests {
    // SHA-256(30 2a 30 05 06 03 2b 65 70 03 21 00 || d75a98...511a), computed independently with
    // python hashlib and `shasum`, then base32-lowercase-nopad like Go's identity.Fingerprint.String().
    @Test func knownVector() throws {
        let id = try PierIdentity(seed: rfcSeed)
        #expect(id.fingerprint.description == "a3r73d62fg5wbk2zkv66mhw3blwnwiyrgs7dbz23ivpy4g3zf6uq")
        #expect(id.fingerprint.bytes.hex == "06e3fd8fda29bb60ab59557de61edb0aecdb231134be30e75b455f8e1b792fa9")
        #expect(id.fingerprint.short == "a3r73d62fg5w")
        #expect(Fingerprint(string: "A3R73D62FG5WBK2ZKV66MHW3BLWNWIYRGS7DBZ23IVPY4G3ZF6UQ") == id.fingerprint)
    }

    @Test func rejectsMalformed() {
        #expect(Fingerprint(string: "abc") == nil)
        #expect(Fingerprint(string: String(repeating: "1", count: 52)) == nil)
    }

    @Test func base32RoundTrip() {
        for n in 0..<40 {
            let bytes = (0..<n).map { UInt8(($0 &* 37 &+ n) & 0xff) }
            #expect(Base32.decode(Base32.encode(bytes)) == bytes)
        }
    }
}

@Suite struct IdentityTests {
    @Test func pemRoundTripAndShape() throws {
        let id = try PierIdentity(seed: rfcSeed)
        let pem = id.privateKeyPEM
        #expect(pem.hasPrefix("-----BEGIN PRIVATE KEY-----"))
        let again = try PierIdentity(pem: pem)
        #expect(again.fingerprint == id.fingerprint)
        // BoringSSL accepts it too.
        _ = try NIOSSLPrivateKey(bytes: Array(pem.utf8), format: .pem)
    }

    @Test func certificateCarriesTheKey() throws {
        let id = PierIdentity.generate()
        let der = try id.makeCertificateDER()
        let cert = try NIOSSLCertificate(bytes: der, format: .der)
        let spki = try cert.extractPublicKey().toSPKIBytes()
        #expect(Fingerprint(spki: spki) == id.fingerprint)
        #expect(spki.count == 44)
    }

    @Test func storeLoadsOrCreatesOnce() throws {
        let store = MemoryStore()
        let a = try IdentityStore.loadOrCreate(in: store)
        let b = try IdentityStore.loadOrCreate(in: store)
        #expect(a.fingerprint == b.fingerprint)
    }

    @Test func fileStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pierkit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileStore(directory: dir)
        #expect(try store.read("x") == nil)
        try store.write(Data("hi".utf8), for: "x")
        #expect(try store.read("x") == Data("hi".utf8))
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("x").path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
    }

    @Test func proofVector() throws {
        // python3: hmac.new(b"\x01"*32, b"pier pair v1" + b"\x02"*32 + fp(rfc8032 key 1), sha256); pierd's
        // TestProofVector (Server/pierd/internal/pairing/pairing_test.go) checks the same vector.
        #expect(Pairing.exporterLabel == "EXPORTER-pier-pair-v1")
        let id = try PierIdentity(seed: rfcSeed)
        let proof = PierIdentity.pairingProof(
            code: [UInt8](repeating: 1, count: 32), exporter: [UInt8](repeating: 2, count: 32),
            clientFingerprint: id.fingerprint)
        #expect(proof.hex == "31031d35b2ec1c3ba97454b216cafb666943195fb24ffd064218a61c8da3caba")
    }
}

@Suite struct LinkTests {
    static let fp = "aaaqeayeaudaocajbifqydiob4ibceqtcqkrmfyydenbwha5dypq"
    static let code = "mrswmz3infvgw3dnnzxxa4lson2hk5txpb4xu634pv7h7aebqkbq"

    @Test func boxLink() throws {
        let l = try PairingLink.parse("pier://192.0.2.10:7444?code=\(Self.code)&fp=\(Self.fp)")
        guard case .box(let b) = l else { Issue.record("expected box"); return }
        #expect(b.host == "192.0.2.10" && b.port == 7444 && b.address == "192.0.2.10:7444")
        #expect(b.fingerprint.bytes == Array(0..<32))
        #expect(b.code == Array(100..<132))
        // order-insensitive, case-insensitive, whitespace tolerant
        let l2 = try PairingLink.parse("  pier://box.example:1?fp=\(Self.fp.uppercased())&code=\(Self.code)\n")
        guard case .box(let b2) = l2 else { Issue.record("expected box"); return }
        #expect(b2.host == "box.example" && b2.fingerprint == b.fingerprint)
        let v6 = try PairingLink.parse("pier://[fe80::1]:7444?code=\(Self.code)&fp=\(Self.fp)")
        guard case .box(let b6) = v6 else { Issue.record("expected box"); return }
        #expect(b6.host == "fe80::1" && b6.address == "[fe80::1]:7444")
    }

    /// pierd prints pier:// links; the scheme is case-insensitive, and links are found inside pasted text.
    @Test func pierLink() throws {
        let pier = try PairingLink.parse("pier://192.0.2.10:7444?code=\(Self.code)&fp=\(Self.fp)")
        #expect(try PairingLink.parse("PIER://192.0.2.10:7444?code=\(Self.code)&fp=\(Self.fp)") == pier)
        #expect(PairingLink.find(in: "Pair: pier://192.0.2.10:7444?code=\(Self.code)&fp=\(Self.fp).") == pier)
        #expect(throws: PierError.self) { try PairingLink.parse("other://192.0.2.10:7444?code=\(Self.code)&fp=\(Self.fp)") }
        #expect(PairingLink.find(in: "Pair: other://192.0.2.10:7444?code=\(Self.code)&fp=\(Self.fp).") == nil)
        #expect(throws: PierError.self) { try PairingLink.parse("piers://192.0.2.10:7444?code=\(Self.code)&fp=\(Self.fp)") }
    }

    @Test func rejectsBadBoxLinks() {
        let q = "?code=\(Self.code)&fp=\(Self.fp)"
        for bad in [
            "pier://203.0.113.5\(q)", "pier://203.0.113.5:0\(q)", "pier://203.0.113.5:70000\(q)",
            "pier://:7444\(q)", "pier://user@203.0.113.5:7444\(q)", "http://203.0.113.5:7444\(q)",
            "pier://203.0.113.5:7444/x\(q)", "pier://203.0.113.5:7444?fp=\(Self.fp)",
            "pier://203.0.113.5:7444?code=abc&fp=\(Self.fp)", "pier://203.0.113.5:7444?code=\(Self.code)",
            "", "pier://",
        ] {
            #expect(throws: PierError.self, "\(bad)") { try PairingLink.parse(bad) }
        }
    }

    @Test func joinLink() throws {
        let d = "cT-zAAdtYWNib29rAQABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXp7fH1-f4CBgoMEZGV2bAAAAg8xOTIuMC4yLjEwOjc0NDQOW2ZlODA6OjFdOjc0NDQ"
        let l = try PairingLink.parse("pier://join?v=1&d=\(d)")
        guard case .join(let j) = l else { Issue.record("expected join"); return }
        #expect(j.from == "macbook" && j.boxes.count == 1)
        #expect(j.expires == Date(timeIntervalSince1970: 1_900_000_000))
        let b = j.boxes[0]
        #expect(b.name == "devl" && b.network == "" && b.addresses == ["192.0.2.10:7444", "[fe80::1]:7444"])
        #expect(b.code == Array(100..<132))
        #expect(try b.pairingLink().address == "192.0.2.10:7444")
        #expect(!j.isExpired(now: Date(timeIntervalSince1970: 1_900_000_030)))
        #expect(j.isExpired(now: Date(timeIntervalSince1970: 1_900_000_100)))
        // trailing byte / truncation / version
        #expect(throws: PierError.self) { try PairingLink.parse("pier://join?v=1&d=\(d)AA") }
        #expect(throws: PierError.self) { try PairingLink.parse("pier://join?v=1&d=\(d.dropLast(8))") }
        #expect(throws: PierError.self) { try PairingLink.parse("pier://join?v=2&d=\(d)") }
        // found inside prose
        let found = PairingLink.find(in: "Join me: pier://join?v=1&d=\(d).")
        #expect(found == l)
    }

    @Test func names() {
        #expect(PierName.isValid("pierctl-dev") && PierName.isValid("a"))
        #expect(!PierName.isValid("local") && !PierName.isValid("-x") && !PierName.isValid("a b") && !PierName.isValid(""))
        #expect(PierName.fromHostname("Octocats-MacBook.local") == "octocats-macbook")
        #expect(PierName.fromHostname("") == "device")
    }

    @Test func boxStoreReplacesAndSuffixes() throws {
        let bs = BoxStore(store: MemoryStore())
        let f1 = PierIdentity.generate().fingerprint, f2 = PierIdentity.generate().fingerprint
        try bs.add(.init(name: "devl", address: "1.2.3.4:7444", fingerprint: f1))
        let second = try bs.add(.init(name: "devl", address: "5.6.7.8:7444", fingerprint: f2))
        #expect(second.name == "devl-2")
        try bs.add(.init(name: "devl", address: "9.9.9.9:7444", fingerprint: f1))  // re-pair same key replaces
        let all = try bs.list()
        #expect(all.count == 2 && all.first { $0.fingerprint == f1 }?.address == "9.9.9.9:7444")
    }
}

/// In-process mutual-TLS server (Ed25519 only, TLS 1.3) to exercise the pin check and the exporter.
@Suite struct TLSLoopbackTests {
    final class ExportHolder: @unchecked Sendable {
        let lock = NIOLockedValueBox<[UInt8]?>(nil)
        let client = NIOLockedValueBox<Fingerprint?>(nil)
    }

    final class ServerExporter: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = NIOAny
        let holder: ExportHolder
        init(_ h: ExportHolder) { holder = h }
        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if case TLSUserEvent.handshakeCompleted = event,
                let handler = try? context.pipeline.syncOperations.handler(type: NIOSSLHandler.self)
            {
                holder.lock.withLockedValue { $0 = try? handler.exportKeyingMaterial(label: Pairing.exporterLabel, length: 32) }
                if let spki = try? handler.peerCertificate?.extractPublicKey().toSPKIBytes() {
                    holder.client.withLockedValue { $0 = Fingerprint(spki: spki) }
                }
            }
            context.fireUserInboundEventTriggered(event)
        }
    }

    func startServer(identity: PierIdentity, holder: ExportHolder, group: EventLoopGroup) async throws -> Channel {
        var cfg = TLSConfiguration.makeServerConfiguration(
            certificateChain: try identity.tlsCredentials().chain, privateKey: try identity.tlsCredentials().key)
        cfg.minimumTLSVersion = .tlsv13
        cfg.certificateVerification = .noHostnameVerification
        cfg.applicationProtocols = ["http/1.1"]
        cfg.verifySignatureAlgorithms = [.ed25519]
        let ctx = try NIOSSLContext(configuration: cfg)
        return try await ServerBootstrap(group: group)
            .childChannelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandler(
                        NIOSSLServerHandler(context: ctx, customVerificationCallback: { _, p in p.succeed(.certificateVerified) }))
                    try ch.pipeline.syncOperations.addHandler(ServerExporter(holder))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
    }

    @Test func exporterMatchesAndPinPasses() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = PierIdentity.generate(), client = PierIdentity.generate()
        let holder = ExportHolder()
        let ch = try await startServer(identity: server, holder: holder, group: group)
        let port = ch.localAddress!.port!
        let dial = try await TLSDial.connect(
            host: "127.0.0.1", port: port, identity: client, pin: server.fingerprint, alpn: ["http/1.1"], group: group
        ) { _ in }
        #expect(dial.negotiatedProtocol == "http/1.1")
        let c = dial.channel
        let clientExp = try await c.eventLoop.submit {
            try c.pipeline.syncOperations.nioSSL_exportKeyingMaterial(label: Pairing.exporterLabel, length: 32)
        }.get()
        #expect(clientExp.count == 32 && clientExp != [UInt8](repeating: 0, count: 32))
        try await Task.sleep(for: .milliseconds(200))
        #expect(holder.lock.withLockedValue { $0 } == clientExp)
        #expect(holder.client.withLockedValue { $0 } == client.fingerprint)
        // different label -> different material
        let other = try await c.eventLoop.submit {
            try c.pipeline.syncOperations.nioSSL_exportKeyingMaterial(label: "other", length: 32)
        }.get()
        #expect(other != clientExp)
        try await c.close()
        try await ch.close()
        try await group.shutdownGracefully()
    }

    @Test func pinMismatchIsHardError() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = PierIdentity.generate(), client = PierIdentity.generate(), wrong = PierIdentity.generate()
        let ch = try await startServer(identity: server, holder: ExportHolder(), group: group)
        let port = ch.localAddress!.port!
        do {
            _ = try await TLSDial.connect(
                host: "127.0.0.1", port: port, identity: client, pin: wrong.fingerprint, alpn: ["http/1.1"], group: group
            ) { _ in }
            Issue.record("expected pin mismatch")
        } catch let PierError.pinMismatch(expected, actual) {
            #expect(expected == wrong.fingerprint.description && actual == server.fingerprint.description)
        }
        try await ch.close()
        try await group.shutdownGracefully()
    }
}
