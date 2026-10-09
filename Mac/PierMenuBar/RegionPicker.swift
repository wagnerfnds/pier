import AppKit
import ScreenCaptureKit

/// "Point at it": the screen dims, the person drags a rectangle over whatever they mean, and that part of the screen
/// becomes a picture for Falar. Esc or a click without a drag cancels. The capture is ScreenCaptureKit's screenshot
/// (macOS 14), which needs the Screen Recording permission: checked first (`CGPreflightScreenCaptureAccess`), asked for
/// only when the person reaches for the feature (`CGRequestScreenCaptureAccess`), never at launch.
@MainActor final class RegionPicker {
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }
    /// The system dialog (once); later changes happen in System Settings → Privacy → Screen Recording, after a relaunch.
    @discardableResult static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    private var overlays: [OverlayPanel] = []
    private var monitor: Any?
    private let completion: (NSImage?) -> Void
    private let fake: NSImage?
    private var done = false

    /// `fake`: tests and screenshots use this picture instead of the screen (no permission involved).
    init(fake: NSImage?, completion: @escaping (NSImage?) -> Void) {
        self.fake = fake
        self.completion = completion
    }

    func start() {
        for screen in NSScreen.screens {
            let o = OverlayPanel(screen: screen)
            o.onSelect = { [weak self] rect in self?.selected(rect, on: screen) }
            o.onCancel = { [weak self] in self?.finish(nil) }
            o.orderFrontRegardless()
            o.makeKey()
            overlays.append(o)
        }
        NSCursor.crosshair.push()
    }

    /// Screenshots: draws the selection by itself, then takes the picture.
    func demo(rect: NSRect, on screen: NSScreen, after: TimeInterval = 1.2) {
        guard let o = overlays.first(where: { $0.screen == screen }) else { return }
        o.showSelection(rect)
        DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
            MainActor.assumeIsolated { self?.selected(rect, on: screen) }
        }
    }

    private func selected(_ rect: NSRect, on screen: NSScreen) {
        guard rect.width >= 8, rect.height >= 8 else { finish(nil); return }
        if let fake {
            // The chosen part of the stand-in picture, so the flow is the real one up to the capture itself.
            finish(Self.crop(fake, rect: rect, screen: screen))
            return
        }
        // The overlays leave the screen before the capture, so the dimming is never in the picture.
        for o in overlays { o.orderOut(nil) }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            let image = await Self.capture(rect, on: screen)
            self.finish(image)
        }
    }

    private func finish(_ image: NSImage?) {
        guard !done else { return }
        done = true
        NSCursor.pop()
        for o in overlays { o.orderOut(nil); o.close() }
        overlays = []
        completion(image)
    }

    /// ScreenCaptureKit's screenshot of `rect` (screen coordinates, AppKit) at the screen's scale.
    static func capture(_ rect: NSRect, on screen: NSScreen) async -> NSImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { Int($0.displayID) == screen.displayID }) else { return nil }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // The display's own coordinates: origin at its top-left corner, in points.
        let local = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        config.sourceRect = local
        let scale = screen.backingScaleFactor
        config.width = Int(rect.width * scale)
        config.height = Int(rect.height * scale)
        config.scalesToFit = false
        config.showsCursor = false
        guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        return NSImage(cgImage: cg, size: rect.size)
    }

    private static func crop(_ image: NSImage, rect: NSRect, screen: NSScreen) -> NSImage? {
        let sx = image.size.width / screen.frame.width, sy = image.size.height / screen.frame.height
        let src = NSRect(x: (rect.minX - screen.frame.minX) * sx, y: (rect.minY - screen.frame.minY) * sy, width: rect.width * sx, height: rect.height * sy)
        let out = NSImage(size: rect.size, flipped: false) { dst in
            image.draw(in: dst, from: src, operation: .copy, fraction: 1)
            return true
        }
        return out
    }
}

/// One dimmed, click-through-less panel per screen; draws the rectangle being dragged.
final class OverlayPanel: NSPanel {
    var onSelect: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?
    private let view = OverlayView()

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        contentView = view
        view.onSelect = { [weak self] r in self?.onSelect?(r) }
        view.onCancel = { [weak self] in self?.onCancel?() }
    }
    override var canBecomeKey: Bool { true }

    func showSelection(_ rect: NSRect) { view.show(rect) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

final class OverlayView: NSView {
    var onSelect: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?
    private var start: NSPoint?
    private var rect: NSRect?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()
        guard let rect else { return }
        // The chosen part shows as is; a hairline and its size around it.
        NSColor.clear.setFill()
        rect.fill(using: .copy)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let p = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        p.lineWidth = 1
        p.stroke()
        let label = "\(Int(rect.width)) × \(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let s = (label as NSString).size(withAttributes: attrs)
        let box = NSRect(x: rect.minX, y: rect.minY - s.height - 10, width: s.width + 12, height: s.height + 6)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        (label as NSString).draw(at: NSPoint(x: box.minX + 6, y: box.minY + 3), withAttributes: attrs)
    }

    func show(_ r: NSRect) {
        guard let window else { return }
        rect = NSRect(x: r.minX - window.frame.minX, y: r.minY - window.frame.minY, width: r.width, height: r.height)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        rect = nil
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let p = convert(event.locationInWindow, from: nil)
        rect = NSRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { start = nil }
        guard let window, let rect, rect.width >= 8, rect.height >= 8 else { onCancel?(); return }
        onSelect?(NSRect(x: rect.minX + window.frame.minX, y: rect.minY + window.frame.minY, width: rect.width, height: rect.height))
    }
}
