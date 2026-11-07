import AppKit
import Testing
import HaloCore
import HaloUI
@testable import HaloDrag

private let items = [
    RingItem(id: "image.to-jpg", title: "JPG", subtitle: nil, symbolName: "photo", category: .image),
    RingItem(id: "image.to-png", title: "PNG", subtitle: nil, symbolName: "photo", category: .image),
    RingItem(id: "pdf.from-image", title: "PDF", subtitle: nil, symbolName: "doc", category: .pdf),
    RingItem(id: "text.ocr", title: "Text", subtitle: nil, symbolName: "text.viewfinder", category: .text),
]
private let c = RingMetrics.canvasSize / 2
private let top = NSPoint(x: c, y: c + 110)    // segment 0 in the drop view's y-up coordinates
private let right = NSPoint(x: c + 110, y: c)  // segment 1
private let file = URL(fileURLWithPath: "/tmp/halo/photo.heic")

@MainActor
private func makeController(_ timing: RingOverlayTiming = .init(present: 0, commit: 0, dismiss: 0)) -> RingOverlayController {
    _ = NSApplication.shared
    let o = RingOverlayController(timing: timing)
    o.respectsReduceMotion = false
    return o
}

@MainActor
private func spin(_ seconds: TimeInterval) async {
    try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
}

@MainActor
@Suite(.serialized) struct RingOverlayControllerTests {
    @Test func panelIsConfiguredToNeverStealFocus() {
        let o = makeController()
        let p = o.panel
        #expect(p.styleMask.contains(.nonactivatingPanel))
        #expect(p.styleMask.contains(.borderless))
        #expect(!p.canBecomeKey && !p.canBecomeMain)
        #expect(p.level.rawValue == 102)
        #expect(p.level.rawValue < Int(CGWindowLevelForKey(.draggingWindow)), "drag image must stay above the ring")
        #expect(p.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]))
        #expect(!p.isOpaque && !p.hasShadow && !p.hidesOnDeactivate && !p.ignoresMouseEvents)
        #expect(p.frame.size == NSSize(width: RingMetrics.canvasSize, height: RingMetrics.canvasSize))
        #expect(o.dropView.registeredDraggedTypes.contains(.fileURL))
        #expect(p.contentView?.subviews.last === o.dropView, "drop view sits above the hosting view")
    }

    @Test func presentDismissPhases() async {
        let o = makeController(.init(present: 0.05, commit: 0, dismiss: 0.05))
        var dropped = false
        o.present(at: NSPoint(x: 600, y: 500), items: items, centerLabel: "photo.heic") { _, _ in dropped = true }
        #expect(o.model.phase == .presenting)
        #expect(o.isPresented)
        #expect(o.model.items == items && o.model.centerLabel == "photo.heic")
        await spin(0.15)
        #expect(o.model.phase == .shown)
        o.dismiss(animated: true)
        #expect(o.model.phase == .dismissing)
        #expect(!o.isPresented)
        await spin(0.15)
        #expect(o.model.phase == .hidden)
        #expect(!o.panel.isVisible)
        #expect(!dropped)
    }

    @Test func representDuringDismissCancelsPendingOrderOut() async {
        let o = makeController(.init(present: 0, commit: 0, dismiss: 0.1))
        o.present(at: NSPoint(x: 600, y: 500), items: items, centerLabel: "") { _, _ in }
        o.dismiss(animated: true)
        o.present(at: NSPoint(x: 700, y: 500), items: items, centerLabel: "") { _, _ in }
        await spin(0.2)
        #expect(o.model.phase == .shown)
        #expect(o.panel.isVisible)
        o.dismiss(animated: false)
        #expect(o.model.phase == .hidden)
    }

    @Test func hoverMapsSegmentsAndRejectsCentre() {
        let o = makeController()
        var hovers: [Int?] = []
        o.onHoverChange = { hovers.append($0) }
        o.present(at: NSPoint(x: 600, y: 500), items: items, centerLabel: "") { _, _ in }
        #expect(o.draggingMoved(toBottomLeftPoint: NSPoint(x: c, y: c)) == [])
        #expect(o.model.hoveredIndex == nil)
        #expect(o.isAwaitingDrop)
        #expect(o.draggingMoved(toBottomLeftPoint: top) == .copy)
        #expect(o.model.hoveredIndex == 0)
        #expect(o.draggingMoved(toBottomLeftPoint: right) == .copy)
        #expect(o.model.hoveredIndex == 1)
        o.draggingLeft()
        #expect(o.model.hoveredIndex == nil)
        #expect(!o.isAwaitingDrop)
        #expect(hovers == [0, 1, nil])
        o.dismiss(animated: false)
    }

    @Test func dropOnSegmentCommitsAndCallsBack() async {
        let o = makeController(.init(present: 0, commit: 0.05, dismiss: 0.05))
        var got: (ActionID, [URL])?
        o.present(at: NSPoint(x: 600, y: 500), items: items, centerLabel: "") { got = ($0, $1) }
        _ = o.draggingMoved(toBottomLeftPoint: right)
        #expect(o.drop(atBottomLeftPoint: right, payload: DragPayload(fileURLs: [file]), promises: []))
        #expect(o.model.phase == .committing("image.to-png"))
        #expect(o.isPresented)
        await spin(0.02)
        #expect(got?.0 == "image.to-png")
        #expect(got?.1 == [file])
        await spin(0.06)
        #expect(o.model.phase == .dismissing)
        await spin(0.1)
        #expect(o.model.phase == .hidden)
        #expect(!o.panel.isVisible)
    }

    @Test func dropInCentreOrWhenDismissingIsRefused() {
        let o = makeController(.init(present: 0, commit: 0, dismiss: 1))
        var calls = 0
        o.present(at: NSPoint(x: 600, y: 500), items: items, centerLabel: "") { _, _ in calls += 1 }
        #expect(!o.drop(atBottomLeftPoint: NSPoint(x: c, y: c), payload: DragPayload(fileURLs: [file]), promises: []))
        #expect(!o.drop(atBottomLeftPoint: top, payload: .empty, promises: []), "nothing to convert")
        o.dismiss(animated: true)
        #expect(o.draggingMoved(toBottomLeftPoint: top) == [])
        #expect(!o.drop(atBottomLeftPoint: top, payload: DragPayload(fileURLs: [file]), promises: []))
        #expect(calls == 0)
        o.dismiss(animated: false)
    }

    @Test func reducedMotionTimingIsInstantForMovement() {
        #expect(RingOverlayTiming.reducedMotion.present == 0)
        #expect(RingOverlayTiming.standard.commit == RingMotion.commitDuration)
        #expect(RingOverlayTiming.standard.dismiss == RingMotion.dismissDuration)
        #expect(RingOverlayTiming.standard.present == RingMotion.presentDuration)
    }
}

// MARK: - Coordinator

@MainActor
final class FakeMonitor: DragTriggerMonitoring {
    var trigger: TriggerKey = .option
    var onSummon: (([URL], NSPoint) -> Void)?
    var onDismiss: (() -> Void)?
    var running = false
    func start() { running = true }
    func stop() { running = false }
}

@MainActor
final class FakeOverlay: RingOverlayPresenting {
    var presented: [(NSPoint, [RingItem], String)] = []
    var dismissed = 0
    var onDrop: ((ActionID, [URL]) -> Void)?
    var isPresented = false
    func present(at screenPoint: NSPoint, items: [RingItem], centerLabel: String, onDrop: @escaping (ActionID, [URL]) -> Void) {
        presented.append((screenPoint, items, centerLabel))
        self.onDrop = onDrop
        isPresented = true
    }
    func dismiss(animated: Bool) { dismissed += 1; isPresented = false }
}

@MainActor
@Suite struct DragCoordinatorTests {
    @Test func summonPresentsItemsAndDropConverts() {
        let m = FakeMonitor(), o = FakeOverlay()
        var asked: [[URL]] = []
        var converted: [(ActionID, [URL])] = []
        let coord = DragCoordinator(monitor: m, overlay: o,
                                    itemsFor: { urls in asked.append(urls); return (items, "\(urls.count) file") },
                                    onConvert: { converted.append(($0, $1)) })
        coord.start()
        #expect(m.running)
        m.onSummon?([file], NSPoint(x: 10, y: 20))
        #expect(asked == [[file]])
        #expect(o.presented.count == 1)
        #expect(o.presented.first?.0 == NSPoint(x: 10, y: 20))
        #expect(o.presented.first?.2 == "1 file")
        o.onDrop?("image.to-jpg", [file])
        #expect(converted.first?.0 == "image.to-jpg")
        #expect(converted.first?.1 == [file])
        coord.trigger = .shift
        #expect(m.trigger == .shift)
    }

    @Test func emptyItemsMeansNoRing() {
        let m = FakeMonitor(), o = FakeOverlay()
        let coord = DragCoordinator(monitor: m, overlay: o, itemsFor: { _ in ([], "") }, onConvert: { _, _ in })
        coord.start()
        m.onSummon?([file], .zero)
        #expect(o.presented.isEmpty)
        m.onSummon?([], .zero)
        #expect(o.presented.isEmpty)
    }

    @Test func dismissHidesRingAndStopDismissesImmediately() {
        let m = FakeMonitor(), o = FakeOverlay()
        let coord = DragCoordinator(monitor: m, overlay: o, itemsFor: { _ in (items, "") }, onConvert: { _, _ in })
        coord.start()
        m.onSummon?([file], .zero)
        m.onDismiss?()
        #expect(o.dismissed == 1)
        m.onDismiss?() // already hidden: no-op
        #expect(o.dismissed == 1)
        coord.stop()
        #expect(!m.running)
    }

    @Test func dragEndOverRingWaitsForDrop() async {
        let env = FakeDragEnvironment()
        let monitor = DragTriggerMonitor(environment: env)
        let overlay = makeController(.init(present: 0, commit: 0, dismiss: 0))
        var converted: [ActionID] = []
        let coord = DragCoordinator(monitor: monitor, overlay: overlay, itemsFor: { _ in (items, "") }, onConvert: { id, _ in converted.append(id) })
        coord.dropGracePeriod = 0.1
        coord.start()
        env.modifierFlags = [.option]
        env.beginFileDrag([file])
        #expect(overlay.isPresented)
        _ = overlay.draggingMoved(toBottomLeftPoint: top)
        env.endDrag() // poll sees the button up before performDragOperation arrives
        #expect(overlay.isPresented, "held back while a drop may still land")
        #expect(overlay.drop(atBottomLeftPoint: top, payload: DragPayload(fileURLs: [file]), promises: []))
        await spin(0.2)
        #expect(converted == ["image.to-jpg"])
        #expect(overlay.model.phase == .hidden)

        // Drag ends with the cursor outside the ring: dismissed straight away.
        env.beginFileDrag([file])
        #expect(overlay.isPresented)
        env.endDrag()
        #expect(!overlay.isPresented)
        coord.stop()
    }
}

// MARK: - Live window-server checks (HALO_LIVE=1 swift test …). They briefly show an invisible panel.

private let live = ProcessInfo.processInfo.environment["HALO_LIVE"] == "1"

@MainActor
@Suite(.serialized, .enabled(if: live)) struct LiveOverlayTests {
    /// loginwindow covers the display with shield windows (level ≥ 2000) while the Mac is locked.
    private func screenIsLocked() -> Bool {
        let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return all.contains { ($0[kCGWindowOwnerName as String] as? String) == "loginwindow" && ($0[kCGWindowLayer as String] as? Int ?? 0) >= 2000 }
    }

    private func windowInfo(_ number: Int) -> [String: Any]? {
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]]
        return list?.first
    }

    @Test func panelAppearsCentredAtLevelWithoutActivating() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let o = makeController()
        let screen = try #require(NSScreen.main)
        let point = NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        o.present(at: point, items: items, centerLabel: "x") { _, _ in }
        await spin(0.3)
        #expect(o.panel.isVisible)
        #expect(!o.panel.isKeyWindow)
        #expect(!app.isActive)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == front, "source app keeps focus")
        let info = try #require(windowInfo(o.panel.windowNumber))
        #expect(info[kCGWindowLayer as String] as? Int == 102)
        let b = try #require(info[kCGWindowBounds as String] as? [String: CGFloat])
        // CG bounds are top-left based: flip with the primary screen's height.
        let primaryH = NSScreen.screens[0].frame.height
        let cgMid = NSPoint(x: b["X"]! + b["Width"]! / 2, y: primaryH - (b["Y"]! + b["Height"]! / 2))
        if screenIsLocked() {
            // The lock screen draws the desktop scaled (~0.9) about the screen centre; only shape is comparable.
            print("screen locked: CG bounds \(b) are lock-screen transformed; panel frame \(o.panel.frame)")
            #expect(abs(b["Width"]! - b["Height"]!) <= 1)
        } else {
            #expect(abs(cgMid.x - point.x) < 1)
            #expect(abs(cgMid.y - point.y) < 1)
            #expect(b["Width"] == RingMetrics.canvasSize)
        }
        #expect(o.panel.frame.midX == point.x && o.panel.frame.midY == point.y)
        o.dismiss(animated: false)
        await spin(0.1)
        #expect(windowInfo(o.panel.windowNumber)?[kCGWindowIsOnscreen as String] as? Bool != true)
    }

    @Test func panelClampsAtScreenCornerOnEveryDisplay() async throws {
        _ = NSApplication.shared
        let o = makeController()
        for screen in NSScreen.screens {
            let corner = NSPoint(x: screen.frame.maxX - 1, y: screen.frame.minY + 1)
            o.present(at: corner, items: items, centerLabel: "") { _, _ in }
            await spin(0.1)
            #expect(screen.visibleFrame.contains(o.panel.frame), "\(screen.localizedName)")
            o.dismiss(animated: false)
        }
    }

    @Test func liveEnvironmentReadsTheSystemDragPasteboardWithoutPrompting() {
        let env = LiveDragSystemEnvironment()
        _ = env.dragPasteboardChangeCount
        let payload = env.readDragPayload()
        // Whatever the last real drag was, any file URLs must be resolved path URLs, never /.file/id= references.
        #expect(payload.fileURLs.allSatisfy { !$0.path.hasPrefix("/.file/") })
        print("live drag pasteboard:", payload.fileURLs.map(\.path), payload.promisedTypeIdentifiers)
        if #available(macOS 15.4, *) {
            print("drag pasteboard accessBehavior:", NSPasteboard(name: .drag).accessBehavior.rawValue)
        }
    }
}
