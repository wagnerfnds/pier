// Spike (Track 7): the preview browser's container (PreviewBrowser.swift) and the Home's in-app Safari (HomeSupport.swift)
// on the native Mac. WKWebView is an NSView there, so the container is the same idea; Safari's view controller does not
// exist on the Mac, where pages open in the default browser (as the Catalyst build already does).
#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import SwiftUI
import WebKit

/// Where a browser's web view goes: the newest container in a window takes it, one leaving gives it back.
final class PreviewWebContainer: NSView {
    var browser: PreviewBrowserModel?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let browser else { return }
        if window != nil { browser.attach(self) } else { browser.left(self) }
    }
}

struct PreviewWebView: NSViewRepresentable {
    let browser: PreviewBrowserModel

    func makeNSView(context: Context) -> PreviewWebContainer {
        let c = PreviewWebContainer()
        c.browser = browser
        c.wantsLayer = true
        c.layer?.backgroundColor = NSColor(Theme.bg).cgColor
        return c
    }

    func updateNSView(_ c: PreviewWebContainer, context: Context) {
        guard c.browser !== browser else { return }
        c.browser?.left(c)
        c.browser = browser
        if c.window != nil { browser.attach(c) }
    }

    static func dismantleNSView(_ c: PreviewWebContainer, coordinator: ()) {
        c.browser?.left(c)
        c.browser = nil
    }
}

/// The Home opens pages in the default browser on the Mac (`DashboardView`'s `openURL`), so this sheet never shows; it
/// opens the page there all the same if something presents it.
struct SafariView: View {
    let url: URL
    var body: some View {
        Color.clear.onAppear { NSWorkspace.shared.open(url) }
    }
}
#endif
