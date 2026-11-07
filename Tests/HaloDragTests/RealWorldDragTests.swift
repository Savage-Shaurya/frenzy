import AppKit
import Testing
import HaloCore
import HaloUI
@testable import HaloDrag

// Bugs a person hits with a real drag. Every test here failed before its fix.

private let items = [
    RingItem(id: "image.to-jpg", title: "JPG", subtitle: nil, symbolName: "photo", category: .image),
    RingItem(id: "image.to-png", title: "PNG", subtitle: nil, symbolName: "photo", category: .image),
]
private let c = RingMetrics.canvasSize / 2
private let wedge = NSPoint(x: c - 110, y: c) // a two-item ring starts at 6 o'clock, so its first wedge is on the left
private let file = URL(fileURLWithPath: "/tmp/halo/photo.heic")

@MainActor
private func controller(_ timing: RingOverlayTiming = .init(present: 0, commit: 0.2, dismiss: 0.1)) -> RingOverlayController {
    _ = NSApplication.shared
    let o = RingOverlayController(timing: timing)
    o.respectsReduceMotion = false
    return o
}

@MainActor
@Suite struct DoubleOpenTests {
    /// Ring opened on a pause, pointer left it, key happened to be down: it used to reopen at once at the new spot.
    @Test func leavingAPauseRingWithTheKeyDownDoesNotReopenIt() {
        let p = MonitorProbe()
        p.monitor.opensOnPause = true
        p.env.beginFileDrag([file])
        for _ in 0..<30 { p.env.tick() }
        #expect(p.summons.count == 1)
        p.env.modifierFlags = [.option]
        p.env.tick()
        p.env.mouseLocation.x += 400
        p.env.tick()
        #expect(p.dismissals == [.pointerLeft])
        for _ in 0..<120 { p.env.tick() }
        #expect(p.summons.count == 1, "the key must be let go and pressed again")
    }

    /// The key came back right after the ring closed (a finger relaxing, or a bad read): the ring used to bloom again.
    @Test func keyBouncingBackJustAfterTheRingClosedDoesNotReopenIt() {
        let p = MonitorProbe(grace: 0.2)
        p.env.modifierFlags = [.option]
        p.env.beginFileDrag([file])
        p.env.modifierFlags = []
        p.env.tick(advance: 0.02)
        p.env.tick(advance: 0.1)
        p.env.tick(advance: 0.15)
        #expect(p.dismissals == [.triggerReleased])
        p.env.tick(advance: 0.1)
        p.env.modifierFlags = [.option]
        for _ in 0..<120 { p.env.tick() }
        #expect(p.summons.count == 1)
    }

    /// The button state read "up" for one tick mid-drag, and the source touched the pasteboard: the session ended, re-armed
    /// on the next drag event, saw "new" contents and opened the ring a second time.
    @Test func aBadButtonReadDoesNotEndTheDrag() {
        let p = MonitorProbe()
        p.env.modifierFlags = [.option]
        p.env.beginFileDrag([file])
        #expect(p.summons.count == 1)
        p.env.isLeftMouseDown = false
        p.env.tick()
        #expect(p.dismissals.isEmpty, "one reading proves nothing")
        p.env.isLeftMouseDown = true
        p.env.tick()
        p.env.dragPasteboardChangeCount += 1
        for _ in 0..<60 { p.env.tick() }
        #expect(p.dismissals.isEmpty)
        #expect(p.summons.count == 1)
    }

    /// Even if the session does end while a ring is up and comes straight back, that's the same drag, not a new one.
    @Test func aDragThatComesRightBackDoesNotReopenTheRing() {
        let p = MonitorProbe()
        p.env.modifierFlags = [.option]
        p.env.beginFileDrag([file])
        p.env.isLeftMouseDown = false
        p.env.tick()
        p.env.tick()
        #expect(p.dismissals == [.dragEnded])
        p.env.isLeftMouseDown = true
        p.env.send(.leftMouseDragged)
        p.env.dragPasteboardChangeCount += 1
        for _ in 0..<60 { p.env.tick() }
        #expect(p.summons.count == 1)
    }

    /// One stale "up" reading, then the main thread stalls while the ring draws: the next tick is past the deadline.
    /// That single reading must not close the ring.
    @Test func aStalledMainThreadDoesNotCloseTheRing() {
        let p = MonitorProbe(grace: 0.2)
        p.env.modifierFlags = [.option]
        p.env.beginFileDrag([file])
        p.env.modifierFlags = []
        p.env.tick()
        p.env.tick(advance: 1.0) // nothing polled for a second
        #expect(p.dismissals.isEmpty)
        #expect(p.monitor.isSummoned)
    }
}

@MainActor
@Suite struct OverlayRealWorldTests {
    /// The poll sees the button up about 8 ms after the drop. That used to cut the chosen wedge's commit short.
    @Test func mouseUpAfterADropKeepsTheCommitMoment() async {
        let env = FakeDragEnvironment()
        let monitor = DragTriggerMonitor(environment: env)
        let overlay = controller()
        let coord = DragCoordinator(monitor: monitor, overlay: overlay, itemsFor: { _ in (items, "") }, onConvert: { _, _ in })
        coord.start()
        env.modifierFlags = [.option]
        env.beginFileDrag([file])
        _ = overlay.draggingMoved(toBottomLeftPoint: wedge)
        #expect(overlay.drop(atBottomLeftPoint: wedge, payload: DragPayload(fileURLs: [file]), promises: []))
        env.endDrag()
        #expect(overlay.model.phase == .committing("image.to-jpg"), "got \(overlay.model.phase)")
        coord.stop()
    }

    /// A ring fading out must not eat a drop aimed at what's underneath: the file would spring back.
    @Test func aRingOnItsWayOutLetsDropsThrough() {
        let o = controller()
        o.present(at: NSPoint(x: 600, y: 500), items: items, centerLabel: "") { _, _ in }
        #expect(!o.panel.ignoresMouseEvents)
        o.dismiss(animated: true)
        #expect(o.panel.ignoresMouseEvents)
        o.present(at: NSPoint(x: 600, y: 500), items: items, centerLabel: "") { _, _ in }
        #expect(!o.panel.ignoresMouseEvents, "a key ring takes drags again")
        o.dismiss(animated: false)
    }
}
