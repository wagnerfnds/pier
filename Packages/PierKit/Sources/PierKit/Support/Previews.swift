import Foundation

/// A worktree's preview as the app opens it (docs/API.md §2.12.1): its public page, and the page on the box's own address.
public enum Previews {
    /// The page at its public link, at the preview's path ("https://p-….docktopier.com/login").
    public static func publicURL(_ p: WorktreePreview) -> URL? {
        guard let link = p.share?.url, !link.isEmpty else { return nil }
        return join(link, p.path)
    }

    /// The page on the box as this device reaches it: the preview's own address when it has one, else the box's address
    /// and the preview's port, at its path. Nil for a box reached only through a relay (no address of its own).
    public static func directURL(_ p: WorktreePreview, host: String) -> URL? {
        if let u = p.url, let url = URL(string: u), url.scheme == "http" || url.scheme == "https", url.host != nil { return url }
        guard let port = p.port, let base = Projects.previewURL(host: host, port: port) else { return nil }
        return join(base.absoluteString, p.path)
    }

    static func join(_ base: String, _ path: String?) -> URL? {
        var b = base
        while b.hasSuffix("/") { b.removeLast() }
        guard let path, path.hasPrefix("/"), path != "/" else { return URL(string: b) }
        return URL(string: b + path)
    }
}

/// How the composer offers to prepare a new worktree (docs/API.md §2.4, §2.6.1): only the code, the project's setup
/// script, or a setup agent that works the project out.
public enum PrepareChoice {
    /// What a box offers: nothing where it always prepares (an older pierd), only the code or its script where it has no
    /// setup agents, and the setup agent too where it has.
    public static func modes(canSkip: Bool, canAgent: Bool) -> [PrepareMode] {
        guard canSkip else { return [] }
        return canAgent ? [.none, .script, .agent] : [.none, .script]
    }

    /// The way picked at first: only the code when the person asked for that last time in the project, else the project's
    /// own default (a setup agent where the person allowed them, until it has a recipe).
    public static func initial(projectDefault: PrepareMode?, skippedLastTime: Bool, modes: [PrepareMode]) -> PrepareMode {
        if skippedLastTime, modes.contains(.none) { return .none }
        if let d = projectDefault, d != .none, modes.contains(d) { return d }
        return .script
    }

    /// What the request carries. Only the code is `prepare: false`, which every box with the capability understands. A
    /// way the person picked is named, so the box does what the composer showed; the project's default, left as it was,
    /// is left to the box, which may hand a recipe a setup agent saved that fails to another one (where the person
    /// allowed them). An older box gets nothing new.
    public static func request(_ mode: PrepareMode, picked: Bool, projectDefault: PrepareMode?, canSkip: Bool, canAgent: Bool) -> (prepare: Bool?, prepareWith: PrepareMode?) {
        guard canSkip else { return (nil, nil) }
        if mode == .none { return (false, nil) }
        guard canAgent, picked || mode != projectDefault else { return (nil, nil) }
        return (nil, mode)
    }

    /// Picking a setup agent asks the person first, once per project: an agent that runs commands unattended is only for
    /// code they trust, and until they allowed it there (`Location.setupAgent`) the box never starts one by itself.
    public static func asksConsent(_ mode: PrepareMode, allowed: Bool) -> Bool { mode == .agent && !allowed }
}
