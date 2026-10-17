// Spike (Track 7): the menu bar item, the edge tab and its side panel (Mac/PierMenuBar) run in the native app's own
// process. The Catalyst app loads that code as a plugin bundle and reaches it through Objective-C selectors cast onto a
// protocol it cannot share; here the plugin class is part of the app and conforms to the bridge's protocol directly.
// The calls still carry dictionaries (MenuBarBridge's parts and strings): replacing them with the app's own models is
// the migration's work, not this spike's.
#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit

extension PierMenuBarPlugin: @preconcurrency PierMenuBarPluginAPI {}
#endif
