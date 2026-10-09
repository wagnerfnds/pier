import Foundation

/// A single-box pairing link: `pier://HOST:PORT?code=<b32>&fp=<b32>` (from `pierd pair`).
public struct BoxPairingLink: Sendable, Hashable {
    public let host: String
    public let port: Int
    public let fingerprint: Fingerprint
    /// Raw 32 byte single-use code. A secret: never log.
    public let code: [UInt8]

    /// "HOST:PORT", IPv6 bracketed.
    public var address: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
}

/// A multi-box join link: `pier://join?v=1&d=<base64url payload>`.
public struct JoinLink: Sendable, Hashable {
    public struct Box: Sendable, Hashable {
        public let fingerprint: Fingerprint
        public let code: [UInt8]
        public let name: String
        public let network: String
        public let tailnet: String
        /// "host:port" candidates.
        public let addresses: [String]

        /// Converts to a single-box link using the first address.
        public func pairingLink() throws -> BoxPairingLink {
            guard let a = addresses.first else { throw PierError.invalidLink("no address") }
            let (h, p) = try PairingLink.splitHostPort(a)
            return BoxPairingLink(host: h, port: p, fingerprint: fingerprint, code: code)
        }
    }

    public let expires: Date
    public let from: String
    public let boxes: [Box]

    /// The client rejects links older than expiry + 1 minute; the box is the real judge.
    public func isExpired(now: Date = Date()) -> Bool { now.timeIntervalSince(expires) > 60 }
}

public enum PairingLink: Sendable, Hashable {
    case box(BoxPairingLink)
    case join(JoinLink)

    public static func parse(_ text: String) throws -> PairingLink {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prefix = schemes.first(where: { s.lowercased().hasPrefix($0) }) else {
            throw PierError.invalidLink("scheme must be pier://")
        }
        var rest = String(s.dropFirst(prefix.count))
        if rest.contains("#") { throw PierError.invalidLink("unexpected fragment") }
        var query = ""
        if let q = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: q)...])
            rest = String(rest[..<q])
        }
        var authority = rest
        if let slash = rest.firstIndex(of: "/") {
            guard rest[slash...] == "/" else { throw PierError.invalidLink("unexpected path") }
            authority = String(rest[..<slash])
        }
        guard !authority.contains("@") else { throw PierError.invalidLink("unexpected userinfo") }
        let params = parseQuery(query)

        if authority.lowercased() == "join" {
            return .join(try parseJoin(params))
        }
        let (host, port) = try splitHostPort(authority)
        guard let fpS = params["fp"], let fp = Fingerprint(string: fpS) else { throw PierError.invalidLink("bad fingerprint") }
        guard let codeS = params["code"], let code = Base32.decode(codeS), code.count == 32 else {
            throw PierError.invalidLink("bad code")
        }
        return .box(BoxPairingLink(host: host, port: port, fingerprint: fp, code: code))
    }

    /// The link schemes: pierd's.
    public static let schemes = ["pier://"]

    /// Finds a `pier://` link inside pasted text (join or box form).
    public static func find(in text: String) -> PairingLink? {
        guard let re = try? NSRegularExpression(pattern: #"pier://[^\s'"<>`]+"#, options: .caseInsensitive) else { return nil }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var cand = ns.substring(with: m.range)
            while let l = cand.last, ".,;:)]".contains(l) { cand.removeLast() }
            if let l = try? parse(cand) { return l }
        }
        return nil
    }

    // MARK: internals

    static func splitHostPort(_ authority: String) throws -> (String, Int) {
        var host: String
        var portS: String
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { throw PierError.invalidLink("bad IPv6 host") }
            host = String(authority[authority.index(after: authority.startIndex)..<close])
            let after = authority[authority.index(after: close)...]
            guard after.hasPrefix(":") else { throw PierError.invalidLink("missing port") }
            portS = String(after.dropFirst())
        } else {
            guard let colon = authority.lastIndex(of: ":"), !authority[..<colon].contains(":") else {
                throw PierError.invalidLink("host:port required")
            }
            host = String(authority[..<colon])
            portS = String(authority[authority.index(after: colon)...])
        }
        guard !host.isEmpty else { throw PierError.invalidLink("empty host") }
        guard let port = Int(portS), (1...65535).contains(port), portS.allSatisfy(\.isASCII) else {
            throw PierError.invalidLink("bad port")
        }
        return (host, port)
    }

    private static func parseQuery(_ q: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            if out[k] == nil { out[k] = String(kv[1]).removingPercentEncoding ?? String(kv[1]) }
        }
        return out
    }

    private static func parseJoin(_ params: [String: String]) throws -> JoinLink {
        guard params["v"] == "1" else { throw PierError.invalidLink("unsupported join link version") }
        guard var d = params["d"] else { throw PierError.invalidLink("missing payload") }
        d = d.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard !d.contains("="), let data = Data(base64Encoded: d + String(repeating: "=", count: (4 - d.count % 4) % 4)) else {
            throw PierError.invalidLink("bad payload encoding")
        }
        var r = Reader(bytes: Array(data))
        let expires = Date(timeIntervalSince1970: TimeInterval(try r.u32()))
        let from = try r.str()
        let count = Int(try r.u8())
        guard (1...16).contains(count) else { throw PierError.invalidLink("bad box count") }
        var boxes: [JoinLink.Box] = []
        for _ in 0..<count {
            guard let fp = Fingerprint(bytes: try r.take(32)) else { throw PierError.invalidLink("bad fingerprint") }
            let code = try r.take(32)
            let name = try r.str()
            let network = try r.str()
            let tailnet = try r.str()
            let n = Int(try r.u8())
            guard (1...4).contains(n) else { throw PierError.invalidLink("bad address count") }
            var addrs: [String] = []
            for _ in 0..<n { addrs.append(try r.str()) }
            boxes.append(.init(fingerprint: fp, code: code, name: name, network: network, tailnet: tailnet, addresses: addrs))
        }
        guard r.remaining == 0 else { throw PierError.invalidLink("trailing bytes") }
        return JoinLink(expires: expires, from: from, boxes: boxes)
    }

    private struct Reader {
        let bytes: [UInt8]
        var pos = 0
        init(bytes: [UInt8]) { self.bytes = bytes }
        var remaining: Int { bytes.count - pos }
        mutating func take(_ n: Int) throws -> [UInt8] {
            guard remaining >= n else { throw PierError.invalidLink("truncated payload") }
            defer { pos += n }
            return Array(bytes[pos..<pos + n])
        }
        mutating func u8() throws -> UInt8 { try take(1)[0] }
        mutating func u32() throws -> UInt32 { try take(4).reduce(0) { ($0 << 8) | UInt32($1) } }
        mutating func str() throws -> String {
            let n = Int(try u8())
            guard let s = String(bytes: try take(n), encoding: .utf8) else { throw PierError.invalidLink("bad utf-8") }
            return s
        }
    }
}

/// Client/box name rules shared with pierd (`^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$`, not "local").
public enum PierName {
    public static func isValid(_ s: String) -> Bool {
        guard (1...63).contains(s.utf8.count), s.lowercased() != "local" else { return false }
        let u = Array(s.utf8)
        func alnum(_ c: UInt8) -> Bool { (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c) }
        return alnum(u[0]) && u.dropFirst().allSatisfy { alnum($0) || $0 == 46 || $0 == 95 || $0 == 45 }
    }

    /// Mirrors pierd's NameFromHostname: lowercase, strip ".local", other chars become "-", trim, <= 63.
    public static func fromHostname(_ host: String, fallback: String = "device") -> String {
        var h = host.lowercased()
        if h.hasSuffix(".local") { h.removeLast(6) }
        var out = String(h.map { c -> Character in
            (c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "_" || c == "-")) ? c : "-"
        })
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        if out.count > 63 { out = String(out.prefix(63)) }
        return isValid(out) ? out : fallback
    }
}
