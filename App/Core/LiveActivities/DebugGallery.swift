#if DEBUG
import SwiftUI
import WidgetKit

/// Debug-only screen (`-widgetGallery home|lock|activity|island|all`) that renders the widget and Live Activity views
/// in-app, for screenshots. The real widgets use the same views (App/Shared/Views).
struct WidgetGalleryView: View {
    let page: String
    private let snap = WidgetSnapshot.sample

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(sharedHex: 0x1B2A3F), Color(sharedHex: 0x0B0F16)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    if page == "home" || page == "all" { home }
                    if page == "lock" || page == "all" { lock }
                    if page == "activity" || page == "all" { activity }
                    if page == "island" || page == "all" { island }
                }
                .padding(.vertical, 60).padding(.horizontal, 16)
            }
        }
    }

    private func widget<V: View>(_ w: CGFloat, _ h: CGFloat, @ViewBuilder _ v: () -> V) -> some View {
        v().padding(12).frame(width: w, height: h)
            .background(BTheme.surface).clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(BTheme.stroke))
    }

    private var home: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                widget(170, 170) { SmallStatusView(snap: snap) }
                widget(170, 170) { SmallStatusView(snap: .empty) }
            }
            widget(364, 170) { ListStatusView(snap: snap, rows: 3) }
            Spacer().frame(height: 4)
            widget(364, 382) { ListStatusView(snap: snap, rows: 6) }
        }
    }

    private var lock: some View {
        VStack(spacing: 18) {
            Text("12:34").font(.system(size: 64, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            HStack(spacing: 12) {
                CircularStatusView(snap: snap).frame(width: 72, height: 72)
                    .background(Color.white.opacity(0.14), in: Circle())
                CircularStatusView(snap: .empty).frame(width: 72, height: 72)
                    .background(Color.white.opacity(0.14), in: Circle())
                InlineStatusView(snap: snap).font(.system(size: 14, weight: .medium))
            }
            RectangularStatusView(snap: snap).frame(width: 170, height: 72, alignment: .leading)
                .padding(.horizontal, 6)
                .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            RectangularStatusView(snap: .empty).frame(width: 170, height: 72, alignment: .leading)
                .padding(.horizontal, 6)
                .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .foregroundStyle(.white)
    }

    private var activity: some View {
        VStack(spacing: 14) {
            ForEach([ActivityContentState.sampleRunning, .sampleWaiting, .sampleFinished], id: \.phase) { st in
                SessionLockScreenView(attrs: .sample, state: st)
                    .background(BTheme.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .frame(width: 369)
            }
        }
    }

    private var island: some View {
        VStack(spacing: 18) {
            ForEach([ActivityContentState.sampleRunning, .sampleWaiting, .sampleQuestion], id: \.self) { st in
                HStack(spacing: 0) {
                    IslandCompactLeading(attrs: .sample, state: st).padding(.leading, 10)
                    Spacer()
                    IslandCompactTrailing(state: st).padding(.trailing, 12)
                }
                .frame(width: 190, height: 37).background(.black, in: Capsule())
            }
            ForEach([ActivityContentState.sampleWaiting, .sampleQuestion, .sampleFinished], id: \.self) { st in
                VStack(spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        IslandExpandedLeading(attrs: .sample)
                        IslandExpandedCenter(attrs: .sample)
                        IslandExpandedTrailing(state: st)
                    }
                    IslandExpandedBottom(attrs: .sample, state: st)
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
                .frame(width: 371).background(.black, in: RoundedRectangle(cornerRadius: 44, style: .continuous))
            }
            HStack(spacing: 14) {
                IslandMinimal(state: .sampleRunning).frame(width: 37, height: 37).background(.black, in: Circle())
                IslandMinimal(state: .sampleWaiting).frame(width: 37, height: 37).background(.black, in: Circle())
                IslandMinimal(state: .sampleFinished).frame(width: 37, height: 37).background(.black, in: Circle())
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)   // the Dynamic Island is always dark
    }
}
#endif
