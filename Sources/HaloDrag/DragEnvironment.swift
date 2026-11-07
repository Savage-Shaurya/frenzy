import AppKit
import UniformTypeIdentifiers

/// What is currently on the system drag pasteboard.
public struct DragPayload: Sendable, Equatable {
    /// Real file URLs (file-reference URLs from Finder are resolved to path URLs). Folders included.
    public var fileURLs: [URL]
    /// Content types of promised files (Mail attachments, Photos, some browser images). The files themselves only
    /// exist once a destination accepts the drop, so there are no URLs for these yet.
    public var promisedTypeIdentifiers: [String]
    /// The best image type carried as raw bytes when there's no file and no promise (some browser and app drags).
    /// Only ever read at the drop.
    public var inlineImageType: String?
    /// A web link and nothing else to convert. Frenzy never fetches anything, so this can only get an explanation.
    public var hasWebLink: Bool

    public init(fileURLs: [URL] = [], promisedTypeIdentifiers: [String] = [], inlineImageType: String? = nil, hasWebLink: Bool = false) {
        self.fileURLs = fileURLs
        self.promisedTypeIdentifiers = promisedTypeIdentifiers
        self.inlineImageType = inlineImageType
        self.hasWebLink = hasWebLink
    }

    public var hasFilePromises: Bool { !promisedTypeIdentifiers.isEmpty }
    public var isEmpty: Bool { fileURLs.isEmpty && promisedTypeIdentifiers.isEmpty && inlineImageType == nil && !hasWebLink }
    /// True when all there is to go on is a web link.
    public var isLinkOnly: Bool { hasWebLink && fileURLs.isEmpty && promisedTypeIdentifiers.isEmpty && inlineImageType == nil }
    public static let empty = DragPayload()
}

/// Low-level events the monitor reacts to. Only mouse events: these need no permission for a global monitor.
public enum DragSystemEvent: Sendable, Equatable {
    case leftMouseDown
    case leftMouseDragged
    case leftMouseUp
}

/// Everything `DragTriggerMonitor` reads from the system. The live implementation needs no TCC permission;
/// tests inject a fake so the state machine runs without a window server.
@MainActor
public protocol DragSystemEnvironment: AnyObject {
    /// `NSEvent.pressedMouseButtons` bit 0.
    var isLeftMouseDown: Bool { get }
    /// `NSEvent.modifierFlags` (system-wide, polled; no key-event monitor involved).
    var modifierFlags: NSEvent.ModifierFlags { get }
    /// Cursor in global screen coordinates (origin bottom-left of the primary screen, y up).
    var mouseLocation: NSPoint { get }
    /// `NSPasteboard(name: .drag).changeCount`. Cheap; never triggers a privacy prompt.
    var dragPasteboardChangeCount: Int { get }
    /// Monotonic seconds.
    var now: TimeInterval { get }
    /// Reads the drag pasteboard. Called at most once per change count.
    func readDragPayload() -> DragPayload
    /// What's under the pointer, for deciding whether a pause means "show the ring". Called rarely (never per tick).
    func pointerTarget(at point: NSPoint) -> PointerTarget
    /// The app in front, which is the app a drag almost always starts from.
    var frontmostProcessID: Int32? { get }
    /// This process, so Frenzy's own windows count as welcome.
    var ownProcessID: Int32 { get }
    /// How each source reads the modifier keys right now, for the log.
    var flagDiagnostics: String { get }

    /// Starts delivering mouse events (global + local monitors). Replaces any previous handler.
    func installEventMonitors(_ handler: @escaping @MainActor (DragSystemEvent) -> Void)
    func removeEventMonitors()
    /// Starts a repeating timer (runs in `.common` modes so it keeps firing during tracking loops).
    func startTicking(interval: TimeInterval, _ handler: @escaping @MainActor () -> Void)
    func stopTicking()
    var isTicking: Bool { get }
}

public extension DragSystemEnvironment {
    func pointerTarget(at point: NSPoint) -> PointerTarget { .desktop }
    var frontmostProcessID: Int32? { nil }
    var ownProcessID: Int32 { getpid() }
    var flagDiagnostics: String { "" }
}

/// What the pointer is over, as far as can be known with no Accessibility permission.
public enum PointerTarget: Sendable, Equatable {
    /// Not somewhere a ring belongs: the Dock (its icons take drops), the menu bar, Stage Manager's strip.
    case blocked
    /// The Desktop or nothing at all.
    case desktop
    /// An app's window.
    case window(number: Int, pid: Int32)
}

/// One on-screen window. Bounds are top-left based, as `CGWindowListCopyWindowInfo` gives them.
public struct OnScreenWindow: Sendable, Equatable {
    public let number: Int
    public let pid: Int32
    public let layer: Int
    public let alpha: Double
    public let bounds: CGRect

    public init(number: Int, pid: Int32, layer: Int, alpha: Double = 1, bounds: CGRect) {
        self.number = number
        self.pid = pid
        self.layer = layer
        self.alpha = alpha
        self.bounds = bounds
    }
}

public enum PointerTargetClassifier {
    /// Windows of these apps are controls, not places to pause on.
    static let chromeApps: Set<String> = ["com.apple.dock", "com.apple.WindowManager", "com.apple.controlcenter", "com.apple.notificationcenterui"]
    /// At or above this level are pop-ups, the drag image itself (500) and the cursor: never "what's under the pointer".
    static let topLayer = 100

    /// - Parameters:
    ///   - point: AppKit screen coordinates (y up).
    ///   - windows: front to back.
    ///   - screens: `frame` and `visibleFrame`, primary first. Outside `visibleFrame` is the Dock or the menu bar.
    public static func classify(point: NSPoint, windows: [OnScreenWindow], screens: [(frame: NSRect, visible: NSRect)],
                                bundleID: (Int32) -> String?) -> PointerTarget {
        if let screen = screens.first(where: { $0.frame.contains(point) }), !screen.visible.contains(point) { return .blocked }
        let flipped = CGPoint(x: point.x, y: (screens.first?.frame.maxY ?? 0) - point.y)
        for window in windows where window.layer < topLayer && window.alpha > 0 && window.bounds.contains(flipped) {
            if window.layer < 0 { return .desktop }
            if bundleID(window.pid).map(chromeApps.contains) == true {
                // The Dock, menu bar extras and Stage Manager's strip are small. A chrome window covering most of the
                // screen is an overlay (macOS shows a see-through tiling layer during Finder drags): look through it.
                let screenArea = screens.first.map { $0.frame.width * $0.frame.height } ?? 0
                if screenArea > 0, window.bounds.width * window.bounds.height > screenArea * 0.5 { continue }
                return .blocked
            }
            return .window(number: window.number, pid: window.pid)
        }
        return .desktop
    }
}

/// Reads file URLs and file promises off a pasteboard. Shared by the monitor and the overlay's drop view.
public enum DragPasteboardReader {
    /// Pasteboard types that mean "files are being dragged" (real or promised).
    public static var fileDragTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } + inlineImageTypes
    }

    /// Image bytes a drag may carry directly, best first (the formats as they were, then TIFF, which is often a re-encode).
    public static let inlineImageTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType(UTType.jpeg.identifier), NSPasteboard.PasteboardType(UTType.heic.identifier),
        .png, NSPasteboard.PasteboardType(UTType.webP.identifier), NSPasteboard.PasteboardType(UTType.gif.identifier), .tiff,
    ]

    public static func payload(from pasteboard: NSPasteboard) -> DragPayload {
        let raw = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let urls = resolveFileURLs(raw)
        // Real files win; promises are only consulted when there are none (Mail, Photos, some browsers).
        guard urls.isEmpty else { return DragPayload(fileURLs: urls) }
        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        var promised = receivers.flatMap(\.fileTypes)
        if promised.isEmpty, !receivers.isEmpty { promised = [UTType.data.identifier] }
        return classify(promisedTypes: promised, pasteboardTypes: pasteboard.types ?? [])
    }

    /// What a drag with no real files carries: promises, then raw image bytes, then a bare link.
    static func classify(promisedTypes: [String], pasteboardTypes: [NSPasteboard.PasteboardType]) -> DragPayload {
        if !promisedTypes.isEmpty { return DragPayload(promisedTypeIdentifiers: promisedTypes.map(normalisedType)) }
        if let image = inlineImageTypes.first(where: pasteboardTypes.contains) {
            return DragPayload(inlineImageType: image.rawValue)
        }
        return DragPayload(hasWebLink: pasteboardTypes.contains(.URL) || pasteboardTypes.contains(NSPasteboard.PasteboardType(UTType.url.identifier)))
    }

    /// Promises may name a type or, in the older form, a file extension ("jpg").
    static func normalisedType(_ value: String) -> String {
        if let type = UTType(value), !type.isDynamic { return type.identifier }
        return UTType(filenameExtension: value)?.identifier ?? value
    }

    /// The image bytes for `payload`, when that's what will be dropped.
    public static func inlineImage(for payload: DragPayload, from pasteboard: NSPasteboard) -> Data? {
        payload.inlineImageType.flatMap { pasteboard.data(forType: NSPasteboard.PasteboardType($0)) }
    }

    /// Finder puts file-reference URLs (`file:///.file/id=…`) on the pasteboard; turn them into path URLs and drop
    /// anything that doesn't resolve to an existing item.
    public static func resolveFileURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls where url.isFileURL {
            let resolved = (url as NSURL).filePathURL ?? url
            let standard = resolved.standardizedFileURL
            guard !standard.path.hasPrefix("/.file/"), seen.insert(standard.path).inserted else { continue }
            result.append(standard)
        }
        return result
    }
}

/// The real system. No Accessibility, Input Monitoring or Screen Recording permission is needed for anything here.
@MainActor
public final class LiveDragSystemEnvironment: DragSystemEnvironment {
    private let pasteboard = NSPasteboard(name: .drag)
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var timer: Timer?

    public init() {}

    public var isLeftMouseDown: Bool { NSEvent.pressedMouseButtons & 1 != 0 }
    /// Either source counts as down, so a stale read from one can't close the ring. `NSEvent.modifierFlags` is what the
    /// live harness proved in a background app; `CGEventSource` reads the session's state directly (no permission).
    public var modifierFlags: NSEvent.ModifierFlags {
        Self.merged(NSEvent.modifierFlags, CGEventSource.flagsState(.combinedSessionState))
    }

    static func merged(_ appKit: NSEvent.ModifierFlags, _ session: CGEventFlags) -> NSEvent.ModifierFlags {
        appKit.union(NSEvent.ModifierFlags(rawValue: UInt(session.rawValue)).intersection(.deviceIndependentFlagsMask))
    }

    public func pointerTarget(at point: NSPoint) -> PointerTarget {
        // Owner, layer and bounds need no Screen Recording permission (only window titles do) and never prompt.
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = raw.compactMap { info -> OnScreenWindow? in
            guard let number = info[kCGWindowNumber as String] as? Int, let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let box = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: box as CFDictionary) else { return nil }
            return OnScreenWindow(number: number, pid: pid, layer: layer, alpha: info[kCGWindowAlpha as String] as? Double ?? 1, bounds: bounds)
        }
        return PointerTargetClassifier.classify(point: point, windows: windows,
                                                screens: NSScreen.screens.map { ($0.frame, $0.visibleFrame) },
                                                bundleID: { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier })
    }

    public var frontmostProcessID: Int32? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    public var flagDiagnostics: String {
        let appKit = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        let session = CGEventSource.flagsState(.combinedSessionState).rawValue & UInt64(NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue)
        return "appKit=0x\(String(appKit, radix: 16)) session=0x\(String(session, radix: 16))"
    }
    public var mouseLocation: NSPoint { NSEvent.mouseLocation }
    public var dragPasteboardChangeCount: Int { pasteboard.changeCount }
    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func readDragPayload() -> DragPayload { DragPasteboardReader.payload(from: pasteboard) }

    public func installEventMonitors(_ handler: @escaping @MainActor (DragSystemEvent) -> Void) {
        removeEventMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        func map(_ event: NSEvent) -> DragSystemEvent? {
            switch event.type {
            case .leftMouseDown: .leftMouseDown
            case .leftMouseDragged: .leftMouseDragged
            case .leftMouseUp: .leftMouseUp
            default: nil
            }
        }
        // Global monitors are delivered on the main thread. Mouse events need no permission (key events would).
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
            guard let e = map(event) else { return }
            MainActor.assumeIsolated { handler(e) }
        }
        // Drags that start in Halo's own windows (settings, toasts) never reach the global monitor.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            if let e = map(event) { MainActor.assumeIsolated { handler(e) } }
            return event
        }
    }

    public func removeEventMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    public func startTicking(interval: TimeInterval, _ handler: @escaping @MainActor () -> Void) {
        stopTicking()
        let t = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { handler() } }
        t.tolerance = interval * 0.25 // lets the system coalesce wake-ups
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    public var isTicking: Bool { timer != nil }
}
