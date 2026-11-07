import AppKit
import Testing
import HaloCore
import HaloUI
@testable import HaloDrag

// Regression tests for the drag review fixes. Panels stay invisible under test (alpha 0), as in the other suites.

private let items = [
    RingItem(id: "image.to-jpg", title: "JPG", subtitle: nil, symbolName: "photo", category: .image),
    RingItem(id: "image.to-png", title: "PNG", subtitle: nil, symbolName: "photo", category: .image),
    RingItem(id: "pdf.from-image", title: "PDF", subtitle: nil, symbolName: "doc", category: .pdf),
    RingItem(id: "text.ocr", title: "Text", subtitle: nil, symbolName: "text.viewfinder", category: .text),
]
private let c = RingMetrics.canvasSize / 2
private let top = NSPoint(x: c, y: c + 110)
private let right = NSPoint(x: c + 110, y: c)
private let fileA = URL(fileURLWithPath: "/tmp/halo/first.heic")
private let fileB = URL(fileURLWithPath: "/tmp/halo/second.heic")

@MainActor
private func makeController(_ timing: RingOverlayTiming = .init(present: 0, commit: 0, dismiss: 0),
                            inbox: URL? = nil) -> RingOverlayController {
    _ = NSApplication.shared
    let root = inbox ?? FileManager.default.temporaryDirectory.appendingPathComponent("halo-fix-inbox-\(UUID().uuidString)")
    let o = RingOverlayController(timing: timing, promiseDestination: root)
    o.respectsReduceMotion = false
    return o
}

private func spin(_ seconds: TimeInterval) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

/// Writes its files when asked; `delay` makes it late.
private final class SlowSource: PromisedFileSource, @unchecked Sendable {
    var promisedCount = 1
    var files: [String] = []
    var delay: TimeInterval = 0
    func deliver(into folder: URL, queue: OperationQueue, reader: @escaping @Sendable (URL, (any Error)?) -> Void) {
        let names = files, delay = self.delay
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            for name in names {
                // A late source writes even if the folder was already cleared.
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent(name)
                try? Data([1]).write(to: url)
                queue.addOperation { reader(url, nil) }
            }
        }
    }
}

@MainActor
@Suite(.serialized) struct ReviewFixDragTests {
    // MARK: 1. A second drag within the drop grace gets its own ring

    @Test func aNewDragDuringTheDropGraceGetsAFreshRing() async {
        let fake = FakeDragEnvironment()
        let monitor = DragTriggerMonitor(environment: fake)
        let overlay = makeController()
        var asked: [[URL]] = []
        var converted: [[URL]] = []
        let coord = DragCoordinator(monitor: monitor, overlay: overlay,
                                    itemsFor: { asked.append($0); return (items, "") }, onConvert: { converted.append($1) })
        coord.dropGracePeriod = 0.15
        coord.start()
        fake.modifierFlags = [.option]
        fake.beginFileDrag([fileA])
        _ = overlay.draggingMoved(toBottomLeftPoint: top)
        fake.endDrag() // over the ring, and no drop comes: the grace timer starts
        #expect(overlay.isPresented)

        fake.beginFileDrag([fileB])
        #expect(asked == [[fileA], [fileB]], "the second drag asked for its own ring")
        #expect(overlay.isPresented)
        #expect(!overlay.isDragInside, "nothing stale from the first drag")
        await spin(0.3)
        #expect(overlay.isPresented, "the first drag's grace timer must not close the new ring")
        #expect(overlay.drop(atBottomLeftPoint: top, payload: DragPayload(fileURLs: [fileB]), promises: []))
        await spin(0.05)
        #expect(converted == [[fileB]])
        coord.stop()
    }

    @Test func aChosenWedgeStillFlashingIsNotReplaced() async {
        let fake = FakeDragEnvironment()
        let monitor = DragTriggerMonitor(environment: fake)
        let overlay = makeController(.init(present: 0, commit: 0.3, dismiss: 0))
        var asked = 0
        let coord = DragCoordinator(monitor: monitor, overlay: overlay, itemsFor: { _ in asked += 1; return (items, "") }, onConvert: { _, _ in })
        coord.start()
        fake.modifierFlags = [.option]
        fake.beginFileDrag([fileA])
        #expect(overlay.drop(atBottomLeftPoint: top, payload: DragPayload(fileURLs: [fileA]), promises: []))
        fake.endDrag()
        fake.beginFileDrag([fileB])
        #expect(asked == 1)
        #expect(overlay.model.phase == .committing("image.to-jpg"))
        coord.stop()
    }

    // MARK: 8. Hub pass-through un-lights the wedge

    @Test func passingThroughTheHubUnlightsTheWedge() {
        let o = makeController()
        o.letsDropsThroughHub = true
        o.present(at: NSPoint(x: 600, y: 500), items: items, centerLabel: "") { _, _ in }
        let mid = NSPoint(x: o.panel.frame.midX, y: o.panel.frame.midY)
        o.pointerMoved(to: NSPoint(x: mid.x + 110, y: mid.y)) // on the right wedge
        #expect(!o.panel.ignoresMouseEvents)
        _ = o.draggingMoved(toBottomLeftPoint: right)
        #expect(o.model.hoveredIndex == 1 && o.isHoveringWedge)
        o.pointerMoved(to: mid) // into the hub: the panel lets the drag through and gets no draggingExited
        #expect(o.panel.ignoresMouseEvents)
        #expect(o.model.hoveredIndex == nil, "the wedge stayed lit")
        #expect(!o.isDragInside && !o.isHoveringWedge, "a stale hover would hold the ring open")
        o.dismiss(animated: false)
    }

    // MARK: 9. The chosen wedge keeps its highlight through draggingEnded

    @Test func draggingEndedDuringTheCommitFlashKeepsTheChoiceLit() {
        let o = makeController(.init(present: 0, commit: 1, dismiss: 0))
        o.present(at: NSPoint(x: 600, y: 500), items: items, centerLabel: "") { _, _ in }
        _ = o.draggingMoved(toBottomLeftPoint: right)
        #expect(o.drop(atBottomLeftPoint: right, payload: DragPayload(fileURLs: [fileA]), promises: []))
        o.draggingLeft() // what draggingEnded calls right after the drop
        #expect(o.model.phase == .committing("image.to-png"))
        #expect(o.model.hoveredIndex == 1)
        o.dismiss(animated: false)
    }

    // MARK: 6, 7, 13. Promised drops

    @Test func eachPromisedDropHasItsOwnID() async {
        let o = makeController()
        var began: [UUID] = [], ended: [UUID] = []
        o.onPromiseDelivery = { e in
            switch e {
            case .began(let id, _, _, _): began.append(id)
            case .ended(let id, _, _, _): ended.append(id)
            case .couldNotReceive: break
            }
        }
        for name in ["a.heic", "b.heic"] {
            o.present(at: NSPoint(x: 600, y: 500), items: items, centerLabel: "") { _, _ in }
            let source = SlowSource()
            source.files = [name]
            #expect(o.drop(atBottomLeftPoint: top, payload: DragPayload(promisedTypeIdentifiers: ["public.heic"]), promises: [source]))
        }
        await spin(0.2)
        #expect(began.count == 2 && Set(began).count == 2)
        #expect(Set(ended) == Set(began))
    }

    @Test func noRoomForTheFilesIsNotBlamedOnTheSourceApp() async throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("halo-fix-file-\(UUID().uuidString)")
        try Data([1]).write(to: blocker)
        let o = makeController(inbox: blocker.appendingPathComponent("inbox")) // a folder can't go inside a file
        var events: [String] = []
        o.onPromiseDelivery = { e in
            switch e {
            case .began: events.append("began")
            case .ended: events.append("ended")
            case .couldNotReceive(_, let n): events.append("couldNotReceive \(n)")
            }
        }
        o.present(at: NSPoint(x: 600, y: 500), items: items, centerLabel: "") { _, _ in }
        #expect(o.drop(atBottomLeftPoint: top, payload: DragPayload(promisedTypeIdentifiers: ["public.heic"]), promises: [SlowSource()]))
        await spin(0.05)
        #expect(events == ["couldNotReceive 1"])
    }

    @Test func aFileArrivingAfterTheTimeoutIsCleanedUp() async throws {
        let o = makeController()
        o.promiseTimeout = 0.05
        var called = false
        o.present(at: NSPoint(x: 600, y: 500), items: items, centerLabel: "") { _, _ in called = true }
        let source = SlowSource()
        source.files = ["late.heic"]
        source.delay = 0.2
        #expect(o.drop(atBottomLeftPoint: top, payload: DragPayload(promisedTypeIdentifiers: ["public.heic"]), promises: [source]))
        await spin(0.5)
        #expect(!called)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: o.promiseDestination.path)) ?? []
        #expect(left.isEmpty, "the late file and its folder are gone: \(left)")
    }

    @Test func theSourceIsReleasedOnceTheDropFinishes() async {
        let o = makeController()
        o.promiseTimeout = 300
        o.present(at: NSPoint(x: 600, y: 500), items: items, centerLabel: "") { _, _ in }
        weak var weakSource: SlowSource?
        do {
            let source = SlowSource()
            source.files = ["a.heic"]
            source.delay = 0.15 // still on its way when we look
            weakSource = source
            #expect(o.drop(atBottomLeftPoint: top, payload: DragPayload(promisedTypeIdentifiers: ["public.heic"]), promises: [source]))
        }
        #expect(o.lastPromiseCollector?.retainedCount == 1, "held while the file is on its way")
        #expect(weakSource != nil)
        await spin(0.4)
        #expect(o.lastPromiseCollector?.isFinished ?? true)
        #expect((o.lastPromiseCollector?.retainedCount ?? 0) == 0)
        #expect(weakSource == nil, "kept for the whole 300 s timeout")
    }

    @Test func aCollectorDropsLateFilesAndItsReceivers() async {
        let probe = LateProbe()
        let receiver = NSObject()
        probe.collector.retain([receiver])
        #expect(probe.collector.retainedCount == 1)
        probe.collector.expire()
        #expect(probe.collector.retainedCount == 0)
        probe.collector.add(URL(fileURLWithPath: "/inbox/x/late.heic"))
        #expect(probe.late == [URL(fileURLWithPath: "/inbox/x/late.heic")])
        await spin(0.05)
        #expect(probe.results == [[]])
    }
}

private final class LateProbe: @unchecked Sendable {
    var results: [[URL]] = []
    var late: [URL] = []
    lazy var collector = PromiseCollector(expected: 1, isAcceptable: { _ in true }, onLate: { [weak self] in self?.late.append($0) }) {
        [weak self] urls, _ in self?.results.append(urls)
    }
}

// MARK: 10. Drag events tick at most every 8 ms

@MainActor
@Suite struct DragTickThrottleTests {
    @Test func aFastMouseCanNotRunTheTickAtEveryEvent() {
        let p = MonitorProbe()
        p.env.beginFileDrag([fileA])
        #expect(p.env.reads == 1, "the first drag event reacts at once")
        // New contents on the pasteboard, then a burst of drag events 1 ms apart.
        p.env.payload = DragPayload(fileURLs: [fileB])
        p.env.dragPasteboardChangeCount += 1
        for _ in 0..<5 {
            p.env.now += 0.001
            p.env.send(.leftMouseDragged)
        }
        #expect(p.env.reads == 1, "throttled inside 8 ms")
        p.env.now += 0.004
        p.env.send(.leftMouseDragged)
        #expect(p.env.reads == 2, "runs again once 8 ms have passed")
    }
}
