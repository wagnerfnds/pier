import CoreGraphics
import Foundation
import Testing

@testable import PierKit

/// Same direction (parallel, not opposite), within floating-point noise.
private func sameDirection(_ a: CGPoint, _ b: CGPoint) -> Bool {
    let cross = a.x * b.y - a.y * b.x
    let dot = a.x * b.x + a.y * b.y
    let la = (a.x * a.x + a.y * a.y).squareRoot(), lb = (b.x * b.x + b.y * b.y).squareRoot()
    return la > 0 && lb > 0 && abs(cross) / (la * lb) < 1e-6 && dot > 0
}

@Suite struct EdgeOutlineTests {
    let widths: [CGFloat] = [19, 23, 26, 30, 36, 44.6]

    @Test func theEndsAreTangentToTheEdgeAndTheFaceAndTheArcsToEachOther() {
        for w in widths {
            let o = EdgeOutline(width: w, height: 200)
            let (flare, corner) = o.topEnd
            // From the tip on the edge, heading down the edge: no corner where the black meets the screen's side.
            #expect(flare.p0 == .zero)
            let start = flare.derivative(at: 0)
            #expect(abs(start.x) < 1e-9 && start.y > 0, "\(w): \(start)")
            // Into the face, heading down it.
            #expect(abs(corner.p3.x - w) < 1e-9 && abs(corner.p3.y - o.flareLength) < 1e-9)
            let end = corner.derivative(at: 1)
            #expect(abs(end.x) < 1e-9 && end.y > 0, "\(w): \(end)")
            // The two arcs meet at one point with one tangent (G1), heading towards the face.
            #expect(abs(flare.p3.x - corner.p0.x) < 1e-9 && abs(flare.p3.y - corner.p0.y) < 1e-9)
            #expect(sameDirection(flare.derivative(at: 1), corner.derivative(at: 0)), "\(w)")
            #expect(flare.derivative(at: 1).x > 0)
            // The radii are what the profile says.
            #expect(abs(o.flareRadius - 0.6 * w) < 1e-9 && abs(o.cornerRadius - 0.5 * w) < 1e-9)
        }
    }

    @Test func curvatureFollowsTheRadiiAndFlipsOnceAtTheInflection() {
        for w in widths {
            let (flare, corner) = EdgeOutline(width: w, height: 200).topEnd
            let r1 = w * EdgeOutline.flareRatio, r2 = w * EdgeOutline.cornerRatio
            for t: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
                let kf = flare.curvature(at: t), kc = corner.curvature(at: t)
                #expect(abs(abs(kf) * r1 - 1) < 0.03, "flare \(w) t=\(t): \(kf * r1)")
                #expect(abs(abs(kc) * r2 - 1) < 0.03, "corner \(w) t=\(t): \(kc * r2)")
                // Concave along the whole flare, convex along the whole corner: one inflection, where they meet.
                #expect(kf.sign == flare.curvature(at: 0).sign)
                #expect(kc.sign == corner.curvature(at: 0).sign)
            }
            #expect(flare.curvature(at: 0.5).sign != corner.curvature(at: 0.5).sign)
        }
    }

    @Test func theFlareRunsAboutTheWidthAlongTheEdge() {
        for w in widths {
            let l = EdgeOutline.flareLength(width: w)
            #expect(abs(l / w - 1.0954) < 0.001, "\(w): \(l / w)")
            let p = EdgeOutline(width: w, height: 200).inflection
            #expect(abs(p.x / w - 0.5455) < 0.001 && abs(p.y / w - 0.5975) < 0.001, "\(w): \(p)")
        }
        #expect(EdgeOutline.flareLength(width: 0) == 0)
    }

    @Test func theOutlineIsOneClosedPathInsideItsBoxWithTheBottomMirroringTheTop() {
        let w: CGFloat = 23, h: CGFloat = 120
        let e = EdgeOutline(width: w, height: h).elements
        #expect(e.count == 7)
        guard case .move(let tip) = e[0], case .close = e[6] else { Issue.record("move … close expected"); return }
        #expect(tip == .zero)
        var at = tip
        var arriving: CGPoint?
        var joins: [(CGPoint, CGPoint)] = []
        for el in e.dropFirst().dropLast() {
            switch el {
            case .curve(let c):
                #expect(abs(c.p0.x - at.x) < 1e-9 && abs(c.p0.y - at.y) < 1e-9, "\(c.p0) vs \(at)")
                if let arriving { joins.append((arriving, c.derivative(at: 0))) }
                arriving = c.derivative(at: 1)
                at = c.p3
                for p in [c.p0, c.c1, c.c2, c.p3] { #expect(p.x >= -1e-9 && p.x <= w + 1e-9 && p.y >= -1e-9 && p.y <= h + 1e-9, "\(p)") }
            case .line(let p):
                let d = CGPoint(x: p.x - at.x, y: p.y - at.y)
                if let arriving { joins.append((arriving, d)) }
                arriving = d
                at = p
            default:
                Issue.record("unexpected \(el)")
            }
        }
        // Flare → corner, corner → face, face → corner, corner → flare: one tangent at each.
        #expect(joins.count == 4)
        for (a, b) in joins { #expect(sameDirection(a, b), "\(a) → \(b)") }
        // Back on the edge at the bottom tip, heading down the edge, tangent to it like the top.
        #expect(abs(at.x) < 1e-9 && abs(at.y - h) < 1e-9)
        if let arriving { #expect(abs(arriving.x) < 1e-9 && arriving.y > 0) }
        guard case .curve(let flare) = e[1], case .curve(let corner) = e[2], case .curve(let bottomCorner) = e[4], case .curve(let bottomFlare) = e[5] else { return }
        for t: CGFloat in [0, 0.3, 0.7, 1] {
            let p = flare.point(at: t), q = bottomFlare.point(at: 1 - t)
            #expect(abs(p.x - q.x) < 1e-9 && abs(h - p.y - q.y) < 1e-9)
            let c = corner.point(at: t), d = bottomCorner.point(at: 1 - t)
            #expect(abs(c.x - d.x) < 1e-9 && abs(h - c.y - d.y) < 1e-9)
        }
    }

    @Test func aBodyWiderThanItsProfileKeepsItsEndsAndItsTangents() {
        // Under the pointer the body widens a little; the ends must not move at all: same flare, same length along the
        // edge, the tip and the face's start where they were, the arcs still tangent to each other.
        let w0: CGFloat = 30
        let base = EdgeOutline(width: w0, height: 200)
        for w in [w0, 32, 34, 36] as [CGFloat] {
            let o = EdgeOutline(width: w, height: 200, profileWidth: w0)
            #expect(o.flareLength == base.flareLength && o.flareRadius == base.flareRadius)
            let (flare, corner) = o.topEnd
            #expect(flare.p0 == .zero)
            #expect(abs(corner.p3.x - w) < 1e-9 && abs(corner.p3.y - base.flareLength) < 1e-9)
            #expect(abs(o.cornerRadius - base.cornerRadius) < 0.5, "\(w): \(o.cornerRadius)")
            #expect(sameDirection(flare.derivative(at: 1), corner.derivative(at: 0)), "\(w)")
            let start = flare.derivative(at: 0), end = corner.derivative(at: 1)
            #expect(abs(start.x) < 1e-9 && start.y > 0 && abs(end.x) < 1e-9 && end.y > 0)
            // Wider only towards the screen: the outline stays within the body, never past the edge.
            for c in [flare, corner] {
                for p in [c.p0, c.c1, c.c2, c.p3] { #expect(p.x >= -1e-9 && p.x <= w + 1e-9 && p.y >= -1e-9, "\(w): \(p)") }
            }
        }
        // The natural profile is the special case.
        #expect(EdgeOutline(width: w0, height: 200, profileWidth: w0) == base)
    }
}

@Suite struct EdgeColumnTests {
    /// Five indicators of 12 with 5 between, from 20 down (the folded Medium tab).
    let column = EdgeColumn(slots: [.init(size: 12)] + Array(repeating: EdgeColumn.Slot(size: 12, gap: 5), count: 4), top: 20)

    @Test func theBaseLayoutStacksTheSlotsWithTheirGaps() {
        #expect(column.tops == [20, 37, 54, 71, 88])
        #expect(column.centers == [26, 43, 60, 77, 94])
        #expect(column.bottom == 100)
        #expect(column.index(at: 26) == 0)
        #expect(column.index(at: 34.4) == 0)   // the gap splits between neighbours: up to 34.5 is the first slot's
        #expect(column.index(at: 34.6) == 1)
        #expect(column.index(at: 10) == nil && column.index(at: 110) == nil)
        // A slot with no size (a button while folded) is never the one under the pointer.
        let folded = EdgeColumn(slots: [.init(size: 0), .init(size: 12), .init(size: 0)], top: 20)
        #expect(folded.index(at: 20) == 1 && folded.index(at: 32) == 1)
    }

    @Test func thePeakIsUnderThePointerAndFadesWithDistance() {
        let s = column.targetScales(pointer: 60, peak: 1.45, reach: 40)
        #expect(abs(s[2] - 1.45) < 1e-9)
        #expect(s[1] == s[3] && s[1] > 1 && s[1] < 1.45)
        #expect(s[0] == s[4] && s[0] > 1 && s[0] < s[1])
        // Beyond the reach, nothing; without a pointer, nothing.
        let far = column.targetScales(pointer: 60, peak: 1.45, reach: 15)
        #expect(far[0] == 1 && far[1] == 1 && abs(far[2] - 1.45) < 1e-9 && far[3] == 1 && far[4] == 1)
        #expect(column.targetScales(pointer: nil, peak: 1.45, reach: 40) == [1, 1, 1, 1, 1])
    }

    @Test func magnificationGrowsEachItemAroundItsOwnCentreAndMovesNothingElse() {
        let scales: [CGFloat] = [1, 1.2, 1.45, 1.2, 1]
        let l = column.magnified(scales: scales)
        for (a, b) in zip(l.sizes, [12, 14.4, 17.4, 14.4, 12] as [CGFloat]) { #expect(abs(a - b) < 1e-9) }
        // Every centre where it was: the item under the pointer grows around itself, the rest never shift.
        for (a, b) in zip(l.centers, column.centers) { #expect(abs(a - b) < 1e-9) }
        #expect(abs(l.tops[2] - (60 - 8.7)) < 1e-9)
        // Nothing magnified: the base layout.
        let still = column.magnified(scales: [1, 1, 1, 1, 1])
        #expect(still.tops == column.tops && still.sizes == column.slots.map(\.size))
        #expect(column.magnified(scales: []) == still)
    }

    @Test func magnifiedItemsStayClearOfTheirNeighboursMarks() {
        // Indicators of 12 at a pitch of 17, the drawn dot 0.62 of the box: with the biggest one 1.45 × and its neighbour
        // about 1.28 ×, the dots keep a clear gap, so growing in place never makes them touch.
        let scales = column.targetScales(pointer: 60, peak: 1.45, reach: 41)
        let l = column.magnified(scales: scales)
        for i in 0..<4 {
            let a = l.centers[i] + l.sizes[i] * 0.62 / 2, b = l.centers[i + 1] - l.sizes[i + 1] * 0.62 / 2
            #expect(b - a > 4, "\(i): \(b - a)")
        }
    }
}
