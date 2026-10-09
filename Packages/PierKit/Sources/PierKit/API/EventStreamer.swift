import Foundation
import NIOConcurrencyHelpers

/// Where an event stream is, for UIs that show "reconnecting...".
public enum EventConnectionState: Sendable, Equatable {
    case connecting
    /// Response headers arrived (first chunk or keepalive may still be pending).
    case connected
    /// The connection ended or failed; reconnecting after `retryIn`.
    case waiting(retryIn: Duration, error: String?)
}

/// Backoff for reconnecting an events stream: `initial`, doubled up to `max`, with jitter.
public struct EventStreamPolicy: Sendable {
    public var initialBackoff: Duration = .seconds(1)
    public var maxBackoff: Duration = .seconds(30)
    public var factor: Double = 2
    /// Fraction of random spread (+-) applied to every wait.
    public var jitter: Double = 0.2
    public init(initialBackoff: Duration = .seconds(1), maxBackoff: Duration = .seconds(30), factor: Double = 2, jitter: Double = 0.2) {
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
        self.factor = factor
        self.jitter = jitter
    }
    public static let `default` = EventStreamPolicy()

    /// An NDJSON line longer than this (events are small; keepalives are a bare `\n`) is dropped instead of being
    /// buffered until a newline that may never come.
    public static let maxLineBytes = 4 << 20
}

/// Typed `GET /v1/events` stream that survives drops: it reconnects with exponential backoff,
/// resumes from the highest `seq` seen (`?since=`), skips keepalive blank lines and undecodable lines,
/// and ends (throwing) only on errors retrying cannot fix (revoked, pin mismatch, 4xx).
public final class EventStreamer: Sendable {
    private let transport: any PierTransport
    private let policy: EventStreamPolicy
    private let sleep: @Sendable (Duration) async throws -> Void
    private let handles = NIOLockedValueBox<[ObjectIdentifier: Handle]>([:])

    public init(
        transport: any PierTransport,
        policy: EventStreamPolicy = .default,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.transport = transport
        self.policy = policy
        self.sleep = sleep
    }

    /// The reset hook: abandon the current connection or backoff wait of every running stream and reconnect now
    /// (backoff restarts from `initialBackoff`). Call on foreground / network change.
    public func reset() {
        let all = handles.withLockedValue { Array($0.values) }
        for h in all { h.kick() }
    }

    public func events(since: Int64? = nil, onState: (@Sendable (EventConnectionState) -> Void)? = nil) -> AsyncThrowingStream<PierEvent, Error> {
        AsyncThrowingStream { continuation in
            let handle = Handle()
            let key = ObjectIdentifier(handle)
            handles.withLockedValue { $0[key] = handle }
            let main = Task { [self] in
                await self.run(since: since, handle: handle, continuation: continuation, onState: onState)
            }
            continuation.onTermination = { [handles] _ in
                main.cancel()
                handle.cancelCurrent()
                _ = handles.withLockedValue { $0.removeValue(forKey: key) }
            }
        }
    }

    // MARK: internals

    /// Per-stream bookkeeping shared between the loop and `reset()`.
    final class Handle: Sendable {
        private struct State { var current: Task<Void, Never>?; var kicked = false; var lastSeq: Int64?; var progressed = false }
        private let state = NIOLockedValueBox(State())
        func set(_ t: Task<Void, Never>) { state.withLockedValue { $0.current = t } }
        func cancelCurrent() { state.withLockedValue { $0.current?.cancel() } }
        func kick() { state.withLockedValue { $0.kicked = true; $0.current?.cancel() } }
        func consumeKick() -> Bool { state.withLockedValue { let k = $0.kicked; $0.kicked = false; return k } }
        var lastSeq: Int64? {
            get { state.withLockedValue { $0.lastSeq } }
            set { state.withLockedValue { $0.lastSeq = newValue } }
        }
        func markProgress() { state.withLockedValue { $0.progressed = true } }
        func takeProgress() -> Bool { state.withLockedValue { let p = $0.progressed; $0.progressed = false; return p } }
    }

    enum Outcome: Sendable { case ended, failed(Error), fatal(Error) }
    private final class OutcomeBox: Sendable {
        private let v = NIOLockedValueBox<Outcome>(.ended)
        func set(_ o: Outcome) { v.withLockedValue { $0 = o } }
        func get() -> Outcome { v.withLockedValue { $0 } }
    }

    static func isFatal(_ e: Error) -> Bool {
        guard let b = e as? PierError else { return e is DecodingError }
        switch b {
        case .transport, .timeout, .tls, .rateLimited: return false
        case .api(let status, _, _): return !(status >= 500 || status == 408)
        case .unauthorized, .pinMismatch, .protocolViolation, .pairingRejected, .invalidLink, .linkExpired, .decoding, .storage: return true
        }
    }

    private func run(
        since: Int64?, handle: Handle, continuation: AsyncThrowingStream<PierEvent, Error>.Continuation,
        onState: (@Sendable (EventConnectionState) -> Void)?
    ) async {
        handle.lastSeq = since
        var backoff = policy.initialBackoff
        while !Task.isCancelled {
            onState?(.connecting)
            let box = OutcomeBox()
            let path = "/v1/events" + (handle.lastSeq.map { "?since=\($0)" } ?? "")
            let phase = Task { [transport] in
                var buffer = Data()
                let decoder = JSONDecoder.pier
                do {
                    onState?(.connected)
                    for try await chunk in transport.stream(path: path) {
                        handle.markProgress()
                        buffer.append(chunk)
                        if buffer.count > EventStreamPolicy.maxLineBytes, !buffer.contains(0x0a) { buffer.removeAll(keepingCapacity: false) }
                        while let nl = buffer.firstIndex(of: 0x0a) {
                            let line = buffer[buffer.startIndex..<nl]
                            buffer.removeSubrange(buffer.startIndex...nl)
                            guard line.contains(where: { $0 != 0x20 && $0 != 0x0d && $0 != 0x09 }) else { continue }
                            guard let ev = try? decoder.decode(PierEvent.self, from: Data(line)) else { continue }
                            if let s = ev.seq { handle.lastSeq = max(handle.lastSeq ?? s, s) }
                            if case .terminated = continuation.yield(ev) { return }
                        }
                    }
                    box.set(.ended)
                } catch is CancellationError {
                    box.set(.ended)
                } catch {
                    box.set(Self.isFatal(error) ? .fatal(error) : .failed(error))
                }
            }
            handle.set(phase)
            await phase.value
            if Task.isCancelled { break }
            if handle.takeProgress() { backoff = policy.initialBackoff }
            if handle.consumeKick() { backoff = policy.initialBackoff; continue }
            var errorText: String?
            switch box.get() {
            case .fatal(let e):
                continuation.finish(throwing: e)
                return
            case .failed(let e): errorText = (e as? LocalizedError)?.errorDescription ?? "\(e)"
            case .ended: break
            }
            let wait = jittered(backoff)
            onState?(.waiting(retryIn: wait, error: errorText))
            let sleeper = Task<Void, Never> { [sleep] in _ = try? await sleep(wait) }
            handle.set(sleeper)
            await sleeper.value
            if Task.isCancelled { break }
            if handle.consumeKick() { backoff = policy.initialBackoff; continue }
            backoff = min(policy.maxBackoff, backoff * policy.factor)
        }
        continuation.finish()
    }

    private func jittered(_ d: Duration) -> Duration {
        guard policy.jitter > 0 else { return d }
        let spread = Double.random(in: -policy.jitter...policy.jitter)
        return d * (1 + spread)
    }
}
