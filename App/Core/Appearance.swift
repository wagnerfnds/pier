import SwiftUI
import UIKit

/// Ajustes ⟶ Aparência: follow the system (default), or always light / dark. Kept in `UserDefaults` (so a `-appearance
/// light` launch argument works too) and applied to the whole app: `.preferredColorScheme` on the root and the windows'
/// style, which sheets, alerts and the Safari view inherit. Widgets and Live Activities follow the system.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appearance"
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: "Sistema"
        case .light: "Claro"
        case .dark: "Escuro"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    private var style: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    /// Sets every window's style. `.preferredColorScheme(nil)` alone does not always give a window back to the system
    /// after an explicit choice.
    @MainActor func apply() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for w in scene.windows { w.overrideUserInterfaceStyle = style }
        }
    }
}
