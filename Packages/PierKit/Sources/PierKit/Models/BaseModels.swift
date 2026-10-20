import Foundation

/// A project's base (`GET /v1/locations/{loc}/base`, capability `base`, docs/API.md §2.15): what every new worktree of it
/// gets that git does not bring, configured once. Files the box keeps for the project (`.env`, `auth.json`, keys) go into
/// each checkout; ignored folders of the main checkout (`vendor`, `node_modules`) are copied into each new worktree before
/// its recipe runs. Each part says whose it is: the box's own, or the team's on a machine several people share. It never
/// holds a file's content.
public struct ProjectBase: Codable, Sendable, Hashable {
    public let key: String
    public let files: [BaseFile]
    public let carry: [BaseCarry]
    /// The team's base for the project on this machine, when there is one.
    public let team: BaseTeam?
    /// What prepares each worktree by script, and whose it is.
    public let recipe: BaseRecipe?
    /// "reflink" (a copy shares the main checkout's blocks on this disk: seconds) or "copy"; nil with nothing to carry.
    public let copy: String?
    public let warnings: [String]

    public init(key: String, files: [BaseFile] = [], carry: [BaseCarry] = [], team: BaseTeam? = nil, recipe: BaseRecipe? = nil,
                copy: String? = nil, warnings: [String] = []) {
        self.key = key; self.files = files; self.carry = carry; self.team = team; self.recipe = recipe; self.copy = copy
        self.warnings = warnings
    }

    enum CodingKeys: String, CodingKey { case key, files, carry, team, recipe, copy, warnings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        files = (try? c.decodeIfPresent([BaseFile].self, forKey: .files)) ?? []
        carry = (try? c.decodeIfPresent([BaseCarry].self, forKey: .carry)) ?? []
        team = try? c.decodeIfPresent(BaseTeam.self, forKey: .team)
        recipe = try? c.decodeIfPresent(BaseRecipe.self, forKey: .recipe)
        copy = try c.decodeIfPresent(String.self, forKey: .copy).flatMap { $0.isEmpty ? nil : $0 }
        warnings = (try? c.decodeIfPresent([String].self, forKey: .warnings)) ?? []
    }

    /// Nothing configured: no files, no folders, no team, no recipe.
    public var isEmpty: Bool { files.isEmpty && carry.isEmpty && team == nil && recipe == nil }
    /// Copies of the carried folders share the main checkout's blocks.
    public var copiesShareBlocks: Bool { copy == "reflink" }
}

/// One file of a project's base.
public struct BaseFile: Codable, Sendable, Hashable, Identifiable {
    /// Where it goes in each checkout.
    public let path: String
    /// "env": a dotenv file, merged key by key; "file": the whole file.
    public let kind: String
    public let size: Int64
    /// The start of its content's hash, to tell versions apart.
    public let sha: String
    /// A dotenv file's keys, never their values.
    public let keys: [String]
    /// "team" or "box".
    public let from: String
    public let added: Date?

    public var id: String { path }
    public var isEnv: Bool { kind == "env" }
    public var isTeams: Bool { from == "team" }

    public init(path: String, kind: String = "file", size: Int64 = 0, sha: String = "", keys: [String] = [], from: String = "box",
                added: Date? = nil) {
        self.path = path; self.kind = kind; self.size = size; self.sha = sha; self.keys = keys; self.from = from; self.added = added
    }

    enum CodingKeys: String, CodingKey { case path, kind, size, sha, keys, from, added }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "file"
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        sha = try c.decodeIfPresent(String.self, forKey: .sha) ?? ""
        keys = (try? c.decodeIfPresent([String].self, forKey: .keys)) ?? []
        from = try c.decodeIfPresent(String.self, forKey: .from) ?? "box"
        added = try c.decodeIfPresent(Date.self, forKey: .added)
    }
}

/// A folder (or file) the project's new worktrees take from the main checkout.
public struct BaseCarry: Codable, Sendable, Hashable, Identifiable {
    public let path: String
    /// Whose config names it: "repo", "team", "box", or "worktreeinclude" (the repository's `.worktreeinclude`).
    public let from: String
    /// The main checkout has it (an install made it there).
    public let inMain: Bool

    public var id: String { path }

    public init(path: String, from: String = "box", inMain: Bool = true) {
        self.path = path; self.from = from; self.inMain = inMain
    }

    enum CodingKeys: String, CodingKey { case path, from, inMain = "in_main" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        from = try c.decodeIfPresent(String.self, forKey: .from) ?? "box"
        inMain = try c.decodeIfPresent(Bool.self, forKey: .inMain) ?? false
    }
}

/// The team's base for a project, as the box last copied it.
public struct BaseTeam: Codable, Sendable, Hashable {
    /// The team's folder for the project on the machine.
    public let dir: String
    /// When root published it last.
    public let published: Date?
    /// Why the team's folder could not be read; the last copy taken still applies.
    public let error: String?

    public init(dir: String, published: Date? = nil, error: String? = nil) {
        self.dir = dir; self.published = published; self.error = error
    }

    enum CodingKeys: String, CodingKey { case dir, published, error }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dir = try c.decodeIfPresent(String.self, forKey: .dir) ?? ""
        published = try c.decodeIfPresent(Date.self, forKey: .published)
        error = try c.decodeIfPresent(String.self, forKey: .error).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// What prepares each worktree by script.
public struct BaseRecipe: Codable, Sendable, Hashable {
    public let setup: String?
    /// The services that start on their own after it.
    public let services: [String]
    /// "repo", "team" or "box".
    public let from: String?
    /// "setup" when a setup agent saved it.
    public let by: String?

    public init(setup: String? = nil, services: [String] = [], from: String? = nil, by: String? = nil) {
        self.setup = setup; self.services = services; self.from = from; self.by = by
    }

    enum CodingKeys: String, CodingKey { case setup, services, from, by }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        setup = try c.decodeIfPresent(String.self, forKey: .setup).flatMap { $0.isEmpty ? nil : $0 }
        services = (try? c.decodeIfPresent([String].self, forKey: .services)) ?? []
        from = try c.decodeIfPresent(String.self, forKey: .from)
        by = try c.decodeIfPresent(String.self, forKey: .by)
    }
}

/// How the project's base went into a worktree, kept with its preparation (`PrepareStatus.base`).
public struct PrepareBase: Codable, Sendable, Hashable {
    public let files: [BaseResult]
    /// The folders copied from the main checkout.
    public let carried: [BaseResult]

    public init(files: [BaseResult] = [], carried: [BaseResult] = []) {
        self.files = files; self.carried = carried
    }

    enum CodingKeys: String, CodingKey { case files, carried }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        files = (try? c.decodeIfPresent([BaseResult].self, forKey: .files)) ?? []
        carried = (try? c.decodeIfPresent([BaseResult].self, forKey: .carried)) ?? []
    }

    public var isEmpty: Bool { files.isEmpty && carried.isEmpty }
    /// The base files the worktree has (written now, already the base's, or changed there).
    public var filesInPlace: [BaseResult] { files.filter { $0.isInPlace } }
    /// The folders that went in, and how long the slowest took.
    public var carriedInPlace: [BaseResult] { carried.filter { $0.action == "carried" } }
    public var carriedMS: Int { carriedInPlace.map { $0.ms ?? 0 }.reduce(0, +) }
    /// What did not go in, with why.
    public var problems: [BaseResult] { (files + carried).filter { $0.action == "failed" } }
}

/// What applying the base did with one path.
public struct BaseResult: Codable, Sendable, Hashable, Identifiable {
    public let path: String
    /// "written", "updated", "unchanged", "kept" (someone changed it there), "carried", "skipped" or "failed".
    public let action: String
    public let reason: String?
    /// The dotenv keys someone changed in the checkout, kept as they are.
    public let keys: [String]
    public let ms: Int?

    public var id: String { path }
    public var isInPlace: Bool { ["written", "updated", "unchanged", "kept"].contains(action) }

    public init(path: String, action: String, reason: String? = nil, keys: [String] = [], ms: Int? = nil) {
        self.path = path; self.action = action; self.reason = reason; self.keys = keys; self.ms = ms
    }

    enum CodingKeys: String, CodingKey { case path, action, reason, keys, ms }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason).flatMap { $0.isEmpty ? nil : $0 }
        keys = (try? c.decodeIfPresent([String].self, forKey: .keys)) ?? []
        ms = try c.decodeIfPresent(Int.self, forKey: .ms)
    }
}
