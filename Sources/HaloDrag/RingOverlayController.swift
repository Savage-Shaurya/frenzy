import AppKit
import SwiftUI
import HaloCore
import HaloUI

/// How long each ring phase lasts before the controller moves on, so RingView's animations can play.
public struct RingOverlayTiming: Sendable, Equatable {
    /// `.presenting` → `.shown`.
    public var present: TimeInterval
    /// `.committing(id)` → `.dismissing` after a drop (the "chosen" flash).
    public var commit: TimeInterval
    /// `.dismissing` → `.hidden` and the panel ordered out.
    public var dismiss: TimeInterval

    public init(present: TimeInterval, commit: TimeInterval, dismiss: TimeInterval) {
        self.present = present
        self.commit = commit
        self.dismiss = dismiss
    }

    /// Matches HaloUI's `RingMotion` so RingView's bloom, commit pulse and fade play out in full.
    /// Drops are accepted during `.presenting` too, so the longer bloom never delays a fast user.
    public static let standard = RingOverlayTiming(present: RingMotion.presentDuration,
                                                   commit: RingMotion.commitDuration,
                                                   dismiss: RingMotion.dismissDuration)
    /// Used when System Settings > Accessibility > Display > Reduce motion is on (RingView crossfades in 0.15 s).
    public static let reducedMotion = RingOverlayTiming(present: 0, commit: 0.15, dismiss: 0.15)
}

/// Lets `DragCoordinator` hold back a drag-ended dismissal while a drop on the ring may still arrive.
@MainActor
public protocol DropPendingReporting: AnyObject {
    /// True while a drag hovers over the ring and could still be dropped on it.
    var isAwaitingDrop: Bool { get }
}

/// A transparent, borderless, non-activating panel hosting `RingView` that accepts file drops.
@MainActor
public final class RingOverlayController: RingOverlayPresenting, DropPendingReporting {
    /// Panel level: above the menu bar, status items and pop-up menus (101) but below the system drag image
    /// (`kCGDraggingWindowLevel`, 500), so the dragged file's icon stays on top of the ring.
    public static let windowLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)

    public let model: RingModel
    public var timing: RingOverlayTiming
    /// Use `RingOverlayTiming.reducedMotion` when the system asks for reduced motion.
    public var respectsReduceMotion = true
    /// Where promised files (Mail, Photos…) are written when dropped on the ring. Each drop gets a subfolder.
    public var promiseDestination: URL
    /// How a promised drop is going: the file isn't here until the source app has written it.
    public var onPromiseDelivery: ((PromiseDeliveryEvent) -> Void)?
    /// Longest wait for a source app to hand over its files. Generous: Photos may fetch a video's original from iCloud.
    public var promiseTimeout: TimeInterval = 300
    /// Called with every hover change (e.g. for haptics: `NSHapticFeedbackManager`).
    public var onHoverChange: ((Int?) -> Void)?

    public private(set) var isDragInside = false
    public var isPresented: Bool {
        switch model.phase {
        case .presenting, .shown, .committing: true
        case .hidden, .dismissing: false
        }
    }
    public var isAwaitingDrop: Bool { isDragInside && (model.phase == .presenting || model.phase == .shown) }
    /// The pointer is on a wedge and a drop there would be accepted.
    public var isHoveringWedge: Bool { isAwaitingDrop && model.hoveredIndex != nil }
    /// The ring's centre on screen while it's up.
    public var ringCenter: NSPoint? { isPresented ? NSPoint(x: panel.frame.midX, y: panel.frame.midY) : nil }

    /// For a ring that opened on a pause: people often pause just before dropping into an app, so a drop in the hub or
    /// beyond the wedges reaches whatever is underneath. Only the wedges take the drop.
    public var letsDropsThroughHub = false
    private var summonPoint = NSPoint.zero
    private var pointerLeftSummonPoint = false
    /// How many times a pause ring's pass-through flag was actually written (tests check it isn't once per tick).
    private(set) var passThroughWrites = 0
    private var isWarm = false

    let panel: NSPanel
    let dropView: RingDropTargetView
    private var onDrop: ((ActionID, [URL]) -> Void)?
    private var generation = 0

    public init(model: RingModel = RingModel(), timing: RingOverlayTiming = .standard,
                promiseDestination: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Frenzy Promised Files", isDirectory: true)) {
        self.model = model
        self.timing = timing
        self.promiseDestination = promiseDestination
        let size = RingMetrics.canvasSize
        let rect = NSRect(x: 0, y: 0, width: size, height: size)

        // `.nonactivatingPanel` must be in the initial style mask (setting it later doesn't fully take effect).
        let panel = RingPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = Self.windowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        // Explicitly false: the whole square takes part in hit-testing and drag-destination lookup, even where
        // RingView draws nothing. (Corners beyond the ring reject the drop, so it springs back.)
        panel.ignoresMouseEvents = false
        panel.sharingType = .readOnly

        let container = NSView(frame: rect)
        container.wantsLayer = true
        container.layer?.backgroundColor = .clear
        let hosting = NSHostingView(rootView: RingView(model: model))
        hosting.sizingOptions = []
        hosting.frame = rect
        hosting.autoresizingMask = [.width, .height]
        let drop = RingDropTargetView(frame: rect)
        drop.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        container.addSubview(drop) // on top, so it is always the drag destination
        panel.contentView = container

        self.panel = panel
        self.dropView = drop
        drop.controller = self
    }

    private var effectiveTiming: RingOverlayTiming {
        respectsReduceMotion && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .reducedMotion : timing
    }

    // MARK: RingOverlayPresenting

    public func present(at screenPoint: NSPoint, items: [RingItem], centerLabel: String,
                        onDrop: @escaping (ActionID, [URL]) -> Void) {
        present(at: screenPoint, items: items, centerLabel: centerLabel, centerSymbolName: nil, onDrop: onDrop)
    }

    /// Same as the contract method, plus an SF Symbol for the ring's centre (`RingModel.centerSymbolName`) and the
    /// dragged files, so a single file shows its thumbnail and size there (`RingModel.showFiles`).
    public func present(at screenPoint: NSPoint, items: [RingItem], centerLabel: String, centerSymbolName: String?,
                        files: [URL] = [], onDrop: @escaping (ActionID, [URL]) -> Void) {
        model.centerSymbolName = centerSymbolName
        model.clearFiles()
        generation += 1
        let gen = generation
        self.onDrop = onDrop
        model.items = items
        model.centerLabel = centerLabel
        model.hoveredIndex = nil
        isDragInside = false

        let screens = NSScreen.screens
        let frame: NSRect
        if let i = OverlayGeometry.screenIndex(containing: screenPoint, in: screens.map(\.frame)) {
            frame = OverlayGeometry.panelFrame(centeredAt: screenPoint, visibleFrame: screens[i].visibleFrame,
                                               backingScale: screens[i].backingScaleFactor)
        } else {
            let s = RingMetrics.canvasSize
            frame = NSRect(x: screenPoint.x - s / 2, y: screenPoint.y - s / 2, width: s, height: s)
        }
        panel.setFrame(frame, display: false)
        summonPoint = screenPoint
        pointerLeftSummonPoint = false
        panel.ignoresMouseEvents = letsDropsThroughHub
        model.phase = .presenting
        panel.alphaValue = HaloRuntime.isUnderTest ? 0 : 1
        panel.orderFrontRegardless() // never `makeKey`/`activate`: the source app keeps focus
        // Finder icons and sizes can wait a beat on a slow volume: the ring blooms first, the centre fills in
        // during the bloom's fade.
        if !files.isEmpty {
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in
                guard let self, self.generation == gen else { return }
                self.model.showFiles(files)
            } }
        }

        after(effectiveTiming.present, gen) { [weak self] in
            guard let self, self.model.phase == .presenting else { return }
            self.model.phase = .shown
        }
    }

    /// Builds the ring's views once, off screen and invisible, so the first ring after launch doesn't hold up the drag while
    /// SwiftUI and the glass set themselves up. Once per controller; does nothing while a ring is up.
    public func prewarm(with sample: [RingItem]) {
        guard !isWarm, model.phase == .hidden, !sample.isEmpty, let content = panel.contentView else { return }
        isWarm = true
        model.items = sample
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        model.items = []
    }

    public func dismiss(animated: Bool) {
        guard model.phase != .hidden else { return }
        generation += 1
        let gen = generation
        model.hoveredIndex = nil
        isDragInside = false
        let delay = animated ? effectiveTiming.dismiss : 0
        if delay <= 0 {
            finishDismiss()
            return
        }
        model.phase = .dismissing
        // On its way out, the ring must not catch a drop (it would refuse it and the file would spring back).
        panel.ignoresMouseEvents = true
        after(delay, gen) { [weak self] in self?.finishDismiss() }
    }

    /// Where the pointer is, in screen coordinates, while `letsDropsThroughHub` is on. A window that ignores mouse events
    /// is also skipped as a drag destination, so this is what lets a drop fall through.
    public func pointerMoved(to point: NSPoint) {
        guard letsDropsThroughHub, acceptsDrags else { return }
        // Near a screen edge the ring is pushed aside, so the pointer can open it already on a wedge: not a choice yet.
        if !pointerLeftSummonPoint {
            guard hypot(point.x - summonPoint.x, point.y - summonPoint.y) > 24 else { setPassThrough(true); return }
            pointerLeftSummonPoint = true
        }
        let distance = hypot(point.x - panel.frame.midX, point.y - panel.frame.midY)
        setPassThrough(distance < RingMetrics.innerRadius || distance > RingMetrics.outerRadius + 14)
    }

    /// While the panel lets the drag through, AppKit sends it no `draggingExited`: un-light the wedge here, or it would
    /// stay lit (and `holdsOpen` would keep the ring up) with the pointer over the hub.
    /// Writes the flag only when it changes: this runs on every drag tick (up to 125 a second), and each write is a call
    /// to the window server that also costs the main thread an extra run loop pass.
    private func setPassThrough(_ through: Bool) {
        if panel.ignoresMouseEvents != through {
            panel.ignoresMouseEvents = through
            passThroughWrites += 1
        }
        if through, isDragInside || model.hoveredIndex != nil { draggingLeft() }
    }

    private func finishDismiss() {
        panel.ignoresMouseEvents = false
        letsDropsThroughHub = false
        panel.orderOut(nil)
        model.phase = .hidden
        model.hoveredIndex = nil
        model.clearFiles()
        onDrop = nil
    }

    private func after(_ delay: TimeInterval, _ gen: Int, _ body: @escaping @MainActor () -> Void) {
        let work = { @MainActor [weak self] in
            guard let self, self.generation == gen else { return }
            body()
        }
        if delay <= 0 { work(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
    }

    // MARK: Drag destination logic (called by RingDropTargetView; internal for tests)

    var acceptsDrags: Bool { model.phase == .presenting || model.phase == .shown }

    /// `point` is in the drop view's own coordinates (non-flipped, y up).
    func draggingMoved(toBottomLeftPoint point: NSPoint, sourceAllows: NSDragOperation = .every) -> NSDragOperation {
        isDragInside = true
        guard acceptsDrags else { setHover(nil); return [] }
        let index = OverlayGeometry.segmentIndex(atBottomLeftPoint: point, size: dropView.bounds.width, count: model.items.count)
        setHover(index)
        return index == nil ? [] : Self.dropOperation(sourceAllows: sourceAllows)
    }

    /// What to answer a drag with. Holding Control narrows a Finder drag to "link" and Command to "move", and AppKit
    /// refuses a drop answered with anything the source no longer allows, so `.copy` alone fails with Control as the
    /// trigger key. Never `.move`: the source could delete the original once the drop lands.
    static func dropOperation(sourceAllows: NSDragOperation) -> NSDragOperation {
        for candidate: NSDragOperation in [.copy, .generic, .link] where sourceAllows.contains(candidate) { return candidate }
        return []
    }

    /// The drag left the ring, or ended. During the commit flash the chosen wedge keeps its highlight: `draggingEnded`
    /// arrives right after the drop.
    func draggingLeft() {
        isDragInside = false
        if case .committing = model.phase { return }
        setHover(nil)
    }

    private func setHover(_ index: Int?) {
        guard model.hoveredIndex != index else { return }
        model.hoveredIndex = index
        onHoverChange?(index)
    }

    /// Commits a drop at `point`. URLs come from `payload`, or from `promises` once received, or from `inlineImage`.
    func drop(atBottomLeftPoint point: NSPoint, payload: DragPayload, promises: [any PromisedFileSource], inlineImage: Data? = nil) -> Bool {
        isDragInside = false
        guard acceptsDrags,
              let index = OverlayGeometry.segmentIndex(atBottomLeftPoint: point, size: dropView.bounds.width, count: model.items.count),
              model.items.indices.contains(index) else { return false }
        let id = model.items[index].id
        guard !payload.fileURLs.isEmpty || !promises.isEmpty || inlineImage != nil, let handler = onDrop else { return false }

        generation += 1
        let gen = generation
        model.hoveredIndex = index
        model.phase = .committing(id)
        onDrop = nil

        if !payload.fileURLs.isEmpty {
            let urls = payload.fileURLs
            // Run after returning from performDragOperation so the source's drag loop finishes promptly.
            DispatchQueue.main.async { MainActor.assumeIsolated { handler(id, urls) } }
        } else if !promises.isEmpty {
            receive(promises, action: id) { urls in if !urls.isEmpty { handler(id, urls) } }
        } else if let inlineImage {
            saveInline(inlineImage, type: payload.inlineImageType ?? "public.png") { urls in if !urls.isEmpty { handler(id, urls) } }
        }
        let t = effectiveTiming
        after(t.commit, gen) { [weak self] in
            guard let self else { return }
            if t.dismiss <= 0 { self.finishDismiss(); return }
            self.model.phase = .dismissing
            self.panel.ignoresMouseEvents = true
            self.after(t.dismiss, gen) { [weak self] in self?.finishDismiss() }
        }
        return true
    }

    private func saveInline(_ data: Data, type: String, completion: @escaping @MainActor ([URL]) -> Void) {
        let url = try? PromiseInbox(root: promiseDestination).save(imageData: data, typeIdentifier: type)
        let drop = UUID()
        onPromiseDelivery?(url == nil ? .couldNotReceive(drop: drop, expected: 1) : .ended(drop: drop, received: 1, expected: 1, cancelled: false))
        let urls = url.map { [$0] } ?? []
        DispatchQueue.main.async { MainActor.assumeIsolated { completion(urls) } }
    }

    private func receive(_ promises: [any PromisedFileSource], action: ActionID, completion: @escaping @MainActor ([URL]) -> Void) {
        let inbox = PromiseInbox(root: promiseDestination)
        let expected = promises.reduce(0) { $0 + $1.promisedCount }
        let drop = UUID()
        guard let folder = try? inbox.makeDropFolder() else {
            // Frenzy's own temp folder failed: the source app did nothing wrong.
            onPromiseDelivery?(.couldNotReceive(drop: drop, expected: expected))
            return
        }
        let collector = PromiseCollector(expected: expected, isAcceptable: { inbox.contains($0) },
                                         onLate: { Self.discardLate($0, in: folder, inbox: inbox) }) { [weak self] urls, cancelled in
            if urls.isEmpty { inbox.remove(dropFolder: folder) }
            self?.onPromiseDelivery?(.ended(drop: drop, received: urls.count, expected: expected, cancelled: cancelled))
            completion(urls)
        }
        // The source apps' receivers stay retained until the drop finishes (every file, the timeout or Cancel).
        collector.retain(promises as [AnyObject])
        lastPromiseCollector = collector
        onPromiseDelivery?(.began(drop: drop, action: action, count: expected, cancel: { collector.cancel() }))
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        for promise in promises {
            promise.deliver(into: folder, queue: queue) { url, error in collector.add(error == nil ? url : nil) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + promiseTimeout) { collector.expire() }
    }

    /// The newest promised drop's collector (tests).
    private(set) weak var lastPromiseCollector: PromiseCollector?

    /// A file that arrived after its drop finished (timed out or cancelled): nothing will convert it, so it goes, and
    /// its drop folder too once empty. Only ever inside the inbox.
    nonisolated static func discardLate(_ url: URL, in folder: URL, inbox: PromiseInbox) {
        guard inbox.contains(url) else { return }
        try? FileManager.default.removeItem(at: url)
        rmdir(folder.path) // only succeeds when empty: files still converting stay
    }
}

/// Never becomes key or main, so showing it can't take focus from the app the drag started in.
final class RingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Transparent view on top of RingView that is the actual `NSDraggingDestination`.
final class RingDropTargetView: NSView {
    weak var controller: RingOverlayController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(DragPasteboardReader.fileDragTypes)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    /// A near-invisible disc (alpha 2/255) over the hit area. The window server routes mouse and drag events by
    /// window shape/alpha for transparent windows, so this guarantees the ring area is "solid" even before
    /// RingView has drawn anything.
    override func draw(_ dirtyRect: NSRect) {
        let r = min(RingMetrics.outerRadius + 60, bounds.width / 2)
        let disc = NSRect(x: bounds.midX - r, y: bounds.midY - r, width: r * 2, height: r * 2)
        NSColor(white: 0, alpha: 2.0 / 255.0).setFill()
        NSBezierPath(ovalIn: disc).fill()
    }

    private func local(_ sender: any NSDraggingInfo) -> NSPoint { convert(sender.draggingLocation, from: nil) }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        controller?.draggingMoved(toBottomLeftPoint: local(sender), sourceAllows: sender.draggingSourceOperationMask) ?? []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        controller?.draggingMoved(toBottomLeftPoint: local(sender), sourceAllows: sender.draggingSourceOperationMask) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { controller?.draggingLeft() }
    override func draggingEnded(_ sender: any NSDraggingInfo) { controller?.draggingLeft() }
    override func wantsPeriodicDraggingUpdates() -> Bool { false }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { controller?.acceptsDrags ?? false }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let controller else { return false }
        let pb = sender.draggingPasteboard
        let payload = DragPasteboardReader.payload(from: pb)
        let promises = payload.fileURLs.isEmpty
            ? (pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? [])
            : []
        // Image bytes are read now: the pasteboard is only sure to hold them during this call.
        let inlineImage = payload.fileURLs.isEmpty && promises.isEmpty ? DragPasteboardReader.inlineImage(for: payload, from: pb) : nil
        return controller.drop(atBottomLeftPoint: local(sender), payload: payload, promises: promises, inlineImage: inlineImage)
    }
}
