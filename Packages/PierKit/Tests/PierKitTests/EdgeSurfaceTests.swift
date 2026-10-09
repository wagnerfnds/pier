import Foundation
import Testing

@testable import PierKit

@Suite struct EdgeLayoutTests {
    // A 1920×1080 screen, menu bar 25 pt and a Dock 70 pt tall (AppKit: origin at the bottom).
    let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let visible = CGRect(x: 0, y: 70, width: 1920, height: 985)

    @Test func rightEdgeIsFlushAndCentredAtTheFraction() {
        let f = EdgeLayout.frame(size: CGSize(width: 44, height: 130), edge: .right, fraction: 0.5, screen: screen, visible: visible)
        #expect(f.maxX == 1920)
        #expect(abs(f.midY - visible.midY) <= 1)
        #expect(f.width == 44 && f.height == 130)
    }

    @Test func leftEdgeAndInset() {
        let flush = EdgeLayout.frame(size: CGSize(width: 44, height: 130), edge: .left, fraction: 0.5, screen: screen, visible: visible)
        #expect(flush.minX == 0)
        let floating = EdgeLayout.frame(size: CGSize(width: 52, height: 300), edge: .right, fraction: 0.5, screen: screen, visible: visible, inset: 10)
        #expect(floating.maxX == 1910)
    }

    @Test func fractionIsMeasuredFromTheTop() {
        let top = EdgeLayout.frame(size: CGSize(width: 44, height: 100), edge: .right, fraction: 0, screen: screen, visible: visible)
        #expect(top.maxY == visible.maxY)
        let bottom = EdgeLayout.frame(size: CGSize(width: 44, height: 100), edge: .right, fraction: 1, screen: screen, visible: visible)
        #expect(bottom.minY == visible.minY)
        let lower = EdgeLayout.frame(size: CGSize(width: 44, height: 100), edge: .right, fraction: 0.55, screen: screen, visible: visible)
        #expect(lower.midY < visible.midY)
    }

    @Test func neverPastTheMenuBarOrTheDock() {
        let f = EdgeLayout.frame(size: CGSize(width: 44, height: 400), edge: .right, fraction: 0.98, screen: screen, visible: visible)
        #expect(f.minY >= visible.minY && f.maxY <= visible.maxY)
        let g = EdgeLayout.frame(size: CGSize(width: 44, height: 400), edge: .right, fraction: -3, screen: screen, visible: visible)
        #expect(g.maxY <= visible.maxY)
    }

    @Test func tallerThanTheScreenIsCentred() {
        let f = EdgeLayout.frame(size: CGSize(width: 44, height: 2000), edge: .right, fraction: 0.2, screen: screen, visible: visible)
        #expect(abs(f.midY - visible.midY) < 1)
    }

    @Test func dragRoundTrips() {
        let size = CGSize(width: 44, height: 130)
        for fraction in [0.0, 0.25, 0.55, 1.0] {
            let f = EdgeLayout.frame(size: size, edge: .right, fraction: fraction, screen: screen, visible: visible)
            let back = EdgeLayout.fraction(forCenterY: f.midY, height: size.height, visible: visible)
            let again = EdgeLayout.frame(size: size, edge: .right, fraction: back, screen: screen, visible: visible)
            #expect(abs(again.midY - f.midY) < 1, "fraction \(fraction)")
        }
        // Dragged beyond the Dock: the fraction stops where the panel stops.
        let low = EdgeLayout.fraction(forCenterY: -500, height: 130, visible: visible)
        #expect(EdgeLayout.frame(size: size, edge: .right, fraction: low, screen: screen, visible: visible).minY == visible.minY)
        #expect(EdgeLayout.fraction(forCenterY: 500, height: 130, visible: CGRect(x: 0, y: 0, width: 10, height: 0)) == 0.5)
    }
}

@Suite struct OptionDoubleTapTests {
    /// Press and release ⌥ alone; returns what the release said.
    private func tap(_ d: inout OptionDoubleTap, at t: TimeInterval, held: TimeInterval = 0.08) -> Bool {
        _ = d.modifiers(option: true, others: false, at: t)
        return d.modifiers(option: false, others: false, at: t + held)
    }

    @Test func twoQuickTapsFire() {
        var d = OptionDoubleTap()
        let r1 = tap(&d, at: 0); #expect(!r1)
        let r2 = tap(&d, at: 0.25); #expect(r2)
    }

    @Test func aThirdTapStartsOver() {
        var d = OptionDoubleTap()
        _ = tap(&d, at: 0); let r3 = tap(&d, at: 0.2); #expect(r3)
        let r4 = tap(&d, at: 0.4); #expect(!r4, "the pair was consumed: the next tap is a first one")
        let r5 = tap(&d, at: 0.6); #expect(r5)
    }

    @Test func slowSecondTapDoesNotFire() {
        var d = OptionDoubleTap()
        _ = tap(&d, at: 0)
        let r6 = tap(&d, at: 1.0); #expect(!r6)
        let r7 = tap(&d, at: 1.2); #expect(r7, "but it counts as a new first tap")
    }

    @Test func holdingOptionIsNotATap() {
        var d = OptionDoubleTap()
        let r8 = tap(&d, at: 0, held: 0.8); #expect(!r8)
        let r9 = tap(&d, at: 1.0); #expect(!r9, "a long press leaves nothing pending")
    }

    @Test func optionWithAKeyIsAShortcut() {
        var d = OptionDoubleTap()
        _ = d.modifiers(option: true, others: false, at: 0)
        d.otherKey(at: 0.05)                                   // ⌥E
        let released = d.modifiers(option: false, others: false, at: 0.1); #expect(!released)
        let r10 = tap(&d, at: 0.2); #expect(!r10, "the shortcut did not count as the first tap")
        // A key between two clean taps forgets the first.
        _ = tap(&d, at: 1.0)
        d.otherKey(at: 1.1)
        let r11 = tap(&d, at: 1.2); #expect(!r11)
    }

    @Test func otherModifiersCancel() {
        var d = OptionDoubleTap()
        _ = d.modifiers(option: true, others: false, at: 0)
        _ = d.modifiers(option: true, others: true, at: 0.03)   // ⌘ joined ⌥
        _ = d.modifiers(option: true, others: false, at: 0.06)
        let released2 = d.modifiers(option: false, others: false, at: 0.1); #expect(!released2)
        let r12 = tap(&d, at: 0.2); #expect(!r12)
        // ⌘ alone while a first tap waits.
        _ = tap(&d, at: 1.0)
        _ = d.modifiers(option: false, others: true, at: 1.1)
        _ = d.modifiers(option: false, others: false, at: 1.15)
        let r13 = tap(&d, at: 1.2); #expect(!r13)
    }

    @Test func releaseWithoutPressIsIgnored() {
        var d = OptionDoubleTap()
        let stray = d.modifiers(option: false, others: false, at: 0); #expect(!stray)
        let r14 = tap(&d, at: 0.1); #expect(!r14)
        let r15 = tap(&d, at: 0.3); #expect(r15)
    }
}

@Suite struct SurfacePagingTests {
    @Test func pagesClampAndRecover() {
        let ids = ["a", "b", "c"]
        #expect(SurfacePaging.page(from: "a", by: 1, in: ids) == "b")
        #expect(SurfacePaging.page(from: "c", by: 1, in: ids) == "c")
        #expect(SurfacePaging.page(from: "a", by: -1, in: ids) == "a")
        #expect(SurfacePaging.page(from: "zz", by: 1, in: ids) == "a")
        #expect(SurfacePaging.page(from: nil, by: 0, in: ids) == "a")
        #expect(SurfacePaging.page(from: "a", by: 1, in: []) == nil)
    }

    @Test func expansionRules() {
        #expect(EdgeSurfaceRules.expanded(needsYou: 1, hovering: false, optionHeld: false, cardOpen: false, finishedToast: false))
        #expect(EdgeSurfaceRules.expanded(needsYou: 0, hovering: true, optionHeld: false, cardOpen: false, finishedToast: false))
        #expect(EdgeSurfaceRules.expanded(needsYou: 0, hovering: false, optionHeld: true, cardOpen: false, finishedToast: false))
        #expect(EdgeSurfaceRules.expanded(needsYou: 0, hovering: false, optionHeld: false, cardOpen: true, finishedToast: false))
        #expect(EdgeSurfaceRules.expanded(needsYou: 0, hovering: false, optionHeld: false, cardOpen: false, finishedToast: true))
        #expect(!EdgeSurfaceRules.expanded(needsYou: 0, hovering: false, optionHeld: false, cardOpen: false, finishedToast: false))
    }
}

@Suite struct WidgetRefreshPolicyTests {
    @Test func freshSnapshotsSkipTheNetwork() {
        let now = Date()
        #expect(WidgetRefreshPolicy.isFresh(updated: now.addingTimeInterval(-30), now: now))
        #expect(!WidgetRefreshPolicy.isFresh(updated: now.addingTimeInterval(-61), now: now))
        #expect(!WidgetRefreshPolicy.isFresh(updated: .distantPast, now: now))
    }

    @Test func busyBoxesRefreshSooner() {
        #expect(WidgetRefreshPolicy.nextRefreshMinutes(needsYou: 1, working: 0) == 5)
        #expect(WidgetRefreshPolicy.nextRefreshMinutes(needsYou: 0, working: 2) == 5)
        #expect(WidgetRefreshPolicy.nextRefreshMinutes(needsYou: 0, working: 0) == 15)
    }
}
