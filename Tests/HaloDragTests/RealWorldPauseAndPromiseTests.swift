import AppKit
import Testing
import HaloCore
import HaloUI
@testable import HaloDrag

private let items = [
    RingItem(id: "image.to-jpg", title: "JPG", subtitle: nil, symbolName: "photo", category: .image),
    RingItem(id: "image.to-png", title: "PNG", subtitle: nil, symbolName: "photo", category: .image),
]
private let c = RingMetrics.canvasSize / 2
private let wedge = NSPoint(x: c - 110, y: c) // a two-item ring starts at 6 o'clock, so its first wedge is on the left
private let file = URL(fileURLWithPath: "/tmp/halo/photo.heic")

@MainActor
private func hold(_ p: MonitorProbe, seconds: Double) { for _ in 0..<Int(seconds * 60) { p.env.tick() } }

@MainActor
private func spin(_ seconds: TimeInterval) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

// MARK: - Pause false positives

@MainActor
@Suite struct PauseFalsePositiveTests {
    private func probe(target: PointerTarget, source: Int32? = 100) -> MonitorProbe {
        let p = MonitorProbe()
        p.monitor.opensOnPause = true
        p.env.target = target
        p.env.frontmostProcessID = source
        return p
    }

    /// Hovering a Dock icon is how you open a file in that app, and the Trash is there.
    @Test func noRingOverTheDock() {
        let p = probe(target: .blocked)
        p.env.beginFileDrag([file])
        hold(p, seconds: 3)
        #expect(p.summons.isEmpty)
    }

    /// Hesitating over a browser's upload area means "about to drop here".
    @Test func anotherAppsWindowTakesALongerPause() {
        let p = probe(target: .window(number: 7, pid: 200))
        p.env.beginFileDrag([file])
        hold(p, seconds: 0.8)
        #expect(p.summons.isEmpty, "not at the normal pause")
        hold(p, seconds: 0.6)
        #expect(p.summons.count == 1, "but the ring is still reachable by staying")
    }

    /// In the window the file came from, or on the Desktop, a pause is the gesture.
    @Test func theSourceAppsOwnWindowOpensAtOnce() {
        let p = probe(target: .window(number: 7, pid: 100))
        p.env.beginFileDrag([file])
        hold(p, seconds: 0.5)
        #expect(p.summons.count == 1)

        let desktop = probe(target: .desktop)
        desktop.env.beginFileDrag([file])
        hold(desktop, seconds: 0.5)
        #expect(desktop.summons.count == 1)

        let own = probe(target: .window(number: 7, pid: getpid()))
        own.env.beginFileDrag([file])
        hold(own, seconds: 0.5)
        #expect(own.summons.count == 1, "Frenzy's own onboarding window counts")
    }

    @Test func theKeyAlwaysWorksEvenOverTheDock() {
        let p = probe(target: .blocked)
        p.env.beginFileDrag([file])
        p.env.modifierFlags = .option
        p.env.tick()
        #expect(p.summons.count == 1, "holding the key is a clear request")
    }

    /// What's under the pointer costs a window-list call, so it isn't asked on every tick.
    @Test func thePointerTargetIsNotPolled() {
        let p = probe(target: .window(number: 7, pid: 200))
        p.env.beginFileDrag([file])
        hold(p, seconds: 1)
        #expect(p.env.targetChecks <= 1)
    }

    /// A folder spring-loads under the pause ring: the new window is what the user was waiting for, so the ring leaves.
    @Test func aWindowOpeningUnderAStillPointerClosesThePauseRing() {
        let p = probe(target: .desktop)
        p.env.beginFileDrag([file])
        hold(p, seconds: 0.5)
        #expect(p.summons.count == 1)
        hold(p, seconds: 0.5)
        #expect(p.dismissals.isEmpty, "nothing changed yet")
        p.env.target = .window(number: 9, pid: 100)
        hold(p, seconds: 0.4)
        #expect(p.dismissals == [.underlyingChanged])
        hold(p, seconds: 2)
        #expect(p.summons.count == 1, "and it doesn't come back")
    }

    @Test func aResultCardAppearingUnderThePointerIsNotASpringLoad() {
        let p = probe(target: .desktop)
        p.env.beginFileDrag([file])
        hold(p, seconds: 0.5)
        p.env.target = .window(number: 9, pid: getpid())
        hold(p, seconds: 0.5)
        #expect(p.dismissals.isEmpty)
    }

    /// Moving over another window on the way to a wedge isn't a spring-load.
    @Test func movingOntoAnotherWindowDoesNotCloseIt() {
        let p = probe(target: .desktop)
        p.env.beginFileDrag([file])
        hold(p, seconds: 0.5)
        p.env.mouseLocation.x += 100
        p.env.target = .window(number: 9, pid: 100)
        hold(p, seconds: 0.5)
        #expect(p.dismissals.isEmpty)
    }

    /// At a screen edge the ring is pushed away from the pointer. Far wedges must stay reachable.
    @Test func nearAScreenEdgeFarWedgesAreStillReachable() {
        let p = probe(target: .desktop)
        p.env.mouseLocation = NSPoint(x: 500, y: 10)
        p.monitor.pauseLeaveCenter = { NSPoint(x: 500, y: 220) } // canvas clamped up from the bottom edge
        p.env.beginFileDrag([file])
        hold(p, seconds: 0.5)
        #expect(p.summons.count == 1)
        p.env.mouseLocation = NSPoint(x: 500, y: 380) // the top wedge: 370 pt from where it opened
        hold(p, seconds: 0.1)
        #expect(p.dismissals.isEmpty, "got \(p.dismissals)")
        p.env.mouseLocation = NSPoint(x: 500, y: 700)
        hold(p, seconds: 0.1)
        #expect(p.dismissals == [.pointerLeft])
    }

    /// Letting go of the key a moment before the mouse, with the pointer on a wedge, must not drop onto what's below.
    @Test func releasingTheKeyOverAWedgeKeepsTheRing() {
        let p = MonitorProbe(grace: 0.2)
        var overWedge = true
        p.monitor.holdsOpen = { overWedge }
        p.env.modifierFlags = [.option]
        p.env.beginFileDrag([file])
        p.env.modifierFlags = []
        hold(p, seconds: 1)
        #expect(p.dismissals.isEmpty)
        overWedge = false
        hold(p, seconds: 0.5)
        #expect(p.dismissals == [.triggerReleased])
    }
}

// MARK: - What's under the pointer

@Suite struct PointerTargetTests {
    private let screen: [(frame: NSRect, visible: NSRect)] = [(NSRect(x: 0, y: 0, width: 1000, height: 800), NSRect(x: 0, y: 70, width: 1000, height: 705))]
    private func classify(_ point: NSPoint, _ windows: [OnScreenWindow], dockPID: Int32 = 1) -> PointerTarget {
        PointerTargetClassifier.classify(point: point, windows: windows, screens: screen, bundleID: { $0 == dockPID ? "com.apple.dock" : "com.example.app" })
    }
    private let everywhere = CGRect(x: 0, y: 0, width: 1000, height: 800)

    @Test func theDockAndMenuBarZonesAreBlocked() {
        #expect(classify(NSPoint(x: 500, y: 30), []) == .blocked, "the Dock's strip")
        #expect(classify(NSPoint(x: 500, y: 790), []) == .blocked, "the menu bar")
        #expect(classify(NSPoint(x: 500, y: 400), []) == .desktop)
    }

    /// A hidden Dock slides over the visible area, so its window has to be recognised too.
    @Test func anAutoHiddenDockIsRecognisedByItsWindow() {
        let dock = OnScreenWindow(number: 1, pid: 1, layer: 20, bounds: CGRect(x: 100, y: 600, width: 800, height: 100))
        #expect(classify(NSPoint(x: 500, y: 150), [dock]) == .blocked)
        #expect(classify(NSPoint(x: 500, y: 400), [dock]) == .desktop, "elsewhere it doesn't matter")
    }

    /// The drag image rides right under the pointer at level 500. If it counted, every pause would be "over" it.
    @Test func theDragImageAndPopUpsAreSeenThrough() {
        let image = OnScreenWindow(number: 2, pid: 50, layer: 500, bounds: everywhere)
        let ring = OnScreenWindow(number: 3, pid: 60, layer: 102, bounds: everywhere)
        let app = OnScreenWindow(number: 4, pid: 70, layer: 0, bounds: everywhere)
        #expect(classify(NSPoint(x: 500, y: 400), [image, ring, app]) == .window(number: 4, pid: 70))
    }

    @Test func theFrontmostWindowAtThePointWins() {
        let front = OnScreenWindow(number: 4, pid: 70, layer: 0, bounds: CGRect(x: 0, y: 0, width: 200, height: 200))
        let back = OnScreenWindow(number: 5, pid: 71, layer: 0, bounds: everywhere)
        // y is flipped: AppKit's (100, 700) is 100 down from the top.
        #expect(classify(NSPoint(x: 100, y: 700), [front, back]) == .window(number: 4, pid: 70))
        #expect(classify(NSPoint(x: 500, y: 400), [front, back]) == .window(number: 5, pid: 71))
    }

    /// During Finder drags macOS puts a see-through, screen-sized tiling layer (a system app's window) on top.
    /// It must not count as the Dock, or a pause over Finder never opens the ring.
    @Test func aScreenSizedSystemOverlayIsSeenThrough() {
        let overlay = OnScreenWindow(number: 8, pid: 1, layer: 20, bounds: everywhere)
        let finder = OnScreenWindow(number: 9, pid: 74, layer: 0, bounds: CGRect(x: 100, y: 100, width: 600, height: 500))
        #expect(classify(NSPoint(x: 300, y: 500), [overlay, finder]) == .window(number: 9, pid: 74))
        #expect(classify(NSPoint(x: 900, y: 400), [overlay]) == .desktop)
        #expect(classify(NSPoint(x: 500, y: 30), [overlay]) == .blocked, "the Dock's zone stays blocked")
    }

    @Test func invisibleWindowsAndTheDesktopLayer() {
        let ghost = OnScreenWindow(number: 6, pid: 72, layer: 0, alpha: 0, bounds: everywhere)
        let icons = OnScreenWindow(number: 7, pid: 73, layer: -2147483603, bounds: everywhere)
        #expect(classify(NSPoint(x: 500, y: 400), [ghost, icons]) == .desktop)
    }

    /// A second display to the left, with no menu-bar strip of its own in this set-up.
    @Test func aSecondDisplayIsJudgedByItsOwnFrames() {
        let screens: [(frame: NSRect, visible: NSRect)] = [
            (NSRect(x: 0, y: 0, width: 1000, height: 800), NSRect(x: 0, y: 0, width: 1000, height: 775)),
            (NSRect(x: -1200, y: 0, width: 1200, height: 900), NSRect(x: -1200, y: 0, width: 1200, height: 875)),
        ]
        #expect(PointerTargetClassifier.classify(point: NSPoint(x: -600, y: 890), windows: [], screens: screens, bundleID: { _ in nil }) == .blocked)
        #expect(PointerTargetClassifier.classify(point: NSPoint(x: -600, y: 400), windows: [], screens: screens, bundleID: { _ in nil }) == .desktop)
    }
}

// MARK: - The key

@Suite struct FlagReadingTests {
    /// Either source reading "down" counts, so one stale read can't close the ring.
    @Test @MainActor func eitherSourceCounts() {
        #expect(LiveDragSystemEnvironment.merged([], .maskAlternate).contains(.option))
        #expect(LiveDragSystemEnvironment.merged(.option, []).contains(.option))
        #expect(!LiveDragSystemEnvironment.merged([], []).contains(.option))
        #expect(LiveDragSystemEnvironment.merged([], .maskSecondaryFn).contains(.function))
        #expect(LiveDragSystemEnvironment.merged([], .maskControl).contains(.control))
        #expect(LiveDragSystemEnvironment.merged([], .maskShift).contains(.shift))
    }
}

/// Reads the real window list and key state. Shows nothing, moves nothing, and asks for no permission.
@MainActor
@Suite struct LiveReadTests {
    @Test func theLiveReadsWorkWithNoPermission() {
        let live = LiveDragSystemEnvironment()
        _ = live.pointerTarget(at: NSPoint(x: 400, y: 400))
        _ = live.modifierFlags
        #expect(live.flagDiagnostics.contains("appKit=") && live.flagDiagnostics.contains("session="))
    }
}

// MARK: - What a drag carries

@Suite struct PayloadClassifyTests {
    private let jpeg = NSPasteboard.PasteboardType("public.jpeg")
    private let url = NSPasteboard.PasteboardType.URL

    @Test func promisesComeFirst() {
        let p = DragPasteboardReader.classify(promisedTypes: ["public.jpeg"], pasteboardTypes: [.tiff, url])
        #expect(p.promisedTypeIdentifiers == ["public.jpeg"])
        #expect(p.inlineImageType == nil && !p.isLinkOnly && p.hasFilePromises)
    }

    @Test func imageBytesWithALinkAreAnImage() {
        let p = DragPasteboardReader.classify(promisedTypes: [], pasteboardTypes: [url, .tiff, jpeg])
        #expect(p.inlineImageType == "public.jpeg", "the file as it was beats a re-encoded TIFF")
        #expect(!p.isLinkOnly && !p.isEmpty)
    }

    @Test func aBareLinkIsJustALink() {
        let p = DragPasteboardReader.classify(promisedTypes: [], pasteboardTypes: [url, .string])
        #expect(p.isLinkOnly && !p.isEmpty)
    }

    @Test func plainTextIsNothing() {
        #expect(DragPasteboardReader.classify(promisedTypes: [], pasteboardTypes: [.string]).isEmpty)
    }

    /// The older promise form lists file extensions, not types.
    @Test func olderPromisesNameExtensions() {
        #expect(DragPasteboardReader.normalisedType("jpg") == "public.jpeg")
        #expect(DragPasteboardReader.normalisedType("public.heic") == "public.heic")
    }

    @Test func aRealPasteboardWithImageBytes() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("halo.test.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setData(Data([9, 9]), forType: .png)
        pb.setString("https://example.com/a.png", forType: .URL)
        let payload = DragPasteboardReader.payload(from: pb)
        #expect(payload.inlineImageType == NSPasteboard.PasteboardType.png.rawValue)
        #expect(DragPasteboardReader.inlineImage(for: payload, from: pb) == Data([9, 9]))
    }

    /// A real file drag is untouched by any of this.
    @Test func realFilesStillWin() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-pb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let real = dir.appendingPathComponent("a.png")
        try Data([1]).write(to: real)
        let pb = NSPasteboard(name: NSPasteboard.Name("halo.test.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.writeObjects([real as NSURL])
        let payload = DragPasteboardReader.payload(from: pb)
        #expect(payload.fileURLs.count == 1)
        #expect(payload.inlineImageType == nil && !payload.hasWebLink)
    }

    @Test func theRingAcceptsWhatItOffers() {
        let types = DragPasteboardReader.fileDragTypes.map(\.rawValue)
        #expect(types.contains(NSPasteboard.PasteboardType.tiff.rawValue) && types.contains("public.jpeg"))
    }
}

// MARK: - Monitor with promises and links

@MainActor
@Suite struct PromiseSummonTests {
    private func drag(_ p: MonitorProbe, _ payload: DragPayload) {
        p.env.isLeftMouseDown = true
        p.env.send(.leftMouseDown)
        p.env.payload = payload
        p.env.dragPasteboardChangeCount += 1
        p.env.send(.leftMouseDragged)
    }

    @Test func aPromiseOpensOnAPauseAndOnTheKey() {
        let p = MonitorProbe()
        p.monitor.summonsForFilePromises = true
        p.monitor.opensOnPause = true
        drag(p, DragPayload(promisedTypeIdentifiers: ["public.heic"]))
        hold(p, seconds: 0.5)
        #expect(p.summons.count == 1 && p.summons.first?.0 == [])
    }

    /// Frenzy's window can't take a promise, so over it a promise still gets the ring (a real file doesn't need it).
    @Test func overFrenzysWindowAPromiseStillGetsTheRing() {
        let p = MonitorProbe()
        p.monitor.summonsForFilePromises = true
        p.monitor.opensOnPause = true
        p.monitor.pauseBlocked = { _ in true }
        drag(p, DragPayload(promisedTypeIdentifiers: ["public.heic"]))
        hold(p, seconds: 0.5)
        #expect(p.summons.count == 1)
    }

    /// Rich text and in-app drags carry image bytes too, so only the key opens the ring for those.
    @Test func imageBytesNeedTheKey() {
        let p = MonitorProbe()
        p.monitor.summonsForFilePromises = true
        p.monitor.opensOnPause = true
        drag(p, DragPayload(inlineImageType: "public.png"))
        hold(p, seconds: 2)
        #expect(p.summons.isEmpty)
        p.env.modifierFlags = .option
        p.env.tick()
        #expect(p.summons.count == 1)
    }

    @Test func aBareLinkGetsOneExplanationAndNoRing() {
        let p = MonitorProbe()
        p.monitor.summonsForFilePromises = true
        p.monitor.opensOnPause = true
        var notices = 0
        p.monitor.onLinkDrag = { notices += 1 }
        drag(p, DragPayload(hasWebLink: true))
        hold(p, seconds: 2)
        #expect(notices == 0, "a pause over a link says nothing")
        p.env.modifierFlags = .option
        hold(p, seconds: 1)
        #expect(notices == 1, "once per drag")
        #expect(p.summons.isEmpty)
    }
}

// MARK: - Delivery

private final class FakeSource: PromisedFileSource {
    var promisedCount = 1
    /// Files to "write" into the folder, by name. Empty = the source app never calls back.
    var files: [String] = []
    var error: (any Error)?
    func deliver(into folder: URL, queue: OperationQueue, reader: @escaping @Sendable (URL, (any Error)?) -> Void) {
        for name in files {
            let url = folder.appendingPathComponent(name)
            try? Data([1]).write(to: url)
            let err = error.map { $0 as NSError }
            queue.addOperation { reader(url, err) }
        }
    }
}

@MainActor
@Suite(.serialized) struct PromiseDeliveryTests {
    private func setUp() throws -> (RingOverlayController, PromiseInbox) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("halo-inbox-\(UUID().uuidString)")
        let o = RingOverlayController(timing: .init(present: 0, commit: 0, dismiss: 0), promiseDestination: root)
        o.respectsReduceMotion = false
        o.present(at: NSPoint(x: 600, y: 500), items: items, centerLabel: "") { _, _ in }
        return (o, PromiseInbox(root: root))
    }

    /// The whole path from a drop to files the job can use.
    @Test func filesArriveAndTheCardIsToldAtEachStep() async throws {
        let (o, inbox) = try setUp()
        var events: [String] = []
        var got: (ActionID, [URL])?
        o.present(at: NSPoint(x: 600, y: 500), items: items, centerLabel: "") { got = ($0, $1) }
        o.onPromiseDelivery = { e in
            switch e {
            case .began(_, _, let n, _): events.append("began \(n)")
            case .ended(_, let r, let x, let c): events.append("ended \(r)/\(x) \(c)")
            case .couldNotReceive: events.append("couldNotReceive")
            }
        }
        let source = FakeSource()
        source.files = ["IMG_1.heic"]
        #expect(o.drop(atBottomLeftPoint: wedge, payload: DragPayload(promisedTypeIdentifiers: ["public.heic"]), promises: [source]))
        await spin(0.15)
        #expect(events == ["began 1", "ended 1/1 false"])
        #expect(got?.0 == "image.to-jpg")
        #expect(got?.1.count == 1 && inbox.contains(got!.1[0]))
        #expect(got?.1[0].lastPathComponent == "IMG_1.heic")
    }

    /// A source app that never answers used to leave the user with nothing, forever.
    @Test func aSourceThatNeverDeliversEndsInAnswerAndCleansUp() async throws {
        let (o, inbox) = try setUp()
        o.promiseTimeout = 0.05
        var ended: (Int, Int, Bool)?
        var called = false
        o.present(at: NSPoint(x: 600, y: 500), items: items, centerLabel: "") { _, _ in called = true }
        o.onPromiseDelivery = { if case .ended(_, let r, let x, let c) = $0 { ended = (r, x, c) } }
        #expect(o.drop(atBottomLeftPoint: wedge, payload: DragPayload(promisedTypeIdentifiers: ["public.heic"]), promises: [FakeSource()]))
        await spin(0.2)
        #expect(ended?.0 == 0 && ended?.1 == 1 && ended?.2 == false)
        #expect(!called, "nothing to convert")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: inbox.root.path)) ?? []
        #expect(left.isEmpty, "the empty drop folder is gone")
    }

    @Test func oneFailedFileOfTwoStillConvertsTheOther() async throws {
        let (o, _) = try setUp()
        var got: [URL] = []
        var ended: (Int, Int)?
        o.present(at: NSPoint(x: 600, y: 500), items: items, centerLabel: "") { _, urls in got = urls }
        o.onPromiseDelivery = { if case .ended(_, let r, let x, _) = $0 { ended = (r, x) } }
        let good = FakeSource(), bad = FakeSource()
        good.files = ["a.jpg"]
        bad.files = ["b.jpg"]
        bad.error = NSError(domain: "t", code: 1)
        #expect(o.drop(atBottomLeftPoint: wedge, payload: DragPayload(promisedTypeIdentifiers: ["public.jpeg", "public.jpeg"]), promises: [good, bad]))
        await spin(0.15)
        #expect(got.map(\.lastPathComponent) == ["a.jpg"])
        #expect(ended?.0 == 1 && ended?.1 == 2)
    }

    @Test func cancelStopsTheWaitAndCleansUp() async throws {
        let (o, inbox) = try setUp()
        var cancel: (@MainActor () -> Void)?
        var ended: Bool?
        var called = false
        o.present(at: NSPoint(x: 600, y: 500), items: items, centerLabel: "") { _, _ in called = true }
        o.onPromiseDelivery = { e in
            switch e {
            case .began(_, _, _, let c): cancel = c
            case .ended(_, _, _, let c): ended = c
            case .couldNotReceive: break
            }
        }
        #expect(o.drop(atBottomLeftPoint: wedge, payload: DragPayload(promisedTypeIdentifiers: ["public.heic"]), promises: [FakeSource()]))
        cancel?()
        await spin(0.05)
        #expect(ended == true && !called)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: inbox.root.path)) ?? []).isEmpty)
    }

    /// A file the source writes outside the drop folder isn't ours to convert or delete.
    @Test func filesOutsideTheInboxAreIgnored() async {
        let collector = CollectorProbe()
        collector.collector.add(URL(fileURLWithPath: "/etc/passwd"))
        await spin(0.05)
        #expect(collector.results == [[]])
    }

    @Test func imageBytesBecomeAFileToConvert() async throws {
        let (o, inbox) = try setUp()
        var got: [URL] = []
        o.present(at: NSPoint(x: 600, y: 500), items: items, centerLabel: "") { _, urls in got = urls }
        #expect(o.drop(atBottomLeftPoint: wedge, payload: DragPayload(inlineImageType: "public.png"), promises: [], inlineImage: Data([1, 2])))
        await spin(0.05)
        #expect(got.count == 1 && inbox.contains(got[0]))
        #expect(got[0].pathExtension == "png")
    }

    @Test func aDropWithNothingAtAllIsRefused() throws {
        let (o, _) = try setUp()
        #expect(!o.drop(atBottomLeftPoint: wedge, payload: DragPayload(hasWebLink: true), promises: []))
        o.dismiss(animated: false)
    }
}

@MainActor
private final class CollectorProbe {
    var results: [[URL]] = []
    lazy var collector = PromiseCollector(expected: 1, isAcceptable: { _ in false }) { [weak self] urls, _ in self?.results.append(urls) }
}

// MARK: - Ring plumbing with promises

@MainActor
@Suite struct PromiseRingTests {
    /// End to end through the coordinator: promise payload, types to items, ring up, drop, converted with received URLs.
    @Test func aPromisedDragOpensTheRingWithItsOwnChoices() async {
        let env = FakeDragEnvironment()
        let monitor = DragTriggerMonitor(environment: env)
        monitor.summonsForFilePromises = true
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("halo-inbox-\(UUID().uuidString)")
        let overlay = RingOverlayController(timing: .init(present: 0, commit: 0, dismiss: 0), promiseDestination: root)
        overlay.respectsReduceMotion = false
        var asked: [[String]] = []
        var converted: [(ActionID, [URL])] = []
        let coord = DragCoordinator(monitor: monitor, overlay: overlay, itemsFor: { _ in ([], "") },
                                    onConvert: { converted.append(($0, $1)) })
        coord.promisedItemsFor = { types in asked.append(types); return (items, "1 image") }
        coord.promisedSymbolFor = { _ in "photo" }
        coord.start()
        env.modifierFlags = .option
        env.isLeftMouseDown = true
        env.send(.leftMouseDown)
        env.payload = DragPayload(promisedTypeIdentifiers: ["public.heic"])
        env.dragPasteboardChangeCount += 1
        env.send(.leftMouseDragged)
        #expect(asked == [["public.heic"]])
        #expect(overlay.isPresented)
        #expect(overlay.model.centerLabel == "1 image" && overlay.model.centerSymbolName == "photo")
        let source = FakeSource()
        source.files = ["IMG.heic"]
        #expect(overlay.drop(atBottomLeftPoint: wedge, payload: env.payload, promises: [source]))
        env.endDrag()
        await spin(0.15)
        #expect(converted.count == 1)
        #expect(converted.first?.1.first?.lastPathComponent == "IMG.heic")
        coord.stop()
    }

    @Test func noChoicesMeansNoRing() {
        let env = FakeDragEnvironment()
        let monitor = DragTriggerMonitor(environment: env)
        monitor.summonsForFilePromises = true
        let overlay = RingOverlayController(timing: .init(present: 0, commit: 0, dismiss: 0))
        let coord = DragCoordinator(monitor: monitor, overlay: overlay, itemsFor: { _ in ([], "") }, onConvert: { _, _ in })
        coord.promisedItemsFor = { _ in ([], "") }
        coord.start()
        env.modifierFlags = .option
        env.isLeftMouseDown = true
        env.send(.leftMouseDown)
        env.payload = DragPayload(promisedTypeIdentifiers: ["com.apple.mail.email"])
        env.dragPasteboardChangeCount += 1
        env.send(.leftMouseDragged)
        #expect(!overlay.isPresented)
        coord.stop()
    }

    /// Listing a folder on the Desktop mid-drag makes macOS ask for permission at the worst moment.
    @Test func theCentreDoesNotLookIntoGuardedFolders() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let guarded = home.appendingPathComponent("Desktop/Project", isDirectory: true)
        #expect(DragCoordinator.filesForCentre([guarded]).isEmpty)
        let free = URL(fileURLWithPath: "/tmp/Project/", isDirectory: true)
        #expect(DragCoordinator.filesForCentre([free]) == [free])
        let photo = home.appendingPathComponent("Desktop/a.png")
        #expect(DragCoordinator.filesForCentre([photo]) == [photo], "a file's name and size need no folder listing")
    }
}

// MARK: - Accepting the drop

@MainActor
@Suite struct DropOperationTests {
    /// Control as the trigger key narrows a Finder drag to "link". Answering `.copy` then made AppKit refuse every drop.
    @Test func answersWithWhatTheSourceStillAllows() {
        #expect(RingOverlayController.dropOperation(sourceAllows: .every) == .copy)
        #expect(RingOverlayController.dropOperation(sourceAllows: [.copy, .move]) == .copy)
        #expect(RingOverlayController.dropOperation(sourceAllows: .link) == .link)
        #expect(RingOverlayController.dropOperation(sourceAllows: .generic) == .generic)
    }

    /// `.move` could make the source delete the original once the drop lands. Never.
    @Test func neverClaimsAMove() {
        #expect(RingOverlayController.dropOperation(sourceAllows: .move) == [])
        #expect(RingOverlayController.dropOperation(sourceAllows: []) == [])
    }

    @Test func hoveringAnswersWithIt() {
        _ = NSApplication.shared
        let o = RingOverlayController(timing: .init(present: 0, commit: 0, dismiss: 0))
        o.respectsReduceMotion = false
        o.present(at: NSPoint(x: 600, y: 500), items: items, centerLabel: "") { _, _ in }
        #expect(o.draggingMoved(toBottomLeftPoint: wedge, sourceAllows: .link) == .link)
        #expect(o.isHoveringWedge)
        #expect(o.ringCenter != nil)
        o.draggingLeft()
        #expect(!o.isHoveringWedge)
        o.dismiss(animated: false)
        #expect(o.ringCenter == nil)
    }
}
