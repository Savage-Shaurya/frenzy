// Live harness for HaloDrag: real NSPanel, real drag pasteboard, real drag destination.
//
//   manual (default): hold Option while dragging any file; the log shows summon / hover / drop / dismiss.
//   --auto:           synthesizes a real system drag with CGEvent (needs Accessibility for the parent terminal)
//                     from a source window in this process onto the ring, then checks every step. Exit 0 = pass.
import AppKit
import ApplicationServices
import HaloCore
import HaloUI
import HaloDrag

setvbuf(stdout, nil, _IOLBF, 0)
func log(_ s: String) { print("[\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime))] \(s)") }

let args = CommandLine.arguments
let postOnly = args.contains("--post-only")   // only synthesize the drag; another process runs the monitor
let releaseScenario = args.contains("--release") // let go of Option mid-drag, then drop away from the ring
let auto = args.contains("--auto") || postOnly
let seconds = Double(args.first { Double($0) != nil } ?? "") ?? (auto ? 15 : 60)

let items: [RingItem] = [
    .init(id: "image.to-jpg", title: "JPG", subtitle: nil, symbolName: "photo", category: .image),
    .init(id: "image.to-png", title: "PNG", subtitle: nil, symbolName: "photo", category: .image),
    .init(id: "pdf.from-image", title: "PDF", subtitle: nil, symbolName: "doc", category: .pdf),
    .init(id: "text.ocr", title: "Text", subtitle: nil, symbolName: "text.viewfinder", category: .text),
]

@MainActor final class Results {
    var summonURLs: [URL] = []
    var summonPoint: NSPoint?
    var hovered: [Int?] = []
    var dropped: (ActionID, [URL])?
    var dismissals: [String] = []
}

@MainActor final class SourceView: NSView, NSDraggingSource {
    var file: URL!
    override func draw(_ r: NSRect) { NSColor.systemBlue.setFill(); bounds.fill() }
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
        log("source: session ended at \(p) operation \(operation.rawValue)")
    }
    override func mouseDown(with event: NSEvent) {
        log("source: mouseDown, starting NSDraggingSession for \(file.lastPathComponent)")
        let item = NSDraggingItem(pasteboardWriter: file as NSURL)
        item.setDraggingFrame(NSRect(x: 30, y: 30, width: 40, height: 40), contents: NSWorkspace.shared.icon(forFile: file.path))
        beginDraggingSession(with: [item], event: event, source: self)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let results = Results()
    log("permissions: AX=\(AXIsProcessTrusted()) listen=\(CGPreflightListenEventAccess()) post=\(CGPreflightPostEventAccess())")

    let monitor = DragTriggerMonitor()
    let overlay = RingOverlayController()
    overlay.onHoverChange = { results.hovered.append($0); log("overlay: hover \($0.map(String.init) ?? "nil")") }
    let coordinator = DragCoordinator(monitor: monitor, overlay: overlay, itemsFor: { urls in
        results.summonURLs = urls
        log("monitor: SUMMON \(urls.map(\.path))")
        return (items, urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")
    }, onConvert: { id, urls in
        results.dropped = (id, urls)
        log("overlay: DROP \(id) \(urls.map(\.path))")
    })
    monitor.onSummonPayload = { payload, p in results.summonPoint = p; log("monitor: payload \(payload) at \(p)") }
    let originalDismiss = monitor.onDismiss
    monitor.onDismiss = {
        let reason = monitor.lastDismissReason.map { "\($0)" } ?? "?"
        results.dismissals.append(reason)
        log("monitor: DISMISS \(reason)")
        originalDismiss?()
    }
    if !postOnly { coordinator.start() }
    log("monitor \(postOnly ? "NOT started (post-only)" : "started"); \(auto ? "auto mode" : "drag a file and hold Option") for \(Int(seconds)) s")

    @MainActor func finish() {
        coordinator.stop()
        guard auto, !postOnly else { exit(0) }
        let checks: [(String, Bool)] = releaseScenario ? [
            ("onSummon fired with the dragged file", results.summonURLs.map(\.lastPathComponent) == ["halo-harness.txt"]),
            ("releasing Option dismissed the ring", results.dismissals.first == "triggerReleased"),
            ("no drop happened", results.dropped == nil),
        ] : [
            ("onSummon fired with the dragged file", results.summonURLs.map(\.lastPathComponent) == ["halo-harness.txt"]),
            ("overlay got draggingEntered/Updated over a segment", results.hovered.contains { $0 != nil }),
            ("performDragOperation delivered the drop", results.dropped?.1.map(\.lastPathComponent) == ["halo-harness.txt"]),
        ]
        for (name, ok) in checks { log("\(ok ? "PASS" : "FAIL") \(name)") }
        exit(checks.allSatisfy(\.1) ? 0 : 1)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { finish() } }

    guard auto else { app.run(); return }

    guard CGPreflightPostEventAccess() else {
        log("FAIL cannot synthesize events: CGPreflightPostEventAccess() == false. Grant Accessibility to the app that runs this script (System Settings > Privacy & Security > Accessibility), then rerun. Manual mode needs no permission.")
        exit(2)
    }

    let file = FileManager.default.temporaryDirectory.appendingPathComponent("halo-harness.txt")
    try? "harness".write(to: file, atomically: true, encoding: .utf8)
    let screen = NSScreen.screens[0]
    let srcRect = NSRect(x: screen.visibleFrame.minX + 80, y: screen.visibleFrame.midY - 50, width: 100, height: 100)
    let win = NSWindow(contentRect: srcRect, styleMask: [.borderless], backing: .buffered, defer: false)
    win.level = .floating
    let src = SourceView(frame: NSRect(origin: .zero, size: srcRect.size))
    src.file = file
    win.contentView = src
    win.orderFrontRegardless()

    let h = screen.frame.height
    func cg(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: h - p.y) } // AppKit → CG (top-left) coordinates
    let start = NSPoint(x: srcRect.midX, y: srcRect.midY)
    let summonAt = NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
    let source = CGEventSource(stateID: .hidSystemState)
    func post(_ type: CGEventType, _ p: NSPoint, flags: CGEventFlags = []) {
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: cg(p), mouseButton: .left)!
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }
    func option(_ down: Bool) {
        let e = CGEvent(keyboardEventSource: source, virtualKey: 58, keyDown: down)!
        e.flags = down ? .maskAlternate : []
        e.post(tap: .cghidEventTap)
    }

    var steps: [(TimeInterval, @MainActor () -> Void)] = []
    var t: TimeInterval = 0.5
    func at(_ dt: TimeInterval, _ f: @escaping @MainActor () -> Void) { t += dt; steps.append((t, f)) }
    at(0) { post(.mouseMoved, start) }
    at(0.2) { post(.leftMouseDown, start) }
    for i in 1...30 { // drag towards the middle of the screen without Option: no ring yet
        let f = Double(i) / 30
        at(0.016) { post(.leftMouseDragged, NSPoint(x: start.x + (summonAt.x - start.x) * f, y: start.y + (summonAt.y - start.y) * f)) }
    }
    at(0.2) { option(true) }
    at(0.05) { post(.leftMouseDragged, summonAt, flags: .maskAlternate) }
    // Ring is centred at the cursor (unless clamped): move up into segment 0 (12 o'clock).
    for i in 1...20 {
        at(0.016) { post(.leftMouseDragged, NSPoint(x: summonAt.x, y: summonAt.y + Double(i) * 6), flags: .maskAlternate) }
    }
    if releaseScenario {
        at(0.2) { option(false) }
        at(0.6) { post(.leftMouseDragged, start) } // past the 0.2 s grace; back over the source (not a drop target)
        at(0.2) { post(.leftMouseUp, start) }
    } else {
        at(0.3) { post(.leftMouseUp, NSPoint(x: summonAt.x, y: summonAt.y + 120), flags: .maskAlternate) }
        at(0.1) { option(false) }
    }
    at(1.0) { finish() }
    for (when, f) in steps {
        DispatchQueue.main.asyncAfter(deadline: .now() + when) { MainActor.assumeIsolated { f() } }
    }
    app.run()
}
