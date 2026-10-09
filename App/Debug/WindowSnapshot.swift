#if DEBUG
import UIKit

/// `-snapshotTo <file.png> [-snapshotAfter <seconds>]`: the app writes a PNG of its own window (the content, without the
/// Mac title bar) after a while (6 s by default). For checking the Mac Catalyst build where `screencapture` has no Screen
/// Recording permission (CI, agents); works in the simulator too.
enum WindowSnapshot {
    @MainActor static func runIfRequested() {
        resizeIfRequested()
        guard let path = UserDefaults.standard.string(forKey: "snapshotTo") else { return }
        let after = UserDefaults.standard.double(forKey: "snapshotAfter")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(after > 0 ? after : 6))
            write(to: URL(fileURLWithPath: path))
        }
    }

    /// `-macWindowSize 1280x800` (Mac Catalyst): the window at that size before the snapshot, so screenshots have a
    /// known frame whatever the last run left behind.
    @MainActor private static func resizeIfRequested() {
        #if targetEnvironment(macCatalyst)
        guard let spec = UserDefaults.standard.string(forKey: "macWindowSize") else { return }
        let parts = spec.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
            // Pinning both restrictions is what reliably sizes a Catalyst window; the geometry request alone is advisory.
            let size = CGSize(width: parts[0], height: parts[1])
            scene.sizeRestrictions?.minimumSize = size
            scene.sizeRestrictions?.maximumSize = size
            let screen = scene.screen.bounds
            let frame = CGRect(x: (screen.width - size.width) / 2, y: (screen.height - size.height) / 2, width: size.width, height: size.height)
            scene.requestGeometryUpdate(.Mac(systemFrame: frame)) { error in log("snapshot: resize \(error)") }
        }
        #endif
    }

    @MainActor static func write(to url: URL) {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let main = windows.first(where: \.isKeyWindow) ?? windows.first else { log("snapshot: no window"); return }
        // Every visible window of the scene, bottom to top: sheets and alerts can sit in windows of their own.
        let layers = (main.windowScene?.windows ?? [main]).filter { !$0.isHidden }.sorted { $0.windowLevel < $1.windowLevel }
        let image = UIGraphicsImageRenderer(bounds: main.bounds).image { _ in
            for w in layers { w.drawHierarchy(in: w.convert(w.bounds, to: main), afterScreenUpdates: true) }
        }
        save(image, to: url)
        // A sheet on the Mac is a window of its own outside this hierarchy: the topmost one goes to "<name>-sheet.png".
        var top = main.rootViewController?.presentedViewController
        while let next = top?.presentedViewController { top = next }
        if let view = top?.view, view.bounds.width > 0 {
            let sheet = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
                view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            }
            save(sheet, to: url.deletingPathExtension().appendingPathExtension("sheet.png"))
        }
    }

    @MainActor private static func save(_ image: UIImage, to url: URL) {
        do {
            try image.pngData()?.write(to: url)
            log("snapshot: wrote \(url.path)")
        } catch {
            log("snapshot: \(error)")
        }
    }

    /// stderr, so it shows when the executable runs from a terminal (NSLog only reaches the unified log there).
    private static func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
}
#endif
