import SwiftUI

// Drawing-side geometry. Everything here derives from `RingGeometry` so the pixels the user sees and the
// segment HaloDrag hit-tests can never disagree: segment i covers [i * step, (i + 1) * step) clockwise from
// `startOffset` (12 o'clock, or 6 o'clock for two segments).

public extension RingGeometry {
    /// Angular width of one segment, in radians.
    static func angularStep(count: Int) -> Double {
        count > 0 ? 2 * .pi / Double(count) : 0
    }

    /// Angle where segment `index` begins (0 = 12 o'clock, clockwise; may pass 2π after `startOffset`).
    static func startAngle(index: Int, count: Int) -> Double {
        startOffset(count: count) + Double(index) * angularStep(count: count)
    }

    /// Angle where segment `index` ends (exclusive).
    static func endAngle(index: Int, count: Int) -> Double {
        startOffset(count: count) + Double(index + 1) * angularStep(count: count)
    }

    /// The point at a ring angle (0 = 12 o'clock, clockwise) and radius, in y-down view coordinates.
    static func point(angle: Double, radius: CGFloat, center: CGPoint) -> CGPoint {
        CGPoint(x: center.x + radius * CGFloat(sin(angle)), y: center.y - radius * CGFloat(cos(angle)))
    }
}

/// One ring segment: an annular sector with a constant-width gap to its neighbours and softly rounded corners.
/// With `count == 1` it is a complete ring (no gap, no seams), or with `maxSweep` one arc centred at 12 o'clock.
public struct RingSegmentShape: Shape {
    public var index: Int
    public var count: Int
    public var innerRadius: CGFloat
    public var outerRadius: CGFloat
    /// Width of the straight gutter between neighbouring segments, in points.
    public var gap: CGFloat
    public var cornerRadius: CGFloat
    /// Optional cap on the drawn sweep (radians), centred in the segment's span. The hit area stays the full span;
    /// used so two choices read as two arcs rather than a split disc.
    public var maxSweep: Double?

    public init(index: Int, count: Int,
                innerRadius: CGFloat = RingMetrics.innerRadius,
                outerRadius: CGFloat = RingMetrics.outerRadius,
                gap: CGFloat = 5, cornerRadius: CGFloat = 10, maxSweep: Double? = nil) {
        self.index = index; self.count = count
        self.innerRadius = innerRadius; self.outerRadius = outerRadius
        self.gap = gap; self.cornerRadius = cornerRadius; self.maxSweep = maxSweep
    }

    public func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard count > 0, (0..<count).contains(index), outerRadius > innerRadius else { return Path() }

        if count == 1, maxSweep.map({ $0 <= 0 || $0 >= 2 * .pi }) ?? true {
            // A full annulus: outer circle one way, inner circle the other, so the default non-zero fill leaves a hole.
            var path = Path()
            path.addArc(center: center, radius: outerRadius, startAngle: .zero, endAngle: .radians(2 * .pi), clockwise: false)
            path.closeSubpath()
            path.addArc(center: center, radius: innerRadius, startAngle: .radians(2 * .pi), endAngle: .zero, clockwise: true)
            path.closeSubpath()
            return path
        }

        var a0 = RingGeometry.startAngle(index: index, count: count)
        var a1 = RingGeometry.endAngle(index: index, count: count)
        if count == 1, let maxSweep {
            // A lone item: one arc over the top, where its label sits (`RingLayout.contentAngle`).
            a0 = -maxSweep / 2; a1 = maxSweep / 2
        } else if let maxSweep, maxSweep > 0, a1 - a0 > maxSweep {
            let trim = (a1 - a0 - maxSweep) / 2
            a0 += trim; a1 -= trim
        }
        let halfGap = max(0, gap / 2)
        let corner = Self.fittingCornerRadius(cornerRadius, innerRadius: innerRadius, outerRadius: outerRadius,
                                              halfGap: halfGap, sweep: a1 - a0)

        // Build the sector shrunk by `corner`, then grow it back with a round-joined stroke: this yields exact
        // rounded corners of radius `corner` while the outer edges land precisely on the original radii and gap.
        guard let core = Self.sector(center: center, inner: innerRadius + corner, outer: outerRadius - corner,
                                     a0: a0, a1: a1, halfGap: halfGap + corner) else { return Path() }
        guard corner > 0.01 else { return Path(core) }
        let grown = core.copy(strokingWithWidth: corner * 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
        // Stroke flattening can overshoot the radii by a fraction of a point; clip to the exact band so the
        // painted region never leaves the area `RingGeometry.index(at:)` maps to this segment.
        // (Inset a quarter point: Bezier circles bulge ~0.03 pt past their nominal radius.)
        let outerClip = outerRadius - 0.25, innerClip = innerRadius + 0.25
        let band = CGMutablePath()
        band.addEllipse(in: CGRect(x: center.x - outerClip, y: center.y - outerClip, width: outerClip * 2, height: outerClip * 2))
        band.addEllipse(in: CGRect(x: center.x - innerClip, y: center.y - innerClip, width: innerClip * 2, height: innerClip * 2))
        return Path(core.union(grown).intersection(band, using: .evenOdd))
    }

    /// Largest corner radius ≤ `requested` that still leaves the shrunk core sector non-degenerate.
    static func fittingCornerRadius(_ requested: CGFloat, innerRadius: CGFloat, outerRadius: CGFloat,
                                    halfGap: CGFloat, sweep: Double) -> CGFloat {
        var corner = min(max(0, requested), (outerRadius - innerRadius) / 2 - 1)
        while corner > 0 {
            let inner = innerRadius + corner
            let ratio = (halfGap + corner) / inner
            if ratio < 1, 2 * asin(Double(ratio)) < sweep * 0.8 { return corner }
            corner -= 0.5
        }
        return 0
    }

    /// Annular sector between `a0` and `a1` whose straight edges are offset `halfGap` points inward (parallel gutters).
    static func sector(center: CGPoint, inner: CGFloat, outer: CGFloat, a0: Double, a1: Double, halfGap: CGFloat) -> CGPath? {
        guard inner > 0, outer > inner, halfGap < inner else { return nil }
        let dOuter = asin(Double(halfGap / outer)), dInner = asin(Double(halfGap / inner))
        let outerStart = a0 + dOuter, outerEnd = a1 - dOuter
        let innerStart = a0 + dInner, innerEnd = a1 - dInner
        guard outerEnd > outerStart, innerEnd > innerStart else { return nil }

        // Ring angles are 0 at 12 o'clock, clockwise; CG angles are 0 at +x and (in y-down space) increase clockwise.
        let cg = { (ringAngle: Double) -> CGFloat in CGFloat(ringAngle - .pi / 2) }
        let path = CGMutablePath()
        path.move(to: RingGeometry.point(angle: outerStart, radius: outer, center: center))
        path.addArc(center: center, radius: outer, startAngle: cg(outerStart), endAngle: cg(outerEnd), clockwise: false)
        path.addLine(to: RingGeometry.point(angle: innerEnd, radius: inner, center: center))
        path.addArc(center: center, radius: inner, startAngle: cg(innerEnd), endAngle: cg(innerStart), clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// Per-count sizing for the ring's content. Pure value so tests can check it.
public struct RingLayout: Sendable, Equatable {
    public let count: Int
    public let gap: CGFloat
    public let cornerRadius: CGFloat
    /// Drawn sweep cap passed to `RingSegmentShape` (two items become two 140° arcs, one item a 200° arc on top).
    public let maxSweep: Double?
    public let iconSize: CGFloat
    public let titleSize: CGFloat
    public let subtitleSize: CGFloat
    public let showsSubtitles: Bool
    /// Radius at which each segment's icon + label is centred.
    public let labelRadius: CGFloat
    /// Width available to a segment's label without leaving its wedge.
    public let contentWidth: CGFloat

    public init(count: Int, innerRadius: CGFloat = RingMetrics.innerRadius, outerRadius: CGFloat = RingMetrics.outerRadius) {
        self.count = count
        let dense = count > 8
        let medium = count > 6
        gap = dense ? 4 : 5
        cornerRadius = dense ? 7 : (medium ? 9 : 11)
        maxSweep = count == 2 ? 140 * .pi / 180 : (count == 1 ? 200 * .pi / 180 : nil)
        iconSize = dense ? 15 : (medium ? 17 : 19)
        titleSize = dense ? 11 : (medium ? 12 : 13)
        subtitleSize = medium ? 10 : 11
        showsSubtitles = !dense
        let mid = (innerRadius + outerRadius) / 2
        labelRadius = mid + 2
        let band = outerRadius - innerRadius
        let maxWidth = band - 8
        if count <= 2 {
            contentWidth = maxWidth
        } else {
            let chord = 2 * labelRadius * CGFloat(sin(RingGeometry.angularStep(count: count) / 2))
            contentWidth = min(maxWidth, chord - gap - 10)
        }
    }

    /// Where segment `index`'s content sits. A lone item reads best at 12 o'clock; otherwise the wedge's centre.
    public func contentAngle(index: Int) -> Double {
        count == 1 ? 0 : RingGeometry.centerAngle(index: index, count: count)
    }
}
