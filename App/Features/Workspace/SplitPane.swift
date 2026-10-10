import SwiftUI

/// Two panes side by side with a divider the pointer (or a finger) drags; the leading pane's width is kept per `key`.
/// Catalyst has no HSplitView, and a split view inside the split view's detail would fight it for the sidebar.
struct SplitPane<Leading: View, Trailing: View>: View {
    let key: String
    var initial: CGFloat = 280
    var minLeading: CGFloat = 180
    var minTrailing: CGFloat = 320
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    @State private var width: CGFloat?
    @State private var dragStart: CGFloat?
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let w = clamp(width ?? stored ?? initial, in: geo.size.width)
            HStack(spacing: 0) {
                leading().frame(width: w)
                divider(total: geo.size.width, current: w)
                trailing().frame(maxWidth: .infinity)
            }
        }
    }

    private var stored: CGFloat? {
        let v = UserDefaults.standard.double(forKey: "split.\(key)")
        return v > 0 ? v : nil
    }

    private func clamp(_ w: CGFloat, in total: CGFloat) -> CGFloat {
        min(max(w, minLeading), max(minLeading, total - minTrailing))
    }

    private func divider(total: CGFloat, current: CGFloat) -> some View {
        Rectangle().fill(hovering || dragStart != nil ? Theme.accent.opacity(0.6) : Theme.stroke)
            .frame(width: hovering || dragStart != nil ? 2 : 1)
            .frame(width: 1)
            .overlay {
                // A wider, invisible handle for the pointer and fingers.
                Color.clear.frame(width: 9).contentShape(Rectangle())
                    .onHover { hovering = $0 }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { g in
                                if dragStart == nil { dragStart = current }
                                width = clamp((dragStart ?? current) + g.translation.width, in: total)
                            }
                            .onEnded { _ in
                                dragStart = nil
                                if let width { UserDefaults.standard.set(Double(width), forKey: "split.\(key)") }
                            }
                    )
            }
            .zIndex(1)
            .accessibilityHidden(true)
    }
}
