import Foundation

/// The page the in-app browser opens for a worktree (a session's Navegador tab, Detalhes' "Abrir no Pier"): one of its
/// dev servers straight at the box's address and port when this device reaches it, else that server's public link
/// (through the box's relay), else nothing, with why, so the browser can say what would give it a page.
public enum PreviewTarget: Equatable, Sendable {
    /// A dev server at the box's own address (`Projects.previewURL`).
    case direct(URL, port: Int)
    /// A dev server's public link (`/v1/shares`): this device does not reach the box's port.
    case publicLink(URL, port: Int)
    /// Nothing listens in the worktree.
    case noServer
    /// A server listens on `port`, but this device does not reach it at the box's address and it has no public link.
    case unreachable(port: Int)

    /// The page to open, when there is one.
    public var url: URL? {
        switch self {
        case .direct(let u, _), .publicLink(let u, _): u
        case .noServer, .unreachable: nil
        }
    }

    /// The page for a worktree: `servers` are its dev servers (`Projects.devServers`), `reachable` what this device
    /// reached of their ports at `host` (a port not probed counts as out of reach), `links` the worktree's public links.
    /// The server on the worktree's own port ($PIER_PORT) goes first, then the rest of its block, then any other, lowest
    /// first: the first one reached opens at the box's address, else the first one with a public link opens there.
    public static func choose(servers: [BoxService], worktreePort: Int?, host: String, reachable: [Int: Bool],
                              links: [PublicLink]) -> PreviewTarget {
        let ports = order(servers.map(\.port), worktreePort: worktreePort)
        guard let first = ports.first else { return .noServer }
        for p in ports where reachable[p] == true {
            if let u = Projects.previewURL(host: host, port: p) { return .direct(u, port: p) }
        }
        for p in ports {
            if let l = links.first(where: { $0.port == p }), let u = URL(string: l.url), u.host != nil { return .publicLink(u, port: p) }
        }
        return .unreachable(port: first)
    }

    /// Ports in the order they are tried: the worktree's own, then its block of ten, then the others, lowest first.
    static func order(_ ports: [Int], worktreePort: Int?) -> [Int] {
        let unique = Set(ports.filter { $0 > 0 }).sorted()
        guard let w = worktreePort, w > 0 else { return unique }
        func rank(_ p: Int) -> Int { p == w ? 0 : (w...w + 9).contains(p) ? 1 : 2 }
        return unique.sorted { (rank($0), $0) < (rank($1), $1) }
    }

    /// What was typed in the browser's address field, as a page. A web address with its scheme stays as written (http
    /// and https only; also about: and data:); without one, http for what reads as a dev server or a box on the network
    /// (a port, an IP address, localhost, a name with no dot or under .local), https for the rest. Nil for what cannot be
    /// an address (nothing, spaces, another scheme).
    public static func url(typed: String) -> URL? {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        let lower = t.lowercased()
        if lower.hasPrefix("about:") || lower.hasPrefix("data:") { return URL(string: t) }
        if let sep = lower.range(of: "://") {
            let scheme = lower[..<sep.lowerBound]
            guard scheme == "http" || scheme == "https", let u = URL(string: t), u.host?.isEmpty == false else { return nil }
            return u
        }
        // "host:port" with no scheme reads to URL as a scheme of its own: the host is found with one in front.
        guard let u = URL(string: "http://" + t), let host = u.host, !host.isEmpty else { return nil }
        let h = host.lowercased()
        let local = u.port != nil || h == "localhost" || !h.contains(".") || h.hasSuffix(".local") || isIPAddress(h)
        return local ? u : URL(string: "https://" + t)
    }

    /// An IPv4 address (four numbers up to 255) or an IPv6 one (it has colons, which no name has).
    static func isIPAddress(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h.contains(":") { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in p.count <= 3 && Int(p).map { (0...255).contains($0) } == true }
    }
}
