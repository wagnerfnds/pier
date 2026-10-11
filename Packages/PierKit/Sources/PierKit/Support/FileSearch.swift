import Foundation

/// "Abrir rápido" in a worktree: every file (tracked and untracked, not ignored) listed once through `POST /v1/exec`,
/// then matched as the person types, the way editors' quick open does (the letters in order, the file's own name
/// first). Paths are relative to the worktree's top folder, like the file routes'. Pure apart from the commands.
public enum FileSearch {
    /// The listing is cut here so it fits the 64 KB `exec` keeps (its tail): the parser drops a path cut in two.
    static let maxBytes = 60_000

    public static let command = "\(GitLog.top) && git ls-files -co --exclude-standard -z | head -c \(maxBytes) # pier-files:list"

    /// For a repository too large to list whole: only the files with `query`'s letters in order, any case, anywhere in
    /// the path (a pathspec `*a*b*c*`, which `search` then ranks). Nil when nothing in the query can narrow it.
    public static func command(matching query: String) -> String? {
        // Glob's own characters would be read as glob, so they don't narrow (`search` still weighs them).
        let letters = query.filter { !$0.isWhitespace && !"*?[]\\".contains($0) }
        guard !letters.isEmpty else { return nil }
        let spec = ":(icase)*" + letters.map { "\($0)*" }.joined()
        return "\(GitLog.top) && git ls-files -co --exclude-standard -z -- \(GitActions.q(spec)) | head -c \(maxBytes) # pier-files:match"
    }

    /// The paths of `command`'s output, and whether the list was cut (a very large repository).
    public static func parse(_ output: String) -> (paths: [String], truncated: Bool) {
        var parts = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        let cut = output.utf8.count >= maxBytes
        if cut, !parts.isEmpty { parts.removeLast() }   // a path cut at the byte limit
        let paths = parts.map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }
        var seen = Set<String>()
        return (paths.filter { seen.insert($0).inserted }, cut)
    }

    /// How well `query` matches `path` (higher is better), nil when its letters are not all there in order. Matches in
    /// the file's own name, at the start of words and in a row count most; shorter paths win ties.
    public static func score(_ query: String, _ path: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        let p = Array(path)
        let lower = Array(path.lowercased())
        guard lower.count == p.count else { return nil }   // a case mapping that changes length: no fuzzy positions
        let nameStart = (path.lastIndex(of: "/").map { path.distance(from: path.startIndex, to: $0) + 1 }) ?? 0

        // Prefer a match inside the file name: try it there first, then over the whole path.
        func match(from start: Int) -> [Int]? {
            var at: [Int] = []
            var i = start
            for c in q {
                while i < lower.count, lower[i] != c { i += 1 }
                guard i < lower.count else { return nil }
                at.append(i)
                i += 1
            }
            return at
        }
        guard let positions = match(from: nameStart) ?? match(from: 0) else { return nil }

        var score = 0
        var prev = -2
        for i in positions {
            score += 10
            if i == prev + 1 { score += 15 }
            if i == 0 || i == nameStart || "/-_. ".contains(p[i - 1]) { score += 20 }
            else if p[i].isUppercase && p[i - 1].isLowercase { score += 15 }
            if i >= nameStart { score += 12 }
            prev = i
        }
        let name = String(lower[nameStart...])
        let joined = String(q)
        if name.hasPrefix(joined) { score += 60 }
        if name == joined || (name as NSString).deletingPathExtension == joined { score += 80 }
        return score - p.count / 4
    }

    /// The best `limit` matches, best first (ties by the shorter path, then alphabetically).
    public static func search(_ query: String, in paths: [String], limit: Int = 60) -> [String] {
        let scored = paths.compactMap { p in score(query, p).map { (p, $0) } }
        return scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            if a.0.count != b.0.count { return a.0.count < b.0.count }
            return a.0 < b.0
        }
        .prefix(limit).map(\.0)
    }
}
