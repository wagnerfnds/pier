import Foundation

// Pairing another device from one that is already paired ("Levar para o iPhone"): the box mints a single-use invite for
// a client that already holds a key it trusts, so the person never needs the box's terminal.
// `POST /v1/pair/invite` -> `{"link":"pier://…","expires":"RFC3339"}` (single use, 10 minutes). A box without the route
// answers 404 (or 405): `PairInviteError.unsupported`.

/// A pairing invite minted by one box: a `pier://` link another device opens or scans.
public struct PairInvite: Sendable, Hashable {
    /// The single-box link (`pier://HOST:PORT?code=…&fp=…`). Holds a secret code: show it, never log it.
    public let link: String
    public let expires: Date?

    public init(link: String, expires: Date?) {
        self.link = link
        self.expires = expires
    }

    /// The parsed single-box link (nil when the box answered with something else, like a join link).
    public var boxLink: BoxPairingLink? {
        if case .box(let l)? = try? PairingLink.parse(link) { return l }
        return nil
    }
}

public enum PairInviteError: Error, Sendable, Equatable {
    /// The box has no invite route: pair with `pierd pair` on the box instead.
    case unsupported
}

/// `POST /v1/pair/invite` answer.
struct PairInviteResponse: Decodable {
    let link: String
    let expires: Date?
}

extension BoxAPI {
    /// Mint a single-use pairing invite for another device; throws `PairInviteError.unsupported` when the box has no
    /// invite route.
    public func pairInvite() async throws -> PairInvite {
        do {
            let r: PairInviteResponse = try decode(try await call(.post, "/v1/pair/invite").data)
            return PairInvite(link: r.link.trimmingCharacters(in: .whitespacesAndNewlines), expires: r.expires)
        } catch let e as BoxError where Self.isMissingRoute(e) {
            throw PairInviteError.unsupported
        }
    }

    /// Go's mux says 404 for an unknown path and 405 for a known path with another method: both mean "no such route" here.
    static func isMissingRoute(_ e: BoxError) -> Bool { e.status == 404 || e.status == 405 }
}

extension JoinLink {
    /// One link for several boxes: `pier://join?v=1&d=<base64url payload>` (docs/PROTOCOL.md §1.2), so a new device
    /// pairs with every box from one QR code.
    public static func encode(boxes: [(name: String, link: BoxPairingLink)], from: String, expires: Date) throws -> String {
        guard (1...16).contains(boxes.count) else { throw PierError.invalidLink("bad box count") }
        var out: [UInt8] = []
        func str(_ s: String) throws {
            let b = Array(s.utf8)
            guard b.count <= 255 else { throw PierError.invalidLink("string too long") }
            out.append(UInt8(b.count)); out += b
        }
        let secs = UInt32(clamping: Int(max(0, expires.timeIntervalSince1970)))
        out += [UInt8(secs >> 24 & 0xFF), UInt8(secs >> 16 & 0xFF), UInt8(secs >> 8 & 0xFF), UInt8(secs & 0xFF)]
        try str(from)
        out.append(UInt8(boxes.count))
        for b in boxes {
            guard PierName.isValid(b.name) else { throw PierError.invalidLink("bad box name") }
            out += b.link.fingerprint.bytes
            out += b.link.code
            try str(b.name)
            try str("")   // network: reach it directly
            try str("")   // tailnet
            out.append(1)
            try str(b.link.address)
        }
        let d = Data(out).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "pier://join?v=1&d=\(d)"
    }
}
