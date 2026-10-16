#if !targetEnvironment(macCatalyst)
import ActivityKit
import WidgetKit
import SwiftUI

struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        Self.make { context in SessionLockScreenView(attrs: context.attributes, state: context.state) }
    }

    /// The activity with `content` as its banner; the Dynamic Island's parts are the same for every version.
    static func make<Content: View>(@ViewBuilder content: @escaping (ActivityViewContext<SessionActivityAttributes>) -> Content) -> ActivityConfiguration<SessionActivityAttributes> {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            content(context)
                .activityBackgroundTint(BTheme.surface)
                .activitySystemActionForegroundColor(BTheme.text)
                .widgetURL(context.attributes.url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { IslandExpandedLeading(attrs: context.attributes) }
                DynamicIslandExpandedRegion(.trailing) { IslandExpandedTrailing(state: context.state) }
                DynamicIslandExpandedRegion(.center) { IslandExpandedCenter(attrs: context.attributes) }
                DynamicIslandExpandedRegion(.bottom) { IslandExpandedBottom(attrs: context.attributes, state: context.state) }
            } compactLeading: {
                IslandCompactLeading(attrs: context.attributes, state: context.state)
            } compactTrailing: {
                IslandCompactTrailing(state: context.state)
            } minimal: {
                IslandMinimal(state: context.state)
            }
            .widgetURL(context.attributes.url)
            .keylineTint(context.state.phase.color)
        }
    }
}

/// iOS 26: the same activity, with the `.small` family the car's dashboard (CarPlay) and the Watch draw: a layout of its
/// own instead of the island's compact glyphs.
@available(iOS 26.0, *)
struct SessionLiveActivityWithSmall: Widget {
    var body: some WidgetConfiguration {
        SessionLiveActivity.make { context in ActivityContent(attrs: context.attributes, state: context.state) }
            .supplementalActivityFamilies([.small])
    }
}

/// The Lock Screen's banner, or the small card of the car and the Watch.
@available(iOS 26.0, *)
private struct ActivityContent: View {
    @Environment(\.activityFamily) private var family
    let attrs: SessionActivityAttributes
    let state: ActivityContentState
    var body: some View {
        switch family {
        case .small: SmallActivityView(attrs: attrs, state: state)
        default: SessionLockScreenView(attrs: attrs, state: state)
        }
    }
}

#Preview("Tela de bloqueio", as: .content, using: SessionActivityAttributes.sample) {
    SessionLiveActivity()
} contentStates: {
    SessionActivityAttributes.ContentState.sampleRunning
    SessionActivityAttributes.ContentState.sampleWaiting
    SessionActivityAttributes.ContentState.sampleFinished
}

#Preview("Ilha compacta", as: .dynamicIsland(.compact), using: SessionActivityAttributes.sample) {
    SessionLiveActivity()
} contentStates: {
    SessionActivityAttributes.ContentState.sampleRunning
    SessionActivityAttributes.ContentState.sampleWaiting
}

#Preview("Ilha expandida", as: .dynamicIsland(.expanded), using: SessionActivityAttributes.sample) {
    SessionLiveActivity()
} contentStates: {
    SessionActivityAttributes.ContentState.sampleWaiting
    SessionActivityAttributes.ContentState.sampleFinished
}
#endif
