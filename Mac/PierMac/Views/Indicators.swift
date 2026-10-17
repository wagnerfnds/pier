// Spike (Track 7): the working indicators as AppKit views. The shared ones (PulseDot.swift, ConversationView.swift,
// SessionSupport.swift) are UIKit views run by Core Animation; these are the same animations on a layer-backed NSView,
// so the native app also keeps them off the main thread.
#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import SwiftUI

/// A layer-backed view that draws nothing itself, takes no clicks and animates one sublayer (an NSView's own backing
/// layer is AppKit's to place: its anchor is a corner, so a scale would grow from there).
class IndicatorView: NSView {
    let shape = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(shape)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.cornerRadius = min(bounds.width, bounds.height) / 2
        CATransaction.commit()
    }

    /// `color` as this view's appearance shows it (a layer's colors are resolved once).
    func resolved(_ color: NSColor) -> CGColor {
        var cg = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cg = color.cgColor }
        return cg
    }
}

/// PulseDot's halo (App/DesignSystem/PulseDot.swift).
struct PulseHalo: NSViewRepresentable {
    let color: NSColor
    let style: PulseDot.Style

    func makeNSView(context: Context) -> HaloView { HaloView(style: style) }
    func updateNSView(_ view: HaloView, context: Context) { view.tint = color }

    final class HaloView: IndicatorView {
        let style: PulseDot.Style
        var tint: NSColor = .clear { didSet { if tint != oldValue { applyColor() } } }

        init(style: PulseDot.Style) {
            self.style = style
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { start() }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyColor()
        }

        private func applyColor() {
            let tint = resolved(tint)
            switch style {
            case .fade: shape.backgroundColor = tint; shape.borderWidth = 0
            case .ripple: shape.backgroundColor = tint.copy(alpha: 0.35); shape.borderWidth = 0
            case .ring: shape.backgroundColor = .clear; shape.borderColor = tint.copy(alpha: 0.55); shape.borderWidth = 1.5
            }
        }

        private func start() {
            guard window != nil, shape.animation(forKey: "pulse") == nil else { return }
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
            shape.add(group, forKey: "pulse")
        }
    }
}

/// The conversation's working dot (`PulsingDot`, App/Features/Session/ConversationView.swift).
struct PulseLayer: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> PulseView { PulseView() }
    func updateNSView(_ view: PulseView, context: Context) { view.tint = color }

    final class PulseView: IndicatorView {
        var tint: NSColor = .clear { didSet { shape.backgroundColor = resolved(tint) } }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            shape.backgroundColor = resolved(tint)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, shape.animation(forKey: "pulse") == nil else { return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0.35
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1
            shrink.toValue = 0.8
            let pulse = CAAnimationGroup()
            pulse.animations = [fade, shrink]
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            shape.add(pulse, forKey: "pulse")
        }
    }
}

/// The light of `ShimmerText` (App/Features/Session/Support/SessionSupport.swift): a soft band of the text color
/// crossing the view every 2.2 s.
struct ShimmerSweep: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> SweepView { SweepView() }

    func updateNSView(_ view: SweepView, context: Context) {
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        var cg = NSColor(Theme.text).cgColor
        appearance?.performAsCurrentDrawingAppearance { cg = NSColor(Theme.text).cgColor }
        view.color = cg
    }

    final class SweepView: NSView {
        private let band = CAGradientLayer()
        private var animatedWidth: CGFloat = -1
        var color: CGColor = NSColor.labelColor.cgColor {
            didSet { band.colors = [color.copy(alpha: 0) ?? color, color, color.copy(alpha: 0) ?? color] }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            band.startPoint = CGPoint(x: 0, y: 0.5)
            band.endPoint = CGPoint(x: 1, y: 0.5)
            layer?.addSublayer(band)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            if bounds.width != animatedWidth { sweep() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { sweep() }
        }

        private func sweep() {
            let w = bounds.width
            guard w > 0, window != nil else { return }
            animatedWidth = w
            let bandWidth = max(40, w * 0.6)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            band.bounds = CGRect(x: 0, y: 0, width: bandWidth, height: bounds.height)
            band.position = CGPoint(x: -bandWidth / 2, y: bounds.midY)
            CATransaction.commit()
            let move = CABasicAnimation(keyPath: "position.x")
            move.fromValue = -w * 0.6 + bandWidth / 2
            move.toValue = w + bandWidth / 2
            move.duration = 2.2
            move.repeatCount = .infinity
            band.add(move, forKey: "sweep")
        }
    }
}
#endif
