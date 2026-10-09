import Foundation
import Testing

@testable import PierKit

private let fp = "ezk6bydn75ceadnykqnnpfuv4ucl7ahps6iummnwq5w2tfelxgba"
private let code = String(repeating: "a", count: 52)
private func json(_ s: String) -> Data { Data(s.utf8) }
private func missing() -> PierError { .api(status: 404, message: "404 page not found", code: nil) }

@Suite struct PairInviteTests {
    @Test func newRouteReturnsTheLinkAsIs() async throws {
        let link = "pier://192.0.2.10:7444?code=\(code)&fp=\(fp)"
        let t = MockTransport { _, path, _ in
            #expect(path == "/v1/pair/invite")
            return (200, json(#"{"link":"\#(link)","expires":"2026-10-08T18:00:00Z"}"#))
        }
        let inv = try await BoxAPI(transport: t).pairInvite()
        #expect(inv.link == link)
        #expect(inv.expires == RFC3339.parse("2026-10-08T18:00:00Z"))
        #expect(inv.boxLink?.address == "192.0.2.10:7444")
        #expect(t.requests == [.init(method: "POST", path: "/v1/pair/invite", body: nil)])
    }

    @Test func missingRouteMeansUnsupported() async throws {
        for status in [404, 405] {
            let t = MockTransport { _, _, _ in throw PierError.api(status: status, message: "no route", code: nil) }
            await #expect(throws: PairInviteError.unsupported) { try await BoxAPI(transport: t).pairInvite() }
            #expect(t.requests.map(\.path) == ["/v1/pair/invite"])
        }
    }

    @Test func otherErrorsAreNotSwallowed() async throws {
        let t = MockTransport { _, _, _ in throw PierError.api(status: 429, message: "too many invites", code: "too_many") }
        await #expect(throws: BoxError.self) { try await BoxAPI(transport: t).pairInvite() }
        #expect(t.requests.count == 1)
    }

    @Test func joinLinkRoundTrips() throws {
        let a = BoxPairingLink(host: "192.0.2.10", port: 7444, fingerprint: Fingerprint(string: fp)!, code: [UInt8](repeating: 1, count: 32))
        let b = BoxPairingLink(host: "lab.example.ts.net", port: 7444, fingerprint: Fingerprint(bytes: [UInt8](repeating: 9, count: 32))!,
                               code: [UInt8](repeating: 2, count: 32))
        let expires = Date(timeIntervalSince1970: 1_791_500_000)
        let s = try JoinLink.encode(boxes: [("devbox", a), ("lab", b)], from: "my-mac", expires: expires)
        #expect(s.hasPrefix("pier://join?v=1&d=") && !s.dropFirst("pier://join?v=1&d=".count).contains("="))
        guard case .join(let j) = try PairingLink.parse(s) else { Issue.record("not a join link"); return }
        #expect(j.from == "my-mac" && j.expires == expires)
        #expect(j.boxes.map(\.name) == ["devbox", "lab"])
        #expect(try j.boxes[0].pairingLink() == a)
        #expect(try j.boxes[1].pairingLink() == b)
        #expect(PairingLink.find(in: "abra: \(s).") != nil)
    }

    @Test func joinLinkRejectsBadInput() {
        let a = BoxPairingLink(host: "h", port: 1, fingerprint: Fingerprint(string: fp)!, code: [UInt8](repeating: 1, count: 32))
        #expect(throws: PierError.self) { try JoinLink.encode(boxes: [], from: "x", expires: Date()) }
        #expect(throws: PierError.self) { try JoinLink.encode(boxes: [("bad name", a)], from: "x", expires: Date()) }
    }
}
