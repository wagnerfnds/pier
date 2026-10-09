import SwiftUI
import UIKit

/// Every answer waits a moment before it goes out, with "Desfazer" in a toast at the bottom (Esc / ⌘Z on a keyboard).
/// One place for the whole app: the needs-you card, the composer and the board use it, and so can any other feature.
///
///     let token = PendingActions.shared.schedule(label: S("Permitir"), perform: { await send() }, onUndo: { restore() })
///     PendingActions.shared.undo(token)
///
/// `perform` runs when the window ends, whether or not the screen that scheduled it is still open (the closure keeps what
/// it needs alive); leaving the app sends everything still waiting at once (iOS would suspend the timer). `onUndo` puts
/// the state back (the card returns, the composer gets its text again). With the setting at "Desligado" `perform` runs
/// right away and there is nothing to undo.
@MainActor @Observable
final class PendingActions {
    static let shared = PendingActions()

    struct Token: Hashable, Sendable {
        fileprivate let id: UUID
        /// The same window as `outcome`.
        func matches(_ o: Outcome?) -> Bool { o?.id == id }
    }

    struct Item: Identifiable, Equatable {
        let id: UUID
        /// What is about to be sent ("Permitir", "Mensagem: “roda os testes”").
        let label: String
        let symbol: String
        let start: Date
        let duration: TimeInterval
        var deadline: Date { start.addingTimeInterval(duration) }
    }

    private struct Job {
        let perform: @MainActor () async -> Void
        let onUndo: (@MainActor () -> Void)?
        let timer: Task<Void, Never>
    }

    /// Waiting to go out, oldest first. The toast shows the newest.
    private(set) var items: [Item] = []
    /// How the last window ended: sent, or undone (a view that marked its row can show the receipt, or put it back).
    private(set) var last: Outcome?
    struct Outcome: Equatable { let id: UUID; let sent: Bool }
    @ObservationIgnored private var jobs: [UUID: Job] = [:]

    // MARK: the setting ("Tempo para desfazer")

    /// UserDefaults key, seconds (0 = off). A launch argument (`-undoSeconds 0`) overrides it for a run, as UI tests do.
    static let secondsKey = "undoSeconds"
    static let choices = [0, 2, 5]
    static let defaultSeconds = 2

    static var seconds: Int {
        let d = UserDefaults.standard
        guard d.object(forKey: secondsKey) != nil else { return defaultSeconds }
        return max(0, d.integer(forKey: secondsKey))
    }

    private init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PendingActions.shared.flush() }
        }
    }

    // MARK: API

    /// Runs `perform` after `after` (default: the person's setting), unless undone first.
    @discardableResult
    func schedule(label: String, symbol: String = "paperplane.fill", after: Duration? = nil,
                  perform: @escaping @MainActor () async -> Void, onUndo: (@MainActor () -> Void)? = nil) -> Token {
        let id = UUID()
        let delay = after ?? .seconds(Self.seconds)
        let secs = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        guard secs > 0 else {
            last = Outcome(id: id, sent: true)
            Self.run(perform)
            return Token(id: id)
        }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.fire(id)
        }
        jobs[id] = Job(perform: perform, onUndo: onUndo, timer: timer)
        withAnimation(.snappy(duration: 0.28)) {
            items.append(Item(id: id, label: label, symbol: symbol, start: Date(), duration: secs))
        }
        UIAccessibility.post(notification: .announcement, argument: S("Enviando \(label). Toque em Desfazer para cancelar."))
        return Token(id: id)
    }

    /// Cancels a pending action and puts its state back. False when it already went out (or never waited).
    @discardableResult
    func undo(_ token: Token) -> Bool { undo(id: token.id) }

    /// Undoes the newest pending action (the toast's button, Esc, ⌘Z).
    @discardableResult
    func undoLatest() -> Bool {
        guard let last = items.last else { return false }
        return undo(id: last.id)
    }

    func isPending(_ token: Token?) -> Bool { token.map { jobs[$0.id] != nil } ?? false }

    /// Sends everything still waiting now (the app is leaving the screen).
    func flush() {
        for id in items.map(\.id) { fire(id) }
    }

    // MARK: internals

    private func undo(id: UUID) -> Bool {
        guard let job = jobs.removeValue(forKey: id) else { return false }
        job.timer.cancel()
        withAnimation(.snappy(duration: 0.25)) { items.removeAll { $0.id == id } }
        last = Outcome(id: id, sent: false)
        job.onUndo?()
        Haptic.impact(.light)
        return true
    }

    private func fire(_ id: UUID) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        job.timer.cancel()
        withAnimation(.snappy(duration: 0.25)) { items.removeAll { $0.id == id } }
        last = Outcome(id: id, sent: true)
        Self.run(job.perform)
    }

    /// Runs under a background-task assertion, so a send that started just before the app left still finishes.
    private static func run(_ perform: @escaping @MainActor () async -> Void) {
        let bg = BackgroundAssertion()
        Task { @MainActor in
            await perform()
            bg.end()
        }
    }
}

/// `beginBackgroundTask` / `endBackgroundTask`, ended once (by the work or by the system's expiration).
private final class BackgroundAssertion: @unchecked Sendable {
    private let lock = NSLock()
    private var id: UIBackgroundTaskIdentifier = .invalid

    @MainActor init() {
        let new = UIApplication.shared.beginBackgroundTask(withName: "pier.pending-action") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
        lock.withLock { id = new }
    }

    @MainActor func end() {
        let old = lock.withLock { () -> UIBackgroundTaskIdentifier in
            let v = id; id = .invalid; return v
        }
        if old != .invalid { UIApplication.shared.endBackgroundTask(old) }
    }
}
