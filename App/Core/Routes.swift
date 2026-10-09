import Foundation
import PierKit

// Navigation route values. `box` is always the paired box's name (BoxRecord.name).
// Resolve a client with `AppModel.client(for: box)`; each route is mapped to a view in Destinations.swift.

/// Opens the conversation/terminal of one session.
struct SessionRoute: Hashable {
    let box: String
    let session: Session
}

/// New task / start agent. `location`/`worktree` pre-fill the form (worktree == nil: create a new one).
struct ComposeRoute: Hashable {
    let box: String
    var location: String? = nil
    var worktree: String? = nil
    /// Opens on "Conversa": an agent tied to no project.
    var chat = false
}

/// One project (location) with its worktrees.
struct ProjectRoute: Hashable {
    let box: String
    let location: String
}

struct WorktreeRoute: Hashable {
    let box: String
    let location: String
    let worktree: String
}

/// Changed files / diffs / git actions of a worktree (optionally for a given session).
struct ReviewRoute: Hashable {
    let box: String
    let location: String
    let worktree: String
    var session: String? = nil
}
