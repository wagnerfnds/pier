import Foundation

/// Finds where a session that is no longer listed used to run. Session names are `<worktree dir>-<agent>-<id>`
/// (`sandbox-subtract-claude-6s1`), so the worktree whose directory name is the longest prefix wins.
public enum SessionLookup {
    public static func worktree(forSessionName name: String, in locations: [Location]) -> (location: String, worktree: String)? {
        var best: (len: Int, loc: String, wt: String)?
        for loc in locations {
            for wt in loc.worktrees ?? [] {
                let dir = (wt.path as NSString).lastPathComponent
                guard !dir.isEmpty, name.hasPrefix(dir + "-"), dir.count > (best?.len ?? 0) else { continue }
                best = (dir.count, loc.name, wt.name)
            }
        }
        return best.map { ($0.loc, $0.wt) }
    }
}
