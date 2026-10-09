import Foundation
import UserNotifications

/// The choices a waiting agent offers, as the notification's own buttons ("Three tiers" / "One plan" / "A table"), so a
/// question is answered from the Lock Screen like a permission is. A category per set of choices, registered when the
/// notification arrives (the service extension for a push, the app for a local one), one action per choice plus "Abrir".
/// Compiled into the app and the notification service extension (App/Shared). Action ids are `CHOICE_<n>`, n the index
/// into the `options` the notification carries in its userInfo (docs/PUSH.md 4.3).
enum NotificationChoices {
    static let categoryPrefix = "CHOICE:"
    static let actionPrefix = "CHOICE_"
    /// The notification's userInfo keys: the push payload's custom keys (docs/PUSH.md 4.1), the same for local ones.
    static let optionsKey = "options"
    static let kindKey = "optionsKind"
    /// The last button: opens the app on the session (handled like a tap).
    static let openAction = "OPEN"
    static let maxOptions = 4
    /// Dynamic categories kept registered (one per distinct set of choices); older ones are dropped.
    static let keep = 24

    /// The words of the buttons that are not choices. The extension has no string catalog: the device's language picks.
    struct Strings: Sendable {
        var open: String
        var hidden: String

        static var current: Strings {
            let pt = Locale.preferredLanguages.first?.lowercased().hasPrefix("pt") ?? false
            return Strings(open: pt ? "Abrir" : "Open", hidden: pt ? "Um agente precisa de você" : "An agent needs you")
        }
    }

    /// The choices in a notification's userInfo, trimmed and capped; nil when it carries none worth a button.
    static func options(in userInfo: [AnyHashable: Any]) -> [String]? {
        guard let raw = userInfo[optionsKey] as? [String] else { return nil }
        let clean = raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return clean.count >= 2 ? Array(clean.prefix(maxOptions)) : nil
    }

    /// One id per set of choices, stable across launches (a hash of the labels, unlike `hashValue`).
    static func categoryID(for options: [String]) -> String {
        categoryPrefix + fnv1a(options.joined(separator: "\u{1F}"))
    }

    static func category(for options: [String], strings: Strings) -> UNNotificationCategory {
        var actions = options.prefix(maxOptions).enumerated().map { i, label in
            UNNotificationAction(identifier: actionPrefix + String(i), title: buttonTitle(label), options: [],
                                 icon: UNNotificationActionIcon(systemImageName: "\(i + 1).circle"))
        }
        actions.append(UNNotificationAction(identifier: openAction, title: strings.open, options: [.foreground],
                                            icon: UNNotificationActionIcon(systemImageName: "arrow.up.forward.app")))
        return UNNotificationCategory(identifier: categoryID(for: options), actions: actions, intentIdentifiers: [],
                                      hiddenPreviewsBodyPlaceholder: strings.hidden, options: [])
    }

    /// Registers the category for `options` next to what is registered already (the app's fixed categories, recent
    /// dynamic ones) and returns its id, for the notification's `categoryIdentifier`.
    static func register(options: [String], strings: Strings = .current) async -> String {
        let center = UNUserNotificationCenter.current()
        let category = category(for: options, strings: strings)
        var set = await center.notificationCategories().filter { $0.identifier != category.identifier }
        let dynamic = set.filter { $0.identifier.hasPrefix(categoryPrefix) }.sorted { $0.identifier < $1.identifier }
        if dynamic.count >= keep { for old in dynamic.prefix(dynamic.count - keep + 1) { set.remove(old) } }
        set.insert(category)
        center.setNotificationCategories(set)
        return category.identifier
    }

    /// Registers the app's fixed categories without dropping the dynamic ones: replacing the whole set would strip the
    /// buttons off a question still sitting on the Lock Screen.
    static func merge(fixed: Set<UNNotificationCategory>) async {
        let center = UNUserNotificationCenter.current()
        let dynamic = await center.notificationCategories().filter { $0.identifier.hasPrefix(categoryPrefix) }
        center.setNotificationCategories(fixed.union(dynamic))
    }

    /// The choice an action picks (`CHOICE_1` → 1); nil for every other action.
    static func index(of action: String) -> Int? {
        guard action.hasPrefix(actionPrefix) else { return nil }
        return Int(action.dropFirst(actionPrefix.count))
    }

    /// A choice as a button title: its first line, short enough to read on a button (the system cuts longer ones).
    static func buttonTitle(_ label: String) -> String {
        let line = label.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? label
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count <= 40 ? t : String(t.prefix(39)) + "…"
    }

    /// FNV-1a (64-bit) of the UTF-8 bytes, as hex.
    private static func fnv1a(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return String(h, radix: 16)
    }
}
