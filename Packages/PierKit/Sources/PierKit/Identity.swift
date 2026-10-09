import Crypto
import Foundation
import NIOSSL
import SwiftASN1
import X509

/// The client's Ed25519 identity: the key *is* the identity; the certificate only carries it into TLS.
public struct PierIdentity: Sendable {
    private let seed: [UInt8]
    public let fingerprint: Fingerprint

    public init(seed: [UInt8]) throws {
        guard seed.count == 32 else { throw PierError.storage("Ed25519 seed must be 32 bytes") }
        self.seed = seed
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        self.fingerprint = Fingerprint(ed25519PublicKey: Array(key.publicKey.rawRepresentation))
    }

    public static func generate() -> PierIdentity {
        // Force-try: a freshly generated key always round-trips.
        try! PierIdentity(seed: Array(Curve25519.Signing.PrivateKey().rawRepresentation))
    }

    // MARK: PKCS#8 / PEM (same on-disk format as pierd's identity.pem)

    private static let pkcs8Prefix: [UInt8] = [0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]

    /// PKCS#8 PEM ("-----BEGIN PRIVATE KEY-----"). Secret: never log.
    public var privateKeyPEM: String {
        let b64 = Data(Self.pkcs8Prefix + seed).base64EncodedString()
        var lines = ["-----BEGIN PRIVATE KEY-----"]
        var i = b64.startIndex
        while i < b64.endIndex {
            let j = b64.index(i, offsetBy: 64, limitedBy: b64.endIndex) ?? b64.endIndex
            lines.append(String(b64[i..<j]))
            i = j
        }
        lines.append("-----END PRIVATE KEY-----")
        return lines.joined(separator: "\n") + "\n"
    }

    public init(pem: String) throws {
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body), der.count == 48,
            Array(der.prefix(16)) == Self.pkcs8Prefix
        else { throw PierError.storage("not an Ed25519 PKCS#8 key") }
        try self.init(seed: Array(der.suffix(32)))
    }

    // MARK: Certificate

    /// Self-signed certificate matching pierd's: CN=pier, now-1h .. now+10y, digitalSignature,
    /// serverAuth+clientAuth, not a CA. The peer never validates any of it; regenerate freely.
    public func makeCertificateDER(now: Date = Date()) throws -> [UInt8] {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let name = try DistinguishedName { CommonName("pier") }
        var serial = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { serial[i] = UInt8.random(in: 0...255) }
        serial[0] &= 0x3f  // < 2^127, positive
        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(bytes: serial[...]),
            publicKey: .init(key.publicKey),
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(10 * 365 * 24 * 3600),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ed25519,
            extensions: try Certificate.Extensions {
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth, .clientAuth])
                Critical(BasicConstraints.notCertificateAuthority)
            },
            issuerPrivateKey: .init(key)
        )
        var serializer = DER.Serializer()
        try serializer.serialize(cert)
        return serializer.serializedBytes
    }

    /// Ready to use in a `TLSConfiguration` (client certificate + key).
    func tlsCredentials() throws -> (chain: [NIOSSLCertificateSource], key: NIOSSLPrivateKeySource) {
        let der = try makeCertificateDER()
        let cert = try NIOSSLCertificate(bytes: der, format: .der)
        let pk = try NIOSSLPrivateKey(bytes: Array(privateKeyPEM.utf8), format: .pem)
        return ([.certificate(cert)], .privateKey(pk))
    }

    /// HMAC-SHA256(code, "pier pair v1" || exporter || fingerprint).
    static func pairingProof(code: [UInt8], exporter: [UInt8], clientFingerprint: Fingerprint) -> [UInt8] {
        var msg = Array("pier pair v1".utf8)
        msg += exporter
        msg += clientFingerprint.bytes
        return Array(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: code)))
    }
}

/// Loads or creates the identity in a ``KeyValueStore`` (stored as PKCS#8 PEM under `identity.pem`).
public enum IdentityStore {
    public static let key = "identity.pem"

    public static func load(from store: KeyValueStore) throws -> PierIdentity? {
        guard let data = try store.read(key) else { return nil }
        return try PierIdentity(pem: String(decoding: data, as: UTF8.self))
    }

    public static func loadOrCreate(in store: KeyValueStore) throws -> PierIdentity {
        if let id = try load(from: store) { return id }
        let id = PierIdentity.generate()
        try store.write(Data(id.privateKeyPEM.utf8), for: key)
        return id
    }
}
