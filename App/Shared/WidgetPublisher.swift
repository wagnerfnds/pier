import Foundation
import WidgetKit

/// Writes the snapshot and asks WidgetKit to reload, at most every few seconds and only when something visible changed.
enum WidgetPublisher {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var lastReload = Date.distantPast
    }
    private static let state = State()

    /// Files are written one after the other, off the main thread: the snapshot's file is read, compared, encoded and
    /// written on every change of any box's sessions.
    private static let writer = DispatchQueue(label: "pier.widget-snapshot", qos: .utility)

    /// `publish` on the writer's queue.
    static func publishInBackground(_ snap: WidgetSnapshot, minInterval: TimeInterval = 20) {
        writer.async { publish(snap, minInterval: minInterval) }
    }

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
