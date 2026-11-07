// End-to-end driver for the real Halo.app. Built standalone by scripts/e2e.sh (no Package.swift target).
//
//   e2e-driver perms                                  print AX / event-post / screen-capture permission state
//   e2e-driver fixtures <dir>                         photo.png, doc.pdf (2 pages), notes.txt, archive.zip-less set
//   e2e-driver drag [options] <file>...               synthesize a real cross-process drag with Option held
//        --target <title>        ring segment to drop on (matched against the segment's accessibility label)
//        --release-option        let go of Option once the ring is up, then drop on the driver's own drop window
//        --expect-no-ring        hold Option, assert no ring appears, then drop on the driver's drop window
//        --screenshot <png>      `screencapture -x` while the ring is up and the target segment is hovered
//        --pause                 no key: hold still mid-drag until the ring opens by itself, then drop on --target
//        --pause-through         no key: pause over the driver's drop window, then drop in the ring's hub. The drop must
//                                reach that window underneath
//        --from-finder           drag the one file's real icon out of a Finder window (revealed first) instead of the
//                                driver's source window: this is what a person does
//        --to-icon               no Option: drop on Halo's menu-bar icon, then choose --target from the menu it opens
//        --to-home               no Option: plain drop on the centre of `halo.home.dropzone` in Halo's home window;
//                                fails when the session ends with operation 0 (the drop was refused)
//   e2e-driver finder-close <title>                   AXPress the close button of Finder windows with this title
//   e2e-driver click-icon                             real mouse click on the menu-bar icon, then Escape (e2e.sh checks
//                                                     Halo's log for "Menu opened")
//   e2e-driver home-window [--timeout s]              Halo's home window (AXIdentifier halo.home, else title "Frenzy") is
//                                                     on screen: frame inside a display and listed by the window server
//   e2e-driver home-close [--timeout s]               AXPress the home window's AXCloseButton, wait until it's gone
//   e2e-driver home-element <id> [options]            find an element in the home window by AXIdentifier (`prefix*`
//                                                     matches a prefix), at any depth
//        --timeout <s>           wait up to s seconds (default 5)
//        --press                 AXPress it (or the nearest pressable descendant / ancestor)
//        --absent                instead wait until no element matches (the home window must still be there)
//        --expect-label <text>   its label (description, title, value, or a descendant's) must contain text
//   e2e-driver verify-image <file> <uti>              valid image of that type (ImageIO)
//   e2e-driver verify-pdf <file> [minPages]           valid PDF (PDFKit)
//   e2e-driver ranking <file>...                      ring titles Halo would show (registry + Halo's usage defaults)
//
// The drag command prints `KEY value` lines (RING, LABELS, TARGET, HOVER, DROPWIN, SESSION, RESULT) and exits 0 on
// success, 1 on a failed expectation, 2 when the environment blocks the test (no event-post permission). The home-*
// commands print HOMEWIN / ELEMENT / LABEL / PRESSED / IDS lines and use the same exit codes (2: no Accessibility).
import AppKit
import ApplicationServices
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import HaloCore
import HaloConverters
import HaloUI
import HaloDrag

setvbuf(stdout, nil, _IOLBF, 0)
let t0 = ProcessInfo.processInfo.systemUptime
func log(_ s: String) { print(String(format: "[%6.3f] ", ProcessInfo.processInfo.systemUptime - t0) + s) }
func out(_ key: String, _ value: String) { print("\(key) \(value)") }
func fail(_ msg: String, code: Int32 = 1) -> Never { print("RESULT FAIL \(msg)"); exit(code) }

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("no command") }
args.removeFirst()
let haloBundleID = "com.snappycrew.frenzy"

// MARK: - Fixtures

func writePNG(_ url: URL, width: Int, height: Int, hue: CGFloat) throws {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
    // A "photo": sky gradient, a sun, some hills.
    let sky = CGGradient(colorsSpace: cs, colors: [NSColor(hue: hue, saturation: 0.6, brightness: 0.95, alpha: 1).cgColor,
                                                    NSColor(hue: hue + 0.1, saturation: 0.3, brightness: 1, alpha: 1).cgColor] as CFArray,
                         locations: [0, 1])!
    ctx.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: height), options: [])
    ctx.setFillColor(NSColor.systemYellow.cgColor)
    ctx.fillEllipse(in: CGRect(x: width * 2 / 3, y: height * 2 / 3, width: width / 6, height: width / 6))
    ctx.setFillColor(NSColor(calibratedRed: 0.2, green: 0.5, blue: 0.25, alpha: 1).cgColor)
    ctx.move(to: .zero)
    for x in stride(from: 0, through: width, by: 8) {
        ctx.addLine(to: CGPoint(x: Double(x), y: Double(height) * (0.3 + 0.08 * sin(Double(x) / 40))))
    }
    ctx.addLine(to: CGPoint(x: width, y: 0)); ctx.closePath(); ctx.fillPath()
    let image = ctx.makeImage()!
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}

func writePDF(_ url: URL, pages: Int) throws {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
    // A large photographic bitmap per page so "Compress" (JPEG re-encode) has something to shrink.
    let w = 1400, h = 1000
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let bmp = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    var seed: UInt64 = 42
    let buf = bmp.data!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<h { for x in 0..<w {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let n = UInt8(truncatingIfNeeded: seed >> 59)
        let i = y * bmp.bytesPerRow + x * 4
        buf[i] = UInt8((x * 255) / w) &+ n; buf[i + 1] = UInt8((y * 255) / h) &+ n; buf[i + 2] = 128 &+ n; buf[i + 3] = 255
    } }
    let image = bmp.makeImage()!
    for p in 1...pages {
        ctx.beginPDFPage(nil)
        ctx.draw(image, in: CGRect(x: 56, y: 300, width: 500, height: 357))
        let text = NSAttributedString(string: "Frenzy E2E page \(p)", attributes: [.font: NSFont.systemFont(ofSize: 28)])
        let line = CTLineCreateWithAttributedString(text)
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

// MARK: - Verification

func verifyImage(_ path: String, uti: String) -> Bool {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let type = CGImageSourceGetType(src) as String?, CGImageSourceGetCount(src) >= 1,
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("not a readable image: \(path)"); return false }
    print("image \(path): type=\(type) \(img.width)x\(img.height)")
    return type == uti && img.width > 0 && img.height > 0
}

func verifyPDF(_ path: String, minPages: Int) -> Bool {
    guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { print("not a readable PDF: \(path)"); return false }
    print("pdf \(path): pages=\(doc.pageCount) text=\((doc.string ?? "").prefix(40).replacingOccurrences(of: "\n", with: " "))")
    return doc.pageCount >= minPages
}

// MARK: - Ring ranking fallback (same registry and usage defaults as Halo.app)

func rankedTitles(_ urls: [URL]) -> [String] {
    let defaults = UserDefaults(suiteName: haloBundleID) ?? .standard
    let registry = DefaultActions.registry(usage: DefaultsUsageStore(defaults: defaults))
    let range = 4...12 // HaloSettings.ringItemsRange (main-actor isolated)
    let limit = min(max(defaults.object(forKey: "halo.maxRingItems") as? Int ?? 10, range.lowerBound), range.upperBound)
    let inputs = urls.compactMap(InputFile.init(url:))
    return inputs.isEmpty ? [] : registry.actions(for: inputs, limit: limit).map { RingItem($0) }
        .map { [$0.title, $0.subtitle].compactMap { $0 }.joined(separator: ", ") }
}

// MARK: - Window server / AX probes (safe from any thread)

struct RingWindow { let frame: CGRect /* CG top-left global */; let windowID: Int }

func haloPID() -> pid_t? {
    NSRunningApplication.runningApplications(withBundleIdentifier: haloBundleID).first?.processIdentifier
}

/// Halo's on-screen ring panel: a 440×440 window at level 102 owned by Halo (bounds need no Screen Recording).
func findRingWindow(pid: pid_t) -> RingWindow? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
    for w in list {
        guard (w[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
              let layer = w[kCGWindowLayer as String] as? Int, layer == NSWindow.Level.popUpMenu.rawValue + 1 /* RingOverlayController.windowLevel */,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat],
              let bw = b["Width"], let bh = b["Height"], abs(bw - RingMetrics.canvasSize) < 1, abs(bh - RingMetrics.canvasSize) < 1
        else { continue }
        return RingWindow(frame: CGRect(x: b["X"]!, y: b["Y"]!, width: bw, height: bh), windowID: w[kCGWindowNumber as String] as? Int ?? 0)
    }
    return nil
}

func ax<T>(_ el: AXUIElement, _ attr: String) -> T? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    return v as? T
}

struct AXSegment { let label: String; let selected: Bool }

/// Reads the ring's segments (labels, in model order) from Halo's accessibility tree.
func axRingSegments(pid: pid_t) -> (group: String, segments: [AXSegment])? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.5)
    guard let windows: [AXUIElement] = ax(app, kAXWindowsAttribute) else { return nil }
    for win in windows {
        var size = CGSize.zero
        if let sv: AXValue = ax(win, kAXSizeAttribute) { AXValueGetValue(sv, .cgSize, &size) }
        guard abs(size.width - RingMetrics.canvasSize) < 1 else { continue }
        var found: (String, [AXSegment])?
        func walk(_ el: AXUIElement, depth: Int) {
            guard found == nil, depth < 12 else { return }
            let desc: String = ax(el, kAXDescriptionAttribute) ?? ""
            if desc.hasPrefix("Conversions"), let kids: [AXUIElement] = ax(el, kAXChildrenAttribute) {
                let segs = kids.compactMap { k -> AXSegment? in
                    let role: String = ax(k, kAXRoleAttribute) ?? ""
                    let d: String = ax(k, kAXDescriptionAttribute) ?? ""
                    guard role == "AXButton", !d.isEmpty else { return nil }
                    return AXSegment(label: d, selected: (ax(k, kAXSelectedAttribute) as Bool?) ?? false)
                }
                if !segs.isEmpty { found = (desc, segs); return }
            }
            for k in (ax(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(k, depth: depth + 1) }
        }
        walk(win, depth: 0)
        if let found { return found }
    }
    return nil
}

func labelMatches(_ label: String, _ title: String) -> Bool { label == title || label.hasPrefix(title + ", ") }

/// Halo's menu-bar icon in CG global (top-left) coordinates, from the app's AXExtrasMenuBar.
func axStatusIcon(pid: pid_t) -> CGRect? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.5)
    guard let bar: AXUIElement = ax(app, "AXExtrasMenuBar"),
          let item = (ax(bar, kAXChildrenAttribute) as [AXUIElement]?)?.first else { return nil }
    var pos = CGPoint.zero, size = CGSize.zero
    if let v: AXValue = ax(item, kAXPositionAttribute) { AXValueGetValue(v, .cgPoint, &pos) }
    if let v: AXValue = ax(item, kAXSizeAttribute) { AXValueGetValue(v, .cgSize, &size) }
    return size.width > 0 && size.height > 0 ? CGRect(origin: pos, size: size) : nil
}

/// Items of any menu Halo currently has open (status menu or the drop menu), with their titles.
func axOpenMenuItems(pid: pid_t) -> [(title: String, element: AXUIElement)] {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.5)
    var items: [(String, AXUIElement)] = []
    func walk(_ el: AXUIElement, depth: Int, inMenu: Bool) {
        guard depth < 8 else { return }
        let role: String = ax(el, kAXRoleAttribute) ?? ""
        if inMenu, role == "AXMenuItem" { items.append(((ax(el, kAXTitleAttribute) as String?) ?? "", el)) }
        for k in (ax(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(k, depth: depth + 1, inMenu: inMenu || role == "AXMenu") }
    }
    walk(app, depth: 0, inMenu: false)
    return items
}

/// A file's icon in a Finder window, in CG global (top-left) coordinates. Finder lists it as an AXImage with AXFilename
/// (icon view), or a text field holding the name (list view). Menus also mention the name, so they aren't searched.
/// The file icon in the same list-view cell as the name field (its exact frame, whatever the indent or column).
func rowIcon(of field: AXUIElement) -> CGRect? {
    guard let cell: AXUIElement = ax(field, kAXParentAttribute) else { return nil }
    for kid in (ax(cell, kAXChildrenAttribute) as [AXUIElement]?) ?? [] where (ax(kid, kAXRoleAttribute) as String?) == "AXImage" {
        guard let posV: AXValue = ax(kid, kAXPositionAttribute), let sizeV: AXValue = ax(kid, kAXSizeAttribute) else { continue }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posV, .cgPoint, &pos); AXValueGetValue(sizeV, .cgSize, &size)
        if size.width > 0, size.height > 0 { return CGRect(origin: pos, size: size) }
    }
    return nil
}

func finderItem(named name: String) -> CGRect? {
    guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return nil }
    let app = AXUIElementCreateApplication(finder.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 1)
    var found: CGRect?
    func walk(_ el: AXUIElement, depth: Int) {
        guard found == nil, depth < 16 else { return }
        let role: String = ax(el, kAXRoleAttribute) ?? ""
        if role == "AXMenuBar" { return }
        let isIcon = role == "AXImage" && (ax(el, "AXFilename") as String?) == name
        let isRow = role == "AXTextField" && (ax(el, kAXValueAttribute) as String?) == name
        if isIcon || isRow, let posV: AXValue = ax(el, kAXPositionAttribute), let sizeV: AXValue = ax(el, kAXSizeAttribute) {
            var pos = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(posV, .cgPoint, &pos); AXValueGetValue(sizeV, .cgSize, &size)
            // List view gives the name's text field, which Finder won't drag from: use the small icon just left of it.
            if size.width > 0, size.height > 0 {
                found = isRow ? (rowIcon(of: el) ?? CGRect(x: pos.x - size.height - 4, y: pos.y, width: size.height, height: size.height))
                              : CGRect(origin: pos, size: size)
                return
            }
        }
        for kid in (ax(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(kid, depth: depth + 1) }
    }
    walk(app, depth: 0)
    return found
}

func runFinderClose(_ argv: [String]) -> Never {
    guard let title = argv.first else { fail("finder-close <title>") }
    guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { fail("Finder is not running") }
    let app = AXUIElementCreateApplication(finder.processIdentifier)
    var closed = 0
    for window in (ax(app, kAXWindowsAttribute) as [AXUIElement]?) ?? [] where (ax(window, kAXTitleAttribute) as String?) == title {
        if let close: AXUIElement = ax(window, kAXCloseButtonAttribute), AXUIElementPerformAction(close, kAXPressAction as CFString) == .success { closed += 1 }
    }
    print("RESULT PASS closed \(closed) Finder window(s)")
    exit(0)
}

func runClickIcon() -> Never {
    guard CGPreflightPostEventAccess() else { fail("BLOCKED cannot post events", code: 2) }
    guard let pid = haloPID() else { fail("Frenzy is not running") }
    guard let icon = axStatusIcon(pid: pid) else { fail("menu-bar icon not found in Frenzy's accessibility tree") }
    out("ICON", "\(icon)")
    let es = CGEventSource(stateID: .hidSystemState)
    let p = CGPoint(x: icon.midX, y: icon.midY)
    for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: es, mouseType: type, mouseCursorPosition: p, mouseButton: .left)!.post(tap: .cghidEventTap)
        usleep(80_000)
    }
    usleep(700_000) // the shell checks Halo's log for "Menu opened" (AX lists a closed menu's items too)
    let esc = CGEvent(keyboardEventSource: es, virtualKey: 53, keyDown: true)!; esc.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: es, virtualKey: 53, keyDown: false)!.post(tap: .cghidEventTap)
    usleep(300_000)
    print("RESULT PASS clicked the icon")
    exit(0)
}

// MARK: - Home window (B3): everything found by AXIdentifier, at any depth (SwiftUI may put an identifier on a
// parent or child of the element you'd expect), never by tree position.

let homeID = "halo.home"

func axString(_ el: AXUIElement, _ attr: String) -> String { (ax(el, attr) as String?) ?? "" }

func axFrame(_ el: AXUIElement) -> CGRect? {
    guard let p: AXValue = ax(el, kAXPositionAttribute), let s: AXValue = ax(el, kAXSizeAttribute) else { return nil }
    var pos = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p, .cgPoint, &pos); AXValueGetValue(s, .cgSize, &size)
    return CGRect(origin: pos, size: size) // CG global, top-left
}

/// `halo.home.action.*` matches every identifier with that prefix; anything else must match exactly.
func idMatcher(_ pattern: String) -> (String) -> Bool {
    if pattern.hasSuffix("*") { let prefix = String(pattern.dropLast()); return { $0.hasPrefix(prefix) } }
    return { $0 == pattern }
}

/// Breadth-first search of `root`'s subtree (bounded, root included) for elements whose AXIdentifier matches.
func axSearch(_ root: AXUIElement, all: Bool = false, limit: Int = 4000, _ match: (String) -> Bool) -> [AXUIElement] {
    var queue = [root], found: [AXUIElement] = [], i = 0
    while i < queue.count, i < limit {
        let el = queue[i]; i += 1
        if match(axString(el, "AXIdentifier")) { found.append(el); if !all { break } }
        queue += (ax(el, kAXChildrenAttribute) as [AXUIElement]?) ?? []
    }
    return found
}

struct HomeWindow { let element: AXUIElement; let frame: CGRect; let title: String; let matched: String }

/// Halo's home window: AXIdentifier `halo.home` on the window or anywhere inside it wins; title "Frenzy" is the fallback.
func axHomeWindow(pid: pid_t) -> HomeWindow? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.5)
    var byTitle: HomeWindow?
    for win in (ax(app, kAXWindowsAttribute) as [AXUIElement]?) ?? [] {
        guard let frame = axFrame(win) else { continue }
        let title = axString(win, kAXTitleAttribute)
        if axString(win, "AXIdentifier") == homeID { return HomeWindow(element: win, frame: frame, title: title, matched: "window AXIdentifier") }
        if !axSearch(win, idMatcher(homeID)).isEmpty { return HomeWindow(element: win, frame: frame, title: title, matched: "AXIdentifier inside the window") }
        if title == "Frenzy", byTitle == nil { byTitle = HomeWindow(element: win, frame: frame, title: title, matched: "title") }
    }
    return byTitle
}

/// The display (CG global bounds) that fully contains `frame`, if any.
func displayContaining(_ frame: CGRect) -> CGRect? {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
    guard CGGetActiveDisplayList(16, &ids, &n) == .success else { return nil }
    return ids.prefix(Int(n)).map(CGDisplayBounds).first { $0.insetBy(dx: -1, dy: -1).contains(frame) }
}

/// The window server lists an on-screen window of `pid` with this frame (AX alone also reports ordered-out windows).
func cgOnScreen(pid: pid_t, frame: CGRect) -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
    return list.contains { w in
        guard (w[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
        let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        return abs(r.minX - frame.minX) < 2 && abs(r.minY - frame.minY) < 2 && abs(r.width - frame.width) < 2 && abs(r.height - frame.height) < 2
    }
}

func homeWindowVisible(_ w: HomeWindow, pid: pid_t) -> Bool {
    !((ax(w.element, kAXMinimizedAttribute) as Bool?) ?? false) && displayContaining(w.frame) != nil && cgOnScreen(pid: pid, frame: w.frame)
}

/// Frontmost window at `p` (CG global) below the Dock level, other than the driver's own: who would get a drop there.
func topWindow(at p: CGPoint) -> (pid: pid_t, owner: String, layer: Int)? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
    for w in list { // front to back
        guard let owner = (w[kCGWindowOwnerPID as String] as? Int).map(pid_t.init), owner != getpid(),
              let layer = w[kCGWindowLayer as String] as? Int, (0..<Int(CGWindowLevelForKey(.dockWindow))).contains(layer),
              (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat],
              CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0).contains(p) else { continue }
        return (owner, w[kCGWindowOwnerName as String] as? String ?? "?", layer)
    }
    return nil
}

/// What VoiceOver would read for an element: description, title, value, help; then its descendants' (a row's text
/// often sits on a child).
func axLabel(_ el: AXUIElement) -> String {
    func own(_ e: AXUIElement) -> [String] {
        [axString(e, kAXDescriptionAttribute), axString(e, kAXTitleAttribute), axString(e, kAXValueAttribute), axString(e, kAXHelpAttribute)]
            .filter { !$0.isEmpty }
    }
    var parts = own(el), queue = (ax(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [], i = 0
    while i < queue.count, i < 60 {
        parts += own(queue[i]); queue += (ax(queue[i], kAXChildrenAttribute) as [AXUIElement]?) ?? []; i += 1
    }
    return parts.joined(separator: " | ")
}

func axCanPress(_ el: AXUIElement) -> Bool {
    var names: CFArray?
    guard AXUIElementCopyActionNames(el, &names) == .success else { return false }
    return ((names as? [String]) ?? []).contains(kAXPressAction)
}

/// The element itself if it supports AXPress, else the nearest pressable descendant, else a pressable ancestor.
func axPressTarget(_ el: AXUIElement) -> AXUIElement? {
    if axCanPress(el) { return el }
    var queue = (ax(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [], i = 0
    while i < queue.count, i < 200 {
        if axCanPress(queue[i]) { return queue[i] }
        queue += (ax(queue[i], kAXChildrenAttribute) as [AXUIElement]?) ?? []; i += 1
    }
    var up: AXUIElement? = ax(el, kAXParentAttribute)
    for _ in 0..<3 {
        guard let p = up else { break }
        if axCanPress(p) { return p }
        up = ax(p, kAXParentAttribute)
    }
    return nil
}

/// Every `halo.*` identifier in the home window, for failure messages.
func homeIdentifiers(_ win: AXUIElement) -> String {
    axSearch(win, all: true) { $0.hasPrefix("halo.") }.map { axString($0, "AXIdentifier") }.joined(separator: ",")
}

func flagValue(_ argv: [String], _ name: String) -> String? {
    guard let i = argv.firstIndex(of: name), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}

func waitUntil(_ timeout: Double, _ check: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    repeat { if check() { return true }; usleep(150_000) } while Date() < end
    return false
}

func homePreflight() -> pid_t {
    guard AXIsProcessTrusted() else { fail("BLOCKED no Accessibility permission: Frenzy's AX tree is unreadable", code: 2) }
    guard let pid = haloPID() else { fail("Frenzy is not running") }
    return pid
}

func runHomeWindow(_ argv: [String]) -> Never {
    let pid = homePreflight()
    let timeout = flagValue(argv, "--timeout").flatMap(Double.init) ?? 5
    var last: HomeWindow?
    let ok = waitUntil(timeout) {
        last = axHomeWindow(pid: pid)
        return last.map { homeWindowVisible($0, pid: pid) } ?? false
    }
    guard let w = last else { fail("no Frenzy window with AXIdentifier \(homeID) or title \"Frenzy\" within \(timeout) s") }
    out("HOMEWIN", "title=\"\(w.title)\" matched=\(w.matched) frame=\(w.frame) display=\(displayContaining(w.frame).map { "\($0)" } ?? "none")")
    guard ok else { fail("home window found but not on screen: frame \(w.frame), on-screen list \(cgOnScreen(pid: pid, frame: w.frame))") }
    print("RESULT PASS home window on screen (\(w.matched))")
    exit(0)
}

func runHomeClose(_ argv: [String]) -> Never {
    let pid = homePreflight()
    let timeout = flagValue(argv, "--timeout").flatMap(Double.init) ?? 5
    var found: HomeWindow?
    guard waitUntil(timeout, { found = axHomeWindow(pid: pid); return found != nil }), let w = found else { fail("no home window to close") }
    guard let close: AXUIElement = ax(w.element, kAXCloseButtonAttribute) else { fail("home window has no AXCloseButton") }
    let r = AXUIElementPerformAction(close, kAXPressAction as CFString)
    out("PRESSED", "AXCloseButton status=\(r.rawValue)")
    guard r == .success else { fail("AXPress on AXCloseButton failed (\(r.rawValue))") }
    let gone = waitUntil(timeout) { axHomeWindow(pid: pid).map { !homeWindowVisible($0, pid: pid) } ?? true }
    guard gone else { fail("home window still on screen \(timeout) s after AXCloseButton") }
    print("RESULT PASS home window closed")
    exit(0)
}

func runHomeElement(_ argv: [String]) -> Never {
    let pid = homePreflight()
    var pattern: String?, press = false, absent = false
    var it = argv.makeIterator()
    while let a = it.next() {
        switch a {
        case "--timeout", "--expect-label": _ = it.next()
        case "--press": press = true
        case "--absent": absent = true
        default: pattern = a
        }
    }
    guard let pattern else { fail("home-element <identifier> [--timeout s] [--press] [--absent] [--expect-label text]") }
    let timeout = flagValue(argv, "--timeout").flatMap(Double.init) ?? 5
    let expect = flagValue(argv, "--expect-label")
    var window: AXUIElement?, hit: AXUIElement?, label = ""
    let ok = waitUntil(timeout) {
        guard let w = axHomeWindow(pid: pid)?.element else { window = nil; return false }
        window = w
        hit = axSearch(w, idMatcher(pattern)).first
        if absent { return hit == nil }
        guard let hit else { return false }
        label = axLabel(hit)
        return expect.map { label.contains($0) } ?? true
    }
    guard let window else { fail("no home window") }
    out("IDS", homeIdentifiers(window))
    if absent {
        guard ok else { fail("\(pattern) still present after \(timeout) s") }
        print("RESULT PASS no element matches \(pattern)"); exit(0)
    }
    guard let hit else { fail("no element with AXIdentifier \(pattern) within \(timeout) s") }
    out("ELEMENT", "id=\(axString(hit, "AXIdentifier")) role=\(axString(hit, kAXRoleAttribute)) frame=\(axFrame(hit).map { "\($0)" } ?? "?")")
    out("LABEL", label)
    guard ok else { fail("label of \(pattern) does not contain \"\(expect ?? "")\": \"\(label)\"") }
    if press {
        guard let target = axPressTarget(hit) else { fail("\(pattern) has no pressable element (no AXPress on it, its children or parents)") }
        let r = AXUIElementPerformAction(target, kAXPressAction as CFString)
        out("PRESSED", "\(axString(target, "AXIdentifier")) role=\(axString(target, kAXRoleAttribute)) label=\"\(axLabel(target))\" status=\(r.rawValue)")
        guard r == .success else { fail("AXPress on \(pattern) failed (\(r.rawValue))") }
    }
    print("RESULT PASS \(pattern)\(press ? " pressed" : " found")")
    exit(0)
}

/// The home drop zone's frame (CG global), after raising the home window so nothing else sits on top of it.
func prepareHomeDropzone(pid: pid_t) -> CGRect {
    var zone: CGRect?, window: HomeWindow?
    _ = waitUntil(5) {
        window = axHomeWindow(pid: pid)
        zone = window.flatMap { axSearch($0.element, idMatcher("halo.home.dropzone")).first }.flatMap(axFrame)
        return zone != nil
    }
    guard let w = window else { fail("no home window to drop on") }
    guard let zone, zone.width > 4, zone.height > 4 else { fail("no halo.home.dropzone in the home window (ids: \(homeIdentifiers(w.element)))") }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
    usleep(400_000)
    let centre = CGPoint(x: zone.midX, y: zone.midY)
    if let top = topWindow(at: centre) {
        out("TOPMOST", "\(top.owner) pid=\(top.pid) layer=\(top.layer)")
        if top.pid != pid, top.layer == 0 { fail("the home drop zone is covered by \(top.owner)'s window") }
    }
    return zone
}

// MARK: - Drag scenario

final class Shared: @unchecked Sendable {
    let lock = NSLock()
    var dropWindowReceived: [URL] = []
    var sessionEnded: (op: UInt, at: NSPoint)?
    func with<T>(_ f: (Shared) -> T) -> T { lock.withLock { f(self) } }
}
let shared = Shared()

@MainActor final class SourceView: NSView, NSDraggingSource {
    var files: [URL] = []
    override func draw(_ r: NSRect) { NSColor.systemBlue.setFill(); bounds.fill() }
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
        shared.with { $0.sessionEnded = (operation.rawValue, p) }
        log("source: session ended at \(p) operation \(operation.rawValue)")
    }
    private var started = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true } // the driver is never the active app
    override func mouseDown(with event: NSEvent) { log("source: mouseDown") }
    // Like Finder, the drag starts on the first movement, not on the press. Halo ignores what's on the drag pasteboard
    // when the button goes down (it's stale), so a session started inside mouseDown races Halo's own mouse-down event.
    override func mouseDragged(with event: NSEvent) {
        guard !started else { return }
        started = true
        log("source: starting NSDraggingSession for \(files.map(\.lastPathComponent))")
        let items = files.enumerated().map { i, f -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: f as NSURL)
            item.setDraggingFrame(NSRect(x: 30 + i * 6, y: 30 - i * 6, width: 40, height: 40), contents: NSWorkspace.shared.icon(forFile: f.path))
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }
}

/// A plain drop target (like a Finder folder) used to prove a drag still completes normally without the ring.
@MainActor final class DropView: NSView {
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ r: NSRect) { NSColor.systemGreen.setFill(); bounds.fill() }
    override func draggingEntered(_ s: any NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ s: any NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ s: any NSDraggingInfo) -> Bool {
        let urls = s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        shared.with { $0.dropWindowReceived = urls }
        log("dropwindow: received \(urls.map(\.lastPathComponent))")
        return true
    }
}

func runDrag(_ argv: [String]) -> Never {
    var target: String?, releaseOption = false, expectNoRing = false, toIcon = false, toHome = false, fromFinder = false, pauseMode = false, pauseThrough = false, screenshot: String?
    var files: [URL] = []
    var it = argv.makeIterator()
    while let a = it.next() {
        switch a {
        case "--target": target = it.next()
        case "--release-option": releaseOption = true
        case "--expect-no-ring": expectNoRing = true
        case "--to-icon": toIcon = true
        case "--to-home": toHome = true
        case "--from-finder": fromFinder = true
        case "--pause": pauseMode = true
        case "--pause-through": pauseThrough = true
        case "--screenshot": screenshot = it.next()
        default: files.append(URL(fileURLWithPath: a).standardizedFileURL)
        }
    }
    guard !files.isEmpty else { fail("no files") }
    guard CGPreflightPostEventAccess() else {
        fail("BLOCKED cannot post events (CGPreflightPostEventAccess false): grant Accessibility to the terminal", code: 2)
    }
    guard let pid = haloPID() else { fail("Frenzy is not running") }
    let axTrusted = AXIsProcessTrusted()
    out("AXTRUSTED", "\(axTrusted)")
    var homeZone: CGRect?
    if toHome {
        guard axTrusted else { fail("BLOCKED --to-home finds the drop zone through Frenzy's AX tree: grant Accessibility", code: 2) }
        homeZone = prepareHomeDropzone(pid: pid)
    }
    var finderStart: CGPoint?
    if fromFinder {
        guard axTrusted else { fail("BLOCKED --from-finder finds the icon through Finder's AX tree: grant Accessibility", code: 2) }
        guard files.count == 1 else { fail("--from-finder takes one file") }
        NSWorkspace.shared.activateFileViewerSelecting(files)
        for _ in 0..<40 {
            usleep(150_000)
            if let icon = finderItem(named: files[0].lastPathComponent) {
                out("FINDERICON", "\(icon)")
                usleep(500_000) // let the window finish animating open
                finderStart = finderItem(named: files[0].lastPathComponent).map { CGPoint(x: $0.midX, y: $0.midY) }
                break
            }
        }
        guard finderStart != nil else { fail("\(files[0].lastPathComponent) not found in any Finder window") }
    }

    return MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let screen = NSScreen.screens[0]
        let vf = screen.visibleFrame, h = screen.frame.height
        let srcRect = NSRect(x: vf.minX + 60, y: vf.midY - 50, width: 100, height: 100)
        // A pause-through ring must open centred on the pointer, so its window can't sit by the screen edge.
        let dropRect = NSRect(x: vf.maxX - (pauseThrough ? 600 : 200), y: vf.midY - 70, width: 140, height: 140)
        func window(_ r: NSRect, _ v: NSView) -> NSWindow {
            let w = NSWindow(contentRect: r, styleMask: [.borderless], backing: .buffered, defer: false)
            w.level = .floating; w.contentView = v; w.orderFrontRegardless(); return w
        }
        let src = SourceView(frame: NSRect(origin: .zero, size: srcRect.size)); src.files = files
        let srcWin = fromFinder ? nil : window(srcRect, src)
        // A home drop needs no fallback target, and the green window must not sit over Halo's.
        let dropWin = toHome ? nil : window(dropRect, DropView(frame: NSRect(origin: .zero, size: dropRect.size)))
        _ = (srcWin, dropWin)
        if let zone = homeZone, CGRect(x: srcRect.minX, y: h - srcRect.maxY, width: srcRect.width, height: srcRect.height)
            .contains(CGPoint(x: zone.midX, y: zone.midY)) {
            fail("the home drop zone \(zone) is under the driver's source window")
        }

        // Everything below runs on a background thread: AppKit's drag loop owns the main thread meanwhile.
        let start = finderStart ?? CGPoint(x: srcRect.midX, y: h - srcRect.midY) // CG top-left coordinates
        let dropPoint = CGPoint(x: dropRect.midX, y: h - dropRect.midY)
        let summon = CGPoint(x: vf.midX - 120, y: h - vf.midY)
        let thread = Thread {
            let es = CGEventSource(stateID: .hidSystemState)
            var optionDown = false
            var cursor = start
            func post(_ type: CGEventType, _ p: CGPoint) {
                let e = CGEvent(mouseEventSource: es, mouseType: type, mouseCursorPosition: p, mouseButton: .left)!
                e.flags = optionDown ? .maskAlternate : []
                e.post(tap: .cghidEventTap); cursor = p
            }
            func option(_ down: Bool) {
                optionDown = down
                let e = CGEvent(keyboardEventSource: es, virtualKey: 58, keyDown: down)!
                e.flags = down ? .maskAlternate : []
                e.post(tap: .cghidEventTap)
            }
            func moveDragged(to p: CGPoint, steps: Int = 20) {
                let a = cursor
                for i in 1...steps {
                    let f = CGFloat(i) / CGFloat(steps)
                    post(.leftMouseDragged, CGPoint(x: a.x + (p.x - a.x) * f, y: a.y + (p.y - a.y) * f))
                    usleep(16_000)
                }
            }
            func finish(_ ok: Bool, _ msg: String) -> Never {
                if optionDown { option(false) }
                usleep(1_200_000) // let the drag session end and Halo finish
                let s = shared.with { ($0.dropWindowReceived, $0.sessionEnded) }
                out("DROPWIN", s.0.map(\.lastPathComponent).joined(separator: ","))
                out("SESSION", s.1.map { "ended op=\($0.op)" } ?? "not-ended")
                if ok, (releaseOption || expectNoRing || pauseThrough) {
                    let want = files.map(\.lastPathComponent)
                    guard s.0.map(\.lastPathComponent) == want else { print("RESULT FAIL drop window did not receive \(want)"); exit(1) }
                    guard s.1 != nil else { print("RESULT FAIL drag session did not end"); exit(1) }
                }
                print(ok ? "RESULT PASS \(msg)" : "RESULT FAIL \(msg)")
                exit(ok ? 0 : 1)
            }
            func waitRing(timeout: Double) -> RingWindow? {
                let end = Date().addingTimeInterval(timeout)
                var wiggle: CGFloat = 1
                while Date() < end {
                    if let r = findRingWindow(pid: pid) { return r }
                    post(.leftMouseDragged, CGPoint(x: cursor.x + wiggle, y: cursor.y)); wiggle = -wiggle
                    usleep(50_000)
                }
                return nil
            }

            usleep(600_000)
            post(.mouseMoved, start); usleep(150_000)
            post(.leftMouseDown, start); usleep(120_000)
            if fromFinder { print("source: mouseDown (Finder)") } // e2e.sh retries only when a drag never started
            if let zone = homeZone {                   // plain drag, Option never pressed: like a Finder drag
                let p = CGPoint(x: zone.midX, y: zone.midY)
                out("HOMEZONE", "\(zone)")
                moveDragged(to: p, steps: 30); usleep(250_000)
                post(.leftMouseDragged, CGPoint(x: p.x + 1, y: p.y)); usleep(250_000)
                if findRingWindow(pid: pid) != nil { post(.leftMouseUp, p); finish(false, "ring appeared during a drag without Option") }
                post(.leftMouseUp, CGPoint(x: p.x + 1, y: p.y))
                var ended: (op: UInt, at: NSPoint)?
                for _ in 0..<60 { ended = shared.with { $0.sessionEnded }; if ended != nil { break }; usleep(50_000) }
                guard let ended else { finish(false, "drag session did not end after the drop") }
                // Operation 0 means the drop zone refused the drag (it slid back): never a pass.
                guard ended.op != 0 else { finish(false, "drop refused: drag session ended with operation 0") }
                finish(true, "dropped on the home drop zone, operation \(ended.op)")
            }
            if pauseThrough {
                moveDragged(to: dropPoint, steps: 30)
                guard waitRing(timeout: 2.5) != nil else { post(.leftMouseUp, dropPoint); finish(false, "ring never opened on the pause") }
                out("RING", "opened on the pause; dropping in the hub")
                usleep(300_000)
                post(.leftMouseDragged, dropPoint); usleep(100_000)
                post(.leftMouseUp, dropPoint)
                finish(true, "the drop went through the ring's hub to the window underneath")
            }
            moveDragged(to: summon, steps: 30)         // no Option yet: no ring
            usleep(250_000)
            if findRingWindow(pid: pid) != nil { finish(false, "ring appeared before Option was pressed") }

            if toIcon {
                guard let icon = axStatusIcon(pid: pid) else { post(.leftMouseUp, start); finish(false, "menu-bar icon not found") }
                out("ICON", "\(icon)")
                let p = CGPoint(x: icon.midX, y: icon.midY)
                moveDragged(to: p, steps: 30); usleep(200_000)
                post(.leftMouseDragged, CGPoint(x: p.x + 1, y: p.y)); usleep(250_000)
                post(.leftMouseUp, CGPoint(x: p.x + 1, y: p.y))
                var items: [(title: String, element: AXUIElement)] = []
                for _ in 0..<30 {
                    items = axOpenMenuItems(pid: pid)
                    if items.contains(where: { $0.title == target }) { break }
                    usleep(100_000)
                }
                out("MENU", items.map(\.title).joined(separator: " | "))
                guard let choice = items.first(where: { $0.title == target }) else { finish(false, "drop menu without \(target ?? "nil")") }
                let pressed = AXUIElementPerformAction(choice.element, kAXPressAction as CFString)
                out("PRESS", "\(pressed.rawValue)")
                finish(pressed == .success, "dropped on the menu-bar icon; chose \(target ?? "")")
            }
            if !pauseMode {
                option(true); usleep(60_000)
                post(.leftMouseDragged, summon)
            }

            if expectNoRing {
                if let r = waitRing(timeout: 1.5) { out("RING", "shown \(r.frame)"); finish(false, "ring appeared for an unsupported file") }
                out("RING", "none")
                moveDragged(to: dropPoint, steps: 30); usleep(150_000)
                post(.leftMouseUp, dropPoint)
                finish(true, "no ring; drag completed on the drop window")
            }

            guard let ring = waitRing(timeout: 2.5) else {
                post(.leftMouseUp, start); finish(false, "ring never appeared")
            }
            out("RING", "shown frame=\(ring.frame)")
            usleep(250_000) // let the bloom settle and SwiftUI publish its AX tree
            var labels: [String] = []
            var source = "ax"
            if axTrusted {
                for _ in 0..<10 {
                    if let tree = axRingSegments(pid: pid) { labels = tree.segments.map(\.label); out("AXGROUP", tree.group); break }
                    usleep(100_000)
                }
            }
            if labels.isEmpty { source = "registry"; labels = rankedTitles(files) }
            out("LABELS", "[\(source)] " + labels.joined(separator: " | "))
            let registryLabels = rankedTitles(files)
            out("REGISTRY", registryLabels.joined(separator: " | "))
            if source == "ax" && labels != registryLabels { out("WARN", "AX order differs from registry ranking") }

            if releaseOption {
                option(false); usleep(700_000)          // past the 0.2 s grace period
                if findRingWindow(pid: pid) != nil { finish(false, "ring still shown after releasing Option") }
                out("RING", "dismissed after Option release")
                moveDragged(to: dropPoint, steps: 30); usleep(150_000)
                post(.leftMouseUp, dropPoint)
                finish(true, "ring dismissed on release; drag completed on the drop window")
            }

            guard let title = target, let index = labels.firstIndex(where: { labelMatches($0, title) }) else {
                post(.leftMouseUp, start); finish(false, "target \(target ?? "nil") not on ring")
            }
            let count = labels.count
            let center = CGPoint(x: ring.frame.midX, y: ring.frame.midY)
            let angle = RingGeometry.centerAngle(index: index, count: count)
            let radius = (RingMetrics.innerRadius + RingMetrics.outerRadius) / 2
            let p = RingGeometry.point(angle: angle, radius: radius, center: center) // y-down == CG global
            out("TARGET", "\(labels[index]) index=\(index)/\(count) at=\(p)")
            moveDragged(to: p, steps: 15); usleep(250_000)
            post(.leftMouseDragged, CGPoint(x: p.x + 1, y: p.y)); usleep(150_000)
            if axTrusted, let tree = axRingSegments(pid: pid) {
                let sel = tree.segments.enumerated().filter(\.element.selected).map { "\($0.offset):\($0.element.label)" }
                out("HOVER", sel.joined(separator: ","))
            }
            if let shot = screenshot {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                let r = ring.frame.insetBy(dx: -20, dy: -20) // only the ring, never the rest of the desktop
                task.arguments = ["-x", "-R\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))", shot]
                try? task.run(); task.waitUntilExit()
                out("SCREENSHOT", "status=\(task.terminationStatus) \(shot)")
            }
            post(.leftMouseUp, CGPoint(x: p.x + 1, y: p.y)); usleep(100_000)
            option(false)
            finish(true, "dropped on \(labels[index])")
        }
        thread.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { fail("timeout") }
        app.run()
        exit(1)
    }
}

// MARK: - Main

switch command {
case "perms":
    print("AX=\(AXIsProcessTrusted()) post=\(CGPreflightPostEventAccess()) listen=\(CGPreflightListenEventAccess()) screen=\(CGPreflightScreenCaptureAccess())")
case "fixtures":
    guard let dir = args.first.map({ URL(fileURLWithPath: $0) }) else { fail("fixtures <dir>") }
    let fm = FileManager.default
    for sub in ["png", "pdf", "pdfc", "txt", "release", "zip", "batch", "icon", "home", "homecancel"] {
        try! fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
    }
    try! writePNG(dir.appendingPathComponent("png/photo.png"), width: 1200, height: 800, hue: 0.58)
    try! writePDF(dir.appendingPathComponent("pdf/doc.pdf"), pages: 2)
    try! writePDF(dir.appendingPathComponent("pdfc/doc.pdf"), pages: 2)
    try! "Frenzy end-to-end test.\n\nLine two of the notes.\nLine three.\n".write(to: dir.appendingPathComponent("txt/notes.txt"), atomically: true, encoding: .utf8)
    try! writePNG(dir.appendingPathComponent("release/photo.png"), width: 600, height: 400, hue: 0.3)
    try! writePNG(dir.appendingPathComponent("icon/photo.png"), width: 900, height: 600, hue: 0.8)
    // Unique names, so Recent Conversions row 0 can only be the home drop's result.
    try! writePNG(dir.appendingPathComponent("home/home-photo.png"), width: 1000, height: 700, hue: 0.45)
    try! writePNG(dir.appendingPathComponent("homecancel/cancel-photo.png"), width: 700, height: 500, hue: 0.95)
    for (i, n) in ["a", "b", "c"].enumerated() {
        try! writePNG(dir.appendingPathComponent("batch/\(n).png"), width: 800, height: 600, hue: 0.1 + 0.2 * CGFloat(i))
    }
    print("fixtures written to \(dir.path)")
case "verify-image":
    guard args.count == 2 else { fail("verify-image <file> <uti>") }
    exit(verifyImage(args[0], uti: args[1]) ? 0 : 1)
case "verify-pdf":
    guard !args.isEmpty else { fail("verify-pdf <file> [minPages]") }
    exit(verifyPDF(args[0], minPages: args.count > 1 ? Int(args[1]) ?? 1 : 1) ? 0 : 1)
case "ranking":
    print(rankedTitles(args.map { URL(fileURLWithPath: $0) }).joined(separator: " | "))
case "drag":
    runDrag(args)
case "click-icon":
    runClickIcon()
case "finder-close":
    runFinderClose(args)
case "escape": // closes a menu a failed menu-bar scenario left open: it would swallow every later click
    let es = CGEventSource(stateID: .hidSystemState)
    for _ in 0..<2 {
        CGEvent(keyboardEventSource: es, virtualKey: 53, keyDown: true)!.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: es, virtualKey: 53, keyDown: false)!.post(tap: .cghidEventTap)
        usleep(200_000)
    }
case "home-window":
    runHomeWindow(args)
case "home-close":
    runHomeClose(args)
case "home-element":
    runHomeElement(args)
default:
    fail("unknown command \(command)")
}
