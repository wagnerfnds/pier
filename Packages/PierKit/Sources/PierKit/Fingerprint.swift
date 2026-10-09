import Crypto
import Foundation

/// SHA-256 of a key's SubjectPublicKeyInfo DER. Text form: lowercase base32, no padding (52 chars).
/// Identical to pierd's `identity.Fingerprint`.
public struct Fingerprint: Hashable, Sendable, Codable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == 32 else { return nil }
        self.bytes = bytes
    }

    public init?(string: String) {
        guard let b = Base32.decode(string.trimmingCharacters(in: .whitespacesAndNewlines)), b.count == 32 else { return nil }
        self.bytes = b
    }

    /// Fingerprint of an arbitrary DER SubjectPublicKeyInfo.
    public init(spki: some Sequence<UInt8>) {
        self.bytes = Array(SHA256.hash(data: Array(spki)))
    }

    /// Fingerprint of an Ed25519 public key (fixed 12 byte SPKI prefix + raw key).
    public init(ed25519PublicKey raw: [UInt8]) {
        self.init(spki: Fingerprint.ed25519SPKIPrefix + raw)
    }

    static let ed25519SPKIPrefix: [UInt8] = [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00]

    public var description: String { Base32.encode(bytes) }
    /// First 12 characters, for display.
    public var short: String { String(description.prefix(12)) }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let f = Fingerprint(string: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "malformed fingerprint"))
        }
        self = f
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}
