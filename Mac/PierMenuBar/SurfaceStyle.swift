import AppKit

// Drawing vocabulary of the Mac surfaces (the edge tab, the toolbar and the Inbox card): the app's Theme tokens as
// dynamic NSColors, the agents' brand colors, and small AppKit views (buttons, capsules, keycaps, state indicators).
// Everything here is AppKit only: the plugin runs inside the Catalyst process, which already loads the iOS flavor of
// SwiftUI, so the macOS one must not be linked a second time.

enum SurfaceStyle {
    // MARK: palette (Theme.swift: light / dark)

    private static func dynamic(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: NSColor.Name("pier." + name)) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static let card = dynamic("card", light: rgb(0xFFFFFF), dark: rgb(0x1E2126))
    static let cardRaised = dynamic("cardRaised", light: rgb(0xEDEFF2), dark: rgb(0x252930))
    /// The toolbar's capsules: a dark gray with a soft shadow (white on light).
    static let capsule = dynamic("capsule", light: rgb(0xFFFFFF), dark: rgb(0x2A2A2C))
    static let stroke = dynamic("stroke", light: NSColor.black.withAlphaComponent(0.09), dark: NSColor.white.withAlphaComponent(0.09))
    static let text = dynamic("text", light: rgb(0x1C2024), dark: rgb(0xE6E8EB))
    static let textDim = dynamic("textDim", light: rgb(0x59616B), dark: rgb(0x8B9199))
    static let textFaint = dynamic("textFaint", light: rgb(0x80878F), dark: rgb(0x5C626B))
    static let accent = dynamic("accent", light: rgb(0x0A67D0), dark: rgb(0x4A99FA))
    static let orange = dynamic("orange", light: rgb(0xB35006), dark: rgb(0xF5A35C))
    static let green = dynamic("green", light: rgb(0x187A3F), dark: rgb(0x4CC38A))
    static let gray = dynamic("gray", light: rgb(0x69707A), dark: rgb(0x7A818B))
    static let red = dynamic("red", light: rgb(0xC93028), dark: rgb(0xE5675F))
    static let wash = dynamic("wash", light: NSColor.black.withAlphaComponent(0.05), dark: NSColor.white.withAlphaComponent(0.06))
    static let shadow = dynamic("shadow", light: NSColor.black.withAlphaComponent(0.14), dark: NSColor.black.withAlphaComponent(0.45))
    /// The tab glued to the screen edge: black, like the hardware notch, in both appearances.
    static let tab = NSColor.black
    /// Text on a filled state color.
    static let onFill = dynamic("onFill", light: rgb(0xFFFFFF), dark: rgb(0x16181B))

    /// The dot / ring colors on the black tab: the dark palette's values, whatever the appearance (the light ones are
    /// deepened for white and go muddy on black).
    static func tabColor(forState state: String) -> NSColor {
        switch state {
        case "needsYou": rgb(0xF5A35C)
        case "working": rgb(0x4A99FA)
        case "done": rgb(0x4CC38A)
        default: rgb(0x7A818B)
        }
    }

    /// The dot / ring colors of the four states (DashState.color).
    static func color(forState state: String) -> NSColor {
        switch state {
        case "needsYou": orange
        case "working": accent
        case "done": green
        default: gray
        }
    }

    /// The agent's brand color (AgentGlyph): as given on dark, darkened to read on white on light.
    static func agentColor(_ agent: String?) -> NSColor {
        let hex: UInt32 = switch (agent ?? "").lowercased() {
        case "claude": 0xD9855B
        case "codex": 0x10A37F
        case "gemini": 0x6C8EF5
        case "opencode": 0xB07CE8
        case "aider": 0xE0C050
        default: 0x7A818B
        }
        return dynamic("agent.\(agent ?? "")", light: readableOnWhite(hex), dark: rgb(hex))
    }

    private static func readableOnWhite(_ hex: UInt32) -> NSColor {
        var r = Double((hex >> 16) & 0xFF), g = Double((hex >> 8) & 0xFF), b = Double(hex & 0xFF)
        func lin(_ c: Double) -> Double { let c = c / 255; return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func contrast() -> Double { 1.05 / (0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b) + 0.05) }
        var steps = 0
        while contrast() < 4.5, steps < 40 { r *= 0.94; g *= 0.94; b *= 0.94; steps += 1 }
        return NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    // MARK: fonts

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }
    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .bold) -> NSFont { .monospacedSystemFont(ofSize: size, weight: weight) }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// An SF Symbol as a template image at a size and weight.
    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .semibold) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        return img?.withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }

    /// A wrapping label.
    static func label(_ text: String, font: NSFont, color: NSColor, lines: Int = 1, alignment: NSTextAlignment = .left) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = font
        f.textColor = color
        f.alignment = alignment
        f.maximumNumberOfLines = lines
        f.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        f.cell?.truncatesLastVisibleLine = true
        if lines == 1 { f.usesSingleLineMode = true; f.cell?.wraps = false }
        f.isSelectable = false
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return f
    }

    /// The label's height when laid out `width` wide.
    static func height(of label: NSTextField, width: CGFloat) -> CGFloat {
        label.preferredMaxLayoutWidth = width
        return ceil(label.sizeThatFits(NSSize(width: width, height: 10_000)).height)
    }
}

// MARK: - views

/// A view that acts on a click (mouse up inside) and knows when the pointer is over it. Subclasses draw.
class ClickableView: NSView {
    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    /// Draws the view (bounds, hovered) when set: rows built on the spot without a subclass.
    var drawBlock: ((NSRect, Bool) -> Void)? { didSet { needsDisplay = true } }
    private(set) var hovered = false { didSet { if hovered != oldValue { hoverChanged() } } }
    private(set) var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?
    var accessibilityTitle: String?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    func hoverChanged() { needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        guard onClick != nil else { super.mouseDown(with: event); return }
        pressed = true
    }
    override func mouseUp(with event: NSEvent) {
        guard onClick != nil else { super.mouseUp(with: event); return }
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func rightMouseDown(with event: NSEvent) {
        if let onRightClick { onRightClick(event) } else { super.rightMouseDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let drawBlock { drawBlock(bounds, hovered || pressed) } else { super.draw(dirtyRect) }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { onClick == nil ? super.accessibilityRole() : .button }
    override func accessibilityLabel() -> String? { accessibilityTitle ?? super.accessibilityLabel() }
    override func isAccessibilityElement() -> Bool { onClick != nil }
    override func accessibilityPerformPress() -> Bool { onClick?(); return onClick != nil }
}

/// A round or capsule button with an SF Symbol, a hover wash and an optional count badge (the Inbox). The glyph is
/// small; the clickable box around it is the view's whole frame. Everything is drawn here, in order (wash, glyph,
/// badge), so the badge is always on top of the glyph.
final class IconButton: ClickableView {
    var symbolName: String { didSet { render() } }
    var tint: NSColor = SurfaceStyle.text { didSet { render() } }
    var badge: Int = 0 { didSet { needsDisplay = true } }
    /// Draws its own capsule background (a standalone circle); inside a capsule it draws only the hover wash.
    var standalone = false { didSet { needsDisplay = true } }
    /// On the black tab: a white glyph and a white hover wash, whatever the appearance.
    var onBlack = false { didSet { render() } }
    /// The glyph's point size, unmagnified.
    var symbolSize: CGFloat { didSet { if symbolSize != oldValue { render() } } }
    /// Magnified (the Dock-like hover on the tab): the glyph is rendered again at its final size, never scaled as pixels.
    var scale: CGFloat = 1 { didSet { if abs(scale - oldValue) > 0.01 { render() } } }
    private var drawnSize: CGFloat { symbolSize * scale }
    private var glyph: NSImage?
    /// Brightens and glows instead of the flat wash (the tab).
    var glow = false { didSet { needsDisplay = true } }

    init(symbol: String, size: CGFloat, symbolSize: CGFloat, title: String) {
        self.symbolName = symbol
        self.symbolSize = symbolSize
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        accessibilityTitle = title
        toolTip = title
        render()
    }
    required init?(coder: NSCoder) { nil }

    /// The glyph at its final size, in its color.
    private func render() {
        glyph = SurfaceStyle.symbol(symbolName, size: drawnSize)?.tinted(onBlack ? NSColor.white.withAlphaComponent(0.92) : tint)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        if standalone {
            SurfaceStyle.capsule.setFill()
            NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
            SurfaceStyle.stroke.setStroke()
            let ring = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: r.height / 2, yRadius: r.height / 2)
            ring.lineWidth = 1
            ring.stroke()
        }
        if hovered || pressed {
            if onBlack, glow {
                // A soft light behind the glyph, brighter when pressed.
                let g = NSGradient(colors: [NSColor.white.withAlphaComponent(pressed ? 0.34 : 0.22), NSColor.white.withAlphaComponent(0)])
                g?.draw(in: NSBezierPath(ovalIn: r.insetBy(dx: -r.width * 0.1, dy: -r.height * 0.1)), relativeCenterPosition: .zero)
            } else if onBlack {
                NSColor.white.withAlphaComponent(pressed ? 0.24 : 0.14).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10).fill()
            } else {
                (pressed ? SurfaceStyle.wash.withAlphaComponent(0.14) : SurfaceStyle.wash).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 3, dy: 3), xRadius: r.height / 2, yRadius: r.height / 2).fill()
            }
        }
        if let glyph {
            let s = glyph.size
            glyph.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height), from: .zero,
                       operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if badge > 0 {
            // The count at the glyph's top-trailing corner, over it by a little, a dark ring cutting it out of the glyph
            // (as iOS badges); drawn last, kept inside the box (it grows with the glyph).
            let text = badge > 99 ? "99+" : "\(badge)"
            let k = max(0.85, scale)
            let fill = onBlack ? SurfaceStyle.tabColor(forState: "needsYou") : SurfaceStyle.orange
            let ink = onBlack ? NSColor(srgbRed: 0.1, green: 0.1, blue: 0.11, alpha: 1) : NSColor.white
            let attrs: [NSAttributedString.Key: Any] = [.font: SurfaceStyle.font(8 * k, .bold), .foregroundColor: ink]
            let size = (text as NSString).size(withAttributes: attrs)
            let h = 12 * k, w = max(h, size.width + 6 * k), ring: CGFloat = 1.5
            var b = NSRect(x: r.midX + drawnSize * 0.4 - w / 2, y: r.midY - drawnSize * 0.6 - h / 2, width: w, height: h)
            b.origin.x = min(b.origin.x, r.maxX - w - ring)
            b.origin.y = max(b.origin.y, r.minY + ring)
            (onBlack ? SurfaceStyle.tab : SurfaceStyle.card).setFill()
            NSBezierPath(roundedRect: b.insetBy(dx: -ring, dy: -ring), xRadius: h / 2 + ring, yRadius: h / 2 + ring).fill()
            fill.setFill()
            NSBezierPath(roundedRect: b, xRadius: h / 2, yRadius: h / 2).fill()
            (text as NSString).draw(at: NSPoint(x: b.midX - size.width / 2, y: b.midY - size.height / 2), withAttributes: attrs)
        }
    }
}

/// A rounded dark box with a hairline and a soft shadow: the toolbar's capsules.
final class CapsuleBox: NSView {
    var radius: CGFloat = 26
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shadow = NSShadow()
        shadow?.shadowColor = SurfaceStyle.shadow
        shadow?.shadowBlurRadius = 10
        shadow?.shadowOffset = NSSize(width: 0, height: -2)
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        SurfaceStyle.capsule.setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        SurfaceStyle.stroke.setStroke()
        let ring = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        ring.lineWidth = 1
        ring.stroke()
    }
}

/// One agent's state drawn in a rect: a blue ring (turned by `angle`) while it works, an amber dot when it needs the
/// person (dimmed for the ones the card is not showing), green when its turn ended, a small gray dot when idle. Plain
/// drawing, no layers: the tab is one shape in one transparent window.
enum IndicatorDrawing {
    static func draw(state: String, dimmed: Bool, in r: NSRect, angle: CGFloat) {
        let color = SurfaceStyle.tabColor(forState: state)
        let c = NSPoint(x: r.midX, y: r.midY)
        if state == "working" {
            let radius = r.width * 0.36
            let ring = NSBezierPath()
            let start = 90 - angle
            ring.appendArc(withCenter: c, radius: radius, startAngle: start, endAngle: start - 270, clockwise: true)
            ring.lineWidth = max(1.6, r.width * 0.14)
            ring.lineCapStyle = .round
            color.setStroke()
            ring.stroke()
            return
        }
        let d = state == "ready" ? r.width * 0.44 : r.width * 0.62
        color.withAlphaComponent(dimmed ? 0.5 : 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)).fill()
    }
}

/// "1", "2"… drawn like a keycap (the Inbox's KeyCap), or a green check square once chosen.
final class KeycapView: NSView {
    var text: String { didSet { needsDisplay = true } }
    var tint: NSColor = SurfaceStyle.accent { didSet { needsDisplay = true } }
    var chosen = false { didSet { needsDisplay = true } }
    /// Drawn inside a hint pill: no raised fill, only the hairline.
    var small = false

    init(_ text: String) {
        self.text = text
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        if chosen {
            SurfaceStyle.green.setFill()
            path.fill()
            if let check = SurfaceStyle.symbol("checkmark", size: 11, weight: .bold) {
                let img = check.tinted(SurfaceStyle.onFill)
                let s = NSSize(width: 12, height: 12)
                img.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
            }
            return
        }
        (small ? SurfaceStyle.wash : SurfaceStyle.cardRaised).setFill()
        path.fill()
        SurfaceStyle.stroke.setStroke()
        path.lineWidth = 1
        path.stroke()
        let attrs: [NSAttributedString.Key: Any] = [.font: SurfaceStyle.mono(small ? 10 : 12), .foregroundColor: tint]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
    }
}

/// A small capsule with words ("Recomendado", "Pronto · title", the key hint).
final class PillLabel: NSView {
    private let field: NSTextField
    var fill: NSColor
    var border: NSColor?
    var padding = NSSize(width: 10, height: 4)
    var leading: NSView?

    init(_ text: String, font: NSFont, color: NSColor, fill: NSColor, border: NSColor? = nil) {
        self.fill = fill
        self.border = border
        field = SurfaceStyle.label(text, font: font, color: color)
        super.init(frame: .zero)
        addSubview(field)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue; invalidateIntrinsicContentSize() }
    }

    func sizeToFit() {
        let lead = leading.map { $0.frame.width + 6 } ?? 0
        let s = field.sizeThatFits(NSSize(width: 600, height: 100))
        frame.size = NSSize(width: ceil(s.width) + padding.width * 2 + lead, height: ceil(s.height) + padding.height * 2)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var x = padding.width
        if let leading {
            if leading.superview == nil { addSubview(leading) }
            leading.frame.origin = NSPoint(x: x, y: (bounds.height - leading.frame.height) / 2)
            x += leading.frame.width + 6
        }
        field.frame = NSRect(x: x, y: padding.height, width: bounds.width - x - padding.width, height: bounds.height - padding.height * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        fill.setFill(); p.fill()
        if let border { border.setStroke(); p.lineWidth = 1; p.stroke() }
    }
}

/// A plain dot for a pill's leading side.
final class DotView: NSView {
    var color: NSColor { didSet { needsDisplay = true } }
    init(color: NSColor, size: CGFloat = 8) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

extension NSImage {
    /// A copy of a template image filled with `color`.
    func tinted(_ color: NSColor) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        img.isTemplate = false
        return img
    }
}
