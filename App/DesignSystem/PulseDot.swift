import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A state dot that moves without the main thread: Core Animation runs the pulse in the render server. A SwiftUI
/// `repeatForever` animation re-renders the view graph every display frame (120 Hz on the Mac), and the sidebar shows
/// several of them for each working agent: measured at about 60% of the Mac's main thread with the window idle.
/// Still under Reduce Motion and under the mock box's UI tests (`Motion.endless`).
struct PulseDot: View {
    enum Style {
        /// Fades to 35% and back (a working agent's dot).
        case fade
        /// A soft halo grows out of the dot and vanishes ("Trabalhando" titles).
        case ripple
        /// A thin ring breathes out of the dot (the Home's agent strip).
        case ring
    }

    let color: Color
    var size: CGFloat = 7
    var style: Style = .fade
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let still = reduceMotion || !Motion.endless
        ZStack {
            if !still, style != .fade {
                PulseHalo(color: UIColor(color), style: style).frame(width: size, height: size)
            }
            if still || style != .fade {
                Circle().fill(color).frame(width: size, height: size)
            } else {
                PulseHalo(color: UIColor(color), style: .fade).frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
    }
}

#if os(iOS)   // UIKit; the native Mac app's own is in Mac/PierMac
private struct PulseHalo: UIViewRepresentable {
    let color: UIColor
    let style: PulseDot.Style

    func makeUIView(context: Context) -> HaloView { HaloView(style: style) }
    func updateUIView(_ view: HaloView, context: Context) { view.tint = color }

    final class HaloView: UIView {
        let style: PulseDot.Style
        var tint: UIColor = .clear { didSet { if tint != oldValue { applyColor() } } }

        init(style: PulseDot.Style) {
            self.style = style
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            // The halos draw outside the dot's frame.
            clipsToBounds = false
            // Core Animation drops a layer's animations when the app goes to the background (a selector observer is
            // removed by itself when the view goes away).
            NotificationCenter.default.addObserver(self, selector: #selector(foreground), name: UIApplication.willEnterForegroundNotification,
                                                   object: nil)
            // A layer's colors are resolved once: light and dark switch them again.
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: HaloView, _: UITraitCollection) in view.applyColor() }
        }

        required init?(coder: NSCoder) { fatalError() }

        @objc private func foreground() { start() }

        override func layoutSubviews() {
            super.layoutSubviews()
            layer.cornerRadius = min(bounds.width, bounds.height) / 2
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { start() }
        }

        private func applyColor() {
            let tint = tint.resolvedColor(with: traitCollection)
            switch style {
            case .fade: backgroundColor = tint; layer.borderWidth = 0
            case .ripple: backgroundColor = tint.withAlphaComponent(0.35); layer.borderWidth = 0
            case .ring: backgroundColor = .clear; layer.borderColor = tint.withAlphaComponent(0.55).cgColor; layer.borderWidth = 1.5
            }
        }

        private func start() {
            guard window != nil, layer.animation(forKey: "pulse") == nil else { return }
            applyColor()
            let fade = CABasicAnimation(keyPath: "opacity")
            let grow = CABasicAnimation(keyPath: "transform.scale")
            let group = CAAnimationGroup()
            switch style {
            case .fade:
                fade.fromValue = 1; fade.toValue = 0.35
                group.animations = [fade]
                group.duration = 0.9
                group.autoreverses = true
                group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            case .ripple:
                fade.fromValue = 1; fade.toValue = 0
                grow.fromValue = 1; grow.toValue = 2.2
                group.animations = [fade, grow]
                group.duration = 1.4
                group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            case .ring:
                fade.fromValue = 1; fade.toValue = 0
                grow.fromValue = 1; grow.toValue = 1.9
                group.animations = [fade, grow]
                group.duration = 1.4
                group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            }
            group.repeatCount = .infinity
            group.isRemovedOnCompletion = false
            layer.add(group, forKey: "pulse")
        }
    }
}
#endif
