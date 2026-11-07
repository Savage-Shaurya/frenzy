import Testing
import SwiftUI
@testable import HaloUI

@Suite struct RingGeometryTests {
    let center = CGPoint(x: RingMetrics.canvasSize / 2, y: RingMetrics.canvasSize / 2)
    let midRadius = (RingMetrics.innerRadius + RingMetrics.outerRadius) / 2

    @Test(arguments: 1...12)
    func centreOfEachSegmentHitsItself(count: Int) {
        for index in 0..<count {
            let angle = RingGeometry.centerAngle(index: index, count: count)
            let point = RingGeometry.point(angle: angle, radius: midRadius, center: center)
            #expect(RingGeometry.index(at: point, center: center, count: count) == index)
        }
    }

    @Test(arguments: 1...12)
    func holeAndFarOutsideMissAll(count: Int) {
        #expect(RingGeometry.index(at: center, center: center, count: count) == nil)
        let inHole = RingGeometry.point(angle: 1, radius: RingMetrics.innerRadius - 4, center: center)
        #expect(RingGeometry.index(at: inHole, center: center, count: count) == nil)
        let far = RingGeometry.point(angle: 1, radius: RingMetrics.outerRadius + 200, center: center)
        #expect(RingGeometry.index(at: far, center: center, count: count) == nil)
    }

    @Test func twelveOClockIsSegmentZeroAndQuarterTurnsAreClockwise() {
        let top = CGPoint(x: center.x + 1, y: center.y - midRadius)
        #expect(RingGeometry.index(at: top, center: center, count: 4) == 0)
        let right = CGPoint(x: center.x + midRadius, y: center.y + 1)
        #expect(RingGeometry.index(at: right, center: center, count: 4) == 1)
        let bottom = CGPoint(x: center.x - 1, y: center.y + midRadius)
        #expect(RingGeometry.index(at: bottom, center: center, count: 4) == 2)
        let left = CGPoint(x: center.x - midRadius, y: center.y - 1)
        #expect(RingGeometry.index(at: left, center: center, count: 4) == 3)
    }

    @Test(arguments: 1...12)
    func spansTileTheCircle(count: Int) {
        let offset = RingGeometry.startOffset(count: count)
        #expect(RingGeometry.startAngle(index: 0, count: count) == offset)
        #expect(abs(RingGeometry.endAngle(index: count - 1, count: count) - offset - 2 * .pi) < 1e-9)
        for index in 0..<count {
            let mid = (RingGeometry.startAngle(index: index, count: count) + RingGeometry.endAngle(index: index, count: count)) / 2
            #expect(abs(mid - RingGeometry.centerAngle(index: index, count: count)) < 1e-9)
        }
    }

    /// Every pixel a segment paints must hit-test to that same segment, and its centre must be painted.
    @Test(arguments: 1...12)
    func drawnShapesAgreeWithHitTesting(count: Int) {
        let rect = CGRect(x: 0, y: 0, width: RingMetrics.canvasSize, height: RingMetrics.canvasSize)
        let layout = RingLayout(count: count)
        let paths = (0..<count).map {
            RingSegmentShape(index: $0, count: count, gap: layout.gap, cornerRadius: layout.cornerRadius, maxSweep: layout.maxSweep).path(in: rect)
        }
        for (index, path) in paths.enumerated() {
            #expect(!path.isEmpty)
            // Where the segment's icon and label sit (a lone item's arc and content are at 12 o'clock).
            let mid = RingGeometry.point(angle: layout.contentAngle(index: index), radius: midRadius, center: center)
            #expect(path.cgPath.contains(mid), "segment \(index)/\(count) should paint under its content")
            // Shape stays within the band.
            let bounds = path.boundingRect
            #expect(bounds.minX >= center.x - RingMetrics.outerRadius - 0.5)
            #expect(bounds.maxX <= center.x + RingMetrics.outerRadius + 0.5)
        }
        if count == 1 {
            #expect(!paths[0].cgPath.contains(center), "single ring keeps its hole")
        }
        var step: CGFloat = 4
        if count > 8 { step = 3 }
        var y: CGFloat = 0
        while y <= rect.maxY {
            var x: CGFloat = 0
            while x <= rect.maxX {
                let p = CGPoint(x: x, y: y)
                for (index, path) in paths.enumerated() where path.cgPath.contains(p) {
                    #expect(RingGeometry.index(at: p, center: center, count: count) == index,
                            "pixel \(p) painted by \(index)/\(count)")
                }
                x += step
            }
            y += step
        }
    }

    /// Two choices read left to right, like the window's tiles: the first is the left arc, the second the right.
    @Test func twoItemsReadLeftToRight() {
        let left = CGPoint(x: center.x - midRadius, y: center.y + 1)
        let right = CGPoint(x: center.x + midRadius, y: center.y - 1)
        #expect(RingGeometry.index(at: left, center: center, count: 2) == 0)
        #expect(RingGeometry.index(at: right, center: center, count: 2) == 1)
        // Just either side of 12 o'clock and 6 o'clock, where the halves meet.
        #expect(RingGeometry.index(at: CGPoint(x: center.x - 2, y: center.y - midRadius), center: center, count: 2) == 0)
        #expect(RingGeometry.index(at: CGPoint(x: center.x + 2, y: center.y - midRadius), center: center, count: 2) == 1)
        #expect(RingGeometry.index(at: CGPoint(x: center.x - 2, y: center.y + midRadius), center: center, count: 2) == 0)
        #expect(RingGeometry.index(at: CGPoint(x: center.x + 2, y: center.y + midRadius), center: center, count: 2) == 1)
        #expect(RingGeometry.centerAngle(index: 0, count: 2) == 1.5 * .pi)
    }

    @Test func boundaryAnglesFallInTheGutter() {
        let rect = CGRect(x: 0, y: 0, width: RingMetrics.canvasSize, height: RingMetrics.canvasSize)
        for count in 2...12 {
            let layout = RingLayout(count: count)
            for index in 0..<count {
                let path = RingSegmentShape(index: index, count: count, gap: layout.gap, cornerRadius: layout.cornerRadius, maxSweep: layout.maxSweep).path(in: rect)
                let edge = RingGeometry.point(angle: RingGeometry.startAngle(index: index, count: count), radius: midRadius, center: center)
                #expect(!path.cgPath.contains(edge))
            }
        }
    }

    @Test(arguments: 1...12)
    func layoutKeepsLabelsInsideTheirWedge(count: Int) {
        let layout = RingLayout(count: count)
        #expect(layout.contentWidth > 30)
        #expect(layout.contentWidth <= RingMetrics.outerRadius - RingMetrics.innerRadius)
        #expect(layout.showsSubtitles == (count <= 8))
        if count > 2 {
            let chord = 2 * layout.labelRadius * CGFloat(sin(RingGeometry.angularStep(count: count) / 2))
            #expect(layout.contentWidth < chord)
        }
    }
}
