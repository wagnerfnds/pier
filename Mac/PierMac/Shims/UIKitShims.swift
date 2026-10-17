// Spike (Track 7): thin stand-ins for the UIKit names App/ uses, so the shared code compiles as a native macOS app
// unchanged wherever the meaning carries over (a copy to the pasteboard, a URL opened, a color, an image resized). They
// keep the UIKit spelling only to keep the shared files as they are; a real migration would give them neutral names
// (Pasteboard.copy, PlatformImage, …) and delete this file.
#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

typealias UIColor = NSColor
typealias UIImage = NSImage
typealias UIFont = NSFont
typealias UIEdgeInsets = NSEdgeInsets

// MARK: images

extension NSImage {
    /// UIKit's `UIImage(cgImage:)`: the bitmap at one point per pixel.
    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private var bitmap: NSBitmapImageRep? {
        if let rep = representations.first as? NSBitmapImageRep { return rep }
        guard let tiff = tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    func pngData() -> Data? { bitmap?.representation(using: .png, properties: [:]) }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        bitmap?.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
}

extension Image {
    init(uiImage: NSImage) { self.init(nsImage: uiImage) }
}

/// UIKit's renderer: a bitmap at `scale`, drawn with the origin at the top left like UIKit's, AppKit drawing (NSString,
/// NSImage, NSColor.setFill) going to it.
final class UIGraphicsImageRendererFormat {
    var scale: CGFloat = 1
    var opaque = false
    init() {}
}

final class UIGraphicsImageRendererContext {
    let cgContext: CGContext
    init(cgContext: CGContext) { self.cgContext = cgContext }
    func fill(_ rect: CGRect) { cgContext.fill(rect) }
}

final class UIGraphicsImageRenderer {
    private let size: CGSize
    private let scale: CGFloat

    init(size: CGSize, format: UIGraphicsImageRendererFormat = UIGraphicsImageRendererFormat()) {
        self.size = size
        self.scale = max(1, format.scale)
    }

    init(bounds: CGRect) {
        self.size = bounds.size
        self.scale = NSScreen.main?.backingScaleFactor ?? 2
    }

    func image(actions: (UIGraphicsImageRendererContext) -> Void) -> NSImage {
        let w = max(1, Int((size.width * scale).rounded())), h = max(1, Int((size.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ns = NSGraphicsContext(bitmapImageRep: rep) else { return NSImage(size: size) }
        rep.size = size
        let cg = ns.cgContext
        // UIKit's coordinates: the origin at the top left, y down.
        cg.translateBy(x: 0, y: CGFloat(h))
        cg.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        actions(UIGraphicsImageRendererContext(cgContext: cg))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}

// MARK: the pasteboard

final class UIPasteboard: @unchecked Sendable {
    static let general = UIPasteboard()

    var string: String? {
        get { NSPasteboard.general.string(forType: .string) }
        set {
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.setString(newValue, forType: .string) }
        }
    }

    var hasStrings: Bool { NSPasteboard.general.availableType(from: [.string]) != nil }
}

// MARK: the application, the device, the screen

struct UIBackgroundTaskIdentifier: Equatable, Sendable {
    let rawValue: Int
    static let invalid = UIBackgroundTaskIdentifier(rawValue: 0)
}

/// A Mac app is never suspended: a "background task" has nothing to hold, and "background" is the app hidden.
@MainActor final class UIApplication {
    static let shared = UIApplication()

    nonisolated static let openSettingsURLString = "x-apple.systempreferences:"
    nonisolated static let didEnterBackgroundNotification = NSApplication.didHideNotification
    nonisolated static let willEnterForegroundNotification = NSApplication.willUnhideNotification
    nonisolated static let didBecomeActiveNotification = NSApplication.didBecomeActiveNotification
    nonisolated static let willResignActiveNotification = NSApplication.willResignActiveNotification
    nonisolated static let willTerminateNotification = NSApplication.willTerminateNotification

    enum State { case active, inactive, background }

    var applicationState: State { NSApp.isHidden ? .background : NSApp.isActive ? .active : .inactive }

    func open(_ url: URL, options: [String: Any] = [:], completionHandler: ((Bool) -> Void)? = nil) {
        let opened = NSWorkspace.shared.open(url)
        completionHandler?(opened)
    }

    func open(_ url: URL, options: [String: Any] = [:]) async -> Bool { NSWorkspace.shared.open(url) }

    func registerForRemoteNotifications() { NSApplication.shared.registerForRemoteNotifications() }

    func beginBackgroundTask(withName name: String?, expirationHandler: (() -> Void)? = nil) -> UIBackgroundTaskIdentifier { .invalid }

    func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) {}

    @discardableResult
    func sendAction(_ action: Selector, to target: Any?, from sender: Any?, for event: Any?) -> Bool {
        NSApp.sendAction(action, to: target, from: sender)
    }
}

enum UIUserInterfaceIdiom { case unspecified, phone, pad, mac }

@MainActor final class UIDevice {
    static let current = UIDevice()
    var userInterfaceIdiom: UIUserInterfaceIdiom { .mac }
    var name: String { Host.current().localizedName ?? "Mac" }
    var model: String { "Mac" }
}

@MainActor final class UIScreen {
    static let main = UIScreen()
    var bounds: CGRect { NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900) }
    var scale: CGFloat { NSScreen.main?.backingScaleFactor ?? 2 }
}

/// No Dynamic Type on the Mac: sizes stay as given.
struct UIFontMetrics {
    init(forTextStyle style: NSFont.TextStyle) {}
    func scaledValue(for value: CGFloat) -> CGFloat { value }
}

// MARK: haptics (none on the Mac; UIKit's do nothing there either)

final class UIImpactFeedbackGenerator {
    enum FeedbackStyle { case light, medium, heavy, soft, rigid }
    init(style: FeedbackStyle = .medium) {}
    func prepare() {}
    func impactOccurred() {}
}

final class UISelectionFeedbackGenerator {
    init() {}
    func prepare() {}
    func selectionChanged() {}
}

final class UINotificationFeedbackGenerator {
    enum FeedbackType { case success, warning, error }
    init() {}
    func prepare() {}
    func notificationOccurred(_ type: FeedbackType) {}
}

// MARK: accessibility and the keyboard

enum UIAccessibility {
    enum Notification { case announcement, screenChanged, layoutChanged }

    @MainActor static var isVoiceOverRunning: Bool { NSWorkspace.shared.isVoiceOverEnabled }

    @MainActor static func post(notification: Notification, argument: Any?) {
        guard notification == .announcement, let text = argument as? String else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

typealias UIResponder = NSResponder

extension NSResponder {
    /// The Mac has no on-screen keyboard: these never post.
    static let keyboardWillShowNotification = Notification.Name("PierMac.keyboardWillShow.never")
    static let keyboardWillHideNotification = Notification.Name("PierMac.keyboardWillHide.never")
}

extension NSView {
    /// UIKit's `isFirstResponder`.
    var isFirstResponder: Bool { window?.firstResponder === self }
}

extension NSImage {
    /// UIKit's `preparingThumbnail(of:)`: the image scaled to fit `size`.
    func preparingThumbnail(of size: CGSize) -> NSImage? {
        guard self.size.width > 0, self.size.height > 0 else { return nil }
        let s = min(size.width / self.size.width, size.height / self.size.height, 1)
        let target = CGSize(width: (self.size.width * s).rounded(), height: (self.size.height * s).rounded())
        return UIGraphicsImageRenderer(size: target).image { _ in self.draw(in: CGRect(origin: .zero, size: target)) }
    }
}
#endif
