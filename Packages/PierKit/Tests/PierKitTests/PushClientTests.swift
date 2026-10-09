import Foundation
import Testing

@testable import PierKit

@Suite struct PushClientTests {
    private func client(_ handler: @escaping @Sendable (BoxClient.Method, String, Data?) throws -> (Int, Data)) -> (PushClient, MockTransport) {
        let t = MockTransport(handler: handler)
        return (PushClient(transport: t), t)
    }

    @Test func infoAndTest() async throws {
        let (c, t) = client { _, path, _ in
            if path == "/v1/push/info" { return (200, Data(#"{"version":"1","apns_env_supported":["development","production"],"bundle_id":"com.example.pier"}"#.utf8)) }
            return (200, Data(#"{"sent":true,"apns_id":"abc"}"#.utf8))
        }
        let i = try await c.info()
        #expect(i.version == "1" && i.apnsEnvSupported.count == 2 && i.bundleID == "com.example.pier")
        let r = try await c.test()
        #expect(r.sent && r.apnsID == "abc")
        #expect(t.requests.map { "\($0.method) \($0.path)" } == ["GET /v1/push/info", "POST /v1/push/test"])
    }

    @Test func deviceBodyAndOptionalFields() async throws {
        let (c, t) = client { _, _, _ in (204, Data()) }
        try await c.putDevice(.init(deviceToken: "ab12", env: .development, locale: "pt-BR", events: .init()))
        try await c.putDevice(.init(deviceToken: "ab12", env: .production, locale: "en", events: .init(waiting: true, finished: false, working: true),
                                    widgetToken: "w1", pushToStartToken: "p1", boxName: "devbox"))
        try await c.deleteDevice()
        let r = t.requests
        #expect(r[0].method == "PUT" && r[0].path == "/v1/push/device")
        let a = try JSONSerialization.jsonObject(with: Data(r[0].body!.utf8)) as! [String: Any]
        #expect(a["device_token"] as? String == "ab12" && a["env"] as? String == "development" && a["locale"] as? String == "pt-BR")
        #expect(a["widget_token"] == nil && a["push_to_start_token"] == nil && a["box_name"] == nil)
        #expect((a["events"] as? [String: Bool]) == ["waiting": true, "finished": true, "working": false])
        let b = try JSONSerialization.jsonObject(with: Data(r[1].body!.utf8)) as! [String: Any]
        #expect(b["widget_token"] as? String == "w1" && b["push_to_start_token"] as? String == "p1" && b["box_name"] as? String == "devbox")
        #expect(r[2].method == "DELETE" && r[2].body == nil)
    }

    @Test func activities() async throws {
        let (c, t) = client { _, _, _ in (204, Data()) }
        try await c.putActivity(box: "devbox", session: "proj wt/1", .init(token: "t0", env: .production))
        try await c.deleteActivity(box: "devbox", session: "s-1")
        #expect(t.requests[0].path == "/v1/push/activities/devbox/proj%20wt%2F1")
        #expect(t.requests[0].body == #"{"token":"t0","env":"production"}"# || t.requests[0].body == #"{"env":"production","token":"t0"}"#)
        #expect(t.requests[1].method == "DELETE" && t.requests[1].path == "/v1/push/activities/devbox/s-1")
    }

    @Test func errorsPropagate() async throws {
        let (c, _) = client { _, _, _ in throw PierError.api(status: 502, message: "apns", code: "apns_error") }
        await #expect(throws: PierError.self) { try await c.test() }
    }

    @Test func hex() { #expect(pushTokenHex(Data([0x0a, 0xff, 0x01])) == "0aff01") }
}
