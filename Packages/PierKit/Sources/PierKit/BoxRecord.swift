import Foundation

/// A paired box: its name, address and pinned key fingerprint.
public struct BoxRecord: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    /// "HOST:PORT" (IPv6 hosts bracketed).
    public var address: String
    public var fingerprint: Fingerprint
    public var pairedAt: Date

    public var id: String { fingerprint.description }

    public init(name: String, address: String, fingerprint: Fingerprint, pairedAt: Date = Date()) {
        self.name = name
        self.address = address
        self.fingerprint = fingerprint
        self.pairedAt = pairedAt
    }

    enum CodingKeys: String, CodingKey {
        case name, address, fingerprint
        case pairedAt = "paired_at"
    }
}

/// Persists paired boxes as a JSON array under `boxes.json` in a ``KeyValueStore``.
public struct BoxStore: Sendable {
    public static let key = "boxes.json"
    private let store: KeyValueStore
    public init(store: KeyValueStore) { self.store = store }

    private static func isoString(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    public func list() throws -> [BoxRecord] {
        guard let data = try store.read(Self.key) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            if let date = PierJSON.parseDate(s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "bad date"))
        }
        return try dec.decode([BoxRecord].self, from: data)
    }

    private func save(_ boxes: [BoxRecord]) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .custom { date, e in
            var c = e.singleValueContainer()
            try c.encode(Self.isoString(date))
        }
        try store.write(try enc.encode(boxes), for: Self.key)
    }

    /// Adds a box. Re-pairing the same key replaces its entry; a taken name gets a `-2`, `-3` suffix.
    @discardableResult
    public func add(_ box: BoxRecord) throws -> BoxRecord {
        var boxes = try list().filter { $0.fingerprint != box.fingerprint }
        var rec = box
        var n = 1
        while boxes.contains(where: { $0.name == rec.name }) {
            n += 1
            rec.name = "\(box.name)-\(n)"
        }
        boxes.append(rec)
        try save(boxes)
        return rec
    }

    public func remove(fingerprint: Fingerprint) throws {
        try save(try list().filter { $0.fingerprint != fingerprint })
    }
}
