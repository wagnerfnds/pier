import SwiftUI
import WebKit
import PierKit

// A worktree's page in the app's own browser: its dev server at the box's address and port when this device reaches it
// (on the same network, or over a VPN), else the server's public link, picked by `PreviewTarget` (PierKit). It shows as a
// session's Navegador tab, beside the conversation like its terminals (SessionTerminals.swift), and as a screen of its own
// from Detalhes ("Abrir no Pier"); both show the worktree's one web view, so the page and its history are the same. A
// dev server's hot reload works as in Safari: plain http and websockets to a host on the network are allowed for web
// content (`NSAllowsArbitraryLoadsInWebContent`, `NSAllowsLocalNetworking`).

// MARK: - model

/// Every worktree's browser opened while the app runs, by "box/location/worktree". Only the few shown last keep their web
/// view (each holds a web content process); an older one starts again from its last page when it shows.
@MainActor
final class PreviewBrowsers {
    static let shared = PreviewBrowsers()
    private var models: [String: PreviewBrowserModel] = [:]
    private var recent: [String] = []
    private static let kept = Platform.isMac ? 3 : 2

    static func key(box: String, location: String, worktree: String) -> String { "\(box)/\(location)/\(worktree)" }

    /// The worktree's browser, made the first time it is asked for.
    func model(box: String, location: String, worktree: String) -> PreviewBrowserModel {
        let key = Self.key(box: box, location: location, worktree: worktree)
        if let m = models[key] { return m }
        let m = PreviewBrowserModel(box: box, location: location, worktree: worktree)
        models[key] = m
        return m
    }

    /// The worktree's browser, if one was opened.
    func existing(box: String, location: String, worktree: String) -> PreviewBrowserModel? {
        models[Self.key(box: box, location: location, worktree: worktree)]
    }

    /// `m` shows: it keeps its web view, and the one shown longest ago past `kept` lets go of its own.
    fileprivate func shown(_ m: PreviewBrowserModel) {
        recent.removeAll { $0 == m.key }
        recent.append(m.key)
        while recent.count > Self.kept { models[recent.removeFirst()]?.releaseWebView() }
    }
}

/// One worktree's browser for the app's run: the page picked for it, the page shown last, and its web view while it is
/// one of the few kept. The bar reads the web view's state from here.
@MainActor @Observable
final class PreviewBrowserModel {
    let box: String
    let location: String
    let worktree: String
    var key: String { PreviewBrowsers.key(box: box, location: location, worktree: worktree) }

    /// Its tab is open beside the worktree's sessions (Detalhes' screen of its own does not open it).
    var tabOpen = false
    /// The page picked for the worktree; nil until picked.
    private(set) var target: PreviewTarget?
    private(set) var choosing = false
    /// The page asked for, until it starts to show (the address shows it meanwhile, and after it failed to load).
    private(set) var requested: URL?
    /// The worktree's own port ($PIER_PORT), where its dev server is expected.
    private(set) var port: Int?
    /// The web page shown last, for the app's run: a browser opened again starts from it.
    private(set) var lastURL: URL?
    /// The web view's own state, for the bar.
    private(set) var url: URL?
    private(set) var title: String?
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    /// Why the page did not load (the server is down, out of reach…), until the next load.
    var failure: String?

    @ObservationIgnored private(set) var webView: WKWebView?
    @ObservationIgnored private var delegate: PreviewBrowserDelegate?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// The views the web view can go in: the newest in a window holds it.
    @ObservationIgnored private var containers: [WeakContainer] = []
    @ObservationIgnored private weak var model: AppModel?
    /// The mock or the demo's box: its pages are drawn here, nothing is fetched (UI tests have no network).
    @ObservationIgnored private var mock = false

    init(box: String, location: String, worktree: String) {
        self.box = box
        self.location = location
        self.worktree = worktree
    }

    /// The view shows: `open` when given (a link's Abrir no Pier), else the page shown already, else the last one, else
    /// the one picked for the worktree.
    func start(model: AppModel, open: URL?) async {
        self.model = model
        mock = model.connection(for: box)?.raw is MockBox
        if let open {
            if open != url { go(to: open) }
            return
        }
        if url != nil || requested != nil { return }
        if let lastURL { go(to: lastURL); return }
        await pick()
    }

    /// Picks the worktree's page again and opens it (nothing shows yet: the dev server may have come up since).
    func pick() async {
        await choose()
        // Not over a page the person asked for meanwhile (typed while this looked).
        if let u = target?.url, url == nil, requested == nil { go(to: u) }
    }

    /// The worktree's dev servers (`GET /v1/services`), whether this device reaches their ports at the box's address
    /// (`PortProbe`, as Detalhes checks them) and their public links, as `PreviewTarget` weighs them.
    func choose() async {
        guard !choosing, let model else { return }
        guard let conn = model.connection(for: box) else {
            // The box is gone (unpaired): no page to look for, and the address can still be typed.
            if target == nil { target = .noServer }
            return
        }
        choosing = true
        defer { choosing = false }
        let api = BoxAPI(transport: conn.raw)
        let wt = conn.location(named: location)?.worktrees?.first { $0.name == worktree }
        var servers: [BoxService] = []
        if let wt, let all = try? await api.services() { servers = Projects.devServers(all, location: location, worktree: wt) }
        var links: [PublicLink] = []
        if conn.info?.has("shares") == true, let all = try? await api.publicLinks() {
            links = all.filter { $0.location == location && $0.worktree == worktree }
        }
        let host = conn.record.host
        var reach: [Int: Bool] = [:]
        if mock {
            // Nothing is reached on the mock's made-up address: its servers count as reached, and their page is drawn here.
            for s in servers { reach[s.port] = true }
        } else {
            await withTaskGroup(of: (Int, Bool).self) { g in
                for p in Set(servers.map(\.port)) { g.addTask { (p, await PortProbe.reachable(host: host, port: p)) } }
                for await (p, ok) in g { reach[p] = ok }
            }
        }
        let t = PreviewTarget.choose(servers: servers, worktreePort: wt?.port, host: host, reachable: reach, links: links)
        if t != target { target = t }
        if port != wt?.port { port = wt?.port }
    }

    func go(to u: URL) {
        let web = ensureWebView()
        failure = nil
        requested = u
        if Self.isWeb(u) { lastURL = u }
        if mock, Self.isWeb(u) {
            web.loadHTMLString(Self.mockPage(u, project: location), baseURL: u)
        } else {
            web.load(URLRequest(url: u))
        }
    }

    /// The page again; after a failure, the one that failed; with nothing shown, the one picked again.
    func reload() {
        let failed = failure != nil
        failure = nil
        if let web = webView, let current = web.url, !failed {
            if mock { go(to: current) } else { web.reload() }
        } else if let u = requested ?? lastURL {
            go(to: u)
        } else {
            Task { await pick() }
        }
    }

    func stop() { webView?.stopLoading() }
    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    /// The web view goes (its tab closed, or shown longest ago): the page shown last stays, for when it opens again.
    func releaseWebView() {
        guard let web = webView else { return }
        observations.forEach { $0.invalidate() }
        observations = []
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        web.removeFromSuperview()
        webView = nil
        delegate = nil
        requested = nil
        failure = nil
        url = nil
        title = nil
        canGoBack = false
        canGoForward = false
        isLoading = false
        progress = 0
    }

    // MARK: the web view

    private func ensureWebView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        // The default persistent store: a page's login and settings stay, as in Safari.
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.allowsBackForwardNavigationGestures = true
        #if DEBUG
        // Debug builds only: Safari's Web Inspector could otherwise read what the person is signed in to on the page.
        web.isInspectable = true
        #endif
        let d = PreviewBrowserDelegate(owner: self)
        web.navigationDelegate = d
        web.uiDelegate = d
        delegate = d
        // WebKit changes these on the main thread.
        observations = [
            web.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            web.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            web.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            web.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            web.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            web.observe(\.estimatedProgress) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
        ]
        webView = web
        return web
    }

    private func sync() {
        guard let web = webView else { return }
        if url != web.url { url = web.url }
        let t = web.title.flatMap { $0.isEmpty ? nil : $0 }
        if title != t { title = t }
        if canGoBack != web.canGoBack { canGoBack = web.canGoBack }
        if canGoForward != web.canGoForward { canGoForward = web.canGoForward }
        if isLoading != web.isLoading { isLoading = web.isLoading }
        let p = web.estimatedProgress
        if abs(p - progress) >= 0.05 || (p >= 1) != (progress >= 1) { progress = p }
        // A page within a single-page app (pushState) changes the address too: the last page follows it.
        if let u = web.url, Self.isWeb(u), u != lastURL { lastURL = u }
    }

    /// The page asked for starts to show: the address follows the web view from here.
    fileprivate func committed() {
        if requested != nil { requested = nil }
        if failure != nil { failure = nil }
    }

    fileprivate func failed(_ error: Error) {
        let e = error as NSError
        // A load another one replaced, and a response WebKit hands elsewhere (a download), are no failures.
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" && e.code == 102 { return }
        failure = e.localizedDescription
    }

    /// `c` is in a window: the web view goes in it, and a page it held before it was let go of comes back.
    fileprivate func attach(_ c: PreviewWebContainer) {
        containers.removeAll { $0.view == nil || $0.view === c }
        containers.append(WeakContainer(view: c))
        let fresh = webView == nil
        let web = ensureWebView()
        if web.superview !== c {
            web.removeFromSuperview()
            web.frame = c.bounds
            web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            c.addSubview(web)
        }
        // After the update that put the view in its window: the bar's state changes with what follows.
        Task { @MainActor in
            PreviewBrowsers.shared.shown(self)
            if fresh, self.requested == nil, self.url == nil, let last = self.lastURL { self.go(to: last) }
        }
    }

    /// `c` left its window, or went: another container still in one (the screen under one popped) takes the web view.
    fileprivate func left(_ c: PreviewWebContainer) {
        containers.removeAll { $0.view == nil || $0.view === c }
        guard let web = webView, web.superview === c || web.superview == nil,
              let other = containers.last(where: { $0.view?.window != nil })?.view else { return }
        attach(other)
    }

    private struct WeakContainer { weak var view: PreviewWebContainer? }

    private static func isWeb(_ u: URL) -> Bool { ["http", "https"].contains(u.scheme?.lowercased() ?? "") }

    /// The mock's page for a dev server: what a box of the person's own would show there, drawn here (nothing fetched).
    private static func mockPage(_ u: URL, project: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let kicker = esc(S("Página de exemplo"))
        let line = esc(S("Numa box sua, aqui aparece o servidor de desenvolvimento desta worktree, com hot reload."))
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(project))</title><style>
        :root { color-scheme: light dark; --bg: #f4f5f7; --card: #fff; --text: #1c2024; --dim: #59616b; --accent: #0a67d0; }
        @media (prefers-color-scheme: dark) { :root { --bg: #16181b; --card: #1e2126; --text: #e6e8eb; --dim: #8b9199; --accent: #4a99fa; } }
        body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: var(--bg); color: var(--text);
               font: 15px -apple-system, system-ui, sans-serif; }
        main { background: var(--card); border-radius: 16px; padding: 32px 36px; max-width: 420px; margin: 24px;
               box-shadow: 0 1px 3px rgba(0,0,0,.08); }
        p.kicker { margin: 0 0 6px; color: var(--accent); font-weight: 600; font-size: 13px; letter-spacing: .02em; }
        h1 { margin: 0 0 12px; font-size: 28px; }
        p { margin: 0 0 14px; color: var(--dim); line-height: 1.45; }
        code { font: 12.5px ui-monospace, Menlo, monospace; color: var(--text); }
        </style></head><body><main><p class="kicker">\(kicker)</p><h1>\(esc(project))</h1><p>\(line)</p>
        <code>\(esc(u.absoluteString))</code></main></body></html>
        """
    }
}

/// The web view's navigation and windows, for its browser: a failed load is said over the page, a link that opens a
/// window opens here, and what is no web page (mail, a phone number, an app's link) goes to the system.
@MainActor
private final class PreviewBrowserDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var owner: PreviewBrowserModel?

    init(owner: PreviewBrowserModel) { self.owner = owner }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let u = navigationAction.request.url, let scheme = u.scheme?.lowercased() else { return .allow }
        if ["http", "https", "about", "data", "blob"].contains(scheme) { return .allow }
        // Mail, a phone number, a message go to the system; nothing else a page asks for leaves the browser (the app's
        // own pier:// links included: a page must not open sessions or pair a box).
        if ["mailto", "tel", "sms"].contains(scheme) { _ = await UIApplication.shared.open(u) }
        return .cancel
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { owner?.failure = nil }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { owner?.committed() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { owner?.failure = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { owner?.failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { owner?.failed(error) }

    /// When the page's process ended lately.
    private var ended: [Date] = []

    /// The page's process ended (memory, a crash): the page loads again, unless it ended twice in half a minute (a page
    /// too heavy for the device would load and end forever): then it says so, with Tentar de novo.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        ended = ended.filter { now.timeIntervalSince($0) < 30 } + [now]
        if ended.count >= 3 {
            ended = []
            owner?.failure = S("A página parou de responder várias vezes seguidas.")
        } else {
            webView.reload()
        }
    }

    /// `target="_blank"` and `window.open`: in this same view, which has no other windows.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

/// Where a browser's web view goes. The web view is the worktree's, kept while the app runs: the newest container in a
/// window takes it (a browser shows in one place at a time), and one leaving gives it back to another still in one.
final class PreviewWebContainer: UIView {
    var browser: PreviewBrowserModel?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let browser else { return }
        if window != nil { browser.attach(self) } else { browser.left(self) }
    }
}

private struct PreviewWebView: UIViewRepresentable {
    let browser: PreviewBrowserModel

    func makeUIView(context: Context) -> PreviewWebContainer {
        let c = PreviewWebContainer()
        c.browser = browser
        c.backgroundColor = UIColor(Theme.bg)
        return c
    }

    func updateUIView(_ c: PreviewWebContainer, context: Context) {
        guard c.browser !== browser else { return }
        c.browser?.left(c)
        c.browser = browser
        if c.window != nil { browser.attach(c) }
    }

    static func dismantleUIView(_ c: PreviewWebContainer, coordinator: ()) {
        c.browser?.left(c)
        c.browser = nil
    }
}

// MARK: - the view

/// A worktree's page under a minimal bar: back, forward, reload or stop, the address (typed into: Return goes there),
/// copy the link, open it in the system's browser. Over the page, what is going on when there is none: the page being
/// looked for, why there is none (no dev server, one out of reach), or why it did not load.
struct PreviewBrowser: View {
    let browser: PreviewBrowserModel
    /// A page to open first (a link's Abrir no Pier); nil: the page shown already, else the last one, else the one picked.
    var open: URL? = nil
    /// The worktree's Detalhes are a tap away (not on the screen Detalhes opened).
    var offersDetails = true

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var address = ""
    @State private var invalid = false
    @State private var opened = false
    @FocusState private var editing: Bool

    /// What the address shows: the page asked for until it starts to show (or after it failed to load), else the page.
    private var shown: URL? { browser.requested ?? browser.url }

    var body: some View {
        VStack(spacing: 0) {
            bar
            ZStack {
                PreviewWebView(browser: browser)
                overlay
            }
            .frame(maxHeight: .infinity)
        }
        .background(Theme.bg)
        .task {
            // `open` once: coming back to this screen keeps where the person went from there.
            let first = opened ? nil : open
            opened = true
            await browser.start(model: model, open: first)
        }
        .onChange(of: shown, initial: true) { _, u in if !editing { address = u.map(Self.display) ?? "" } }
        .onChange(of: editing) { _, now in if !now { invalid = false; address = shown.map(Self.display) ?? "" } }
        .accessibilityIdentifier("preview-browser")
    }

    /// The address as people read it: about:blank and a data page's long text are left out.
    private static func display(_ u: URL) -> String {
        let s = u.absoluteString
        if s == "about:blank" || s.hasPrefix("data:") { return "" }
        return s
    }

    // MARK: bar

    private var bar: some View {
        HStack(spacing: 2) {
            barButton("chevron.left", S("Voltar"), id: "browser-back", disabled: !browser.canGoBack) { browser.goBack() }
            barButton("chevron.right", S("Avançar"), id: "browser-forward", disabled: !browser.canGoForward) { browser.goForward() }
            if browser.isLoading {
                barButton("xmark", S("Parar"), id: "browser-stop") { browser.stop() }
            } else {
                barButton("arrow.clockwise", S("Recarregar"), id: "browser-reload") { browser.reload() }
            }
            field
                .padding(.horizontal, 4)
            barButton("doc.on.doc", S("Copiar link"), id: "browser-copy", disabled: shown == nil || Self.display(shown!).isEmpty) {
                guard let u = shown else { return }
                UIPasteboard.general.string = u.absoluteString
                model.showToast(S("Link copiado"), symbol: "link")
            }
            barButton("safari", S("Abrir no navegador padrão"), id: "browser-system", disabled: shown.map { !Self.isWeb($0) } ?? true) {
                if let u = shown { openURL(u) }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: Platform.isMac ? 38 : 46)
        .background(Theme.bg)
        .overlay(alignment: .bottom) {
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.stroke).frame(height: 1)
                if browser.isLoading {
                    GeometryReader { g in
                        Rectangle().fill(Theme.accent).frame(width: g.size.width * max(0.08, browser.progress), height: 2)
                    }
                    .frame(height: 2)
                }
            }
            .frame(height: 2, alignment: .bottom)
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: shown?.scheme?.lowercased() == "https" ? "lock.fill" : "globe")
                .font(.system(size: Density.small - 1)).foregroundStyle(Theme.textFaint)
                .accessibilityHidden(true)
            ZStack(alignment: .leading) {
                TextField(S("Endereço"), text: $address)
                    .textFieldStyle(.plain)
                    .font(.system(size: Density.small + 1))
                    .foregroundStyle(Theme.text)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($editing)
                    .onSubmit(go)
                    .opacity(editing || compactAddress == nil ? 1 : 0)
                    .accessibilityIdentifier("browser-address")
                // Not editing: the page's host and path, as Safari shows them, the whole address a click away.
                if !editing, let short = compactAddress {
                    Text(verbatim: short).font(.system(size: Density.small + 1)).foregroundStyle(Theme.text)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { editing = true }
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Platform.isMac ? 26 : 34)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(invalid ? Theme.red : editing ? Theme.accent.opacity(0.5) : Theme.stroke)
        }
        .frame(maxWidth: .infinity)
    }

    /// The address without its scheme and a lone trailing slash ("p-….docktopier.com/login"); nil when none shows.
    private var compactAddress: String? {
        guard let u = shown, Self.isWeb(u) else { return nil }
        var s = u.absoluteString
        for p in ["https://", "http://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
        if s.hasSuffix("/"), s.filter({ $0 == "/" }).count == 1 { s.removeLast() }
        return s
    }

    private func barButton(_ symbol: String, _ label: String, id: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: Density.small + 2, weight: .medium))
                .foregroundStyle(disabled ? Theme.textFaint.opacity(0.5) : Theme.textDim)
                .frame(width: Platform.isMac ? 26 : 34, height: Platform.isMac ? 26 : 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    /// Return in the address: there, when it reads as one.
    private func go() {
        guard let u = PreviewTarget.url(typed: address) else {
            invalid = !address.trimmingCharacters(in: .whitespaces).isEmpty
            return
        }
        invalid = false
        editing = false
        browser.go(to: u)
    }

    private static func isWeb(_ u: URL) -> Bool { ["http", "https"].contains(u.scheme?.lowercased() ?? "") }

    // MARK: over the page

    @ViewBuilder private var overlay: some View {
        if let why = browser.failure {
            notice(symbol: "exclamationmark.triangle", title: S("Não foi possível abrir a página"), text: why, retry: { browser.reload() })
        } else if shown == nil {
            if browser.choosing || browser.target == nil {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Procurando a página da worktree…").font(.callout).foregroundStyle(Theme.textDim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
            } else if case .unreachable(let port)? = browser.target {
                // Ports as text: a number in the person's format would read "41.010" in Portuguese.
                notice(symbol: "wifi.exclamationmark", title: S("O servidor na porta \(String(port)) não é alcançado deste aparelho"),
                       text: S("Crie um link público para ele nos Detalhes da worktree, ou use a mesma rede da box (ou uma VPN)."),
                       retry: { Task { await browser.pick() } })
                    .task(id: scenePhase == .active) { await watch() }
            } else {
                notice(symbol: "globe", title: S("Nenhum servidor de desenvolvimento nesta worktree"),
                       text: browser.port.map { S("Suba o servidor dela na porta \(String($0)) ($PIER_PORT), num terminal ao lado ou pelos serviços nos Detalhes: a página aparece aqui assim que ele responder.") }
                           ?? S("Suba o servidor de desenvolvimento dela, num terminal ao lado ou pelos serviços nos Detalhes: a página aparece aqui assim que ele responder."),
                       retry: { Task { await browser.pick() } })
                    .task(id: scenePhase == .active) { await watch() }
            }
        }
    }

    /// While there is no page, the worktree is looked at again every few seconds: a dev server started beside it (in a
    /// terminal, by the agent) shows here by itself.
    private func watch() async {
        // Only while the app is in front: on the Mac a window behind others would otherwise ask the box all day.
        guard scenePhase == .active else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(4))
            if Task.isCancelled || shown != nil { return }
            await browser.pick()
        }
    }

    private func notice(symbol: String, title: String, text: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.textDim)
                .frame(width: 44, height: 44)
                .background(Theme.cardRaised, in: Circle())
                .padding(.bottom, 2)
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).multilineTextAlignment(.center)
            Text(text).font(.footnote).foregroundStyle(Theme.textDim).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(action: retry) { Label("Tentar de novo", systemImage: "arrow.clockwise") }
                    .accessibilityIdentifier("browser-retry")
                if offersDetails {
                    Button {
                        router.push(WorktreeDetailsRoute(box: browser.box, location: browser.location, worktree: browser.worktree))
                    } label: { Label("Detalhes", systemImage: "server.rack") }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser-notice")
    }
}

// MARK: - a screen of its own

/// A worktree's page on a screen of its own: Detalhes' "Abrir no Pier" beside a dev server's link or its public link
/// (Debug: `-openBrowser <loc>[/<worktree>]`, `-browserURL <url>`).
struct PreviewBrowserRoute: Hashable {
    let box: String
    let location: String
    let worktree: String
    /// The page to open; nil: the one shown last, else the one picked for the worktree.
    var url: URL? = nil
}

struct PreviewBrowserScreen: View {
    let route: PreviewBrowserRoute
    @State private var browser: PreviewBrowserModel

    init(route: PreviewBrowserRoute) {
        self.route = route
        _browser = State(initialValue: PreviewBrowsers.shared.model(box: route.box, location: route.location, worktree: route.worktree))
    }

    var body: some View {
        PreviewBrowser(browser: browser, open: route.url, offersDetails: false)
            .navigationTitle(browser.title ?? S("Navegador"))
            .navigationBarTitleDisplayMode(.inline)
    }

    #if DEBUG
    /// `-openBrowser <loc>[/<worktree>]` (with `-browserURL <url>`): the worktree's browser at launch, as Abrir no Pier
    /// opens it.
    @MainActor static func openIfRequested(_ model: AppModel) {
        guard let spec = UserDefaults.standard.string(forKey: "openBrowser") else { return }
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard let c = model.boxes.first else { return }
            let parts = spec.split(separator: "/", maxSplits: 1).map(String.init)
            let main = c.location(named: parts[0])?.worktrees?.first { $0.main == true }?.name ?? parts[0]
            let url = UserDefaults.standard.string(forKey: "browserURL").flatMap(PreviewTarget.url(typed:))
            model.router.push(PreviewBrowserRoute(box: c.name, location: parts[0], worktree: parts.count > 1 ? parts[1] : main, url: url))
        }
    }
    #endif
}

/// Detalhes' "Abrir no Pier" beside a dev server's link or a public link: the page in the app's browser, on a screen of
/// its own (the worktree's browser: the same page and history as its sessions' Navegador tab).
struct PreviewOpenButton: View {
    let box: String
    let location: String
    let worktree: String
    let url: URL
    @Environment(Router.self) private var router

    var body: some View {
        Button {
            router.push(PreviewBrowserRoute(box: box, location: location, worktree: worktree, url: url))
        } label: { Image(systemName: "macwindow") }
        .buttonStyle(.borderless)
        .help("Abrir no Pier")
        .accessibilityLabel("Abrir no Pier")
        .accessibilityIdentifier("preview-open-\(url.absoluteString)")
    }
}
