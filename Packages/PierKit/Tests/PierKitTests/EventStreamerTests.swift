import Foundation
import NIOConcurrencyHelpers
import Testing

@testable import PierKit

/// Records the waits the streamer asks for and returns at once (no real sleeping).
final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _waits: [Duration] = []
    var waits: [Duration] { lock.withLock { _waits } }
    func sleep(_ d: Duration) async throws {
        lock.withLock { _waits.append(d) }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private let noJitter = EventStreamPolicy(initialBackoff: .seconds(1), maxBackoff: .seconds(8), factor: 2, jitter: 0)

private func collect(_ stream: AsyncThrowingStream<PierEvent, Error>, count: Int) async throws -> [PierEvent] {
    var out: [PierEvent] = []
    for try await e in stream {
        out.append(e)
        if out.count == count { break }
    }
    return out
}

@Suite struct EventStreamerTests {
    @Test func parsesChunkedNDJSONAndSkipsKeepalives() async throws {
        let whole = line(1) + Data("\n".utf8) + line(2, "agent.waiting") + Data("  \n".utf8)
        // split in the middle of a line and a multi-byte char
        let a = whole.prefix(30), b = whole.dropFirst(30)
        let t = MockTransport(connections: [.init(chunks: [Data(a), Data(b), Data("garbage\n".utf8), line(3)], end: .hang)])
        let s = EventStreamer(transport: t, policy: noJitter)
        let events = try await collect(s.events(since: nil), count: 3)
        #expect(events.map(\.seq) == [1, 2, 3])
        #expect(events[1].type == "agent.waiting")
        #expect(t.streamPaths == ["/v1/events"])
    }

    @Test func reconnectsResumingFromMaxSeqWithBackoff() async throws {
        let t = MockTransport(connections: [
            .init(chunks: [line(5), line(7), line(6)], end: .fail(PierError.transport("reset by peer"))),
            .init(chunks: [], end: .fail(PierError.transport("refused"))),
            .init(chunks: [], end: .fail(PierError.timeout)),
            .init(chunks: [line(8)], end: .finish),
            .init(chunks: [line(9)], end: .hang),
        ])
        let log = SleepLog()
        let s = EventStreamer(transport: t, policy: noJitter, sleep: log.sleep)
        let events = try await collect(s.events(since: 4), count: 5)
        #expect(events.map(\.seq) == [5, 7, 6, 8, 9])
        #expect(t.streamPaths == ["/v1/events?since=4", "/v1/events?since=7", "/v1/events?since=7", "/v1/events?since=7", "/v1/events?since=8"])
        // after data: 1s; two failures without data: 2s, 4s; data again resets to 1s
        #expect(log.waits == [.seconds(1), .seconds(2), .seconds(4), .seconds(1)])
    }

    @Test func backoffIsCapped() async throws {
        let fails = (0..<6).map { _ in MockTransport.Connection(chunks: [], end: .fail(PierError.transport("down"))) }
        let t = MockTransport(connections: fails + [.init(chunks: [line(1)], end: .hang)])
        let log = SleepLog()
        let s = EventStreamer(transport: t, policy: noJitter, sleep: log.sleep)
        _ = try await collect(s.events(since: nil), count: 1)
        #expect(log.waits == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(8), .seconds(8)])
    }

    @Test func jitterStaysWithinBounds() async throws {
        let t = MockTransport(connections: (0..<5).map { _ in .init(chunks: [], end: .fail(PierError.transport("x"))) } + [.init(chunks: [line(1)], end: .hang)])
        let log = SleepLog()
        let s = EventStreamer(transport: t, policy: EventStreamPolicy(initialBackoff: .seconds(1), maxBackoff: .seconds(1), factor: 1, jitter: 0.2), sleep: log.sleep)
        _ = try await collect(s.events(since: nil), count: 1)
        #expect(log.waits.count == 5)
        for w in log.waits { #expect(w >= .milliseconds(799) && w <= .milliseconds(1201)) }
    }

    @Test func revokedEndsTheStream() async {
        let t = MockTransport(connections: [.init(chunks: [line(1)], end: .fail(PierError.unauthorized))])
        let s = EventStreamer(transport: t, policy: noJitter, sleep: SleepLog().sleep)
        var got: [Int64?] = []
        var thrown: Error?
        do { for try await e in s.events(since: nil) { got.append(e.seq) } } catch { thrown = error }
        #expect(got == [1])
        guard case PierError.unauthorized? = thrown else {
            Issue.record("expected unauthorized, got \(String(describing: thrown))")
            return
        }
        #expect(t.streamPaths.count == 1)
    }

    @Test func clientErrorsAreFatalButServerErrorsRetry() async throws {
        let t = MockTransport(connections: [
            .init(chunks: [], end: .fail(PierError.api(status: 503, message: "busy", code: nil))),
            .init(chunks: [], end: .fail(PierError.rateLimited(message: "slow down"))),
            .init(chunks: [line(1)], end: .hang),
        ])
        let s = EventStreamer(transport: t, policy: noJitter, sleep: SleepLog().sleep)
        #expect(try await collect(s.events(since: nil), count: 1).count == 1)

        let t2 = MockTransport(connections: [.init(chunks: [], end: .fail(PierError.api(status: 400, message: "bad", code: "bad_request")))])
        let s2 = EventStreamer(transport: t2, policy: noJitter, sleep: SleepLog().sleep)
        await #expect(throws: PierError.self) { for try await _ in s2.events(since: nil) {} }
    }

    @Test func resetHookReconnectsImmediately() async throws {
        let t = MockTransport(connections: [
            .init(chunks: [line(1), line(2)], end: .hang),
            .init(chunks: [line(3)], end: .hang),
        ])
        let log = SleepLog()
        let s = EventStreamer(transport: t, policy: noJitter, sleep: log.sleep)
        var seen: [Int64] = []
        var kicked = false
        for try await e in s.events(since: nil) {
            seen.append(e.seq ?? 0)
            if e.seq == 2 && !kicked {
                kicked = true
                s.reset()
            }
            if e.seq == 3 { break }
        }
        #expect(seen == [1, 2, 3])
        #expect(t.streamPaths == ["/v1/events", "/v1/events?since=2"])
        #expect(log.waits.isEmpty)  // no backoff for a reset
    }

    @Test func resetDuringBackoffSkipsTheWait() async throws {
        let t = MockTransport(connections: [
            .init(chunks: [line(1)], end: .fail(PierError.transport("gone"))),
            .init(chunks: [line(2)], end: .hang),
        ])
        // a sleep that only ends when cancelled (a long backoff)
        let s = EventStreamer(transport: t, policy: noJitter, sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        let waiting = Task { () -> [Int64] in
            var seen: [Int64] = []
            for try await e in s.events(since: nil) {
                seen.append(e.seq ?? 0)
                if e.seq == 2 { break }
            }
            return seen
        }
        try await Task.sleep(for: .milliseconds(150))
        s.reset()
        #expect(try await waiting.value == [1, 2])
    }

    @Test func cancellingStopsReconnecting() async throws {
        let t = MockTransport(connections: [.init(chunks: [line(1)], end: .fail(PierError.transport("x")))])
        let s = EventStreamer(transport: t, policy: noJitter, sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        let task = Task { for try await _ in s.events(since: nil) {} }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        _ = try? await task.value
        try await Task.sleep(for: .milliseconds(50))
        #expect(t.streamPaths.count == 1)
    }

    @Test func stateCallbacks() async throws {
        let t = MockTransport(connections: [
            .init(chunks: [], end: .fail(PierError.transport("refused"))),
            .init(chunks: [line(1)], end: .hang),
        ])
        let states = NIOLockedValueBox<[EventConnectionState]>([])
        let s = EventStreamer(transport: t, policy: noJitter, sleep: SleepLog().sleep)
        _ = try await collect(s.events(since: nil, onState: { st in states.withLockedValue { $0.append(st) } }), count: 1)
        let all = states.withLockedValue { $0 }
        #expect(all.first == .connecting)
        #expect(all.contains { if case .waiting(let d, let e) = $0 { return d == .seconds(1) && e?.contains("refused") == true } else { return false } })
        #expect(all.last == .connected)
    }

    @Test func replaysTheRealJournalFile() async throws {
        let ndjson = try Fixture.data("events.ndjson")
        let t = MockTransport(connections: [.init(chunks: [ndjson], end: .hang)])
        let s = EventStreamer(transport: t, policy: noJitter)
        let total = ndjson.split(separator: 0x0a).count
        let events = try await collect(s.events(since: 238), count: total)
        #expect(events.count == total && events.first?.seq == 239)
        #expect(t.streamPaths == ["/v1/events?since=238"])
    }

    /// A box that never sends a newline cannot grow the line buffer without bound: the over-long line is dropped and
    /// the events after it still arrive.
    @Test func dropsAnEndlessLineAndKeepsGoing() async throws {
        let endless = Data(repeating: UInt8(ascii: "x"), count: EventStreamPolicy.maxLineBytes + 1)
        let tail = Data("yyy\n".utf8) + line(2)
        let t = MockTransport(connections: [.init(chunks: [line(1), endless, tail], end: .hang)])
        let s = EventStreamer(transport: t, policy: noJitter)
        let events = try await collect(s.events(since: nil), count: 2)
        #expect(events.map(\.seq) == [1, 2])
    }
}
