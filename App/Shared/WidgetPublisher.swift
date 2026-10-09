import Foundation
import WidgetKit

/// Writes the snapshot and asks WidgetKit to reload, at most every few seconds and only when something visible changed.
enum WidgetPublisher {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var lastReload = Date.distantPast
    }
    private static let state = State()

    static func publish(_ snap: WidgetSnapshot, minInterval: TimeInterval = 20) {
        let changed = SnapshotStore.write(snap)
        guard changed else { return }
        state.lock.lock()
        let due = Date().timeIntervalSince(state.lastReload) >= minInterval
        if due { state.lastReload = Date() }
        state.lock.unlock()
        if due { WidgetCenter.shared.reloadAllTimelines() }
    }
}
