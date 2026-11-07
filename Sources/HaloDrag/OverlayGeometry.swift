import AppKit
import HaloUI

/// Pure placement and hit-test maths for the overlay panel. All screen rects are AppKit global coordinates
/// (origin bottom-left of the primary screen, y up); view points handed to `RingGeometry` are top-left, y down.
public enum OverlayGeometry {
    /// The screen whose frame contains `point`; else the nearest one; nil only when `screens` is empty.
    /// Uses half-open rects so a point on the seam between two displays belongs to exactly one.
    public static func screenIndex(containing point: NSPoint, in frames: [NSRect]) -> Int? {
        if let i = frames.firstIndex(where: { point.x >= $0.minX && point.x < $0.maxX && point.y >= $0.minY && point.y < $0.maxY }) {
            return i
        }
        func distance(_ r: NSRect) -> CGFloat {
            let dx = max(r.minX - point.x, 0, point.x - r.maxX)
            let dy = max(r.minY - point.y, 0, point.y - r.maxY)
            return dx * dx + dy * dy
        }
        return frames.indices.min { distance(frames[$0]) < distance(frames[$1]) }
    }

    /// A `size`×`size` square centred on `point`, shifted to lie inside `visibleFrame` (centred on it when it is
    /// smaller than the square), with its origin snapped to the display's pixel grid.
    public static func panelFrame(centeredAt point: NSPoint, size: CGFloat = RingMetrics.canvasSize,
                                  visibleFrame: NSRect, backingScale: CGFloat = 2) -> NSRect {
        func clamp(_ origin: CGFloat, _ lo: CGFloat, _ length: CGFloat) -> CGFloat {
            if length <= size { return lo + (length - size) / 2 }
            return min(max(origin, lo), lo + length - size)
        }
        let x = clamp(point.x - size / 2, visibleFrame.minX, visibleFrame.width)
        let y = clamp(point.y - size / 2, visibleFrame.minY, visibleFrame.height)
        let scale = max(backingScale, 1)
        return NSRect(x: (x * scale).rounded() / scale, y: (y * scale).rounded() / scale, width: size, height: size)
    }

    /// Converts a point in a non-flipped view of height `height` (y up) to top-left view coordinates (y down).
    public static func topLeftPoint(fromBottomLeft p: NSPoint, height: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: height - p.y)
    }

    /// Where the ring's centre sits in top-left view coordinates. The view is a square, so it is just the middle.
    public static func ringCenter(size: CGFloat = RingMetrics.canvasSize) -> CGPoint {
        CGPoint(x: size / 2, y: size / 2)
    }

    /// Segment under a point given in a non-flipped (y-up) view of side `size`.
    public static func segmentIndex(atBottomLeftPoint p: NSPoint, size: CGFloat = RingMetrics.canvasSize, count: Int) -> Int? {
        RingGeometry.index(at: topLeftPoint(fromBottomLeft: p, height: size), center: ringCenter(size: size), count: count)
    }

    /// Segment under a point in global screen coordinates, for a panel occupying `panelFrame`.
    public static func segmentIndex(atScreenPoint p: NSPoint, panelFrame: NSRect, count: Int) -> Int? {
        let local = NSPoint(x: p.x - panelFrame.minX, y: p.y - panelFrame.minY)
        return segmentIndex(atBottomLeftPoint: local, size: panelFrame.width, count: count)
    }
}
