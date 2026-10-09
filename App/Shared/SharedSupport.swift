import Foundation
import PierKit
#if canImport(Security)
import Security
#endif

/// Constants and storage shared by the app and the widget extension (this folder is compiled into both targets).
enum Shared {
    /// The app's bundle id, also from the widget extension (whose own id is `<app id>.widgets`). Every other identifier
    /// derives from it at build time (`PIER_BUNDLE_ID`, Config/Base.xcconfig).
    static let appBundleID: String = {
        let id = Bundle.main.bundleIdentifier ?? "dev.pier.app"
        return id.hasSuffix(".widgets") ? String(id.dropLast(".widgets".count)) : id
    }()
    /// `group.<app id>`, from Info.plist (`PierAppGroup`).
    static let appGroup: String = infoString("PierAppGroup") ?? "group.\(appBundleID)"
    /// The keychain service of the identity and the pairings (`PierKeychainService`, default the bundle id).
    static let keychainService: String = infoString("PierKeychainService") ?? appBundleID

    /// An Info.plist string whose build setting was expanded (nil when missing or left as `$(…)`).
    static func infoString(_ key: String) -> String? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: key) as? String, !s.isEmpty, !s.contains("$(") else { return nil }
        return s
    }

    /// The App Group container (nil only in an unsigned/mis-provisioned build).
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    /// Application Support for the app's own files ("Pier"). The Mac app is not sandboxed, so this is the person's real
    /// ~/Library/Application Support: the Mac uses the bundle id there instead of a generic name.
    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if targetEnvironment(macCatalyst)
        return base.appendingPathComponent(appBundleID, isDirectory: true)
        #else
        return base.appendingPathComponent("Pier", isDirectory: true)
        #endif
    }()

    /// A file inside the App Group container; falls back to Application Support so unsigned builds keep working.
    static func fileURL(_ name: String) -> URL {
        #if targetEnvironment(macCatalyst)
        let base = containerURL ?? supportDirectory
        #else
        let base = containerURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(name)
    }

    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    // MARK: deep links

    static var homeURL: URL { URL(string: "pier://home")! }

    /// `pier://session?box=&name=`.
    static func sessionURL(box: String, name: String) -> URL { link("session", box: box, name: name) }

    /// `pier://review?box=&name=`: the Review screen of the session's worktree (the Live Activity's "Revisar"); the app
    /// falls back to the session itself when it has no worktree.
    static func reviewURL(box: String, name: String) -> URL { link("review", box: box, name: name) }

    private static func link(_ host: String, box: String, name: String) -> URL {
        var c = URLComponents()
        c.scheme = "pier"
        c.host = host
        c.queryItems = [URLQueryItem(name: "box", value: box), URLQueryItem(name: "name", value: name)]
        return c.url ?? homeURL
    }

    // MARK: JSON

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}

/// The keychain shared by the app and the extension (access group `<TeamID>.<app id>.shared`).
enum SharedKeychain {
    /// Resolved from Info.plist (`$(AppIdentifierPrefix)` is expanded at build time); nil when it is not a usable group.
    static var accessGroup: String? {
        guard let g = Bundle.main.object(forInfoDictionaryKey: "PierKeychainGroup") as? String,
              !g.contains("$("), !g.hasPrefix("."), g.hasSuffix(".shared") else { return nil }
        return g
    }

    static func store() -> any KeyValueStore {
        #if DEBUG && targetEnvironment(macCatalyst)
        if let dir = unsignedMacStore { return FileStore(directory: dir) }
        #endif
        return KeychainStore(service: Shared.keychainService, accessGroup: accessGroup)
    }

    #if DEBUG && targetEnvironment(macCatalyst)
    /// A Debug Mac build run without its entitlements (`CODE_SIGNING_ALLOWED=NO`: no provisioning profile for the Mac yet)
    /// gets -34018 from every keychain call. It keeps the identity and pairings in 0600 files instead, like pierctl, so
    /// pairing can be tried before the Mac is provisioned. Signed and Release builds always use the keychain.
    private static let unsignedMacStore: URL? = {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Shared.keychainService + ".probe",
                                kSecMatchLimit as String: kSecMatchLimitOne]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        guard SecItemCopyMatching(q as CFDictionary, nil) == errSecMissingEntitlement else { return nil }
        return Shared.supportDirectory.appendingPathComponent("unsigned-dev-keys", isDirectory: true)
    }()
    #endif

    /// One-time move of the identity and paired boxes from the old (app-only) keychain group into the shared one, so an
    /// already-paired phone keeps its pairing. The old group is the app's default (`<TeamID>.<app id>`),
    /// which an unqualified query still reaches. Safe to call on every launch.
    static func migrateLegacyIfNeeded() {
        guard let group = accessGroup else { return }
        let flag = "keychain.migratedToShared.v1"
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: flag) else { return }
        let shared = KeychainStore(service: Shared.keychainService, accessGroup: group)
        // Old items live in the app's own group (the default before the entitlement existed).
        let legacy = KeychainStore(service: Shared.keychainService, accessGroup: legacyGroup(from: group))
        var ok = true
        for key in [IdentityStore.key, BoxStore.key] {
            do {
                if try shared.read(key) != nil { continue }          // already there (a fresh pair, or a previous partial run)
                guard let data = try legacy.read(key) else { continue }
                try shared.write(data, for: key)
                guard try shared.read(key) == data else { ok = false; continue }
                // Remove only the legacy copy (explicit app-id group) once the shared one is verified.
                try? legacy.remove(key)
            } catch { ok = false }
        }
        if ok { ud.set(true, forKey: flag) }
    }

    /// `<Team>.<app id>.shared` -> `<Team>.<app id>`
    static func legacyGroup(from shared: String) -> String? {
        guard shared.hasSuffix(".shared") else { return nil }
        return String(shared.dropLast(".shared".count))
    }

    #if DEBUG
    /// `-testKeychainMigration 1`: moves the current items back to the legacy group, runs the migration, logs the outcome.
    static func debugSelfTest() {
        guard let group = accessGroup, let legacyID = legacyGroup(from: group) else { NSLog("MIGRATION-TEST no group"); return }
        let shared = KeychainStore(service: Shared.keychainService, accessGroup: group), legacy = KeychainStore(service: Shared.keychainService, accessGroup: legacyID)
        var before: [String: Data] = [:]
        for k in [IdentityStore.key, BoxStore.key] {
            guard let d = try? shared.read(k) else { NSLog("MIGRATION-TEST missing %@", k); return }
            before[k] = d
            try? legacy.write(d, for: k); try? shared.remove(k)
        }
        UserDefaults.standard.removeObject(forKey: "keychain.migratedToShared.v1")
        migrateLegacyIfNeeded()
        for (k, d) in before {
            let ok = ((try? shared.read(k)) ?? nil) == d
            let gone = ((try? legacy.read(k)) ?? nil) == nil
            NSLog("MIGRATION-TEST %@ migrated=%d legacyRemoved=%d", k, ok ? 1 : 0, gone ? 1 : 0)
        }
    }
    #endif
}

/// Phone-side display preferences the extension needs (renames and hidden projects), mirrored from `LocalPrefs`.
struct SharedDisplayPrefs: Codable, Sendable {
    var renames: [String: String] = [:]
    var hidden: Set<String> = []

    private static var url: URL { Shared.fileURL("display-prefs.json") }

    static func load() -> SharedDisplayPrefs {
        guard let d = try? Data(contentsOf: url), let p = try? Shared.decoder().decode(SharedDisplayPrefs.self, from: d) else { return SharedDisplayPrefs() }
        return p
    }
    func save() {
        if let d = try? Shared.encoder().encode(self) { try? d.write(to: Self.url, options: .atomic) }
    }
    func displayName(box: String, location: String) -> String { renames["\(box)/\(location)"] ?? location }
    func isHidden(box: String, location: String) -> Bool { hidden.contains("\(box)/\(location)") }
}
