import Foundation

/// What the agent's last turn changed, read from the transcript's edit items (no network).
public struct TurnChanges: Equatable, Sendable {
    public var files: Int
    public var added: Int
    public var removed: Int

    public init(files: Int, added: Int, removed: Int) { (self.files, self.added, self.removed) = (files, added, removed) }

    /// The edits after the last prompt (a `user`, `command` or `report` item starts a turn). nil when there are none.
    public static func lastTurn(_ items: [TranscriptItem]) -> TurnChanges? {
        var start = 0
        for (i, it) in items.enumerated() {
            switch it.type {
            case .user, .command, .report: start = i + 1
            default: break
            }
        }
        var seen = Set<String>()
        var added = 0, removed = 0
        for it in items[start...] where it.type == .edit {
            seen.insert(it.file ?? it.id)
            added += it.added ?? 0
            removed += it.removed ?? 0
        }
        return seen.isEmpty ? nil : TurnChanges(files: seen.count, added: added, removed: removed)
    }

    /// A worktree's uncommitted state from a review item (`GET /v1/review`).
    public static func uncommitted(_ item: ReviewItem) -> TurnChanges? {
        item.files.isEmpty ? nil : TurnChanges(files: item.files.count, added: item.added, removed: item.removed)
    }
}
