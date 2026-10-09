import Foundation
#if canImport(Security)
import Security
#endif

/// Minimal secret/blob storage. Implementations: ``KeychainStore`` (iOS/macOS), ``FileStore`` (CLI).
public protocol KeyValueStore: Sendable {
    func read(_ key: String) throws -> Data?
    func write(_ data: Data, for key: String) throws
    func remove(_ key: String) throws
}

/// Files under a directory (0700), each file 0600. Used by `pierctl` (~/.config/pierctl).
public struct FileStore: KeyValueStore {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    private func url(_ key: String) throws -> URL {
        guard !key.contains("/"), !key.hasPrefix(".") else { throw PierError.storage("bad key") }
        return directory.appendingPathComponent(key)
    }

    public func read(_ key: String) throws -> Data? {
        let u = try url(key)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return try Data(contentsOf: u)
    }

    public func write(_ data: Data, for key: String) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let u = try url(key)
        try data.write(to: u, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
    }

    public func remove(_ key: String) throws {
        let u = try url(key)
        if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
    }
}

#if canImport(Security)
/// Generic-password Keychain items, `AfterFirstUnlockThisDeviceOnly` so background refresh works.
public struct KeychainStore: KeyValueStore {
    public let service: String
    public let accessGroup: String?
    public init(service: String, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func query(_ key: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func read(_ key: String) throws -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return nil }
        guard st == errSecSuccess, let d = out as? Data else { throw PierError.storage("keychain read failed (\(st))") }
        return d
    }

    public func write(_ data: Data, for key: String) throws {
        let update = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw PierError.storage("keychain update failed (\(update))") }
        var q = query(key)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let st = SecItemAdd(q as CFDictionary, nil)
        guard st == errSecSuccess else { throw PierError.storage("keychain add failed (\(st))") }
    }

    public func remove(_ key: String) throws {
        let st = SecItemDelete(query(key) as CFDictionary)
        guard st == errSecSuccess || st == errSecItemNotFound else { throw PierError.storage("keychain delete failed (\(st))") }
    }
}
#endif

/// In-memory store (tests, previews).
public final class MemoryStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    public init() {}
    public func read(_ key: String) throws -> Data? { lock.withLock { items[key] } }
    public func write(_ data: Data, for key: String) throws { lock.withLock { items[key] = data } }
    public func remove(_ key: String) throws { lock.withLock { items[key] = nil } }
}
