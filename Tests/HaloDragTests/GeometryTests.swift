import AppKit
import Testing
import HaloUI
@testable import HaloDrag

@Suite struct OverlayGeometryTests {
    let size = RingMetrics.canvasSize // 440
    // A 1512×982 built-in display with menu bar + Dock, and a 2560×1440 external to its right and slightly lower.
    let builtIn = NSRect(x: 0, y: 0, width: 1512, height: 982)
    let builtInVisible = NSRect(x: 0, y: 87, width: 1512, height: 862)
    let external = NSRect(x: 1512, y: -300, width: 2560, height: 1440)
    // An external above the main display (negative x, positive y).
    let above = NSRect(x: -400, y: 982, width: 1920, height: 1080)

    @Test func screenLookupUsesHalfOpenRectsAndFallsBackToNearest() {
        let frames = [builtIn, external, above]
        #expect(OverlayGeometry.screenIndex(containing: NSPoint(x: 10, y: 10), in: frames) == 0)
        #expect(OverlayGeometry.screenIndex(containing: NSPoint(x: 1512, y: 100), in: frames) == 1, "seam belongs to the right display")
        #expect(OverlayGeometry.screenIndex(containing: NSPoint(x: 1511.9, y: 100), in: frames) == 0)
        #expect(OverlayGeometry.screenIndex(containing: NSPoint(x: 2000, y: -250), in: frames) == 1)
        #expect(OverlayGeometry.screenIndex(containing: NSPoint(x: -300, y: 1500), in: frames) == 2)
        #expect(OverlayGeometry.screenIndex(containing: NSPoint(x: 100, y: 982), in: frames) == 2, "top edge of main = bottom of the one above")
        // Off every screen (cursor can't be, but rounding can): nearest wins.
        #expect(OverlayGeometry.screenIndex(containing: NSPoint(x: 700, y: -5), in: frames) == 0)
        #expect(OverlayGeometry.screenIndex(containing: NSPoint(x: 5000, y: 0), in: frames) == 1)
        #expect(OverlayGeometry.screenIndex(containing: .zero, in: []) == nil)
    }

    @Test func centredOnCursorWhenRoomAllAround() {
        let f = OverlayGeometry.panelFrame(centeredAt: NSPoint(x: 700, y: 500), visibleFrame: builtInVisible)
        #expect(f == NSRect(x: 480, y: 280, width: size, height: size))
    }

    @Test func clampedToVisibleFrameEdges() {
        // Bottom-left corner (Dock area) → pushed up to the visible frame.
        let bl = OverlayGeometry.panelFrame(centeredAt: NSPoint(x: 5, y: 20), visibleFrame: builtInVisible)
        #expect(bl.origin == NSPoint(x: 0, y: 87))
        // Top-right corner, under the menu bar.
        let tr = OverlayGeometry.panelFrame(centeredAt: NSPoint(x: 1510, y: 980), visibleFrame: builtInVisible)
        #expect(tr.maxX == builtInVisible.maxX)
        #expect(tr.maxY == builtInVisible.maxY)
        #expect(builtInVisible.contains(tr))
    }

    @Test func clampsOnScreensWithNegativeOrigins() {
        let visible = NSRect(x: 1512, y: -300, width: 2560, height: 1415)
        let f = OverlayGeometry.panelFrame(centeredAt: NSPoint(x: 1520, y: -290), visibleFrame: visible, backingScale: 1)
        #expect(f.origin == NSPoint(x: 1512, y: -300))
        let g = OverlayGeometry.panelFrame(centeredAt: NSPoint(x: -390, y: 2050), visibleFrame: NSRect(x: -400, y: 982, width: 1920, height: 1055))
        #expect(g.minX == -400)
        #expect(g.maxY == CGFloat(2037))
    }

    @Test func tinyScreenCentresTheCanvas() {
        let small = NSRect(x: 100, y: 100, width: 400, height: 300)
        let f = OverlayGeometry.panelFrame(centeredAt: NSPoint(x: 120, y: 120), visibleFrame: small, backingScale: 1)
        #expect(f.midX == small.midX)
        #expect(f.midY == small.midY)
    }

    @Test func originSnapsToPixelGrid() {
        let retina = OverlayGeometry.panelFrame(centeredAt: NSPoint(x: 700.3, y: 500.8), visibleFrame: builtInVisible, backingScale: 2)
        #expect(retina.origin == NSPoint(x: 480.5, y: 281)) // 480.3 → 480.5, 280.8 → 281.0 at 2x
        let oneX = OverlayGeometry.panelFrame(centeredAt: NSPoint(x: 700.3, y: 500.6), visibleFrame: builtInVisible, backingScale: 1)
        #expect(oneX.origin == NSPoint(x: 480, y: 281))
        #expect(retina.size == NSSize(width: size, height: size))
    }

    @Test func yFlipToTopLeftCoordinates() {
        #expect(OverlayGeometry.topLeftPoint(fromBottomLeft: NSPoint(x: 10, y: 400), height: 440) == CGPoint(x: 10, y: 40))
        #expect(OverlayGeometry.topLeftPoint(fromBottomLeft: NSPoint(x: 0, y: 0), height: 440) == CGPoint(x: 0, y: 440))
    }

    @Test func hitTestMapsCompassPointsWithYFlip() {
        let c = size / 2
        // Bottom-left (AppKit) coordinates: larger y = higher on screen = 12 o'clock.
        #expect(OverlayGeometry.segmentIndex(atBottomLeftPoint: NSPoint(x: c, y: c + 110), count: 4) == 0)
        #expect(OverlayGeometry.segmentIndex(atBottomLeftPoint: NSPoint(x: c + 110, y: c), count: 4) == 1)
        #expect(OverlayGeometry.segmentIndex(atBottomLeftPoint: NSPoint(x: c, y: c - 110), count: 4) == 2)
        #expect(OverlayGeometry.segmentIndex(atBottomLeftPoint: NSPoint(x: c - 110, y: c), count: 4) == 3)
        // 60° clockwise from 12 o'clock with 8 segments (45° each) → index 1.
        #expect(OverlayGeometry.segmentIndex(atBottomLeftPoint: NSPoint(x: c + 87, y: c + 50), count: 8) == 1)
    }

    @Test func hitTestCentreAndOutsideAreNil() {
        let c = size / 2
        #expect(OverlayGeometry.segmentIndex(atBottomLeftPoint: NSPoint(x: c, y: c), count: 6) == nil)
        #expect(OverlayGeometry.segmentIndex(atBottomLeftPoint: NSPoint(x: c + RingMetrics.innerRadius - 1, y: c), count: 6) == nil)
        #expect(OverlayGeometry.segmentIndex(atBottomLeftPoint: NSPoint(x: c + RingMetrics.innerRadius + 1, y: c), count: 6) != nil)
        #expect(OverlayGeometry.segmentIndex(atBottomLeftPoint: NSPoint(x: 0, y: 0), count: 6) == nil, "corner is beyond outer + slop")
        #expect(OverlayGeometry.segmentIndex(atBottomLeftPoint: NSPoint(x: c, y: c + 100), count: 0) == nil)
    }

    @Test func screenPointHitTestAccountsForPanelOrigin() {
        let panel = NSRect(x: 1600, y: -200, width: size, height: size)
        let top = NSPoint(x: panel.midX, y: panel.midY + 120)
        #expect(OverlayGeometry.segmentIndex(atScreenPoint: top, panelFrame: panel, count: 3) == 0)
        let left = NSPoint(x: panel.midX - 100, y: panel.midY + 20) // ~281° → third segment of 3
        #expect(OverlayGeometry.segmentIndex(atScreenPoint: left, panelFrame: panel, count: 3) == 2)
        let lowerLeft = NSPoint(x: panel.midX - 100, y: panel.midY - 60) // ~239° → second segment
        #expect(OverlayGeometry.segmentIndex(atScreenPoint: lowerLeft, panelFrame: panel, count: 3) == 1)
    }

    /// Two choices: the first is the left arc on screen (y-up), the second the right.
    @Test func twoChoicesPutTheFirstOnTheLeft() {
        let panel = NSRect(x: 300, y: 200, width: size, height: size)
        let left = NSPoint(x: panel.midX - 110, y: panel.midY + 10)
        let right = NSPoint(x: panel.midX + 110, y: panel.midY - 10)
        #expect(OverlayGeometry.segmentIndex(atScreenPoint: left, panelFrame: panel, count: 2) == 0)
        #expect(OverlayGeometry.segmentIndex(atScreenPoint: right, panelFrame: panel, count: 2) == 1)
    }

    @Test func agreesWithRingGeometryForEverySegment() {
        let c = size / 2
        for count in 1...12 {
            for i in 0..<count {
                let a = RingGeometry.centerAngle(index: i, count: count)
                let r = (RingMetrics.innerRadius + RingMetrics.outerRadius) / 2
                // Angle 0 = 12 o'clock, clockwise: in y-up coordinates that's (sin, cos).
                let p = NSPoint(x: c + r * CGFloat(sin(a)), y: c + r * CGFloat(cos(a)))
                #expect(OverlayGeometry.segmentIndex(atBottomLeftPoint: p, count: count) == i, "count \(count) index \(i)")
            }
        }
    }
}
