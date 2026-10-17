import Foundation
import Testing

@testable import PierKit

/// The in-app browser's page for a worktree: its dev server at the box's address when this device reaches it, else its
/// public link, else why there is none; and what is typed in its address field.
@Suite struct PreviewTargetTests {
    private func server(_ port: Int) -> BoxService {
        BoxService(location: "shop", worktree: "checkout-fix", path: "/home/octocat/code/shop-checkout-fix", port: port)
    }

    private func link(_ port: Int, _ name: String = "a1b2") -> PublicLink {
        PublicLink(name: name, url: "https://p-\(name).example.com", location: "shop", worktree: "checkout-fix", port: port)
    }

    @Test func aServerThisDeviceReachesOpensAtTheBoxsAddress() {
        let t = PreviewTarget.choose(servers: [server(41010)], worktreePort: 41010, host: "devbox.local", reachable: [41010: true], links: [link(41010)])
        #expect(t == .direct(URL(string: "http://devbox.local:41010")!, port: 41010))
        #expect(t.url?.absoluteString == "http://devbox.local:41010")
        // An IPv6 address goes in brackets.
        let v6 = PreviewTarget.choose(servers: [server(41010)], worktreePort: nil, host: "fd00::1", reachable: [41010: true], links: [])
        #expect(v6.url?.absoluteString == "http://[fd00::1]:41010")
    }

    @Test func outOfReachItsPublicLinkOpens() {
        let t = PreviewTarget.choose(servers: [server(41010)], worktreePort: 41010, host: "devbox.local", reachable: [41010: false], links: [link(41010)])
        #expect(t == .publicLink(URL(string: "https://p-a1b2.example.com")!, port: 41010))
        // A port not probed yet counts as out of reach.
        let unprobed = PreviewTarget.choose(servers: [server(41010)], worktreePort: 41010, host: "devbox.local", reachable: [:], links: [link(41010)])
        #expect(unprobed == .publicLink(URL(string: "https://p-a1b2.example.com")!, port: 41010))
        // A box reached through a relay has no address of its own for the page: the link it is.
        let relayed = PreviewTarget.choose(servers: [server(41010)], worktreePort: 41010, host: "", reachable: [41010: true], links: [link(41010)])
        #expect(relayed == .publicLink(URL(string: "https://p-a1b2.example.com")!, port: 41010))
    }

    @Test func withoutEitherItSaysWhy() {
        #expect(PreviewTarget.choose(servers: [], worktreePort: 41010, host: "devbox.local", reachable: [:], links: [link(41010)]) == .noServer)
        let t = PreviewTarget.choose(servers: [server(41012), server(41010)], worktreePort: 41010, host: "devbox.local",
                                     reachable: [41010: false, 41012: false], links: [link(5173)])
        #expect(t == .unreachable(port: 41010))
        #expect(t.url == nil)
        // A link that is no web address is not one.
        let bad = PublicLink(name: "x", url: "not a link", location: "shop", worktree: "checkout-fix", port: 41010)
        #expect(PreviewTarget.choose(servers: [server(41010)], worktreePort: 41010, host: "", reachable: [:], links: [bad]) == .unreachable(port: 41010))
    }

    @Test func theWorktreesOwnPortGoesFirst() {
        // Its own port, then the rest of its block, then any other, lowest first; a port listed twice counts once.
        #expect(PreviewTarget.order([3000, 41013, 41010, 41011, 41013, 0], worktreePort: 41010) == [41010, 41011, 41013, 3000])
        #expect(PreviewTarget.order([5173, 41020, 3000], worktreePort: 41010) == [3000, 5173, 41020])
        #expect(PreviewTarget.order([5173, 3000], worktreePort: nil) == [3000, 5173])
        // Every server reached: the worktree's own wins over a lower port.
        let all = PreviewTarget.choose(servers: [server(3000), server(41011), server(41010)], worktreePort: 41010, host: "devbox.local",
                                       reachable: [3000: true, 41010: true, 41011: true], links: [])
        #expect(all == .direct(URL(string: "http://devbox.local:41010")!, port: 41010))
        // Only another one reached: that one, at the box's address, before the worktree's own public link.
        let other = PreviewTarget.choose(servers: [server(41010), server(41011)], worktreePort: 41010, host: "devbox.local",
                                         reachable: [41010: false, 41011: true], links: [link(41010)])
        #expect(other == .direct(URL(string: "http://devbox.local:41011")!, port: 41011))
        // None reached: the link of the first in that order that has one.
        let links = PreviewTarget.choose(servers: [server(41010), server(41011)], worktreePort: 41010, host: "devbox.local",
                                         reachable: [:], links: [link(41011, "c3d4")])
        #expect(links == .publicLink(URL(string: "https://p-c3d4.example.com")!, port: 41011))
    }

    @Test func typedAddresses() {
        func typed(_ s: String) -> String? { PreviewTarget.url(typed: s)?.absoluteString }
        // As written, with a scheme of the web's.
        #expect(typed("https://example.com/a?b=1") == "https://example.com/a?b=1")
        #expect(typed("  http://devbox.local:41010/  ") == "http://devbox.local:41010/")
        #expect(typed("HTTP://Example.com") == "HTTP://Example.com")
        #expect(typed("about:blank") == "about:blank")
        // A dev server or a box on the network: plain http.
        #expect(typed("localhost:3000") == "http://localhost:3000")
        #expect(typed("devbox.local:41010/app") == "http://devbox.local:41010/app")
        #expect(typed("devbox") == "http://devbox")
        #expect(typed("devbox.local") == "http://devbox.local")
        #expect(typed("192.0.2.20") == "http://192.0.2.20")
        #expect(typed("[fd00::1]:41010") == "http://[fd00::1]:41010")
        #expect(typed("my-box.example.ts.net:41010") == "http://my-box.example.ts.net:41010")
        // A name on the internet: https.
        #expect(typed("example.com") == "https://example.com")
        #expect(typed("docs.example.com/guide") == "https://docs.example.com/guide")
        // Not an address.
        #expect(typed("") == nil)
        #expect(typed("   ") == nil)
        #expect(typed("two words") == nil)
        #expect(typed("ftp://example.com") == nil)
        #expect(typed("javascript:alert(1)") == nil)
        #expect(typed("http://") == nil)
    }

    @Test func ipAddresses() {
        #expect(PreviewTarget.isIPAddress("203.0.113.5"))
        #expect(PreviewTarget.isIPAddress("fd00::1"))
        #expect(PreviewTarget.isIPAddress("[::1]"))
        #expect(!PreviewTarget.isIPAddress("203.0.113"))
        #expect(!PreviewTarget.isIPAddress("203.0.113.256"))
        #expect(!PreviewTarget.isIPAddress("devbox.local"))
    }
}
