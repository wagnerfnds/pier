import Foundation

// MARK: tolerant string enums

/// A state of an agent session. Unknown values from newer boxes decode to `.unknown(raw)` instead of failing.
public enum AgentState: RawRepresentable, Codable, Hashable, Sendable {
    case idle, running, waiting, finished
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "idle": self = .idle
        case "running": self = .running
        case "waiting": self = .waiting
        case "finished": self = .finished
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .idle: "idle"
        case .running: "running"
        case .waiting: "waiting"
        case .finished: "finished"
        case .unknown(let s): s
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

extension TranscriptItem {
    /// The tolerant view of `kind`.
    public enum Kind: RawRepresentable, Hashable, Sendable {
        case user, text, tools, edit, crew, command, notice, artifact, question, report
        case unknown(String)

        public init(rawValue: String) {
            switch rawValue {
            case "user": self = .user
            case "text": self = .text
            case "tools": self = .tools
            case "edit": self = .edit
            case "crew": self = .crew
            case "command": self = .command
            case "notice": self = .notice
            case "artifact": self = .artifact
            case "question": self = .question
            case "report": self = .report
            default: self = .unknown(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .user: "user"
            case .text: "text"
            case .tools: "tools"
            case .edit: "edit"
            case .crew: "crew"
            case .command: "command"
            case .notice: "notice"
            case .artifact: "artifact"
            case .question: "question"
            case .report: "report"
            case .unknown(let s): s
            }
        }
    }

    public var type: Kind { Kind(rawValue: kind) }
}

// MARK: JSON

public typealias JSON = [String: JSONValue]

extension JSONDecoder {
    /// Decoder for pierd's JSON: RFC 3339 dates with 0-9 fractional digits (and numeric offsets).
    public static var pier: JSONDecoder { PierJSON.makeDecoder() }
}

extension JSONValue {
    public var intValue: Int? {
        if case .number(let n) = self, n.isFinite, abs(n) < 9e15 { return Int(n) }
        return nil
    }
    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}

/// RFC 3339 as Go prints it (`2026-10-07T19:07:42.53987405Z`): 0 to 9 fraction digits, `Z` or `+hh:mm`.
public enum RFC3339 {
    public static func parse(_ s: String) -> Date? {
        let u = Array(s.utf8)
        // YYYY-MM-DDTHH:MM:SS
        guard u.count >= 20, u[4] == 0x2d, u[7] == 0x2d, u[10] == 0x54 || u[10] == 0x74 || u[10] == 0x20, u[13] == 0x3a, u[16] == 0x3a else { return nil }
        func num(_ a: Int, _ n: Int) -> Int? {
            var v = 0
            for i in a..<(a + n) {
                let d = Int(u[i]) - 0x30
                guard d >= 0, d <= 9 else { return nil }
                v = v * 10 + d
            }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2), let mi = num(14, 2), let sec = num(17, 2),
            (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, sec <= 60
        else { return nil }
        var i = 19
        var frac = 0.0
        if u[i] == 0x2e {
            i += 1
            var scale = 0.1
            let start = i
            while i < u.count, u[i] >= 0x30, u[i] <= 0x39 {
                frac += Double(u[i] - 0x30) * scale
                scale /= 10
                i += 1
            }
            if i == start { return nil }
        }
        var offset = 0
        guard i < u.count else { return nil }
        if u[i] == 0x5a || u[i] == 0x7a {
            i += 1
        } else if u[i] == 0x2b || u[i] == 0x2d {
            let sign = u[i] == 0x2d ? -1 : 1
            guard i + 6 == u.count, u[i + 3] == 0x3a, let oh = num(i + 1, 2), let om = num(i + 4, 2) else { return nil }
            offset = sign * (oh * 3600 + om * 60)
            i += 6
        } else { return nil }
        guard i == u.count else { return nil }
        // days from civil (Howard Hinnant)
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        let secs = days * 86400 + h * 3600 + mi * 60 + sec - offset
        return Date(timeIntervalSince1970: Double(secs) + frac)
    }

    /// `2026-10-07T19:07:42.539874050Z` (UTC, 9 digits): safe to send back as `after=`.
    public static func format(_ date: Date) -> String {
        let t = date.timeIntervalSince1970
        var whole = t.rounded(.down)
        var nanos = Int(((t - whole) * 1e9).rounded())
        if nanos >= 1_000_000_000 { nanos -= 1_000_000_000; whole += 1 }
        let secs = Int(whole)
        var days = secs / 86400
        var rem = secs % 86400
        if rem < 0 { rem += 86400; days -= 1 }
        // civil from days
        let z = days + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y0 = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = m <= 2 ? y0 + 1 : y0
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%09dZ", y, m, d, rem / 3600, (rem % 3600) / 60, rem % 60, nanos)
    }
}

// MARK: errors

/// A box-level error `{"error": "...", "code": "..."}` (or a plain-text body), with the HTTP status.
public struct BoxError: Error, Decodable, Sendable, LocalizedError, Hashable {
    public var status: Int
    public let error: String
    public let code: String?

    public enum Code: String, Sendable {
        case notFound = "not_found", sessionExited = "session_exited", sessionExists = "session_exists"
        case agentWaiting = "agent_waiting", refused, unsupported, tmuxMissing = "tmux_missing", gitFailed = "git_failed"
        case commandFailed = "command_failed", tooMany = "too_many", fileChanged = "file_changed", badRequest = "bad_request"
        case `internal`
    }

    public var kind: Code? { code.flatMap(Code.init(rawValue:)) }
    public var errorDescription: String? { error }

    public init(status: Int = 0, error: String, code: String? = nil) {
        self.status = status
        self.error = error
        self.code = code
    }

    enum CodingKeys: String, CodingKey { case error, code }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = 0
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
        code = try c.decodeIfPresent(String.self, forKey: .code)
    }

    /// Parse an error response body: JSON `{"error","code"}` or plain text.
    public static func parse(status: Int, body: Data) -> BoxError {
        if var e = try? JSONDecoder().decode(BoxError.self, from: body), !e.error.isEmpty {
            e.status = status
            return e
        }
        let text = String(decoding: body.prefix(500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return BoxError(status: status, error: text.isEmpty ? "HTTP \(status)" : text)
    }
}

// MARK: requests / small types

public enum WorktreeRemoval: Sendable, Hashable {
    /// 200: removed immediately.
    case removed(String)
    /// 202: an archive script runs first; follow `worktree.archive.*` / `worktree.removed` events.
    case archiving(script: String)
}

public struct SendRequest: Codable, Sendable, Hashable {
    public enum When: String, Codable, Sendable { case now, idle }
    public var text: String
    public var enter: Bool?
    public var when: When?
    public var force: Bool?
    public var idemKey: String?

    public init(text: String, enter: Bool? = true, when: When? = .now, force: Bool? = nil, idemKey: String? = nil) {
        self.text = text
        self.enter = enter
        self.when = when
        self.force = force
        self.idemKey = idemKey
    }

    enum CodingKeys: String, CodingKey { case text, enter, when, force, idemKey = "idem_key" }

    /// A single keystroke (menu answer) the person authorises: `{"text":"1","enter":false,"when":"now","force":true}`.
    public static func key(_ k: String) -> SendRequest { SendRequest(text: k, enter: false, when: .now, force: true) }
}

public enum ControlKey: String, Codable, Sendable, CaseIterable {
    case escape, enter, tab, btab, up, down, left, right, interrupt
    case k1 = "1", k2 = "2", k3 = "3", k4 = "4", k5 = "5", k6 = "6", k7 = "7", k8 = "8", k9 = "9", y, n

    /// Key for a menu digit "1"..."9".
    public init?(digit: String) { self.init(rawValue: digit) }
}

// MARK: events

/// One line of `GET /v1/events`.
public struct PierEvent: Codable, Sendable, Identifiable, Hashable {
    public var id: Int64 { seq ?? 0 }
    public let seq: Int64?
    public let type: String
    public let time: Date
    public let box: String?
    public let origin: String?
    public let error: String?
    public let data: JSON?

    public init(seq: Int64? = nil, type: String, time: Date = Date(), box: String? = nil, origin: String? = nil, error: String? = nil, data: JSON? = nil) {
        self.seq = seq
        self.type = type
        self.time = time
        self.box = box
        self.origin = origin
        self.error = error
        self.data = data
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decodeIfPresent(Int64.self, forKey: .seq)
        type = try c.decode(String.self, forKey: .type)
        time = try c.decodeIfPresent(Date.self, forKey: .time) ?? Date()
        box = try c.decodeIfPresent(String.self, forKey: .box)
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        data = try? c.decodeIfPresent(JSON.self, forKey: .data)
    }

    public func str(_ k: String) -> String? { data?[k]?.stringValue }
    public func int(_ k: String) -> Int? { data?[k]?.intValue }
    public func bool(_ k: String) -> Bool? { data?[k]?.boolValue }
}
