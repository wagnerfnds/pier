// Spike (Track 7): the iPhone- and iPad-only SwiftUI modifiers App/ uses, as no-ops (or their nearest Mac meaning) on
// the native Mac, so the shared views compile unchanged. Our declarations win over SwiftUI's unavailable ones.
#if os(macOS) && !targetEnvironment(macCatalyst)
import SwiftUI

enum NavigationBarItem {
    enum TitleDisplayMode { case automatic, inline, large }
}

struct TextInputAutocapitalization: Sendable {
    static let never = TextInputAutocapitalization()
    static let words = TextInputAutocapitalization()
    static let sentences = TextInputAutocapitalization()
    static let characters = TextInputAutocapitalization()
}

enum UIKeyboardType { case `default`, asciiCapable, numbersAndPunctuation, URL, numberPad, phonePad, emailAddress, decimalPad, webSearch }

/// iOS's edit mode (a List's reorder and delete handles). A Mac List reorders and deletes without it.
enum EditMode: Sendable {
    case inactive, transient, active
    var isEditing: Bool { self != .inactive }
}

private struct EditModeKey: EnvironmentKey {
    static let defaultValue: Binding<EditMode>? = nil
}

extension EnvironmentValues {
    var editMode: Binding<EditMode>? {
        get { self[EditModeKey.self] }
        set { self[EditModeKey.self] = newValue }
    }
}

/// `.toolbar(.hidden, for: .tabBar)`: the Mac has no tab bar to hide.
struct TabBarToolbarPlacement {
    static let tabBar = TabBarToolbarPlacement()
}

extension ToolbarItemPlacement {
    static var topBarTrailing: ToolbarItemPlacement { .primaryAction }
    static var topBarLeading: ToolbarItemPlacement { .navigation }
    static var navigationBarTrailing: ToolbarItemPlacement { .primaryAction }
    static var navigationBarLeading: ToolbarItemPlacement { .navigation }
}

extension ListStyle where Self == InsetListStyle {
    /// iOS's grouped cards; the Mac's inset list is the nearest.
    static var insetGrouped: InsetListStyle { .inset }
}

/// `.searchable(…, placement: .navigationBarDrawer(displayMode: .always))`: the Mac's search field goes in the toolbar.
enum DrawerDisplayModeShim { case always, automatic }

extension SearchFieldPlacement {
    static func navigationBarDrawer(displayMode: DrawerDisplayModeShim) -> SearchFieldPlacement { .automatic }
}

extension ContentShapeKinds {
    /// A context menu's lifted preview is iOS's; the Mac's nearest shape kind is the drag preview's.
    static var contextMenuPreview: ContentShapeKinds { .dragPreview }
}

/// `.listSectionSpacing(.compact)`: iOS's grouped list spacing; nothing to set on the Mac.
struct ListSectionSpacingShim {
    static let compact = ListSectionSpacingShim()
    static let `default` = ListSectionSpacingShim()
    static func custom(_ value: CGFloat) -> ListSectionSpacingShim { ListSectionSpacingShim() }
}

extension View {
    func listSectionSpacing(_ spacing: ListSectionSpacingShim) -> some View { self }
    func navigationBarTitleDisplayMode(_ mode: NavigationBarItem.TitleDisplayMode) -> some View { self }
    func textInputAutocapitalization(_ autocapitalization: TextInputAutocapitalization?) -> some View { self }
    func keyboardType(_ type: UIKeyboardType) -> some View { self }
    func toolbar(_ visibility: Visibility, for placement: TabBarToolbarPlacement) -> some View { self }

    /// No full-screen covers on the Mac: a sheet.
    func fullScreenCover<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                        @ViewBuilder content: @escaping () -> Content) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
    }
}
#endif
