import SwiftUI

/// Two panes side by side with a divider the pointer (or a finger) drags; the leading pane's width is kept per `key`.
/// Catalyst has no HSplitView, and a split view inside the split view's detail would fight it for the sidebar.
/// With `split` off the trailing pane lies over the leading one, both the whole width (a session's tabs, one showing at
/// a time): the panes stay the same views either way, so turning the split on or off moves them instead of making them
/// again (a terminal's stream, the conversation's place).
struct SplitPane<Leading: View, Trailing: View>: View {
    let key: String
    var initial: CGFloat = 280
    /// The leading pane's share of the width until the divider is first dragged, instead of `initial`.
    var initialFraction: CGFloat? = nil
    var minLeading: CGFloat = 180
    var minTrailing: CGFloat = 320
    var split = true
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    @State private var width: CGFloat?
    @State private var dragStart: CGFloat?
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let w = clamp(width ?? stored ?? initialFraction.map { (geo.size.width * $0).rounded() } ?? initial, in: geo.size.width)
            PaneLayout(leading: w, split: split) {
                leading().frame(maxWidth: .infinity, maxHeight: .infinity)
                divider(total: geo.size.width, current: w)
                    .opacity(split ? 1 : 0)
                    .allowsHitTesting(split)
                trailing().frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// Where `SplitPane` puts its three views (the leading pane, the divider, the trailing pane): side by side, or both panes
/// the whole size with the trailing one on top and the divider out of sight.
private struct PaneLayout: Layout {
    let leading: CGFloat
    let split: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let h = bounds.height
        if split {
            let w = min(leading, bounds.width)
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: w, height: h))
            subviews[1].place(at: CGPoint(x: bounds.minX + w, y: bounds.minY), proposal: ProposedViewSize(width: 1, height: h))
            subviews[2].place(at: CGPoint(x: bounds.minX + w + 1, y: bounds.minY),
                              proposal: ProposedViewSize(width: max(0, bounds.width - w - 1), height: h))
        } else {
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            subviews[1].place(at: bounds.origin, proposal: ProposedViewSize(width: 1, height: h))
            subviews[2].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}
