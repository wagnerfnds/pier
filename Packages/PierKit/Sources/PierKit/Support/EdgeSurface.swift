import Foundation
import CoreGraphics

// The Mac's edge surface (the tab at the screen edge, the toolbar it expands into and the Inbox card), the pure parts:
// where the panel goes, when two ⌥ taps count as "open Falar", and how the card pages through the agents. Compiled into
// the app (through PierKit) and into the AppKit plugin (Mac/PierMenuBar lists this file as a source of its own), so the
// two agree without the plugin linking the whole kit.

/// Which screen edge the tab is glued to.
public enum EdgeSide: String, Sendable, CaseIterable {
    case left, right
}

/// Where the edge panel sits on a screen. AppKit coordinates (origin bottom-left); `fraction` is the tab's centre as a
/// share of the usable height measured from the top (0 = top, 1 = bottom), so a position survives a change of screen size.
public enum EdgeLayout {
    /// The panel's frame: flush with the screen's edge (`inset` away from it for the floating toolbar), its centre at
    /// `fraction` of the visible area, never past the menu bar or the Dock (a panel taller than the area is centred).
    public static func frame(size: CGSize, edge: EdgeSide, fraction: Double, screen: CGRect, visible: CGRect, inset: CGFloat = 0) -> CGRect {
        let x: CGFloat = switch edge {
        case .right: screen.maxX - size.width - inset
        case .left: screen.minX + inset
        }
        // Whole points: a frame with a fractional height would end on a half pixel, and a grown tab clamped at the top
        // could end a hair short of the folded one.
        let height = ceil(size.height), width = ceil(size.width)
        let wanted = visible.maxY - CGFloat(fraction.clamped01) * visible.height
        let centerY = clampCenter(wanted, height: height, visible: visible)
        return CGRect(x: x.rounded(), y: (centerY - height / 2).rounded(), width: width, height: height)
    }

    /// The fraction for a panel whose centre was dragged to `centerY`, clamped the same way `frame` clamps.
    public static func fraction(forCenterY centerY: CGFloat, height: CGFloat, visible: CGRect) -> Double {
        guard visible.height > 0 else { return 0.5 }
        let y = clampCenter(centerY, height: height, visible: visible)
        return Double((visible.maxY - y) / visible.height).clamped01
    }

    private static func clampCenter(_ y: CGFloat, height: CGFloat, visible: CGRect) -> CGFloat {
        let lo = visible.minY + height / 2, hi = visible.maxY - height / 2
        guard lo <= hi else { return visible.midY }
        return min(max(y, lo), hi)
    }
}

/// Two quick taps on ⌥, alone, open Falar from any app. Fed with every modifier change (and every other key press); says
/// when a double tap completed. A tap is a press and release within `tapWindow` with no other key or modifier meanwhile;
/// the second press must come within `gap` of the first release. ⌥ held, ⌥ with a key (⌥E, ⌘⌥…) or three slow taps
/// never count.
public struct OptionDoubleTap: Sendable {
    public var tapWindow: TimeInterval
    public var gap: TimeInterval
    private var pressedAt: TimeInterval?
    private var dirty = false
    private var firstReleaseAt: TimeInterval?

    public init(tapWindow: TimeInterval = 0.35, gap: TimeInterval = 0.45) {
        self.tapWindow = tapWindow
        self.gap = gap
    }

    /// `option`: ⌥ is down after this change; `others`: another modifier (⌘ ⌃ ⇧ fn) is down too. True on the second tap.
    public mutating func modifiers(option: Bool, others: Bool, at t: TimeInterval) -> Bool {
        if others {
            // ⌘⌥ and friends: whatever was in progress is not a tap.
            dirty = pressedAt != nil
            firstReleaseAt = nil
            if !option { pressedAt = nil; dirty = false }
            return false
        }
        if option {
            guard pressedAt == nil else { return false }
            if let first = firstReleaseAt, t - first > gap { firstReleaseAt = nil }
            pressedAt = t
            dirty = false
            return false
        }
        guard let down = pressedAt else { return false }
        pressedAt = nil
        let clean = !dirty && t - down <= tapWindow
        dirty = false
        guard clean else { firstReleaseAt = nil; return false }
        if firstReleaseAt != nil {
            firstReleaseAt = nil
            return true
        }
        firstReleaseAt = t
        return false
    }

    /// A key pressed (any key): ⌥ was a modifier, not a tap, and a first tap waiting for its twin is forgotten.
    public mutating func otherKey(at t: TimeInterval) {
        if pressedAt != nil { dirty = true }
        firstReleaseAt = nil
    }
}

/// The tab's size (Ajustes → Mac → Tamanho): the glued tab, its indicators and the buttons it grows to hold scale together.
public enum EdgeSizeClass: String, CaseIterable, Sendable {
    case small, medium, large
}

/// The tab's measurements for a size class. The body is narrow — about 1.9 × an indicator — with the indicators centred
/// in it and their pitch about 1.4 × their size; the glyphs are small and the clickable boxes around them bigger (24 pt
/// or more, invisible, inside the shape). The column of items and the shape's height come from `column` / `height`, for
/// any openness between folded (0) and grown (1): the tab morphs between the two along that one number.
public struct EdgeMetrics: Sendable, Equatable {
    /// The folded body's width (indicators only) and the grown body's (its buttons).
    public var tabWidth: CGFloat
    public var expandedWidth: CGFloat
    /// An indicator's box and the gap between two.
    public var indicator: CGFloat
    public var indicatorGap: CGFloat
    /// The Inbox button's box, the other buttons' box and the gap between those: hit targets, bigger than the glyph.
    public var inboxButton: CGFloat
    public var button: CGFloat
    public var buttonGap: CGFloat
    /// The buttons' symbol size (the Inbox and + a point more, Falar one less, "…" two less).
    public var glyph: CGFloat
    /// The first and the last item sit at the centre of the body's round ends (the drop's bulb), this much further in:
    /// the indicators of the folded tab, and the Inbox and "…" of the grown one (more, so the Inbox count fits the end).
    public var padding: CGFloat
    public var grownPadding: CGFloat
    /// Between the sections (Inbox · agents · tools · more), a hairline in the middle.
    public var sectionGap: CGFloat
    /// The panel reaches this far past the screen edge, so the pointer resting on the last pixel is still inside.
    public var slop: CGFloat

    public init(tabWidth: CGFloat, expandedWidth: CGFloat, indicator: CGFloat, indicatorGap: CGFloat, inboxButton: CGFloat, button: CGFloat,
                buttonGap: CGFloat, glyph: CGFloat, padding: CGFloat, grownPadding: CGFloat, sectionGap: CGFloat, slop: CGFloat = 4) {
        self.tabWidth = tabWidth; self.expandedWidth = expandedWidth; self.indicator = indicator; self.indicatorGap = indicatorGap
        self.inboxButton = inboxButton; self.button = button; self.buttonGap = buttonGap; self.glyph = glyph
        self.padding = padding; self.grownPadding = grownPadding; self.sectionGap = sectionGap; self.slop = slop
    }

    public static func metrics(_ size: EdgeSizeClass) -> EdgeMetrics {
        switch size {
        case .small: EdgeMetrics(tabWidth: 19, expandedWidth: 26, indicator: 10, indicatorGap: 4, inboxButton: 26, button: 24, buttonGap: 2,
                                 glyph: 12, padding: 1, grownPadding: 5, sectionGap: 6)
        case .medium: EdgeMetrics(tabWidth: 23, expandedWidth: 30, indicator: 12, indicatorGap: 5, inboxButton: 28, button: 26, buttonGap: 3,
                                  glyph: 14, padding: 2, grownPadding: 5, sectionGap: 7)
        case .large: EdgeMetrics(tabWidth: 30, expandedWidth: 36, indicator: 16, indicatorGap: 6, inboxButton: 32, button: 30, buttonGap: 3,
                                 glyph: 16, padding: 2, grownPadding: 6, sectionGap: 8)
        }
    }

    /// The round ends' inset for an openness.
    public func padding(openness o: CGFloat) -> CGFloat { padding + (grownPadding - padding) * o.clamped01 }

    /// The body's width between folded (0) and grown (1).
    public func bodyWidth(openness o: CGFloat) -> CGFloat { tabWidth + (expandedWidth - tabWidth) * o.clamped01 }

    /// How far along the edge each end's S-curve runs, for a body `width` wide (the profile scales with the body).
    public func flare(width: CGFloat) -> CGFloat { EdgeOutline.flareLength(width: width) }
    public func flare(openness o: CGFloat) -> CGFloat { flare(width: bodyWidth(openness: o)) }

    /// Height of a column of `n` indicators (at least one: the quiet ring when there is no agent).
    public func indicatorsHeight(_ n: Int) -> CGFloat {
        let n = max(n, 1)
        return CGFloat(n) * indicator + CGFloat(n - 1) * indicatorGap
    }

    /// The slot of "+" in `column`; Falar, Apontar and "…" follow. Slot 0 is the Inbox, 1… the indicators (or the
    /// quiet ring when there is no agent).
    public static func toolSlot(indicators n: Int) -> Int { 1 + max(n, 1) }

    /// The items down the tab for an openness: the Inbox, the indicators (or the quiet ring), +, Falar, Apontar, "…".
    /// Folded, the buttons have no size and no gap, so the column is the indicators alone; grown, the quiet ring is
    /// gone. The first item's centre sits at the top end's round centre (the flare's length in) plus `padding`.
    public func column(openness: CGFloat, indicators n: Int) -> EdgeColumn {
        let o = openness.clamped01
        var slots: [EdgeColumn.Slot] = [.init(size: inboxButton * o)]
        if n > 0 {
            for i in 0..<n { slots.append(.init(size: indicator, gap: i == 0 ? sectionGap * o : indicatorGap)) }
        } else {
            slots.append(.init(size: indicator * (1 - o), gap: sectionGap * o))
        }
        slots.append(.init(size: button * o, gap: (n > 0 ? sectionGap : 0) * o))
        slots.append(.init(size: button * o, gap: buttonGap * o))
        slots.append(.init(size: button * o, gap: buttonGap * o))
        slots.append(.init(size: button * o, gap: sectionGap * o))
        let first = indicator / 2 + (inboxButton / 2 - indicator / 2) * o
        return EdgeColumn(slots: slots, top: flare(openness: o) + padding(openness: o) - first)
    }

    /// The shape's height for an openness: both S-curves, the paddings and the column between the centres of its first
    /// and last items.
    public func height(openness: CGFloat, indicators n: Int) -> CGFloat {
        let o = openness.clamped01
        let last = indicator / 2 + (button / 2 - indicator / 2) * o
        return column(openness: o, indicators: n).bottom - last + padding(openness: o) + flare(openness: o)
    }

    /// How much the body widens with the biggest item magnified `peak` ×: half of the item's growth (the glyph takes
    /// the other half from the margins), so a magnified glyph keeps its room without the face jumping out.
    public func magnifiedExtra(peak: CGFloat) -> CGFloat { max(0, peak - 1) * max(inboxButton, button, indicator) * 0.5 }

    /// The tab's window: one fixed canvas for a state, big enough for the grown tab and for the magnification, with
    /// `side` more beside the shape for the labels. The shape is drawn in it, centred, the rest transparent, so the
    /// window never moves or resizes while the pointer is on it (it changes only with the agents' count, the labels,
    /// or the settings).
    public func canvasSize(indicators n: Int, peak: CGFloat, side: CGFloat = 0) -> CGSize {
        CGSize(width: ceil(expandedWidth + magnifiedExtra(peak: peak) + slop + side), height: ceil(height(openness: 1, indicators: n)))
    }

    /// Where the shape's top tip sits in a canvas `canvasHeight` tall: centred, so folding and growing happen around
    /// the same middle.
    public func shapeTop(openness: CGFloat, indicators n: Int, canvasHeight: CGFloat) -> CGFloat {
        (canvasHeight - height(openness: openness, indicators: n)) / 2
    }

    /// The folded tab: the indicators between the two ends.
    public func collapsedSize(indicators n: Int) -> CGSize {
        CGSize(width: tabWidth, height: height(openness: 0, indicators: n))
    }

    /// The grown tab: Inbox, the agents (left out when there are none), +, Falar, Apontar, and "…".
    public func expandedSize(indicators n: Int) -> CGSize {
        CGSize(width: expandedWidth, height: height(openness: 1, indicators: n))
    }
}

/// The tab's silhouette, the pure geometry: a narrow body hanging from the screen edge like a drop. Each end is an
/// S-curve — a wide concave flare, tangent to the edge (radius 0.6 × the body's width), that turns with no corner and
/// no flat step into the body's convex round end (radius 0.5 × the width), tangent to the face; the flare's circle and
/// the corner's circle touch, so the whole outline is one continuous path, tangent everywhere. The same profile serves
/// the folded tab and the grown one: the arcs scale with the width. A body widened under the pointer keeps the profile
/// of its unmagnified width (`profileWidth`): the ends stay exactly where they are, only the face moves out, the
/// corner's circle riding along with it. Local coordinates: x = 0 on the screen edge, x = width on the face, y along
/// the edge from the top tip down.
public struct EdgeOutline: Sendable, Equatable {
    public static let flareRatio: CGFloat = 0.6
    public static let cornerRatio: CGFloat = 0.5

    public var width: CGFloat
    public var height: CGFloat
    /// The flare's radius and how far along the edge each end's S-curve runs: the natural ones for `width`, or the
    /// ones of the width the profile was made for.
    public var flareRadius: CGFloat
    public var flareLength: CGFloat

    public init(width: CGFloat, height: CGFloat) {
        self.init(width: width, height: height, profileWidth: width)
    }

    public init(width: CGFloat, height: CGFloat, profileWidth: CGFloat) {
        self.width = width
        self.height = height
        flareRadius = profileWidth * Self.flareRatio
        flareLength = Self.flareLength(width: profileWidth)
    }

    /// The corner's radius: the one that keeps its circle, tangent to the face, touching the flare's circle —
    /// (width² + flare²) / (2 width) − flare radius; half the width for the natural profile, and all but the same for
    /// a body a little wider than its profile.
    public var cornerRadius: CGFloat { (width * width + flareLength * flareLength) / (2 * width) - flareRadius }

    /// How far along the edge an end's S-curve runs (≈ 1.095 × width): where the flare's circle, tangent to the edge at
    /// the tip, and the corner's circle, tangent to the face, touch.
    public static func flareLength(width: CGFloat) -> CGFloat {
        let r1 = width * flareRatio, r2 = width * cornerRatio
        let dx = width - r1 - r2
        return max(0, (r1 + r2) * (r1 + r2) - dx * dx).squareRoot()
    }

    /// A cubic Bézier segment (each circular arc is one).
    public struct Cubic: Sendable, Equatable {
        public var p0: CGPoint, c1: CGPoint, c2: CGPoint, p3: CGPoint

        public init(p0: CGPoint, c1: CGPoint, c2: CGPoint, p3: CGPoint) {
            self.p0 = p0; self.c1 = c1; self.c2 = c2; self.p3 = p3
        }

        public func point(at t: CGFloat) -> CGPoint {
            let u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p3.x, y: a * p0.y + b * c1.y + c * c2.y + d * p3.y)
        }

        public func derivative(at t: CGFloat) -> CGPoint {
            let u = 1 - t
            let a = 3 * u * u, b = 6 * u * t, c = 3 * t * t
            return CGPoint(x: a * (c1.x - p0.x) + b * (c2.x - c1.x) + c * (p3.x - c2.x),
                           y: a * (c1.y - p0.y) + b * (c2.y - c1.y) + c * (p3.y - c2.y))
        }

        public func secondDerivative(at t: CGFloat) -> CGPoint {
            let u = 1 - t
            return CGPoint(x: 6 * u * (c2.x - 2 * c1.x + p0.x) + 6 * t * (p3.x - 2 * c2.x + c1.x),
                           y: 6 * u * (c2.y - 2 * c1.y + p0.y) + 6 * t * (p3.y - 2 * c2.y + c1.y))
        }

        /// Signed curvature: the sign tells which way the curve turns, its size is 1 / radius.
        public func curvature(at t: CGFloat) -> CGFloat {
            let d = derivative(at: t), dd = secondDerivative(at: t)
            let speed = (d.x * d.x + d.y * d.y).squareRoot()
            guard speed > 0 else { return 0 }
            return (d.x * dd.y - d.y * dd.x) / (speed * speed * speed)
        }

        /// The same curve run the other way, mirrored about the line y = `h` (the bottom end, from the top one).
        public func mirrored(about h: CGFloat) -> Cubic {
            func m(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: h - p.y) }
            return Cubic(p0: m(p3), c1: m(c2), c2: m(c1), p3: m(p0))
        }
    }

    /// The top end's two curves, from the tip on the edge: the concave flare up to the inflection, the convex corner
    /// from there to the face. The arcs' centres are `flareRadius + cornerRadius` apart, so the arcs touch where the
    /// line through the centres crosses them, and share a tangent there.
    public var topEnd: (flare: Cubic, corner: Cubic) {
        let r1 = flareRadius, r2 = cornerRadius
        let c1 = CGPoint(x: r1, y: 0), c2 = CGPoint(x: width - r2, y: flareLength)
        let a = atan2(c2.y - c1.y, c2.x - c1.x)
        var flare = Self.arc(center: c1, radius: r1, from: .pi, to: a)
        flare.p0 = .zero   // exactly on the edge (sin π is not quite 0)
        return (flare, Self.arc(center: c2, radius: r2, from: a - .pi, to: 0))
    }

    /// Where the flare turns into the corner.
    public var inflection: CGPoint { topEnd.flare.p3 }

    public enum Element: Sendable, Equatable {
        case move(CGPoint)
        case line(CGPoint)
        case curve(Cubic)
        case close
    }

    /// The whole outline from the top tip: the top end, down the face, the bottom end (the top one mirrored), and back
    /// up the edge (closed; that side lies on the screen edge, out of sight).
    public var elements: [Element] {
        let top = topEnd
        return [.move(CGPoint(x: 0, y: 0)), .curve(top.flare), .curve(top.corner), .line(CGPoint(x: width, y: height - flareLength)),
                .curve(top.corner.mirrored(about: height)), .curve(top.flare.mirrored(about: height)), .close]
    }

    /// A circular arc as one cubic (exact at its ends, within 0.03 % between), swept from angle `a0` to `a1`.
    static func arc(center c: CGPoint, radius r: CGFloat, from a0: CGFloat, to a1: CGFloat) -> Cubic {
        let k = 4 / 3 * tan((a1 - a0) / 4) * r
        let p0 = CGPoint(x: c.x + r * cos(a0), y: c.y + r * sin(a0))
        let p3 = CGPoint(x: c.x + r * cos(a1), y: c.y + r * sin(a1))
        return Cubic(p0: p0, c1: CGPoint(x: p0.x - k * sin(a0), y: p0.y + k * cos(a0)),
                     c2: CGPoint(x: p3.x + k * sin(a1), y: p3.y - k * cos(a1)), p3: p3)
    }
}

/// The column of items down the tab — the Inbox, the indicators (or the quiet ring), +, Falar, Apontar, "…" — and
/// their Dock-like magnification under the pointer. Base coordinates: y along the tab from the shape's top tip, nothing
/// magnified. Pure, so the rules are tested: the item under the pointer grows around its own centre, its neighbours a
/// little, the rest not at all; no item ever moves, so the shape, its ends and the window around it stay put.
public struct EdgeColumn: Sendable, Equatable {
    public struct Slot: Sendable, Equatable {
        public var size: CGFloat
        /// Space before this slot.
        public var gap: CGFloat
        public init(size: CGFloat, gap: CGFloat = 0) {
            self.size = size
            self.gap = gap
        }
    }

    public var slots: [Slot]
    /// The first slot's top.
    public var top: CGFloat

    public init(slots: [Slot], top: CGFloat) {
        self.slots = slots
        self.top = top
    }

    /// Each slot's top, unmagnified.
    public var tops: [CGFloat] {
        var y = top
        var out: [CGFloat] = []
        for s in slots { y += s.gap; out.append(y); y += s.size }
        return out
    }
    public var centers: [CGFloat] { zip(tops, slots).map { $0 + $1.size / 2 } }
    /// The last slot's bottom.
    public var bottom: CGFloat { slots.reduce(top) { $0 + $1.gap + $1.size } }

    /// The slot under `y` among the ones with a size (the gaps split between neighbours); nil beyond the ends.
    public func index(at y: CGFloat) -> Int? {
        let centers = centers
        var best: (Int, CGFloat)?
        for (i, s) in slots.enumerated() where s.size > 0 {
            let d = abs(centers[i] - y)
            let gap = y < centers[i] ? s.gap : (i + 1 < slots.count ? slots[i + 1].gap : 0)
            if d <= s.size / 2 + gap / 2, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    /// The scale each slot heads for with the pointer at `y`: `peak` right under it, fading to 1 with a cosine over
    /// `reach` points on each side; all 1 without a pointer.
    public func targetScales(pointer y: CGFloat?, peak: CGFloat, reach: CGFloat) -> [CGFloat] {
        guard let y, reach > 0, peak > 1 else { return Array(repeating: 1, count: slots.count) }
        return centers.map { c in
            let d = abs(c - y) / reach
            return d >= 1 ? 1 : 1 + (peak - 1) * (0.5 + 0.5 * cos(d * .pi))
        }
    }

    public struct Layout: Sendable, Equatable {
        public var tops: [CGFloat]
        public var sizes: [CGFloat]

        public init(tops: [CGFloat], sizes: [CGFloat]) {
            self.tops = tops
            self.sizes = sizes
        }

        public var centers: [CGFloat] { zip(tops, sizes).map { $0 + $1 / 2 } }
    }

    /// The magnified layout: each slot `size × scale` tall around its own centre; the centres never move.
    public func magnified(scales: [CGFloat]) -> Layout {
        let centers = centers
        let sizes = slots.indices.map { slots[$0].size * (scales.indices.contains($0) ? scales[$0] : 1) }
        return Layout(tops: zip(centers, sizes).map { $0 - $1 / 2 }, sizes: sizes)
    }
}

/// When the tab is open (grown into its buttons) and when it folds back, from the pointer and the pins. One place for
/// the rule, so a pointer moving across the buttons never folds it: the tab stays open while the pointer is inside,
/// folds only `grace` after it left (a return within the grace cancels), and never while something pins it (the card or
/// the menu open, an agent needing the person, ⌥ held, the finished toast).
public struct EdgeHover: Sendable, Equatable {
    public var grace: TimeInterval
    public private(set) var inside = false
    public private(set) var pinned: Bool
    public private(set) var expanded: Bool
    /// When to call `tick` (nil: nothing scheduled).
    public private(set) var collapseAt: TimeInterval?

    public init(grace: TimeInterval = 0.4, pinned: Bool = false) {
        self.grace = grace
        self.pinned = pinned
        self.expanded = pinned
    }

    /// The pointer came in: open now, forget a pending fold. True when `expanded` changed.
    @discardableResult public mutating func entered(at t: TimeInterval) -> Bool {
        inside = true
        collapseAt = nil
        return set(true)
    }

    /// The pointer left: fold after the grace, unless pinned. Never changes `expanded` by itself.
    public mutating func exited(at t: TimeInterval) {
        inside = false
        collapseAt = pinned ? nil : t + grace
    }

    /// Something pins the tab open (or stops doing so). Unpinned with the pointer away: the fold waits the grace too.
    @discardableResult public mutating func pin(_ on: Bool, at t: TimeInterval) -> Bool {
        pinned = on
        if on { collapseAt = nil; return set(true) }
        if !inside { collapseAt = t + grace }
        return false
    }

    /// The scheduled moment: folds when the pointer is still away and nothing pins. True when it folded.
    @discardableResult public mutating func tick(at t: TimeInterval) -> Bool {
        guard let due = collapseAt, t >= due else { return false }
        collapseAt = nil
        guard !inside, !pinned else { return false }
        return set(false)
    }

    private mutating func set(_ on: Bool) -> Bool {
        guard expanded != on else { return false }
        expanded = on
        return true
    }
}

/// A screen of the side panel (the app beside the tab): the Inbox, the agents, one agent, a new task or chat, the
/// project picker of a new task, Falar.
public enum PanelScreen: Equatable, Sendable, Hashable {
    case inbox
    case agents
    case agent(String)
    case compose(chat: Bool)
    case project
    case talk

    /// The screens the tab's buttons open (the bottom of a stack).
    public var isRoot: Bool {
        switch self {
        case .inbox, .agents, .compose, .talk: true
        case .agent, .project: false
        }
    }
}

/// The side panel's navigation: one stack of screens, opened from the tab's buttons (a root), pushed into (an agent, the
/// project picker), walked back with the chevron or Esc, closed with Esc at the root or the ×. Pure, so the rules are
/// tested: the same button again closes the panel, an indicator opens its agent under the agents list, a task just
/// started replaces the form by its agent, an agent that is gone takes the panel back to the list.
public struct PanelNavigator: Equatable, Sendable {
    public private(set) var stack: [PanelScreen] = []

    public init() {}

    public var isOpen: Bool { !stack.isEmpty }
    public var top: PanelScreen? { stack.last }
    public var canGoBack: Bool { stack.count > 1 }

    /// A tab button: opens its screen (a new stack); the button of the screen already on top closes the panel.
    public mutating func toggle(root: PanelScreen) {
        if stack.count == 1, stack[0] == root { stack = [] } else { stack = [root] }
    }

    /// Shows a screen on top (a root replaces the stack).
    public mutating func show(_ screen: PanelScreen) {
        if screen.isRoot { stack = [screen] } else if top != screen { stack.append(screen) }
    }

    /// An indicator on the tab: that agent, with the list under it.
    public mutating func showAgent(_ id: String) {
        stack = [.agents, .agent(id)]
    }

    /// A task or chat just started: its agent takes the form's place (back goes to the list).
    public mutating func started(agent id: String) {
        stack = [.agents, .agent(id)]
    }

    /// The agent shown is gone (archived, ended): back to the list.
    public mutating func agentGone(_ id: String) {
        guard top == .agent(id) else { return }
        stack.removeLast()
        if stack.isEmpty { stack = [.agents] }
    }

    /// The chevron: one screen back. False at the root.
    @discardableResult public mutating func back() -> Bool {
        guard stack.count > 1 else { return false }
        stack.removeLast()
        return true
    }

    /// Esc: back when there is somewhere to go, else close. True when the panel closed.
    @discardableResult public mutating func escape() -> Bool {
        if back() { return false }
        stack = []
        return true
    }

    public mutating func close() { stack = [] }
}

/// The Inbox card on the Mac shows one agent at a time and pages through the rest.
public enum SurfacePaging {
    /// The card `delta` places from `current` (clamped to the ends; the first card when `current` is gone).
    public static func page(from current: String?, by delta: Int, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let i = ids.firstIndex(of: current) else { return ids.first }
        return ids[min(max(i + delta, 0), ids.count - 1)]
    }
}

/// When the Mac's edge tab opens into the toolbar by itself: while an agent needs the person (and the toolbar is how they
/// answer), while they rest the pointer on it or hold ⌥, while the card is open, and for a moment after a turn finished
/// (the "Pronto" label). Hover and ⌥ only add; nothing here collapses what needs attention.
public enum EdgeSurfaceRules {
    public static func expanded(needsYou: Int, hovering: Bool, optionHeld: Bool, cardOpen: Bool, finishedToast: Bool) -> Bool {
        needsYou > 0 || hovering || optionHeld || cardOpen || finishedToast
    }
}

/// The widgets' refresh timing, the same on the phone and on the Mac desktop.
public enum WidgetRefreshPolicy {
    /// A snapshot the app wrote this recently is used as is (no connection to the boxes from the widget process).
    public static let freshFor: TimeInterval = 60

    public static func isFresh(updated: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(updated) < freshFor
    }

    /// Minutes until the next timeline entry: sooner while agents work or wait, longer when the boxes are quiet.
    public static func nextRefreshMinutes(needsYou: Int, working: Int) -> Int {
        needsYou > 0 || working > 0 ? 5 : 15
    }
}

private extension Double {
    var clamped01: Double { min(max(self, 0), 1) }
}

private extension CGFloat {
    var clamped01: CGFloat { Swift.min(Swift.max(self, 0), 1) }
}
