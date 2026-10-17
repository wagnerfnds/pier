import Foundation
import PierKit

/// Where Pier lives on the web, and the commands that install and pair pierd (site/install.sh, the npm package, the
/// Homebrew formula): the onboarding and "Instalar o pierd" show them with Copiar.
enum PierLinks {
    static let site = "https://docktopier.com/"
    static let installCommand = "curl -fsSL \(site)install.sh | sh"
    static let npmCommand = "npm install -g pierd && pierd setup"
    static let brewCommand = "brew install wagnerfnds/tap/pierd && pierd setup"
}

/// This device's own names and addresses, for `LocalHost.isThisDevice` (a pairing link from pierd on this Mac).
enum ThisDevice {
    #if os(macOS)
    static var names: [String] { [LocalHostName.value] }   // the native Mac: no DNS wait
    #else
    static var names: [String] { [ProcessInfo.processInfo.hostName] }
    #endif

    static var addresses: [String] {
        var out: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return out }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr else { continue }
            let family = sa.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(family == UInt8(AF_INET) ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            if getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                // "fe80::1%en0": the scope is not part of the address a link names.
                out.append(String(cString: host).split(separator: "%").first.map(String.init) ?? "")
            }
        }
        return out
    }

    /// Whether a pairing link names this very device.
    static func isHere(_ link: PairingLink) -> Bool {
        guard case .box(let b) = link else { return false }
        return LocalHost.isThisDevice(b.host, names: names, addresses: addresses)
    }
}
