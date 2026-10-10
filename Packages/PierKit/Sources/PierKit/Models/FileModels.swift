// Codable models of a worktree's files (docs/API.md §2.7): one folder's entries, one file, a save.
import Foundation

/// One entry of a folder listing (`GET /v1/locations/{l}/worktrees/{w}/files?path=`).
public struct FileEntry: Codable, Sendable, Hashable, Identifiable {
    /// What an entry is. Unknown values from newer boxes read as `.other`.
    public enum Kind: String, Codable, Sendable, Hashable {
        case dir, file, link, other

        public init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
        }
    }

    public let name: String
    public let type: Kind
    /// Bytes, for files.
    public let size: Int?
    /// git's two-character porcelain code (`" M"`, `"??"`, …) for a file with changes; nil when clean.
    public let status: String?
    /// A folder with changes somewhere below it.
    public let changed: Bool
    /// Matched by `.gitignore`.
    public let ignored: Bool
    /// A link's own text.
    public let target: String?
    /// What a link leads to, when that is inside the worktree (`.dir` or `.file`); nil for a dangling link or one leading out.
    public let points: Kind?

    public init(name: String, type: Kind, size: Int? = nil, status: String? = nil, changed: Bool = false, ignored: Bool = false,
                target: String? = nil, points: Kind? = nil) {
        self.name = name
        self.type = type
        self.size = size
        self.status = status
        self.changed = changed
        self.ignored = ignored
        self.target = target
        self.points = points
    }

    enum CodingKeys: String, CodingKey { case name, type, size, status, changed, ignored, target, points }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decodeIfPresent(Kind.self, forKey: .type) ?? .other
        size = try c.decodeIfPresent(Int.self, forKey: .size)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        changed = try c.decodeIfPresent(Bool.self, forKey: .changed) ?? false
        ignored = try c.decodeIfPresent(Bool.self, forKey: .ignored) ?? false
        target = try c.decodeIfPresent(String.self, forKey: .target)
        points = try c.decodeIfPresent(Kind.self, forKey: .points)
    }

    public var id: String { name }
    /// A folder, or a link to one inside the worktree: it can be opened as a folder.
    public var isFolder: Bool { type == .dir || (type == .link && points == .dir) }
    /// A file, or a link to one inside the worktree: it can be opened in the editor.
    public var isFile: Bool { type == .file || (type == .link && points == .file) }
}

/// One folder of a worktree (`GET …/files`). `path` is "" for the worktree's root.
public struct DirListing: Codable, Sendable, Hashable {
    public let path: String
    public let entries: [FileEntry]
    /// More than the box lists at once (5000 entries).
    public let truncated: Bool

    public init(path: String, entries: [FileEntry], truncated: Bool = false) {
        self.path = path
        self.entries = entries
        self.truncated = truncated
    }

    enum CodingKeys: String, CodingKey { case path, entries, truncated }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        entries = try c.decodeIfPresent([FileEntry].self, forKey: .entries) ?? []
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

/// One file of a worktree (`GET …/file`), or its new state after a save (`PUT …/file`).
public struct WorktreeFile: Codable, Sendable, Hashable {
    public let path: String
    public let size: Int
    public let modified: Date?
    /// sha256 of the file's bytes (lowercase hex): what a save must name to overwrite this version.
    public let sha: String
    public let executable: Bool
    public let binary: Bool
    /// `"utf8"` (content is the text) or `"base64"` (binary); nil when the content was left out.
    public let encoding: String?
    public let content: String?
    /// Over the box's limit (2 MiB): metadata only.
    public let tooLarge: Bool

    public init(path: String, size: Int = 0, modified: Date? = nil, sha: String = "", executable: Bool = false, binary: Bool = false,
                encoding: String? = nil, content: String? = nil, tooLarge: Bool = false) {
        self.path = path
        self.size = size
        self.modified = modified
        self.sha = sha
        self.executable = executable
        self.binary = binary
        self.encoding = encoding
        self.content = content
        self.tooLarge = tooLarge
    }

    enum CodingKeys: String, CodingKey {
        case path, size, modified, sha, executable, binary, encoding, content
        case tooLarge = "too_large"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        modified = try c.decodeIfPresent(Date.self, forKey: .modified)
        sha = try c.decodeIfPresent(String.self, forKey: .sha) ?? ""
        executable = try c.decodeIfPresent(Bool.self, forKey: .executable) ?? false
        binary = try c.decodeIfPresent(Bool.self, forKey: .binary) ?? false
        encoding = try c.decodeIfPresent(String.self, forKey: .encoding)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        tooLarge = try c.decodeIfPresent(Bool.self, forKey: .tooLarge) ?? false
    }

    /// The text of a text file that came with its content.
    public var text: String? { encoding == "utf8" ? content : nil }

    /// The bytes, whatever the encoding (nil when the content was left out).
    public var data: Data? {
        guard let content else { return nil }
        return encoding == "base64" ? Data(base64Encoded: content) : Data(content.utf8)
    }
}

/// A save (`PUT …/file`). `sha` names the version the edit started from: the box answers 409 `file_changed` when the
/// file moved on since (an agent wrote it). `create` makes a new file (409 `file_exists` if one is there); `force`
/// skips both checks.
public struct FileWrite: Codable, Sendable, Hashable {
    public var content: String
    public var encoding: String
    public var sha: String?
    public var create: Bool?
    public var force: Bool?

    public init(text: String, sha: String?, create: Bool = false, force: Bool = false) {
        self.content = text
        self.encoding = "utf8"
        self.sha = sha
        self.create = create ? true : nil
        self.force = force ? true : nil
    }

    public init(data: Data, sha: String?, create: Bool = false, force: Bool = false) {
        self.content = data.base64EncodedString()
        self.encoding = "base64"
        self.sha = sha
        self.create = create ? true : nil
        self.force = force ? true : nil
    }
}
