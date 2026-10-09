import WidgetKit
import SwiftUI
import PierKit

struct StatusEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    var isPlaceholder = false
}

/// Tries a live fetch from the boxes (short timeout) and falls back to the snapshot the app wrote to the App Group.
struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: .now, snapshot: .sample, isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (StatusEntry) -> Void) {
        if context.isPreview {
            completion(StatusEntry(date: .now, snapshot: .sample))
            return
        }
        completion(StatusEntry(date: .now, snapshot: SnapshotStore.read() ?? .empty))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<StatusEntry>) -> Void) {
        Task {
            let snap = await Self.load()
            let minutes = WidgetRefreshPolicy.nextRefreshMinutes(needsYou: snap.needsYou, working: snap.working)
            let next = Date().addingTimeInterval(TimeInterval(minutes * 60))
            completion(Timeline(entries: [StatusEntry(date: .now, snapshot: snap)], policy: .after(next)))
        }
    }

    /// A snapshot the app or a background refresh wrote this recently is used as is (`WidgetRefreshPolicy.freshFor`):
    /// every `reloadAllTimelines` the app asks for would otherwise open a TLS connection to every box from this process
    /// for data the app just fetched. The same on the Mac, where the app writes the snapshot to the App Group too.
    static func load() async -> WidgetSnapshot {
        let stored = SnapshotStore.read()
        if let stored, WidgetRefreshPolicy.isFresh(updated: stored.updated) { return stored }
        guard let access = BoxAccess.load() else { return stored ?? .empty }
        let fetches = await access.fetchSessions(timeout: .seconds(8))
        guard fetches.contains(where: { $0.sessions != nil }) else {
            // Nothing answered (off the home network, or local network blocked for extensions): the app's last snapshot.
            return stored ?? WidgetSnapshot.make(from: fetches, prefs: SharedDisplayPrefs.load())
        }
        let snap = WidgetSnapshot.make(from: fetches, prefs: SharedDisplayPrefs.load())
        SnapshotStore.write(snap)
        return snap
    }
}

enum StatusWidgetConfig {
    /// `<app bundle id>.status`. The kind keys the widgets people placed: it follows the bundle id, so it never changes
    /// for an install that keeps its bundle id.
    static let kind = Shared.appBundleID + ".status"

    /// The Mac desktop has no Lock Screen families and adds the extra-large one (the large layout with six rows fills it).
    static var families: [WidgetFamily] {
        #if targetEnvironment(macCatalyst)
        [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
        #else
        [.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline]
        #endif
    }

    @MainActor static func make() -> some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StatusProvider()) { entry in
            StatusWidgetEntryView(entry: entry)
                .containerBackground(BTheme.surface, for: .widget)
        }
        .configurationDisplayName("Agentes")
        .description("Quantos agentes precisam de você, estão trabalhando ou terminaram.")
        .supportedFamilies(families)
        .contentMarginsDisabled()
    }
}

/// The widget before iOS 26 (no push-driven reloads).
struct StatusWidget: Widget {
    var body: some WidgetConfiguration { StatusWidgetConfig.make() }
}

/// iOS 26+: the same widget, reloadable by a `widgets` push from pierd. `pushHandler` has no `#available` form
/// inside a configuration, so the bundle picks one of the two types.
@available(iOS 26.0, *)
struct StatusWidgetPushEnabled: Widget {
    var body: some WidgetConfiguration { StatusWidgetConfig.make().pushHandler(StatusWidgetPushHandler.self) }
}

/// Receives the widgets' APNs token and hands it to the app through the App Group (`push-state.json`); the app sends it
/// to every box as `widget_token`. The extension also re-registers right away, so a rotated token is not lost while the
/// app is closed.
@available(iOS 26.0, *)
struct StatusWidgetPushHandler: WidgetPushHandler {
    func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo]) {
        let hex = pushTokenHex(pushInfo.token)
        PushStateStore.update { $0.widgetToken = hex }
        guard let access = BoxAccess.load() else { return }
        Task { _ = await PushRegistrar.registerAll(access: access) }
    }
}

struct StatusWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StatusEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall:
                SmallStatusView(snap: entry.snapshot).padding(12)
                    .widgetURL(Shared.homeURL)
            case .systemMedium:
                ListStatusView(snap: entry.snapshot, rows: 3).padding(12)
            case .systemLarge, .systemExtraLarge:
                ListStatusView(snap: entry.snapshot, rows: 6).padding(12)
            case .accessoryCircular:
                CircularStatusView(snap: entry.snapshot).widgetURL(Shared.homeURL)
            case .accessoryRectangular:
                RectangularStatusView(snap: entry.snapshot)
                    .widgetURL(entry.snapshot.ranked.first?.url ?? Shared.homeURL)
            case .accessoryInline:
                InlineStatusView(snap: entry.snapshot).widgetURL(Shared.homeURL)
            default:
                SmallStatusView(snap: entry.snapshot).padding(12)
            }
        }
        .redacted(reason: entry.isPlaceholder ? .placeholder : [])
    }
}

#Preview("Pequeno", as: .systemSmall) {
    StatusWidget()
} timeline: {
    StatusEntry(date: .now, snapshot: .sample)
    StatusEntry(date: .now, snapshot: .empty)
}

#Preview("Médio", as: .systemMedium) {
    StatusWidget()
} timeline: {
    StatusEntry(date: .now, snapshot: .sample)
}

#Preview("Grande", as: .systemLarge) {
    StatusWidget()
} timeline: {
    StatusEntry(date: .now, snapshot: .sample)
}

#Preview("Tela de bloqueio", as: .accessoryRectangular) {
    StatusWidget()
} timeline: {
    StatusEntry(date: .now, snapshot: .sample)
}
