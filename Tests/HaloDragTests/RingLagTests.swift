import AppKit
import Testing
import HaloCore
import HaloUI
@testable import HaloDrag

/// The founder, 8 Nov 2026: "The ring is very laggy." These pin down the per-tick costs found while measuring it.
private let lagItems: [RingItem] = (0..<8).map {
    RingItem(id: ActionID(rawValue: "lag.\($0)"), title: "Item \($0)", subtitle: nil, symbolName: "doc", category: .pdf)
}

@MainActor
@Suite(.serialized) struct RingLagTests {
    private func controller() -> RingOverlayController {
        _ = NSApplication.shared
        let o = RingOverlayController(timing: .init(present: 0, commit: 0, dismiss: 0))
        o.respectsReduceMotion = false
        return o
    }

    /// A pause ring hears the pointer on every drag tick (up to 125 a second). Writing the pass-through flag each time
    /// cost a window-server call and an extra run loop pass per tick; it must only be written when it changes.
    @Test func pauseRingWritesPassThroughOnlyWhenItChanges() {
        let o = controller()
        o.letsDropsThroughHub = true
        o.present(at: NSPoint(x: 600, y: 500), items: lagItems, centerLabel: "") { _, _ in }
        let centre = NSPoint(x: o.panel.frame.midX, y: o.panel.frame.midY)
        let before = o.passThroughWrites
        // Still at the summon point for 250 ticks, then 250 ticks resting on one wedge.
        for _ in 0..<250 { o.pointerMoved(to: centre) }
        #expect(o.panel.ignoresMouseEvents, "the hub lets drops through")
        let wedge = NSPoint(x: centre.x, y: centre.y + 110)
        for i in 0..<250 { o.pointerMoved(to: NSPoint(x: wedge.x + CGFloat(i % 3), y: wedge.y)) }
        #expect(!o.panel.ignoresMouseEvents, "a wedge takes the drop")
        #expect(o.passThroughWrites - before <= 2, "\(o.passThroughWrites - before) writes for 500 ticks")
        // Back to the hub: one more write, and the behaviour is unchanged.
        o.pointerMoved(to: centre)
        #expect(o.panel.ignoresMouseEvents)
        o.dismiss(animated: false)
    }

    /// Building the ring once at launch takes SwiftUI's and the glass's setup off the first drag. It leaves no trace.
    @Test func prewarmLeavesTheRingHiddenAndEmpty() {
        let o = controller()
        o.prewarm(with: lagItems)
        #expect(o.model.phase == .hidden)
        #expect(o.model.items.isEmpty)
        #expect(!o.panel.isVisible)
        #expect(!o.isPresented)
        // A ring presented after the prewarm is the real one.
        o.present(at: NSPoint(x: 600, y: 500), items: Array(lagItems.prefix(3)), centerLabel: "a.pdf") { _, _ in }
        #expect(o.model.items.count == 3)
        o.dismiss(animated: false)
    }

    @Test func prewarmNeverTouchesARingThatIsUp() {
        let o = controller()
        o.present(at: NSPoint(x: 600, y: 500), items: Array(lagItems.prefix(2)), centerLabel: "a.pdf") { _, _ in }
        o.prewarm(with: lagItems)
        #expect(o.model.items.count == 2, "the ring on screen keeps its items")
        #expect(o.isPresented)
        o.dismiss(animated: false)
        // Still cold, so it can warm once now; a second call does nothing.
        o.prewarm(with: lagItems)
        o.present(at: NSPoint(x: 600, y: 500), items: Array(lagItems.prefix(2)), centerLabel: "a.pdf") { _, _ in }
        o.prewarm(with: lagItems)
        #expect(o.model.items.count == 2)
        o.dismiss(animated: false)
    }

    /// Ten seconds of a 125 Hz drag that keeps stopping and starting: the window list (about 0.4 ms a call) is read at
    /// most once per still spell, never per tick.
    @Test func aLongPauseRichDragReadsTheWindowListRarely() {
        let p = MonitorProbe()
        p.monitor.opensOnPause = true
        p.env.target = .window(number: 9, pid: 4242) // another app's window: the long pause applies
        p.env.frontmostProcessID = 100
        p.env.beginFileDrag([URL(fileURLWithPath: "/tmp/halo/lag.pdf")])
        var spells = 0
        var x: CGFloat = 100
        for tick in 0..<1250 {
            // 0.6 s moving, then 0.6 s still (past the 0.4 s pause, short of the 1.2 s one), and again.
            let moving = (tick / 75) % 2 == 0
            if moving { x += 9 } else if tick % 75 == 0 { spells += 1 }
            p.env.mouseLocation = NSPoint(x: x, y: 400)
            p.env.now += 0.008
            p.env.send(.leftMouseDragged)
        }
        #expect(p.summons.isEmpty, "no still spell reached 1.2 s over another app")
        #expect(p.env.targetChecks <= spells, "\(p.env.targetChecks) window-list reads for \(spells) pauses")
        p.env.endDrag()
    }
}
