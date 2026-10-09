#if !targetEnvironment(macCatalyst)
import ActivityKit
import WidgetKit
import SwiftUI

struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            SessionLockScreenView(attrs: context.attributes, state: context.state)
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
