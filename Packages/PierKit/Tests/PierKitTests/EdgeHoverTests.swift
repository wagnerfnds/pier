import Foundation
import Testing

@testable import PierKit

@Suite struct EdgeMetricsTests {
    let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let visible = CGRect(x: 0, y: 70, width: 1920, height: 985)

    @Test func everySizeKeepsHitTargetsAndGrowsAroundTheTab() {
        for size in EdgeSizeClass.allCases {
            let m = EdgeMetrics.metrics(size)
            #expect(m.button >= 24 && m.inboxButton >= 24 && m.expandedWidth >= 24, "\(size)")
            #expect(m.expandedWidth > m.tabWidth)
            // A narrow body, about 1.9 × an indicator; the indicators about 1.4 × their size apart.
            #expect(abs(m.tabWidth / m.indicator - 1.9) < 0.1, "\(size): \(m.tabWidth / m.indicator)")
            #expect(abs((m.indicator + m.indicatorGap) / m.indicator - 1.4) < 0.05, "\(size)")
            // The glyphs are smaller than their boxes: the clickable area is the box, invisible, inside the body.
            #expect(m.glyph < m.button && m.button <= m.expandedWidth)
            for edge in EdgeSide.allCases {
                for n in [0, 1, 3, 8] {
                    for fraction in [0.0, 0.3, 0.55, 1.0] {
                        let tab = EdgeLayout.frame(size: m.collapsedSize(indicators: n), edge: edge, fraction: fraction, screen: screen, visible: visible)
                        let open = EdgeLayout.frame(size: m.expandedSize(indicators: n), edge: edge, fraction: fraction, screen: screen, visible: visible)
                        // The grown tab contains the folded one: a pointer on the tab stays inside while it opens.
                        #expect(open.contains(tab), "\(size) \(edge) n=\(n) f=\(fraction): \(open) vs \(tab)")
                        #expect(edge == .right ? open.maxX == screen.maxX : open.minX == screen.minX)
                        // Whole points, inside the visible area.
                        #expect(open.minY == open.minY.rounded() && open.height == open.height.rounded())
                        #expect(open.minY >= visible.minY && open.maxY <= visible.maxY)
                    }
                }
            }
        }
    }

    @Test func sizesOrderAndAgentsSection() {
        let s = EdgeMetrics.metrics(.small), m = EdgeMetrics.metrics(.medium), l = EdgeMetrics.metrics(.large)
        #expect(s.collapsedSize(indicators: 3).height < m.collapsedSize(indicators: 3).height)
        #expect(m.collapsedSize(indicators: 3).height < l.collapsedSize(indicators: 3).height)
        #expect(s.tabWidth < m.tabWidth && m.tabWidth < l.tabWidth)
        // No agent: the grown tab has no agents section (the folded one keeps room for the quiet ring).
        #expect(m.expandedSize(indicators: 0).height < m.expandedSize(indicators: 1).height)
        #expect(m.collapsedSize(indicators: 0) == m.collapsedSize(indicators: 1))
        #expect(abs(m.expandedSize(indicators: 4).height - m.expandedSize(indicators: 3).height - (m.indicator + m.indicatorGap)) < 1e-9)
    }

    @Test func theColumnMorphsContinuouslyFromFoldedToGrown() {
        let m = EdgeMetrics.metrics(.medium)
        for n in [0, 3] {
            // Folded: the indicators alone, the first centred at the top end's round centre (+ padding), the last likewise.
            let folded = m.column(openness: 0, indicators: n)
            let flare = m.flare(width: m.tabWidth)
            #expect(folded.slots[0].size == 0 && folded.slots.suffix(4).allSatisfy { $0.size == 0 && $0.gap == 0 })
            #expect(abs(folded.centers[1] - (flare + m.padding)) < 1e-9)
            let h0 = m.height(openness: 0, indicators: n)
            #expect(abs((h0 - folded.centers[max(n, 1)]) - (flare + m.padding)) < 1e-9)
            // Grown: the Inbox first, "…" last, each at its end's round centre (+ padding); the quiet ring gone.
            let grown = m.column(openness: 1, indicators: n)
            let flare1 = m.flare(width: m.expandedWidth)
            #expect(grown.slots[0].size == m.inboxButton && grown.slots.last?.size == m.button)
            #expect(abs(grown.centers[0] - (flare1 + m.grownPadding)) < 1e-9)
            let h1 = m.height(openness: 1, indicators: n)
            #expect(abs((h1 - grown.centers[grown.slots.count - 1]) - (flare1 + m.grownPadding)) < 1e-9)
            if n == 0 { #expect(grown.slots[1].size == 0) }
            #expect(EdgeMetrics.toolSlot(indicators: n) == 1 + max(n, 1) && grown.slots.count == EdgeMetrics.toolSlot(indicators: n) + 4)
            // In between: the shape only grows, and nothing jumps.
            var last = (h: h0, centers: folded.centers)
            var o: CGFloat = 0
            while o < 1 {
                o = min(1, o + 0.02)
                let c = m.column(openness: o, indicators: n)
                let h = m.height(openness: o, indicators: n)
                #expect(h >= last.h - 1e-9 && h - last.h < 6, "o=\(o): \(h) from \(last.h)")
                for (a, b) in zip(c.centers, last.centers) { #expect(abs(a - b) < 6, "o=\(o)") }
                last = (h, c.centers)
            }
        }
    }

    @Test func theCanvasIsFixedForAStateAndTheShapeIsCentredInIt() {
        for size in EdgeSizeClass.allCases {
            let m = EdgeMetrics.metrics(size)
            for n in [0, 1, 3, 8] {
                let canvas = m.canvasSize(indicators: n)
                // Room for the grown tab and the slop; whole points; the folded tab fits too.
                #expect(canvas.height == ceil(m.height(openness: 1, indicators: n)) && canvas.width == canvas.width.rounded())
                #expect(canvas.width >= m.expandedWidth + m.slop)
                #expect(canvas.height >= m.collapsedSize(indicators: n).height)
                // The same canvas whatever the pointer does: only the agents' count, a label or the settings change it.
                #expect(m.canvasSize(indicators: n, side: 80).height == canvas.height)
                #expect(m.canvasSize(indicators: n, side: 80).width == canvas.width + 80)
                // The shape's middle is the canvas's middle at any openness: folding and growing never move it.
                var o: CGFloat = 0
                while o <= 1 {
                    let top = m.shapeTop(openness: o, indicators: n, canvasHeight: canvas.height)
                    let mid = top + m.height(openness: o, indicators: n) / 2
                    #expect(abs(mid - canvas.height / 2) < 1e-9, "\(size) n=\(n) o=\(o)")
                    #expect(top >= -1e-9)
                    o += 0.25
                }
            }
        }
    }

    @Test func theFirstIndicatorSitsInTheRoundEndWithEqualMargins() {
        for size in EdgeSizeClass.allCases {
            let m = EdgeMetrics.metrics(size)
            let o = EdgeOutline(width: m.tabWidth, height: m.collapsedSize(indicators: 3).height)
            let c = m.column(openness: 0, indicators: 3)
            let dot = m.indicator * 0.62   // the drawn dot (IndicatorDrawing)
            let above = (c.centers[1] - dot / 2) - o.inflection.y   // from the dot up to the tip of the round end
            let beside = (m.tabWidth - dot) / 2
            #expect(abs(above - beside) <= m.padding + 0.5, "\(size): above \(above) beside \(beside)")
        }
    }
}

@Suite struct EdgeHoverTests {
    @Test func pointerInsideOpensAndNeverFoldsWhileInside() {
        var h = EdgeHover()
        let opened = h.entered(at: 0)
        #expect(opened)
        #expect(h.expanded)
        // Ticks while inside do nothing (no fold was scheduled).
        let folded = h.tick(at: 5)
        #expect(!folded)
        #expect(h.expanded)
    }

    @Test func foldsOnlyAfterTheGraceAndAReturnCancelsIt() {
        var h = EdgeHover(grace: 0.4)
        h.entered(at: 0)
        h.exited(at: 1)
        #expect(h.collapseAt == 1.4)
        let early = h.tick(at: 1.2)
        #expect(!early && h.expanded, "too early")
        h.entered(at: 1.3)                      // back across a gap between buttons
        #expect(h.collapseAt == nil)
        let cancelled = h.tick(at: 1.5)
        #expect(!cancelled && h.expanded, "the return cancelled the fold")
        h.exited(at: 2)
        let folded = h.tick(at: 2.4)
        #expect(folded)
        #expect(!h.expanded)
    }

    @Test func flickerAcrossGapsNeverFolds() {
        var h = EdgeHover(grace: 0.4)
        var t = 0.0
        h.entered(at: t)
        for _ in 0..<20 {
            t += 0.1; h.exited(at: t)
            t += 0.1; h.entered(at: t)
            let folded = h.tick(at: t)
            #expect(!folded && h.expanded)
        }
    }

    @Test func pinsHoldItOpen() {
        var h = EdgeHover(grace: 0.4)
        h.pin(true, at: 0)                       // the card opened
        #expect(h.expanded)
        h.exited(at: 1)
        #expect(h.collapseAt == nil)
        let held = h.tick(at: 9)
        #expect(!held && h.expanded)
        h.pin(false, at: 10)                     // the card closed with the pointer away: grace, then fold
        #expect(h.collapseAt == 10.4)
        let folded = h.tick(at: 10.4)
        #expect(folded && !h.expanded)
        // Unpinned with the pointer inside: nothing scheduled.
        h.entered(at: 11); h.pin(true, at: 11); h.pin(false, at: 12)
        #expect(h.collapseAt == nil && h.expanded)
    }

    @Test func startsOpenWhenPinnedFromTheStart() {
        let h = EdgeHover(pinned: true)
        #expect(h.expanded && h.pinned)
        var g = EdgeHover()
        #expect(!g.expanded)
        g.exited(at: 0)                          // a stray exit before any enter schedules nothing harmful
        let folded = g.tick(at: 1)
        #expect(!folded)
    }
}
