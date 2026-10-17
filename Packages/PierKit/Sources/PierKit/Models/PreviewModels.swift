import Foundation

/// A worktree's preview (`GET`/`PUT …/worktrees/{wt}/preview`, capability `preview`, docs/API.md §2.12.1): the page a
/// person opens to see the worktree, recorded by whoever got it running (a setup agent, a task agent: `pierd preview
/// set`), with a test login of the app and its public link. An empty object means nothing was recorded.
public struct WorktreePreview: Codable, Sendable, Hashable {
    /// Where the page answers on the box: one of the worktree's ports.
    public var port: Int?
    /// The page to open first ("/login").
    public var path: String?
    /// The page's own address, when it is not the box's port.
    public var url: String?
    /// A test login of the app (a demo user its setup made), not anyone's account.
    public var login: PreviewLogin?
    public var note: String?
    /// When it was last recorded (answers only).
    public var updated: Date?
    /// Its public link (answers only): the one the box made for it by itself, or another of the worktree's to its port.
    public var share: PreviewShare?

    public init(port: Int? = nil, path: String? = nil, url: String? = nil, login: PreviewLogin? = nil, note: String? = nil,
                updated: Date? = nil, share: PreviewShare? = nil) {
        self.port = port; self.path = path; self.url = url; self.login = login; self.note = note; self.updated = updated; self.share = share
    }

    enum CodingKeys: String, CodingKey { case port, path, url, login, note, updated, share }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = try c.decodeIfPresent(Int.self, forKey: .port).flatMap { $0 > 0 ? $0 : nil }
        path = try c.decodeIfPresent(String.self, forKey: .path).flatMap { $0.isEmpty ? nil : $0 }
        url = try c.decodeIfPresent(String.self, forKey: .url).flatMap { $0.isEmpty ? nil : $0 }
        login = try? c.decodeIfPresent(PreviewLogin.self, forKey: .login)
        note = try c.decodeIfPresent(String.self, forKey: .note).flatMap { $0.isEmpty ? nil : $0 }
        updated = try c.decodeIfPresent(Date.self, forKey: .updated)
        share = try? c.decodeIfPresent(PreviewShare.self, forKey: .share)
    }

    /// What `PUT` sends: what was recorded, never the box's own answers (`updated`, `share`).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(port, forKey: .port)
        try c.encodeIfPresent(path, forKey: .path)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(login, forKey: .login)
        try c.encodeIfPresent(note, forKey: .note)
    }

    /// Nothing recorded.
    public var isEmpty: Bool { port == nil && path == nil && url == nil && login == nil && note == nil }
}

/// A test login of a worktree's web app.
public struct PreviewLogin: Codable, Sendable, Hashable {
    public var user: String
    public var password: String?
    public var note: String?

    public init(user: String, password: String? = nil, note: String? = nil) {
        self.user = user; self.password = password; self.note = note
    }

    enum CodingKeys: String, CodingKey { case user, password, note }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        password = try c.decodeIfPresent(String.self, forKey: .password).flatMap { $0.isEmpty ? nil : $0 }
        note = try c.decodeIfPresent(String.self, forKey: .note).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// A preview's public link (`https://p-….docktopier.com`).
public struct PreviewShare: Codable, Sendable, Hashable {
    public let name: String
    public let url: String
    public let expires: Date?
    /// The link the box made for the preview itself, renewed while the worktree is there.
    public let auto: Bool

    public init(name: String, url: String, expires: Date? = nil, auto: Bool = false) {
        self.name = name; self.url = url; self.expires = expires; self.auto = auto
    }

    enum CodingKeys: String, CodingKey { case name, url, expires, auto }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        url = try c.decode(String.self, forKey: .url)
        expires = try c.decodeIfPresent(Date.self, forKey: .expires)
        auto = try c.decodeIfPresent(Bool.self, forKey: .auto) ?? false
    }
}
