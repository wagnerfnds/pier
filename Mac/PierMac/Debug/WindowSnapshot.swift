// Spike (Track 7): App/Debug/WindowSnapshot.swift for the native Mac app: `-macWindowSize WxH` (the window pinned at
// that content size, as the Catalyst build pins its scene's size restrictions) and `-snapshotTo <file.png>`.
#if DEBUG && os(macOS) && !targetEnvironment(macCatalyst)
import AppKit

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

    @MainActor private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0.contentView != nil }
    }

    @MainActor private static func resizeIfRequested() {
        guard let spec = UserDefaults.standard.string(forKey: "macWindowSize") else { return }
        let parts = spec.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard let w = mainWindow else { log("snapshot: no window to resize"); return }
            let size = NSSize(width: parts[0], height: parts[1])
            w.contentMinSize = size
            w.contentMaxSize = size
            w.setContentSize(size)
            w.center()
        }
    }

    @MainActor static func write(to url: URL) {
        // The window's frame view: the toolbar and the title with the content.
        guard let content = mainWindow?.contentView, let view = content.superview ?? Optional(content), view.bounds.width > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { log("snapshot: no window"); return }
        view.cacheDisplay(in: view.bounds, to: rep)
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            log("snapshot: wrote \(url.path)")
        } catch {
            log("snapshot: \(error)")
        }
    }

    private static func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
}
#endif
