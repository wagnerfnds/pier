import Foundation

/// The rules of a worktree's file tree: paths (always relative to the worktree, `/`-separated, "" for its root), the
/// rows an outline shows for the folders that are open, and the badge a file's git status earns.
public enum FileTree {
    public static func join(_ dir: String, _ name: String) -> String { dir.isEmpty ? name : dir + "/" + name }

    /// "a/b/c.txt" → "a/b"; a top-level path → "".
    public static func parent(of path: String) -> String {
        guard let i = path.lastIndex(of: "/") else { return "" }
        return String(path[..<i])
    }

    /// "a/b/c.txt" → "c.txt".
    public static func name(of path: String) -> String {
        guard let i = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: i)...])
    }

    /// The folders that must be open for `path` to show: "a/b/c.txt" → ["a", "a/b"].
    public static func ancestors(of path: String) -> [String] {
        var out: [String] = []
        var cur = parent(of: path)
        while !cur.isEmpty {
            out.insert(cur, at: 0)
            cur = parent(of: cur)
        }
        return out
    }

    public struct Row: Sendable, Hashable, Identifiable {
        public let path: String
        /// 0 for the root's entries.
        public let depth: Int
        public let entry: FileEntry
        public var id: String { path }
    }

    /// The outline's rows: the root's entries, and under every open folder its own entries (as far as they are loaded),
    /// depth first. `hideIgnored` leaves out what `.gitignore` matches.
    public static func rows(listings: [String: [FileEntry]], open: Set<String>, hideIgnored: Bool = false) -> [Row] {
        var out: [Row] = []
        func walk(_ dir: String, _ depth: Int) {
            for e in listings[dir] ?? [] where !(hideIgnored && e.ignored) {
                let p = join(dir, e.name)
                out.append(Row(path: p, depth: depth, entry: e))
                if e.isFolder, open.contains(p) { walk(p, depth + 1) }
            }
        }
        walk("", 0)
        return out
    }

    /// What a status shows in the tree and the tabs: a letter and a tone.
    public enum Badge: String, Sendable, Hashable {
        case modified = "M", added = "A", untracked = "U", deleted = "D", renamed = "R", conflict = "!"
    }

    /// The badge for git's porcelain XY code (nil when clean or unknown).
    public static func badge(_ status: String?) -> Badge? {
        guard let s = status, s.count == 2 else { return nil }
        if s == "??" { return .untracked }
        if s == "!!" { return nil }
        if s.contains("U") || s == "AA" || s == "DD" { return .conflict }
        let x = s.first!, y = s.last!
        // A file new to git (or moved) stays that even once edited again; otherwise the work tree's side says more
        // about the file on disk than the index's.
        if x == "A" { return .added }
        if x == "R" || x == "C" { return .renamed }
        for c in [y, x] where c != " " {
            switch c {
            case "M", "T": return .modified
            case "A": return .added
            case "D": return .deleted
            case "R", "C": return .renamed
            default: continue
            }
        }
        return nil
    }
}
