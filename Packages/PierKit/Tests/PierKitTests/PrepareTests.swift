import Foundation
import Testing

@testable import PierKit

@Suite struct PrepareTests {
    @Test func statusesDecode() throws {
        let skipped = try Fixture.decode("prepare_skipped.json", as: PrepareStatus.self)
        #expect(skipped.state == .skipped && skipped.since != nil && skipped.services == ["web", "compose"] && skipped.hasWork)
        let failed = try Fixture.decode("prepare_failed.json", as: PrepareStatus.self)
        #expect(failed.state == .failed && failed.error?.contains("missing script") == true)
        let unknown = try Fixture.decode("prepare_unknown.json", as: PrepareStatus.self)
        #expect(unknown.state == .unknown && unknown.since == nil && !unknown.hasWork)
        // A state a later box adds reads as unknown rather than failing the whole screen.
        let later = try JSONDecoder.pier.decode(PrepareStatus.self, from: Data(#"{"state":"paused"}"#.utf8))
        #expect(later.state == .unknown && later.services.isEmpty)
    }

    /// prepare goes out only when it was set: an older box never sees the field, and nil keeps today's behavior.
    @Test func requestsCarryPrepareOnlyWhenSet() throws {
        func body<T: Encodable>(_ v: T) throws -> String { String(decoding: try PierJSON.makeEncoder().encode(v), as: UTF8.self) }
        #expect(try body(WorktreeRequest(name: "quick", prepare: false)).contains(#""prepare":false"#))
        #expect(try !body(WorktreeRequest(name: "full")).contains("prepare"))
        #expect(try body(TaskRequest(location: "shop", name: "quick", prepare: false)).contains(#""prepare":false"#))
        #expect(try !body(TaskRequest(location: "shop", name: "full")).contains("prepare"))
    }

    @Test func routes() async throws {
        let t = MockTransport { method, path, _ in
            (method == .post ? 202 : 200, try Fixture.data(method == .post ? "prepare_running.json" : "prepare_skipped.json"))
        }
        let a = BoxAPI(transport: t, eventPolicy: EventStreamPolicy(jitter: 0))
        #expect(try await a.prepareStatus(location: "shop", worktree: "fix/login").state == .skipped)
        #expect(try await a.prepare(location: "shop", worktree: "fix/login").state == .running)
        #expect(t.requests.map { "\($0.method) \($0.path)" } == [
            "GET /v1/locations/shop/worktrees/fix%2Flogin/prepare",
            "POST /v1/locations/shop/worktrees/fix%2Flogin/prepare",
        ])
    }
}
