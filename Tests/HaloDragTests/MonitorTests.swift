import AppKit
import Testing
import HaloCore
@testable import HaloDrag

/// Scriptable stand-in for the system: button, modifiers, drag pasteboard, clock.
@MainActor
final class FakeDragEnvironment: DragSystemEnvironment {
    var isLeftMouseDown = false
    var modifierFlags: NSEvent.ModifierFlags = []
    var mouseLocation = NSPoint(x: 500, y: 400)
    var dragPasteboardChangeCount = 10
    var now: TimeInterval = 1000
    var payload = DragPayload.empty
    var reads = 0
    var handler: (@MainActor (DragSystemEvent) -> Void)?
    var tickHandler: (@MainActor () -> Void)?
    var tickInterval: TimeInterval?
    var monitorsInstalled: Bool { handler != nil }
    /// What's under the pointer, and how often the monitor asked (it must not ask on every tick).
    var target: PointerTarget = .desktop
    var targetChecks = 0
    var frontmostProcessID: Int32?
    func pointerTarget(at point: NSPoint) -> PointerTarget { targetChecks += 1; return target }

    func readDragPayload() -> DragPayload { reads += 1; return payload }
    func installEventMonitors(_ handler: @escaping @MainActor (DragSystemEvent) -> Void) { self.handler = handler }
    func removeEventMonitors() { handler = nil }
    func startTicking(interval: TimeInterval, _ handler: @escaping @MainActor () -> Void) { tickInterval = interval; tickHandler = handler }
    func stopTicking() { tickHandler = nil; tickInterval = nil }
    var isTicking: Bool { tickHandler != nil }

    func send(_ e: DragSystemEvent) { handler?(e) }
    func tick(advance: TimeInterval = 1.0 / 60) { now += advance; tickHandler?() }

    /// User presses the button on a file and starts dragging it: a new drag pasteboard is written.
    func beginFileDrag(_ urls: [URL]) {
        isLeftMouseDown = true
        send(.leftMouseDown)
        payload = DragPayload(fileURLs: urls)
        dragPasteboardChangeCount += 1
        send(.leftMouseDragged)
    }

    func endDrag() {
        isLeftMouseDown = false
        send(.leftMouseUp)
    }
}

@MainActor
final class MonitorProbe {
    let env = FakeDragEnvironment()
    let monitor: DragTriggerMonitor
    var summons: [([URL], NSPoint)] = []
    var dismissals: [DragDismissReason] = []

    init(trigger: TriggerKey = .option, grace: TimeInterval = 0.2) {
        monitor = DragTriggerMonitor(trigger: trigger, releaseGracePeriod: grace, environment: env)
        monitor.onSummon = { [unowned self] urls, p in summons.append((urls, p)) }
        monitor.onDismiss = { [unowned self] in dismissals.append(monitor.lastDismissReason!) }
        monitor.start()
    }
}

private let fileA = URL(fileURLWithPath: "/tmp/halo/photo.heic")
private let fileB = URL(fileURLWithPath: "/tmp/halo/report.pdf")

@MainActor
@Suite struct DragTriggerMonitorTests {
    @Test func idleHasNoTimerAndInstallsOnlyMouseMonitors() {
        let p = MonitorProbe()
        #expect(p.env.monitorsInstalled)
        #expect(!p.env.isTicking, "no polling while idle (battery)")
    }

    @Test func summonsWhenFileDragLiveAndTriggerHeld() throws {
        let p = MonitorProbe()
        p.env.mouseLocation = NSPoint(x: 812, y: -140)
        p.env.beginFileDrag([fileA, fileB])
        #expect(p.env.isTicking)
        #expect(abs(try #require(p.env.tickInterval) - 1.0 / 60) < 1e-9)
        #expect(p.summons.isEmpty, "trigger not held yet")
        p.env.tick()
        p.env.modifierFlags = [.option]
        p.env.tick()
        #expect(p.summons.count == 1)
        #expect(p.summons.first?.0 == [fileA, fileB])
        #expect(p.summons.first?.1 == NSPoint(x: 812, y: -140))
        for _ in 0..<30 { p.env.tick() }
        #expect(p.summons.count == 1, "summoned once per drag")
        #expect(p.env.reads == 1, "pasteboard read once per change count")
        #expect(p.monitor.isSummoned)
    }

    @Test func triggerHeldBeforeDragStartsSummonsImmediately() {
        let p = MonitorProbe()
        p.env.modifierFlags = [.option, .command]
        p.env.beginFileDrag([fileA])
        #expect(p.summons.count == 1, "other modifiers alongside the trigger are fine")
    }

    @Test func noSummonWithoutDragPasteboardChange() {
        let p = MonitorProbe()
        p.env.modifierFlags = [.option]
        p.env.payload = DragPayload(fileURLs: [fileA]) // left over from an earlier drag
        p.env.isLeftMouseDown = true
        p.env.send(.leftMouseDown)
        p.env.send(.leftMouseDragged) // e.g. dragging a window or selecting text
        for _ in 0..<10 { p.env.tick() }
        #expect(p.summons.isEmpty)
        #expect(p.env.reads == 0)
    }

    @Test func stalePasteboardWrittenWhileButtonUpIsIgnored() {
        let p = MonitorProbe()
        p.env.modifierFlags = [.option]
        // Some app writes the drag pasteboard with no button down: not a drag.
        p.env.payload = DragPayload(fileURLs: [fileA])
        p.env.dragPasteboardChangeCount += 1
        p.env.isLeftMouseDown = true
        p.env.send(.leftMouseDown) // baseline taken now, includes the stale write
        for _ in 0..<5 { p.env.tick() }
        #expect(p.summons.isEmpty)
    }

    @Test func changeWithoutButtonDownNeverSummons() {
        let p = MonitorProbe()
        p.env.modifierFlags = [.option]
        p.env.payload = DragPayload(fileURLs: [fileA])
        p.env.dragPasteboardChangeCount += 1
        p.env.send(.leftMouseDragged) // spurious event, but the button is not actually down
        #expect(p.summons.isEmpty)
        p.env.tick() // the second "up" reading ends it, 16 ms later
        #expect(p.summons.isEmpty)
        #expect(!p.env.isTicking)
    }

    @Test func missedMouseDownFallsBackToIdleBaseline() {
        let p = MonitorProbe()
        p.env.modifierFlags = [.option]
        p.env.isLeftMouseDown = true
        p.env.payload = DragPayload(fileURLs: [fileA])
        p.env.dragPasteboardChangeCount += 1
        p.env.send(.leftMouseDragged) // first event we see
        #expect(p.summons.count == 1)
    }

    @Test func nonFileDragDoesNotSummon() {
        let p = MonitorProbe()
        p.env.modifierFlags = [.option]
        p.env.beginFileDrag([]) // text / image data only
        for _ in 0..<5 { p.env.tick() }
        #expect(p.summons.isEmpty)
    }

    @Test func otherTriggerKeyIgnoresOption() {
        let p = MonitorProbe(trigger: .shift)
        p.env.modifierFlags = [.option]
        p.env.beginFileDrag([fileA])
        p.env.tick()
        #expect(p.summons.isEmpty)
        p.env.modifierFlags = [.shift]
        p.env.tick()
        #expect(p.summons.count == 1)
    }

    @Test func changingTriggerWhileRunningTakesEffect() {
        let p = MonitorProbe()
        p.monitor.trigger = .control
        p.env.modifierFlags = [.control]
        p.env.beginFileDrag([fileA])
        #expect(p.summons.count == 1)
    }

    @Test func quickReleaseWithinGraceKeepsRing() {
        let p = MonitorProbe(grace: 0.2)
        p.env.modifierFlags = [.option]
        p.env.beginFileDrag([fileA])
        p.env.modifierFlags = []
        p.env.tick(advance: 0.05)
        p.env.tick(advance: 0.1)
        p.env.modifierFlags = [.option]
        p.env.tick(advance: 0.05)
        p.env.modifierFlags = []
        p.env.tick(advance: 0.05)
        p.env.tick(advance: 0.1) // 0.15 into the second release
        #expect(p.dismissals.isEmpty)
        #expect(p.monitor.isSummoned)
    }

    @Test func releaseBeyondGraceDismissesAndRepressSummonsAgain() {
        let p = MonitorProbe(grace: 0.2)
        p.env.modifierFlags = [.option]
        p.env.beginFileDrag([fileA])
        p.env.modifierFlags = []
        p.env.tick(advance: 0.02)
        p.env.tick(advance: 0.1)
        #expect(p.dismissals.isEmpty)
        p.env.tick(advance: 0.15)
        #expect(p.dismissals == [.triggerReleased])
        #expect(!p.monitor.isSummoned)
        #expect(p.env.isTicking, "still watching the same drag")
        // Up for a while, then a deliberate press: the ring comes back at once.
        p.env.tick(advance: 0.7)
        p.env.modifierFlags = [.option]
        p.env.tick()
        #expect(p.summons.count == 2)
    }

    @Test func zeroGraceDismissesOnFirstReleasedTick() {
        let p = MonitorProbe(grace: 0)
        p.env.modifierFlags = [.option]
        p.env.beginFileDrag([fileA])
        p.env.modifierFlags = []
        p.env.tick()
        #expect(p.dismissals == [.triggerReleased])
    }

    @Test func mouseUpEndsSessionAndStopsPolling() {
        let p = MonitorProbe()
        p.env.modifierFlags = [.option]
        p.env.beginFileDrag([fileA])
        p.env.endDrag()
        #expect(p.dismissals == [.dragEnded])
        #expect(!p.env.isTicking)
        #expect(p.monitor.currentPayload == nil)
    }

    @Test func buttonUpSeenByPollWithoutEventEndsSession() {
        let p = MonitorProbe()
        p.env.modifierFlags = [.option]
        p.env.beginFileDrag([fileA])
        p.env.isLeftMouseDown = false // mouse-up event lost (e.g. swallowed by another app's tap)
        p.env.tick()
        #expect(p.dismissals.isEmpty, "one reading can be wrong in a background app")
        p.env.tick()
        #expect(p.dismissals == [.dragEnded])
        #expect(!p.env.isTicking)
    }

    @Test func dragEndWithoutSummonIsSilent() {
        let p = MonitorProbe()
        p.env.beginFileDrag([fileA])
        p.env.endDrag()
        #expect(p.dismissals.isEmpty)
    }

    @Test func nextDragAfterOneEndsWorks() {
        let p = MonitorProbe()
        p.env.modifierFlags = [.option]
        p.env.beginFileDrag([fileA])
        p.env.endDrag()
        p.env.beginFileDrag([fileB])
        #expect(p.summons.map(\.0) == [[fileA], [fileB]])
    }

    @Test func secondMouseDownWhileArmedResetsSession() {
        let p = MonitorProbe()
        p.env.modifierFlags = [.option]
        p.env.beginFileDrag([fileA])
        p.env.send(.leftMouseDown) // missed the mouse-up in between
        #expect(p.dismissals == [.dragEnded])
        for _ in 0..<3 { p.env.tick() }
        #expect(p.summons.count == 1, "old pasteboard is stale for the new press")
    }

    @Test func promisesIgnoredByDefaultButOptIn() {
        let p = MonitorProbe()
        var payloads: [DragPayload] = []
        p.monitor.onSummonPayload = { payload, _ in payloads.append(payload) }
        p.env.modifierFlags = [.option]
        p.env.isLeftMouseDown = true
        p.env.send(.leftMouseDown)
        p.env.payload = DragPayload(promisedTypeIdentifiers: ["public.jpeg"])
        p.env.dragPasteboardChangeCount += 1
        p.env.tick()
        #expect(p.summons.isEmpty)
        p.monitor.summonsForFilePromises = true
        p.env.tick()
        #expect(p.summons.count == 1)
        #expect(p.summons.first?.0 == [])
        #expect(payloads.first?.promisedTypeIdentifiers == ["public.jpeg"])
    }

    @Test func stopWhileSummonedDismissesAndRemovesMonitors() {
        let p = MonitorProbe()
        p.env.modifierFlags = [.option]
        p.env.beginFileDrag([fileA])
        p.monitor.stop()
        #expect(p.dismissals == [.stopped])
        #expect(!p.env.monitorsInstalled)
        #expect(!p.env.isTicking)
        p.env.beginFileDrag([fileB]) // no handler any more
        #expect(p.summons.count == 1)
    }

    @Test func startDuringDragPicksItUp() {
        let env = FakeDragEnvironment()
        env.isLeftMouseDown = true
        env.modifierFlags = [.option]
        let monitor = DragTriggerMonitor(environment: env)
        var count = 0
        monitor.onSummon = { _, _ in count += 1 }
        monitor.start()
        env.payload = DragPayload(fileURLs: [fileA])
        env.dragPasteboardChangeCount += 1
        env.tick()
        #expect(count == 1)
    }

    @Test func triggerFlagsMapping() {
        #expect(TriggerKey.option.flags == .option)
        #expect(TriggerKey.shift.flags == .shift)
        #expect(TriggerKey.control.flags == .control)
        #expect(TriggerKey.function.flags == .function)
    }
}

@Suite struct PasteboardReaderTests {
    @Test func resolvesAndDeduplicatesFileURLs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-drag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("a b.txt")
        try Data("x".utf8).write(to: file)
        // A Finder-style `file:///.file/id=…` reference, bridged from NSURL the way readObjects hands it over.
        let refObject = try #require((file as NSURL).perform(#selector(NSURL.fileReferenceURL))?.takeUnretainedValue() as? NSURL)
        #expect(refObject.absoluteString?.hasPrefix("file:///.file/id=") == true)
        let reference = refObject as URL
        let web = URL(string: "https://example.com/x.png")!
        let out = DragPasteboardReader.resolveFileURLs([reference, file, web])
        #expect(out.map { $0.resolvingSymlinksInPath().path } == [file.resolvingSymlinksInPath().path])
    }

    @Test func readsFileURLsFromARealPasteboard() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-drag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("one.png"), b = dir.appendingPathComponent("two.pdf")
        try Data("x".utf8).write(to: a)
        try Data("y".utf8).write(to: b)
        let pb = NSPasteboard(name: NSPasteboard.Name("halo.test.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.writeObjects([a as NSURL, b as NSURL])
        let payload = DragPasteboardReader.payload(from: pb)
        #expect(payload.fileURLs.map(\.lastPathComponent) == ["one.png", "two.pdf"])
        #expect(!payload.hasFilePromises)

        pb.clearContents()
        pb.setString("just text", forType: .string)
        #expect(DragPasteboardReader.payload(from: pb).isEmpty)
    }

    @Test func fileDragTypesIncludePromises() {
        let types = DragPasteboardReader.fileDragTypes.map(\.rawValue)
        #expect(types.contains(NSPasteboard.PasteboardType.fileURL.rawValue))
        #expect(types.contains("com.apple.NSFilePromiseItemMetaData"))
    }
}

@MainActor
@Suite struct PauseToOpenTests {
    private func probe() -> MonitorProbe {
        let p = MonitorProbe()
        p.monitor.opensOnPause = true
        return p
    }
    private let file = [URL(fileURLWithPath: "/tmp/a.png")]
    private func hold(_ p: MonitorProbe, seconds: Double) { for _ in 0..<Int(seconds * 60) { p.env.tick() } }

    @Test func holdingStillOpensTheRingWithNoKey() {
        let p = probe()
        p.env.beginFileDrag(file)
        hold(p, seconds: 0.3)
        #expect(p.summons.isEmpty, "too soon")
        hold(p, seconds: 0.2)
        #expect(p.summons.count == 1)
        #expect(p.monitor.summonedByPause)
    }

    @Test func steadyMovementNeverOpensIt() {
        let p = probe()
        p.env.beginFileDrag(file)
        for i in 0..<240 {
            p.env.mouseLocation.x += 8
            p.env.mouseLocation.y += CGFloat(i % 2)
            p.env.tick()
        }
        #expect(p.summons.isEmpty)
    }

    @Test func aShakyHandStillCountsAsHoldingStill() {
        let p = probe()
        p.env.beginFileDrag(file)
        for i in 0..<36 {
            p.env.mouseLocation.x = 500 + (i.isMultiple(of: 2) ? 3 : -3)
            p.env.tick()
        }
        #expect(p.summons.count == 1)
    }

    @Test func offMeansOff() {
        let p = MonitorProbe()
        p.env.beginFileDrag(file)
        hold(p, seconds: 2)
        #expect(p.summons.isEmpty)
    }

    @Test func draggingAwayClosesItAndItStaysClosed() {
        let p = probe()
        p.env.beginFileDrag(file)
        hold(p, seconds: 0.5)
        p.env.mouseLocation.x += 100
        p.env.tick()
        #expect(p.dismissals.isEmpty, "still near the ring")
        p.env.mouseLocation.x += 200
        p.env.tick()
        #expect(p.dismissals == [.pointerLeft])
        hold(p, seconds: 2)
        #expect(p.summons.count == 1, "one pause per drag")
    }

    @Test func noRingOverHalosOwnWindow() {
        let p = probe()
        p.monitor.pauseBlocked = { _ in true }
        p.env.beginFileDrag(file)
        hold(p, seconds: 2)
        #expect(p.summons.isEmpty)
    }

    @Test func aNewDragGetsANewPause() {
        let p = probe()
        p.env.beginFileDrag(file)
        hold(p, seconds: 0.5)
        p.env.endDrag()
        #expect(p.dismissals == [.dragEnded])
        p.env.beginFileDrag(file)
        hold(p, seconds: 0.5)
        #expect(p.summons.count == 2)
    }

    @Test func theKeyStillOpensItAtOnceAndReleasingClosesIt() {
        let p = probe()
        p.env.beginFileDrag(file)
        p.env.modifierFlags = .option
        p.env.tick()
        #expect(p.summons.count == 1)
        #expect(!p.monitor.summonedByPause)
        p.env.modifierFlags = []
        hold(p, seconds: 0.5)
        #expect(p.dismissals == [.triggerReleased])
        hold(p, seconds: 2)
        #expect(p.summons.count == 1, "letting go means no, so no pause ring either")
    }
}

