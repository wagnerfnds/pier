import Foundation

/// APNs environment a device token belongs to.
public enum PushEnvironment: String, Codable, Sendable { case development, production }

/// Which transitions the person wants a push for (`events` of `PUT /v1/push/device`).
public struct PushEvents: Codable, Sendable, Hashable {
    public var waiting: Bool
    public var finished: Bool
    public var working: Bool
    public init(waiting: Bool = true, finished: Bool = true, working: Bool = false) {
        self.waiting = waiting; self.finished = finished; self.working = working
    }
}

/// `GET /v1/push/info`.
public struct PushInfo: Codable, Sendable, Hashable {
    public var version: String
    public var apnsEnvSupported: [String]
    public var bundleID: String
    enum CodingKeys: String, CodingKey {
        case version
        case apnsEnvSupported = "apns_env_supported"
        case bundleID = "bundle_id"
    }
}

/// `PUT /v1/push/device` body.
public struct PushDeviceRegistration: Codable, Sendable, Hashable {
    public var deviceToken: String
    public var env: PushEnvironment
    public var locale: String
    public var events: PushEvents
    public var widgetToken: String?
    public var pushToStartToken: String?
    /// The name this phone gave the box (`BoxRecord.name`); the server puts it in the payload's `box` key.
    public var boxName: String?

    public init(deviceToken: String, env: PushEnvironment, locale: String, events: PushEvents,
                widgetToken: String? = nil, pushToStartToken: String? = nil, boxName: String? = nil) {
        self.deviceToken = deviceToken; self.env = env; self.locale = locale; self.events = events
        self.widgetToken = widgetToken; self.pushToStartToken = pushToStartToken; self.boxName = boxName
    }

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token", env, locale, events
        case widgetToken = "widget_token", pushToStartToken = "push_to_start_token", boxName = "box_name"
    }
}

/// `PUT /v1/push/activities/{box}/{session}` body.
public struct PushActivityRegistration: Codable, Sendable, Hashable {
    public var token: String
    public var env: PushEnvironment
    public init(token: String, env: PushEnvironment) { self.token = token; self.env = env }
}

/// `POST /v1/push/test` answer.
public struct PushTestResult: Codable, Sendable, Hashable {
    public var sent: Bool
    public var apnsID: String?
    enum CodingKeys: String, CodingKey { case sent, apnsID = "apns_id" }
}

/// Typed client for the box's push routes (`/v1/push/*`, docs/PUSH.md), served by pierd on its main port.
public struct PushClient: Sendable {
    private let transport: any PierTransport
    private let encoder = PierJSON.makeEncoder()
    private let decoder = JSONDecoder()

    public init(transport: any PierTransport) {
        self.transport = transport
    }

    public init(box: BoxRecord, identity: PierIdentity) {
        self.init(transport: BoxClient(box: box, identity: identity, origin: "ios-push"))
    }

    private func send(_ method: BoxClient.Method, _ path: String, body: Data?) async throws -> (status: Int, data: Data) {
        try await transport.send(method, path: path, body: body)
    }

    public func info() async throws -> PushInfo {
        try decode(try await send(.get, "/v1/push/info", body: nil).data)
    }

    public func putDevice(_ reg: PushDeviceRegistration) async throws {
        _ = try await send(.put, "/v1/push/device", body: try encoder.encode(reg))
    }

    public func deleteDevice() async throws {
        _ = try await send(.delete, "/v1/push/device", body: nil)
    }

    public func putActivity(box: String, session: String, _ reg: PushActivityRegistration) async throws {
        _ = try await send(.put, Self.activityPath(box: box, session: session), body: try encoder.encode(reg))
    }

    public func deleteActivity(box: String, session: String) async throws {
        _ = try await send(.delete, Self.activityPath(box: box, session: session), body: nil)
    }

    public func test() async throws -> PushTestResult {
        try decode(try await send(.post, "/v1/push/test", body: nil).data)
    }

    public func reset() async {
        await transport.reset()
    }

    static func activityPath(box: String, session: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=%")
        let b = box.addingPercentEncoding(withAllowedCharacters: allowed) ?? box
        let s = session.addingPercentEncoding(withAllowedCharacters: allowed) ?? session
        return "/v1/push/activities/\(b)/\(s)"
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try decoder.decode(T.self, from: data) } catch { throw PierError.decoding("\(error)") }
    }
}

/// Lower-case hex of a device / activity token.
public func pushTokenHex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
