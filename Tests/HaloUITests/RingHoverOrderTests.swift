import Testing
import SwiftUI
@testable import HaloUI

/// The ring no longer lifts the hovered bubble with a zIndex: reordering the glass container's entries made it re-merge
/// every shape on each hover (about 50% more frames per hover). That is only safe while no bubble ever overlaps the
/// hovered one, so this holds the layout to it, for the overlay and for the window and onboarding.
@Suite struct RingHoverOrderTests {
    private func circle(_ offset: CGSize, _ diameter: CGFloat) -> (CGPoint, CGFloat) {
        (CGPoint(x: offset.width, y: offset.height), diameter / 2)
    }

    private func positions(_ layout: RingBubbleLayout, hovered: Int) -> [(CGPoint, CGFloat)] {
        (0..<layout.count).map { index in
            if index == hovered {
                return circle(layout.offset(index: index, extra: RingMotion.hoverPush), layout.diameter * RingMotion.hoverScale)
            }
            if layout.isNeighbour(index, of: hovered) {
                return circle(layout.pushedAside(index: index, from: hovered, by: RingMotion.neighbourPush),
                              layout.diameter * RingMotion.neighbourScale)
            }
            return circle(layout.offset(index: index), layout.diameter * RingMotion.restingScale)
        }
    }

    @Test(arguments: 2...12)
    func theHoveredBubbleNeverOverlapsAnother(count: Int) {
        for layout in [RingBubbleLayout(count: count), RingBubbleLayout.window(count: count)] {
            for hovered in 0..<count {
                let all = positions(layout, hovered: hovered)
                let (h, hr) = all[hovered]
                for (index, (c, r)) in all.enumerated() where index != hovered {
                    let gap = hypot(h.x - c.x, h.y - c.y) - hr - r
                    #expect(gap > 0, "\(count) bubbles (diameter \(layout.diameter)): \(index) overlaps hovered \(hovered) by \(-gap)")
                }
            }
        }
    }
}
