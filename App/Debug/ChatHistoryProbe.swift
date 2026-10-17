#if DEBUG
import SwiftUI

/// Only the synthetic chat lab opts into this counter. It records how many older-page requests happened, never
/// their offsets or contents. `before=0` (a dashboard's tail read) is not a request for earlier history.
enum ChatHistoryDiagnostics {
    static var enabled: Bool {
        UITestMock.enabled && MockChatLab.enabled && UserDefaults.standard.bool(forKey: "uiTestChatLabProbe")
    }
    private static let lock = NSLock()
    private static let logQueue = DispatchQueue(label: "pier.synthetic-scroll-log", qos: .utility)
    nonisolated(unsafe) private static var beforeRequests = 0
    nonisolated(unsafe) private static var logNumber = 0

    static func didRequestHistory() {
        guard enabled else { return }
        let count = lock.withLock { beforeRequests += 1; return beforeRequests }
        emit(["event": "history-request", "count": count])
        Task { @MainActor in
            // Requests can finish on different queues; an older update cannot move the counter backwards.
            ChatHistoryProbeModel.shared.count = max(ChatHistoryProbeModel.shared.count, count)
        }
    }

    /// Passive diagnostics for the opt-in synthetic fixture. Nothing here is observed by the view graph;
    /// the caller reports scheduled decisions, not every layout update. `target` is a role, never a row/session ID.
    static func recordScroll(event: String, sequence: Int, step: Int, action: String, target: String,
                             distanceFromBottom: Double?, contentHeight: Double?, visibleMinY: Double?,
                             visibleMaxY: Double?, viewportHeight: Double?, followsBottom: Bool,
                             isUserInteracting: Bool, isViewportChanging: Bool, itemCount: Int) {
        guard enabled else { return }
        emit([
            "event": event, "sequence": sequence, "step": step, "action": action, "target": target,
            "distanceFromBottom": number(distanceFromBottom), "contentHeight": number(contentHeight),
            "visibleMinY": number(visibleMinY), "visibleMaxY": number(visibleMaxY),
            "viewportHeight": number(viewportHeight), "followsBottom": followsBottom,
            "interacting": isUserInteracting, "resizing": isViewportChanging, "itemCount": itemCount,
        ])
    }

    /// Separates the mock's record/draft handoff from layout failures without changing its UI or event behavior.
    static func recordMockStream(_ phase: String) {
        guard enabled else { return }
        emit(["event": "mock-stream", "phase": phase])
    }

    private static func number(_ value: Double?) -> Any {
        guard let value, value.isFinite else { return NSNull() }
        return (value * 100).rounded() / 100
    }

    private static func emit(_ fields: [String: Any]) {
        var fields = fields
        fields["record"] = lock.withLock { logNumber += 1; return logNumber }
        fields["uptime"] = number(ProcessInfo.processInfo.systemUptime)
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        // NSLog reaches the unified log after a normal Finder/CUA launch, and the XCTest console in CI.
        // Logging happens off the main actor so a diagnostic collector cannot stall a layout transaction.
        logQueue.async { NSLog("CHAT-SCROLL %@", json) }
    }
}

@MainActor @Observable
private final class ChatHistoryProbeModel {
    static let shared = ChatHistoryProbeModel()
    var count = 0
}

/// A one-point accessibility sentinel outside the scroll view. Observing it does not fold or lay out the record.
/// Absent unless the explicit mock-only launch flag is present; never included in a Release build.
@MainActor
struct ChatHistoryProbe: View {
    @State private var model = ChatHistoryProbeModel.shared

    var body: some View {
        if ChatHistoryDiagnostics.enabled {
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier("chat-history-before-count")
                .accessibilityLabel("Synthetic history requests")
                .accessibilityValue(String(model.count))
        }
    }
}
#endif
