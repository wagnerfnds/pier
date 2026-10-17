import Foundation
import CoreGraphics
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The Mac (Catalyst with the Mac idiom, or the native Mac app) gets denser, pointer-sized layouts; iPad and iPhone keep
/// touch sizes.
enum Platform {
    #if os(iOS)
    static let isMac = ProcessInfo.processInfo.isMacCatalystApp
    /// An iPhone, which keeps one pane at a time even when a big one in landscape reports a regular width.
    @MainActor static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    #else
    static let isMac = true
    @MainActor static var isPhone: Bool { false }
    #endif
}

/// Sizes of the sidebar and the project workspace: the Mac's are its own sidebars' (13 pt text in 26 pt rows), the
/// iPad's leave room for a finger.
enum Density {
    static var row: CGFloat { Platform.isMac ? 26 : 36 }
    static var text: CGFloat { Platform.isMac ? 13 : 16 }
    static var small: CGFloat { Platform.isMac ? 11 : 13 }
    static var glyph: CGFloat { Platform.isMac ? 18 : 24 }
    static var indent: CGFloat { Platform.isMac ? 14 : 18 }
    static var icon: CGFloat { Platform.isMac ? 13 : 16 }
    /// The bars at the bottom of the window (the sidebar's footer, the workspace's status bar): one height, so their
    /// top lines meet across the split.
    static var bar: CGFloat { Platform.isMac ? 30 : 40 }
}
