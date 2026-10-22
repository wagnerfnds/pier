import SwiftUI
import AVKit
import CryptoKit
import PierKit

// What an agent shows the person of its work: the captures it handed over with `pierd capture add` (before and after,
// a recording), one gallery at the end of their turn (`ConversationFold`'s `captures`), and the pictures a call
// returned (a browser's screenshot), under that call's detail. A tap opens them full screen: zoom, swipe between them,
// share. docs/API.md §4.10.

/// One picture or recording the gallery and the viewer show.
struct CaptureMedia: Identifiable, Hashable {
    enum Source: Hashable {
        /// A capture the agent handed over.
        case capture(CaptureRef)
        /// Picture `index` of what call `tool` returned.
        case toolImage(tool: String, index: Int)
    }
    let source: Source

    var id: String {
        switch source {
        case .capture(let c): "capture-\(c.id)"
        case .toolImage(let t, let i): "tool-\(t)-\(i)"
        }
    }
    var capture: CaptureRef? { if case .capture(let c) = source { c } else { nil } }
    var caption: String? { capture?.caption.flatMap { $0.isEmpty ? nil : $0 } }
    var isVideo: Bool { capture?.isVideo ?? false }
    var aspect: Double? { capture?.aspect }
    /// "Antes" / "Depois", for a capture that says which it is.
    var badge: String? {
        guard let c = capture else { return nil }
        if c.isBefore { return S("Antes") }
        if c.isAfter { return S("Depois") }
        return nil
    }
    var accessibilityLabel: String {
        let what = isVideo ? S("Gravação") : S("Captura")
        return [badge.map { "\(what), \($0)" } ?? what, caption].compactMap { $0 }.joined(separator: ": ")
    }
}

/// What the viewer shows: the pictures of one gallery and the one tapped.
struct CaptureViewerState: Identifiable {
    let id = UUID()
    let media: [CaptureMedia]
    let start: Int
}

/// The viewer opened away from the session's screen (an Inbox card): where its pictures come from, too.
struct CaptureViewing: Identifiable {
    let loader: CaptureLoader
    let state: CaptureViewerState
    var id: UUID { state.id }
}

enum CaptureLoadError: Error { case unreadable }

/// Where one session's pictures come from: the box, through `CaptureCache`.
struct CaptureLoader {
    let box: String
    let session: String
    let client: any PierBoxClient

    private func key(_ m: CaptureMedia, thumb: Bool) -> String { "\(box)/\(session)/\(m.id)/\(thumb ? "thumb" : "full")" }

    /// The picture, or its small copy when the box keeps one (`thumb`).
    @MainActor func image(_ m: CaptureMedia, thumb: Bool) async throws -> UIImage {
        let small = thumb && (m.capture?.thumb ?? false)
        let client = client, session = session, source = m.source
        return try await CaptureCache.image(key(m, thumb: small), downsample: thumb ? 900 : nil) {
            switch source {
            case .capture(let c): try await client.captureData(session: session, id: c.id, thumb: small)
            case .toolImage(let t, let i): try await client.toolImage(session: session, id: t, index: i)
            }
        }
    }

    /// A recording, as a file the player can open.
    @MainActor func videoFile(_ m: CaptureMedia) async throws -> URL {
        guard case .capture(let c) = m.source else { throw CaptureLoadError.unreadable }
        let client = client, session = session
        return try await CaptureCache.file(key(m, thumb: false), ext: c.type == "video/quicktime" ? "mov" : "mp4") {
            try await client.captureData(session: session, id: c.id, thumb: false)
        }
    }
}

/// Pictures read once: decoded in memory, and their bytes on disk (Caches/Captures, a hash of box, session and
/// capture), since a capture never changes. The demo and the UI tests' mock box keep theirs in memory, as their
/// conversations are (`TranscriptCache`).
@MainActor enum CaptureCache {
    private static let memory: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 96 << 20
        return c
    }()
    private static var inflight: [String: Task<Data, Error>] = [:]
    private static var usesDisk: Bool { !UITestMock.enabled && !DemoMode.isOn }

    /// Asked each time: the demo comes and goes while the app runs.
    private static var folder: URL {
        let base = usesDisk ? (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            : FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Captures", isDirectory: true)
    }

    private static func path(_ key: String, ext: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(digest).appendingPathExtension(ext)
    }

    static func cached(_ key: String) -> UIImage? { memory.object(forKey: key as NSString) }

    /// The bytes: from the disk, from a fetch already on its way, or fetched now (and kept).
    private static func data(_ key: String, ext: String, fetch: @escaping @Sendable () async throws -> Data) async throws -> Data {
        let file = path(key, ext: ext)
        if usesDisk, let d = await Task.detached(operation: { try? Data(contentsOf: file) }).value { return d }
        if let t = inflight[key] { return try await t.value }
        let t = Task { try await fetch() }
        inflight[key] = t
        defer { inflight[key] = nil }
        let d = try await t.value
        if usesDisk { await keep(d, at: file) }
        return d
    }

    private static func keep(_ d: Data, at file: URL) async {
        await Task.detached {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? d.write(to: file, options: .atomic)
        }.value
    }

    /// A picture decoded off the main thread; `downsample` caps its longer side (in pixels) for a tile.
    static func image(_ key: String, downsample: CGFloat?, fetch: @escaping @Sendable () async throws -> Data) async throws -> UIImage {
        let k = key + (downsample.map { "@\(Int($0))" } ?? "")
        if let i = cached(k) { return i }
        let d = try await data(key, ext: "img", fetch: fetch)
        let img = await Task.detached { () -> UIImage? in
            guard let i = UIImage(data: d) else { return nil }
            let px = CGSize(width: i.size.width * i.scale, height: i.size.height * i.scale)
            if let cap = downsample, max(px.width, px.height) > cap {
                let f = cap / max(px.width, px.height)
                return i.preparingThumbnail(of: CGSize(width: (px.width * f).rounded(), height: (px.height * f).rounded()))
            }
            return i.preparingForDisplay() ?? i
        }.value
        guard let img else { throw CaptureLoadError.unreadable }
        memory.setObject(img, forKey: k as NSString, cost: Int(img.size.width * img.size.height * img.scale * img.scale * 4))
        return img
    }

    /// The bytes as a file of their own (a recording, for the player).
    static func file(_ key: String, ext: String, fetch: @escaping @Sendable () async throws -> Data) async throws -> URL {
        let file = path(key, ext: ext)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let d = try await data(key, ext: ext, fetch: fetch)
        if !FileManager.default.fileExists(atPath: file.path) { await keep(d, at: file) }
        return file
    }
}

// MARK: gallery

/// A turn's captures: one strip of tiles under the agent's answer, "Antes" and "Depois" on theirs, each with its caption.
struct CaptureGalleryRow: View {
    let vm: SessionViewModel
    let id: String
    let captures: [CaptureRef]
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let media = captures.map { CaptureMedia(source: .capture($0)) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "camera.viewfinder").font(.caption).foregroundStyle(Theme.textDim)
                Text(captures.count == 1 ? S("1 captura") : S("\(captures.count) capturas")).font(.footnote).foregroundStyle(Theme.textDim)
            }
            .accessibilityHidden(true)
            CaptureStrip(loader: vm.captureLoader, media: media, height: sizeClass == .regular ? 220 : 168) { i in
                vm.viewer = CaptureViewerState(media: media, start: i)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capture-gallery")
    }
}

/// The pictures a call returned, under its detail: smaller tiles, opened the same way.
struct ToolImagesRow: View {
    let vm: SessionViewModel
    let tool: String
    let count: Int

    var body: some View {
        let media = (0..<min(count, 12)).map { CaptureMedia(source: .toolImage(tool: tool, index: $0)) }
        CaptureStrip(loader: vm.captureLoader, media: media, height: 120) { i in
            vm.viewer = CaptureViewerState(media: media, start: i)
        }
        .accessibilityIdentifier("tool-images")
    }
}

struct CaptureStrip: View {
    let loader: CaptureLoader
    let media: [CaptureMedia]
    let height: CGFloat
    let open: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(media.enumerated()), id: \.element.id) { i, m in
                    Button { open(i) } label: { CaptureTile(loader: loader, media: m, height: height) }
                        .buttonStyle(.plain)
                        .hoverEffect(.lift)
                        .accessibilityLabel(m.accessibilityLabel)
                        .accessibilityHint(S("Abre em tela cheia"))
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }
}

/// One tile: the picture's small copy (a recording's play glyph), its badge, and its caption under it.
struct CaptureTile: View {
    let loader: CaptureLoader
    let media: CaptureMedia
    let height: CGFloat
    @State private var image: UIImage?
    @State private var failed = false

    private var width: CGFloat {
        var a: CGFloat = media.isVideo ? 9 / 16 : 16 / 10
        if let image, image.size.height > 0 { a = image.size.width / image.size.height } else if let r = media.aspect { a = CGFloat(r) }
        return min(max(height * a, height * 0.46), height * 1.9)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            content
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
                .overlay(alignment: .topLeading) {
                    if let b = media.badge { CaptureBadge(text: b, after: media.capture?.isAfter == true).padding(7) }
                }
            if let c = media.caption {
                Text(c).font(.caption).foregroundStyle(Theme.textDim).lineLimit(2).multilineTextAlignment(.leading)
                    .frame(width: width, alignment: .leading)
            }
        }
        .task(id: media.id) { await load() }
    }

    @ViewBuilder private var content: some View {
        if media.isVideo {
            ZStack {
                Color.black.opacity(0.85)
                VStack(spacing: 6) {
                    Image(systemName: "play.circle.fill").font(.system(size: 34)).foregroundStyle(.white.opacity(0.92))
                    Text("Gravação").font(.caption2.weight(.medium)).foregroundStyle(.white.opacity(0.75))
                }
            }
        } else if let image {
            Image(uiImage: image).resizable().scaledToFill()
        } else if failed {
            ZStack {
                Theme.cardRaised
                Image(systemName: "photo.badge.exclamationmark").font(.title3).foregroundStyle(Theme.textFaint)
            }
        } else {
            ZStack {
                Theme.cardRaised
                ProgressView().controlSize(.small)
            }
        }
    }

    private func load() async {
        guard !media.isVideo, image == nil else { return }
        do { image = try await loader.image(media, thumb: true); failed = false } catch { failed = true }
    }
}

/// "Antes" (amber) or "Depois" (green) on a tile's corner and over the viewer.
struct CaptureBadge: View {
    let text: String
    let after: Bool
    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background((after ? Theme.green : Theme.orange).opacity(0.92), in: Capsule())
            .accessibilityHidden(true)
    }
}

// MARK: viewer

/// The gallery full screen: one picture at a time on black, pinch or double-tap to zoom, swipe (or ← →) to the next,
/// its badge, caption and Compartilhar; Esc or ✕ closes it.
struct CaptureViewer: View {
    let loader: CaptureLoader
    let state: CaptureViewerState
    @Environment(\.dismiss) private var dismiss
    @State private var page: String
    @State private var images: [String: UIImage] = [:]
    @State private var videos: [String: URL] = [:]

    init(loader: CaptureLoader, state: CaptureViewerState) {
        self.loader = loader
        self.state = state
        // The one tapped, from the first frame.
        _page = State(initialValue: state.media.indices.contains(state.start) ? state.media[state.start].id : state.media.first?.id ?? "")
    }

    private var index: Int { state.media.firstIndex { $0.id == page } ?? 0 }
    private var current: CaptureMedia? { state.media.indices.contains(index) ? state.media[index] : nil }

    var body: some View {
        // The bars above and below the picture, never over it: a light screenshot would hide white controls.
        VStack(spacing: 0) {
            topBar
            TabView(selection: $page) {
                ForEach(state.media) { m in
                    CapturePage(loader: loader, media: m, image: $images[m.id], video: $videos[m.id]).tag(m.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            captionBar
        }
        .background(Color.black.ignoresSafeArea())
        .background(alignment: .center) { keys }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("capture-viewer")
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36).background(.white.opacity(0.14), in: Circle())
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(S("Fechar"))
            if let b = current?.badge { CaptureBadge(text: b, after: current?.capture?.isAfter == true) }
            Spacer()
            if state.media.count > 1 {
                Text(S("\(index + 1) de \(state.media.count)")).font(.footnote.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
            }
            share
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
    }

    @ViewBuilder private var share: some View {
        if let m = current {
            if let url = videos[m.id] {
                ShareLink(item: url) { shareIcon }.accessibilityLabel(S("Compartilhar"))
            } else if let img = images[m.id] {
                let title = m.caption ?? (m.isVideo ? S("Gravação") : S("Captura"))
                ShareLink(item: Image(uiImage: img), preview: SharePreview(title, image: Image(uiImage: img))) { shareIcon }
                    .accessibilityLabel(S("Compartilhar"))
            }
        }
    }

    private var shareIcon: some View {
        Image(systemName: "square.and.arrow.up").font(.body.weight(.semibold)).foregroundStyle(.white)
            .frame(width: 36, height: 36).background(.white.opacity(0.14), in: Circle())
    }

    /// The caption under the picture (room for one either way, so a swipe never moves the picture).
    private var captionBar: some View {
        Text(current?.caption ?? " ").font(.subheadline).foregroundStyle(.white).multilineTextAlignment(.center)
            .lineLimit(3)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 12)
            .opacity(current?.caption == nil ? 0 : 1)
    }

    /// ← and → from a keyboard (the iPad's, the Mac's).
    private var keys: some View {
        HStack {
            Button("") { step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
        }
        .opacity(0).accessibilityHidden(true)
    }

    private func step(_ d: Int) {
        let i = index + d
        guard state.media.indices.contains(i) else { return }
        withAnimation(.snappy) { page = state.media[i].id }
    }
}

/// One page of the viewer: the picture (zoomable) or the recording (a player), loaded on demand.
private struct CapturePage: View {
    let loader: CaptureLoader
    let media: CaptureMedia
    @Binding var image: UIImage?
    @Binding var video: URL?
    @State private var failed = false
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if media.isVideo, let player {
                VideoPlayer(player: player).onDisappear { player.pause() }
            } else if let image, !media.isVideo {
                ZoomableImage(image: image)
            } else if failed {
                VStack(spacing: 10) {
                    Image(systemName: "photo.badge.exclamationmark").font(.largeTitle).foregroundStyle(.white.opacity(0.6))
                    Text("Não deu para abrir a captura").font(.subheadline).foregroundStyle(.white.opacity(0.8))
                    Button("Tentar de novo") { failed = false; Task { await load() } }.buttonStyle(.bordered).tint(.white)
                }
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: media.id) { await load() }
    }

    private func load() async {
        do {
            if media.isVideo {
                if player == nil {
                    let url = try await loader.videoFile(media)
                    video = url
                    player = AVPlayer(url: url)
                }
            } else if image == nil {
                image = try await loader.image(media, thumb: false)
            }
        } catch { failed = true }
    }
}

/// A picture that pinches and double-taps to zoom, centred, fitting the screen at rest.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomingImageView { ZoomingImageView(image: image) }
    func updateUIView(_ view: ZoomingImageView, context: Context) { view.show(image) }
}

final class ZoomingImageView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()

    init(image: UIImage) {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 6
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        addSubview(imageView)
        let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        tap.numberOfTapsRequired = 2
        addGestureRecognizer(tap)
        show(image)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        setZoomScale(1, animated: false)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == 1 { imageView.frame = CGRect(origin: .zero, size: bounds.size); contentSize = bounds.size }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        if zoomScale > 1 {
            setZoomScale(1, animated: true)
        } else {
            let p = g.location(in: imageView)
            let size = CGSize(width: bounds.width / 2.5, height: bounds.height / 2.5)
            zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}
