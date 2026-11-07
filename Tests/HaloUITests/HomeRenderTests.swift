import Testing
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import HaloCore
import HaloConverters
@testable import HaloUI

/// Renders every state of the main window to PNG (light and dark) for the design review, through a real
/// NSHostingView so AppKit-backed controls draw. Output: loop/shots/<HALO_SHOTS or "latest">/home-*.png.
@MainActor
@Suite struct HomeRenderTests {
    /// Design-review renders. Only kept in the project when asked for (HALO_SHOTS=<name> puts them in
    /// loop/shots/<name>); a normal test run writes them to temp, so the project stays clean.
    static var shotsDirectory: URL {
        guard let name = ProcessInfo.processInfo.environment["HALO_SHOTS"], !name.isEmpty else {
            return FileManager.default.temporaryDirectory.appendingPathComponent("frenzy-shots-\(getpid())", isDirectory: true)
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent("loop/shots/\(name)", isDirectory: true)
    }

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static var builtFixtures: URL?

    /// Real files (an image, a PDF, text), so Quick Look draws real thumbnails and the registry sees real types. Built once
    /// per run: rebuilding them for each caller pulled the files out from under tests running alongside.
    static func fixtures() throws -> URL {
        if let builtFixtures { return builtFixtures }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-home-render", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let image = try #require(Self.gradientImage(width: 640, height: 480))
        for (name, type) in [("Holiday photo.png", UTType.png), ("Holiday photo.jpg", UTType.jpeg)] {
            let dest = try #require(CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL,
                                                                     type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, image, nil)
            #expect(CGImageDestinationFinalize(dest))
        }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdf = try #require(CGContext(dir.appendingPathComponent("Quarterly report.pdf") as CFURL, mediaBox: &box, nil))
        pdf.beginPDFPage(nil)
        pdf.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        pdf.fill(CGRect(x: 60, y: 600, width: 492, height: 120))
        for row in 0..<12 {
            pdf.setFillColor(CGColor(gray: 0.75, alpha: 1))
            pdf.fill(CGRect(x: 60, y: 540 - row * 34, width: row % 3 == 2 ? 300 : 492, height: 12))
        }
        pdf.endPDFPage()
        pdf.closePDF()
        try Data("Invoice 2041\nTotal due: 1,240.00\nThank you for your business.\n".utf8)
            .write(to: dir.appendingPathComponent("scan.txt"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("clip.mp4"))
        builtFixtures = dir
        return dir
    }

    static func gradientImage(width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(red: 0.98, green: 0.62, blue: 0.36, alpha: 1), CGColor(red: 0.30, green: 0.45, blue: 0.85, alpha: 1)]
        let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        ctx.setFillColor(CGColor(red: 1, green: 0.95, blue: 0.7, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: width / 2, y: height / 2, width: 120, height: 120))
        return ctx.makeImage()
    }

    /// The formats the real registry offers for `url`, exactly as the app computes them.
    static func realItems(for url: URL) throws -> [RingItem] {
        let input = try #require(InputFile(url: url))
        return DefaultActions.registry(usage: MemoryUsageStore()).actions(for: [input], limit: 12).map(RingItem.init)
    }

    private func render(_ model: HomeModel, name: String, scheme: NSAppearance.Name, settings: HaloSettings? = nil) throws {
        let suite = "halo.tests.render.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = try settings ?? HaloSettings(defaults: #require(UserDefaults(suiteName: suite)))
        let host = NSHostingView(rootView: HomeView(model: model, settings: settings))
        host.frame = NSRect(origin: .zero, size: HomeMetrics.size)
        host.appearance = NSAppearance(named: scheme)
        try snapshot(host, name: name, scheme: scheme)
        #expect(host.bounds.width >= HomeMetrics.size.width)
    }

    private func snapshot(_ host: NSView, name: String, scheme: NSAppearance.Name) throws {
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.backgroundColor = scheme == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Long enough for Quick Look to deliver thumbnails.
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: Self.shotsDirectory, withIntermediateDirectories: true)
        try png.write(to: Self.shotsDirectory.appendingPathComponent("\(name)-\(scheme == .darkAqua ? "dark" : "light").png"))
    }

    static let items: [RingItem] = Array(RingRenderTests.sample.filter { $0.title != "PNG" }.prefix(8))

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func everyStateRenders(scheme: NSAppearance.Name) throws {
        let dir = try Self.fixtures()

        let empty = HomeModel()
        try render(empty, name: "home-1-first-launch", scheme: scheme)

        let notice = HomeModel()
        notice.notice = "Frenzy can't convert this kind of item yet."
        try render(notice, name: "home-2-notice", scheme: scheme)

        let choice = HomeModel()
        let png = dir.appendingPathComponent("Holiday photo.png")
        choice.choice = HomeChoice(files: [png], subject: "Holiday photo.png", items: try Self.realItems(for: png))
        try render(choice, name: "home-3-choose", scheme: scheme)

        let recents = HomeModel()
        let now = Date()
        recents.recents = [
            HomeRecent(outputs: [dir.appendingPathComponent("Holiday photo.jpg")], actionTitle: "JPG", date: now, count: 1),
            HomeRecent(outputs: [dir.appendingPathComponent("Quarterly report.pdf")], actionTitle: "Compress",
                       date: now.addingTimeInterval(-600), count: 1),
            HomeRecent(outputs: [dir.appendingPathComponent("scan.txt")], actionTitle: "To Text",
                       date: now.addingTimeInterval(-7200), count: 1),
            HomeRecent(outputs: [dir.appendingPathComponent("clip.mp4")], actionTitle: "MP4",
                       date: now.addingTimeInterval(-90000), count: 3),
        ]
        try render(recents, name: "home-4-recents", scheme: scheme)

        let working = HomeModel()
        working.recents = Array(recents.recents.prefix(2))
        working.jobs = [
            HomeJob(id: "a", title: "To Text", subject: "scan.png", state: .working(0.4),
                    stage: "Preparing text recognition. The first time can take about a minute."),
            HomeJob(id: "c", title: "JPG", subject: "IMG_2041.heic", state: .done),
            HomeJob(id: "b", title: "MP4", subject: "clip.mov", state: .failed("This video has no picture track."),
                    canRetry: true),
        ]
        try render(working, name: "home-5-working", scheme: scheme)
    }

    /// Zip and Unzip as the app offers them: a zip gets Unzip first, a folder gets Zip only. Also the live ring.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func archiveChoicesRender(scheme: NSAppearance.Name) throws {
        let dir = try Self.fixtures()
        let zip = dir.appendingPathComponent("Holiday photos.zip")
        try Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)).write(to: zip)
        let folder = dir.appendingPathComponent("Holiday photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let zipItems = try Self.realItems(for: zip)
        #expect(zipItems.map(\.id) == ["archive.unzip", "archive.zip"])
        let zipChoice = HomeModel()
        zipChoice.choice = HomeChoice(files: [zip], subject: zip.lastPathComponent, items: zipItems)
        try render(zipChoice, name: "home-6-choose-zip", scheme: scheme)

        let folderItems = try Self.realItems(for: folder)
        #expect(folderItems.map(\.id) == ["archive.zip", "archive.to-tgz"])
        let folderChoice = HomeModel()
        folderChoice.choice = HomeChoice(files: [folder], subject: folder.lastPathComponent, items: folderItems)
        try render(folderChoice, name: "home-7-choose-folder", scheme: scheme)

        for (items, name) in [(zipItems, "ring-zip"), (folderItems, "ring-folder")] {
            let model = RingModel()
            model.items = items
            model.centerLabel = name == "ring-zip" ? zip.lastPathComponent : folder.lastPathComponent
            // What AppController.centerSymbol(for:) picks for these items.
            model.centerSymbolName = name == "ring-zip" ? "archivebox.fill" : "folder"
            model.phase = .shown
            model.hoveredIndex = 0
            let content = ZStack {
                LinearGradient(colors: [Color(red: 0.36, green: 0.52, blue: 0.78), Color(red: 0.86, green: 0.62, blue: 0.56)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RingView(model: model)
            }
            .frame(width: RingMetrics.canvasSize, height: RingMetrics.canvasSize)
            .environment(\.colorScheme, scheme == .darkAqua ? .dark : .light)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: Self.shotsDirectory.appendingPathComponent("\(name)-\(scheme == .darkAqua ? "dark" : "light").png"))
        }
    }

    /// Every bubble can be picked from the keyboard without Full Keyboard Access: Return for a lone choice, else 1 to 9.
    @Test func bubblesHaveKeys() {
        #expect(BubbleShortcut(index: 0, of: 1) == .returnKey)
        #expect(BubbleShortcut(index: 0, of: 2) == .digit(1))
        #expect(BubbleShortcut(index: 8, of: 12) == .digit(9))
        #expect(BubbleShortcut(index: 9, of: 12) == nil, "no key past the ninth bubble")
        #expect(BubbleShortcut.digit(3).key == KeyEquivalent("3"))
        #expect(BubbleShortcut.returnKey.key == .return)
        // Keys never repeat within a cluster.
        let keys = (0..<12).compactMap { BubbleShortcut(index: $0, of: 12)?.label }
        #expect(Set(keys).count == keys.count)
    }

    /// The quiet line only promises keys that exist.
    @Test func theHintLineMatchesTheKeys() {
        #expect(ChoiceHint.text(count: 1).contains("Return"))
        #expect(ChoiceHint.text(count: 2).contains("1 or 2"))
        #expect(ChoiceHint.text(count: 6).contains("1 to 6"))
        #expect(ChoiceHint.text(count: 12).contains("1 to 9"))
        let item = RingRenderTests.sample[0]
        #expect(ChoiceHint.tooltip(item: item, shortcut: .digit(1)) == "Smaller file (press 1)")
        // Past the ninth bubble there is no number key: the tooltip and the line say how to get there.
        #expect(ChoiceHint.tooltip(item: item, shortcut: nil) == "Smaller file (arrow keys, then Return)")
        #expect(ChoiceHint.text(count: 12).contains("arrow keys"))
    }

    /// The idle hero is the six illustrative bubbles of the brief, around a hub that fits among them.
    @Test func idleHeroIsSixBubbles() {
        #expect(HomeHero.items.map(\.title) == ["JPG", "PDF", "Compress", "MP4", "M4A", "To Text"])
        #expect(Set(HomeHero.items.map(\.id)).count == 6)
    }

    /// For every count the app can offer: each bubble stays on the stage in every hover state and while swollen by a
    /// drag, the hub stays clear of the bubbles (closer than 8 pt and the glass would merge at rest), and resting
    /// bubbles keep clear of each other, so no invisible button sits on a neighbour.
    @Test func everyClusterFitsItsStage() {
        for count in 1...12 {
            let stage = BubbleStage(count: count)
            let layout = stage.layout
            let bounds = stage.bounds.insetBy(dx: -0.01, dy: -0.01)
            #expect(bounds.width <= HomeMetrics.size.width, "\(count) wider than the window")
            func circle(_ offset: CGSize, _ diameter: CGFloat) -> CGRect {
                CGRect(x: offset.width - diameter / 2, y: offset.height - diameter / 2, width: diameter, height: diameter)
            }
            for index in 0..<count {
                let home = layout.offset(index: index)
                // Resting, and swollen with the whole cluster while a file is over the window.
                #expect(bounds.contains(circle(home, layout.diameter)), "\(count)/\(index) at rest")
                let scale = BubbleStage.dropScale
                #expect(bounds.contains(circle(CGSize(width: home.width * scale, height: home.height * scale),
                                               layout.diameter * scale)), "\(count)/\(index) under a drag")
                // Hovered, and every neighbour of a hovered bubble.
                #expect(bounds.contains(circle(layout.offset(index: index, extra: RingMotion.hoverPush),
                                               layout.diameter * RingMotion.hoverScale)), "\(count)/\(index) hovered")
                for hovered in 0..<count where layout.isNeighbour(index, of: hovered) {
                    #expect(bounds.contains(circle(layout.pushedAside(index: index, from: hovered, by: RingMotion.neighbourPush),
                                                   layout.diameter * RingMotion.neighbourScale)),
                            "\(count)/\(index) beside \(hovered)")
                }
                let reach = hypot(home.width, home.height)
                #expect(reach - layout.diameter / 2 - BubbleStage.hub / 2 >= 8, "\(count)/\(index) crowds the hub")
                for other in 0..<count where other != index {
                    let there = layout.offset(index: other)
                    #expect(hypot(home.width - there.width, home.height - there.height) >= layout.diameter,
                            "\(count): \(index) overlaps \(other)")
                }
            }
        }
    }

    /// The hero's real, laid-out height at every count, and with a long notice, always leaves the Recent list its
    /// header, one row and a peek, so nothing is ever pushed out of the window.
    @Test func theHeroAlwaysLeavesRoomForRecent() throws {
        let suite = "halo.tests.render.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = try HaloSettings(defaults: #require(UserDefaults(suiteName: suite)))
        func height(_ model: HomeModel) -> CGFloat {
            NSHostingView(rootView: DropZone(model: model, trigger: settings.trigger, opensOnPause: settings.opensOnPause)
                .frame(width: HomeMetrics.size.width)).fittingSize.height
        }
        let room = HomeMetrics.size.height - HomeMetrics.footer - RecentsMetrics.header - RecentsMetrics.headerGap
            - RecentsMetrics.row - RecentsMetrics.peek
        let file = URL(fileURLWithPath: "/tmp/halo-test-a.png")
        for count in 1...12 {
            let model = HomeModel()
            model.choice = HomeChoice(files: [file], subject: "a.png", items: Self.twelve(count))
            let needed = height(model)
            #expect(needed <= room, "\(count) choices need \(needed), room \(room)")
            #expect(needed >= BubbleStage(count: count).bounds.height, "\(count)")
        }
        let notice = HomeModel()
        notice.notice = String(repeating: "Frenzy can't convert this kind of item yet. ", count: 3)
        #expect(height(notice) <= room)
        #expect(height(notice) == height(HomeModel()), "a notice must not make the button jump")
    }

    /// Exactly `count` distinct real-looking choices.
    static func twelve(_ count: Int) -> [RingItem] { Array(RingRenderTests.sample.prefix(count)) }

    // MARK: Accessibility and keys, through the real view tree

    /// What SwiftUI's accessibility nodes answer. They implement these methods without declaring the protocol.
    private func axText(_ element: NSObject, _ selector: String) -> String {
        guard element.responds(to: Selector(selector)) else { return "" }
        return (element.perform(Selector(selector))?.takeUnretainedValue() as? String) ?? ""
    }

    /// Every element in the host's accessibility tree: what an outside client such as `e2e-driver` walks.
    private func accessibilityTree(of root: NSView) -> [NSObject] {
        var found: [NSObject] = [], queue: [NSObject] = [root], index = 0
        while index < queue.count, index < 4000 {
            let element = queue[index]; index += 1
            found.append(element)
            if element.responds(to: Selector(("accessibilityChildren"))) {
                queue += (element.perform(Selector(("accessibilityChildren")))?.takeUnretainedValue() as? [NSObject]) ?? []
            }
        }
        return found
    }

    private func identifier(_ element: NSObject) -> String { axText(element, "accessibilityIdentifier") }
    private func label(_ element: NSObject) -> String { axText(element, "accessibilityLabel") }
    private func role(_ element: NSObject) -> String { axText(element, "accessibilityRole") }

    /// AXPress, as `e2e-driver home-element --press` does. Its effect is what the tests check.
    private func press(_ element: NSObject) {
        _ = element.perform(Selector(("accessibilityPerformPress")))
    }

    /// A live window around the view, built with the same calls in the same order as `WindowPresenter` makes the app's,
    /// so the title bar and safe area are the real ones, and accessibility and key equivalents have somewhere to go.
    private func host(_ model: HomeModel) throws -> (window: NSWindow, view: NSView, cleanup: () -> Void) {
        let suite = "halo.tests.render.\(UUID().uuidString)"
        let settings = try HaloSettings(defaults: #require(UserDefaults(suiteName: suite)))
        // What an assistive client sets on an app. Stays on: other tests may be spinning the run loop in the middle of theirs.
        NSApplication.shared.perform(Selector(("accessibilitySetEnhancedUserInterfaceAttribute:")), with: NSNumber(value: true))
        let controller = NSHostingController(rootView: HomeView(model: model, settings: settings))
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(HomeMetrics.size)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.styleMask.insert(.miniaturizable)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let view = controller.view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return (window, view, { window.close(); UserDefaults.standard.removePersistentDomain(forName: suite) })
    }

    /// `scripts/e2e.sh` finds these by identifier at any depth and presses them through accessibility.
    @Test(arguments: [1, 2, 6, 12])
    func everyBubbleIsFindableAndPressable(count: Int) throws {
        let items = Self.twelve(count)
        for item in items {
            let model = HomeModel()
            var chosen: [ActionID] = []
            model.onChoose = { id, _ in chosen.append(id) }
            let file = URL(fileURLWithPath: "/tmp/halo-test-a.png")
            model.choice = HomeChoice(files: [file], subject: "a.png", items: items)
            let (_, view, cleanup) = try host(model)
            defer { cleanup() }
            let tree = accessibilityTree(of: view)
            let ids = tree.map(identifier)
            #expect(ids.contains("halo.home"), "\(ids.filter { !$0.isEmpty })")
            #expect(ids.contains("halo.home.dropzone"))
            #expect(ids.contains("halo.home.cancel"))
            #expect(!ids.contains("halo.home.choose"))
            #expect(ids.filter { $0.hasPrefix("halo.home.action.") }.count == count, "one per choice, no duplicates")
            let element = try #require(tree.first { identifier($0) == "halo.home.action.\(item.id.rawValue)" })
            #expect(label(element) == item.title)
            #expect(role(element) == "AXButton")
            press(element)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            #expect(chosen == [item.id])
            #expect(model.choice == nil)
            if count > 2 { break } // One press is enough once the larger clusters have been found.
        }
    }

    /// Idle: no fake buttons for the illustration, and the ones the script needs are there.
    @Test func idleWindowOffersOnlyRealControls() throws {
        let model = HomeModel()
        var choosing = 0
        model.onChooseFiles = { choosing += 1 }
        let (_, view, cleanup) = try host(model)
        defer { cleanup() }
        let tree = accessibilityTree(of: view)
        let ids = tree.map(identifier)
        #expect(ids.contains("halo.home.dropzone"))
        #expect(!ids.contains { $0.hasPrefix("halo.home.action.") })
        #expect(!ids.contains("halo.home.cancel"))
        #expect(!tree.map(label).contains { $0.hasPrefix("Compress") }, "the illustrative bubbles are hidden from accessibility")
        let choose = try #require(tree.first { identifier($0) == "halo.home.choose" })
        press(choose)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(choosing == 1)
    }

    /// Cancel takes the choice away and brings the drop zone back, with the bubbles gone from accessibility.
    @Test func cancelReturnsToIdle() throws {
        let model = HomeModel()
        model.choice = HomeChoice(files: [URL(fileURLWithPath: "/tmp/halo-test-a.png")], subject: "a.png", items: Self.twelve(3))
        let (_, view, cleanup) = try host(model)
        defer { cleanup() }
        let cancel = try #require(accessibilityTree(of: view).first { identifier($0) == "halo.home.cancel" })
        press(cancel)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        #expect(model.choice == nil)
        let ids = accessibilityTree(of: view).map(identifier)
        #expect(!ids.contains { $0.hasPrefix("halo.home.action.") })
        #expect(ids.contains("halo.home.dropzone"))
        #expect(ids.contains("halo.home.choose"))
    }

    /// An element's frame in screen points (y up), as an accessibility client reads it.
    private func frame(_ element: NSObject) -> NSRect {
        let selector = Selector(("accessibilityFrame"))
        typealias Getter = @convention(c) (NSObject, Selector) -> NSRect
        return unsafeBitCast(element.method(for: selector), to: Getter.self)(element, selector)
    }

    /// In a window built like the app's, with the title bar over the content: at every count, and with a long Recent
    /// list, the window's content fills it exactly, and every control is inside it, below the title bar (which takes
    /// clicks for itself), on its own bubble, and clear of the Recent list.
    @Test(arguments: 1...12)
    func everyControlIsInsideTheWindow(count: Int) throws {
        let dir = try Self.fixtures()
        let model = HomeModel()
        model.recents = (0..<9).map { index in
            HomeRecent(outputs: [dir.appendingPathComponent("Holiday photo.jpg")], actionTitle: "JPG",
                       date: Date().addingTimeInterval(Double(-600 * index)), count: 1)
        }
        let items = Self.twelve(count)
        model.choice = HomeChoice(files: [dir.appendingPathComponent("Holiday photo.png")], subject: "Holiday photo.png", items: items)
        let (window, view, cleanup) = try host(model)
        defer { cleanup() }
        let tree = accessibilityTree(of: view)
        let bounds = window.frame
        let usable = window.contentLayoutRect.height
        #expect(usable < bounds.height, "the test window should have a title bar over its content")
        let top = bounds.minY + usable
        func element(_ id: String) throws -> NSObject { try #require(tree.first { identifier($0) == id }) }

        #expect(frame(try element("halo.home")) == bounds, "a title bar must not shift or shrink the window's content")

        let settings = try #require(tree.first { label($0) == "Settings" })
        let actions = try items.map { try element("halo.home.action.\($0.id.rawValue)") }.map(frame)
        let cancel = frame(try element("halo.home.cancel"))
        for control in actions + [cancel, frame(settings)] {
            #expect(bounds.contains(control), "\(count): \(control) outside \(bounds)")
            #expect(control.maxY <= top, "\(count): \(control) under the title bar, which ends at \(top)")
            #expect(control.width >= 24 && control.height >= 20, "\(count): \(control) too small to hit")
        }
        // Each button is where its bubble is, in order round the ring, and no two share a point.
        let layout = RingBubbleLayout.window(count: count)
        for (index, action) in actions.enumerated() {
            #expect(abs(action.width - layout.diameter) < 1, "\(count)/\(index): \(action)")
            for other in actions[(index + 1)...] {
                #expect(hypot(action.midX - other.midX, action.midY - other.midY) >= layout.diameter - 1, "\(count)/\(index)")
            }
        }
        let hub = try #require(tree.first { label($0).hasPrefix("Holiday photo.png") })
        for (index, action) in actions.enumerated() {
            let offset = layout.offset(index: index)
            #expect(abs(action.midX - frame(hub).midX - offset.width) < 1, "\(count)/\(index) x")
            #expect(abs(action.midY - frame(hub).midY + offset.height) < 1, "\(count)/\(index) y")
        }
        // The hero ends above the list, which keeps at least its first row.
        let first = frame(try element("halo.home.recent.0"))
        #expect(cancel.minY >= first.maxY, "\(count): Cancel \(cancel) overlaps the list \(first)")
        #expect(first.minY >= bounds.minY + HomeMetrics.footer, "\(count): the first row \(first) is cut by the footer")
    }

    /// The same for the idle window, whose drop zone the script aims at.
    @Test func theIdleWindowFitsAndTheDropZoneIsRealEstate() throws {
        let model = HomeModel()
        let (window, view, cleanup) = try host(model)
        defer { cleanup() }
        let tree = accessibilityTree(of: view)
        let zone = frame(try #require(tree.first { identifier($0) == "halo.home.dropzone" }))
        let choose = frame(try #require(tree.first { identifier($0) == "halo.home.choose" }))
        #expect(window.frame.contains(zone))
        #expect(zone.contains(choose))
        #expect(zone.width == window.frame.width, "the whole width takes a drop")
        // With nothing to list, the hero has everything but the footer's line.
        #expect(abs(zone.height - (HomeMetrics.size.height - HomeMetrics.footer)) < 1, "\(zone)")
    }

    private func pressKey(_ characters: String, keyCode: UInt16, in window: NSWindow) throws -> Bool {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, characters: characters,
                                                  charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        return window.contentView?.performKeyEquivalent(with: event) ?? false
    }

    /// Digit keys pick the matching bubble, and only while there is a choice.
    @Test func digitKeysPickBubbles() throws {
        let items = Self.twelve(6)
        let model = HomeModel()
        var chosen: [ActionID] = []
        model.onChoose = { id, _ in chosen.append(id) }
        model.choice = HomeChoice(files: [URL(fileURLWithPath: "/tmp/halo-test-a.png")], subject: "a.png", items: items)
        let (window, _, cleanup) = try host(model)
        defer { cleanup() }
        #expect(try pressKey("3", keyCode: 20, in: window))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(chosen == [items[2].id])
    }

    /// Return picks a lone choice.
    @Test func returnPicksALoneChoice() throws {
        let items = Self.twelve(1)
        let model = HomeModel()
        var chosen: [ActionID] = []
        model.onChoose = { id, _ in chosen.append(id) }
        model.choice = HomeChoice(files: [URL(fileURLWithPath: "/tmp/halo-test-a.png")], subject: "a.png", items: items)
        let (window, _, cleanup) = try host(model)
        defer { cleanup() }
        #expect(try pressKey("\r", keyCode: 36, in: window))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(chosen == [items[0].id])
    }

    /// A PDF's choices, previews off, and the Settings pane with its new Privacy section.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func polishedStatesRender(scheme: NSAppearance.Name) throws {
        let dir = try Self.fixtures()
        let doc = dir.appendingPathComponent("Quarterly report.pdf")

        let pdfChoice = HomeModel()
        pdfChoice.choice = HomeChoice(files: [doc], subject: doc.lastPathComponent, items: try Self.realItems(for: doc))
        try render(pdfChoice, name: "home-8-choose-pdf", scheme: scheme)

        let noPreviews = HomeModel()
        noPreviews.recents = [
            HomeRecent(outputs: [dir.appendingPathComponent("Holiday photo.jpg")], actionTitle: "JPG", date: Date(), count: 1),
            HomeRecent(outputs: [doc], actionTitle: "Compress", date: Date().addingTimeInterval(-600), count: 1),
        ]
        let suite = "halo.tests.render.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: HaloSettings.Key.showPreviews)
        defer { defaults.removePersistentDomain(forName: suite) }
        try render(noPreviews, name: "home-9-recents-no-previews", scheme: scheme, settings: HaloSettings(defaults: defaults))

        let paneSuite = "halo.tests.render.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: paneSuite) }
        let paneSettings = HaloSettings(defaults: try #require(UserDefaults(suiteName: paneSuite)))
        let pane = NSHostingView(rootView: GeneralSettingsPane(settings: paneSettings).frame(width: 460))
        pane.appearance = NSAppearance(named: scheme)
        pane.frame = NSRect(origin: .zero, size: pane.fittingSize)
        try snapshot(pane, name: "settings-general", scheme: scheme)
    }

    /// Iteration 27 leftovers: a long Recent list resting on whole rows, a job waiting at 0 %, a retryable failure.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func leftoverStatesRender(scheme: NSAppearance.Name) throws {
        let dir = try Self.fixtures()
        let outputs = [("Holiday photo.jpg", "JPG"), ("Quarterly report.pdf", "Compress"), ("scan.txt", "To Text"),
                       ("clip.mp4", "MP4")]
        let long = HomeModel()
        long.recents = (0..<9).map { index in
            let (name, title) = outputs[index % outputs.count]
            return HomeRecent(outputs: [dir.appendingPathComponent(name)], actionTitle: title,
                       date: Date().addingTimeInterval(Double(-600 * index)), count: 1)
        }
        try render(long, name: "home-10-long-recents", scheme: scheme)

        let waiting = HomeModel()
        waiting.jobs = [
            HomeJob(id: "w", title: "MP4", subject: "clip.mov", state: .working(0)),
            HomeJob(id: "p", title: "JPG", subject: "IMG_2041.heic", state: .working(0.72)),
            HomeJob(id: "f", title: "PDF", subject: "notes.rtf", state: .failed("The file couldn't be read."), canRetry: true),
        ]
        try render(waiting, name: "home-11-jobs", scheme: scheme)
    }

    /// B3d: a result that just finished comes in with the green wash and check, frozen at its first frame.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func arrivalRenders(scheme: NSAppearance.Name) throws {
        let dir = try Self.fixtures()
        let model = HomeModel()
        let now = Date()
        let older = [("Quarterly report.pdf", "Compress", 600.0), ("scan.txt", "To Text", 7200), ("clip.mp4", "MP4", 90000)]
            .map { name, title, age in
                HomeRecent(outputs: [dir.appendingPathComponent(name)], actionTitle: title,
                           date: now.addingTimeInterval(-age), count: 1)
            }
        model.recents = older
        model.jobs = [HomeJob(id: "p", title: "PDF", subject: "notes.rtf", state: .working(0.35))]
        let arrived = HomeRecent(outputs: [dir.appendingPathComponent("Holiday photo.jpg")], actionTitle: "JPG",
                                 date: now, count: 1)
        model.recents = [arrived] + older
        #expect(model.arrivals == [arrived.id])

        let suite = "halo.tests.render.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = try HaloSettings(defaults: #require(UserDefaults(suiteName: suite)))
        let host = NSHostingView(rootView: HomeView(model: model, settings: settings).environment(\.haloHoldsArrival, true))
        host.frame = NSRect(origin: .zero, size: HomeMetrics.size)
        host.appearance = NSAppearance(named: scheme)
        try snapshot(host, name: "home-12-arrival", scheme: scheme)
    }

    /// Every cluster size the app can offer, one lit, plus the drag-over state idle and choosing, and a key instead of
    /// the pause. Layout, clipping and contrast only: an offline render has no Liquid Glass.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func clusterStatesRender(scheme: NSAppearance.Name) throws {
        let dir = try Self.fixtures()
        let png = dir.appendingPathComponent("Holiday photo.png")
        let now = Date()
        let recents = (0..<9).map { index in
            HomeRecent(outputs: [dir.appendingPathComponent("Holiday photo.jpg")], actionTitle: "JPG",
                       date: now.addingTimeInterval(Double(-600 * index)), count: 1)
        }
        func save(_ model: HomeModel, _ name: String, hover: Int? = nil, target: Bool = false, pause: Bool = true) throws {
            let suite = "halo.tests.render.\(UUID().uuidString)"
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.set(pause, forKey: HaloSettings.Key.opensOnPause)
            let host = NSHostingView(rootView: HomeView(model: model, settings: HaloSettings(defaults: defaults))
                .environment(\.haloHoldsHover, hover)
                .environment(\.haloHoldsDropTarget, target))
            host.frame = NSRect(origin: .zero, size: HomeMetrics.size)
            host.appearance = NSAppearance(named: scheme)
            try snapshot(host, name: name, scheme: scheme)
        }
        for count in 1...12 {
            let model = HomeModel()
            model.choice = HomeChoice(files: [png], subject: "Holiday photo.png", items: Self.twelve(count))
            model.recents = Array(recents.prefix(count == 9 ? 9 : 2))
            try save(model, "home-choice-\(count)", hover: count > 1 ? count / 2 : nil)
        }
        try save(HomeModel(), "home-drag-over", target: true)
        try save(HomeModel(), "home-hold-key", pause: false)
        let targeted = HomeModel()
        targeted.choice = HomeChoice(files: [png], subject: "Holiday photo.png", items: Self.twelve(6))
        try save(targeted, "home-choice-drag-over", target: true)
        let many = HomeModel()
        many.choice = HomeChoice(files: [png, dir.appendingPathComponent("Holiday photo.jpg")], subject: "2 files",
                                 items: Self.twelve(5))
        try save(many, "home-choice-two-files")
        let long = HomeModel()
        long.choice = HomeChoice(files: [png], subject: "A very long file name from a camera or a colleague, final v2.png",
                                 items: Self.twelve(4))
        try save(long, "home-choice-long-name")
    }

    /// Only a result that turns up while the window's model is live counts as arriving, and only for a moment.
    @Test func arrivalsAreOnlyFreshResults() async throws {
        let model = HomeModel()
        model.arrivalLifetime = .milliseconds(80)
        // The model's clock is pinned: other suites can stall the main actor for 40 s mid-test.
        let now = Date()
        model.now = { now }
        func recent(_ name: String, age: TimeInterval) -> HomeRecent {
            HomeRecent(outputs: [URL(fileURLWithPath: "/tmp/halo-test-\(name)")], actionTitle: "JPG",
                       date: now.addingTimeInterval(-age), count: 1)
        }
        // The first list is history, even if its newest entry is seconds old (Halo just relaunched).
        let history = [recent("a.jpg", age: 2), recent("b.jpg", age: 900)]
        model.recents = history
        #expect(model.arrivals.isEmpty)
        // The same list again (a refresh) brings nothing new.
        model.recents = history
        #expect(model.arrivals.isEmpty)
        // A new result, 1.2 s old (it waited behind its "Done" row): it arrives.
        let fresh = recent("c.jpg", age: 1.2)
        model.recents = [fresh] + history
        #expect(model.arrivals == [fresh.id])
        // New to the list but long finished (a moved file put back): not an arrival.
        let stale = recent("d.jpg", age: 600)
        model.recents = [fresh] + history + [stale]
        #expect(model.arrivals == [fresh.id])
        // Unseen, it leaves the set on its own. Bounded by turns, not by the clock: other suites' renders once held
        // the main actor for 40 s, and the removal and this poll then woke together.
        for _ in 0..<500 where !model.arrivals.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.arrivals.isEmpty)
        // Once a row has shown an arrival it is spent at once, so a re-created row (window reopened) stays calm.
        model.arrivalLifetime = .seconds(60)
        let next = recent("e.jpg", age: 0.5)
        model.recents = [next, fresh] + history + [stale]
        #expect(model.arrivals == [next.id])
        model.settleArrival(next.id)
        #expect(model.arrivals.isEmpty)
    }

    @Test func recentListRestsOnWholeRows() {
        let row = RecentsMetrics.row, peek = RecentsMetrics.peek
        // Everything fits: the list keeps all the space it is given.
        #expect(RecentsMetrics.viewport(available: 300, rows: 3) == 300)
        // Five rows that fit: none is hidden, and none is dimmed (no fade without overflow).
        #expect(RecentsMetrics.viewport(available: row * 5 + 10, rows: 5) == row * 5 + 10)
        #expect(RecentsMetrics.viewport(available: row * 5, rows: 5) == row * 5)
        #expect(RecentsMetrics.viewport(available: 0, rows: 5) == 0)
        // The fade only exists when rows overflow, so rows that fit are never dimmed.
        #expect(!RecentsMetrics.overflows(available: row * 5 + 10, rows: 5))
        #expect(RecentsMetrics.overflows(available: row * 5 - 1, rows: 5))
        #expect(!RecentsMetrics.overflows(available: 0, rows: 5))
        // The list asks for exactly its header and rows, so an all-fit list never scrolls or fades.
        #expect(RecentsMetrics.natural(rows: 3) == RecentsMetrics.header + RecentsMetrics.headerGap + row * 3)
        // The peek is at least the next row's title line and wholly inside the fade.
        #expect(RecentsMetrics.peek >= 22 && RecentsMetrics.fade >= RecentsMetrics.peek)
        #expect(RecentsMetrics.fadeClear >= 22 && RecentsMetrics.fadeClear < RecentsMetrics.fade)
        // Less than one row and its peek: it takes what there is.
        #expect(RecentsMetrics.viewport(available: row + peek - 4, rows: 5) == row + peek - 4)
        // Overflow: whole rows plus a short peek, never more than the space given, never a half row.
        for available in stride(from: row + peek, through: 600, by: 7) {
            let height = RecentsMetrics.viewport(available: available, rows: 40)
            #expect(height <= available)
            let rows = ((height - peek) / row)
            #expect(rows == rows.rounded() && rows >= 1, "\(available) -> \(height)")
            #expect(available - height < row, "wastes a whole row at \(available)")
        }
    }

    @Test func failedJobsOfferTryAgainOnlyWhenAsked() {
        #expect(HomeJob(id: "a", title: "JPG", subject: "a.heic", state: .failed("No")).canRetry == false)
        let model = HomeModel()
        var retried: [String] = []
        model.onRetryJob = { retried.append($0) }
        model.jobs = [HomeJob(id: "a", title: "JPG", subject: "a.heic", state: .failed("No"), canRetry: true)]
        model.onRetryJob("a")
        #expect(retried == ["a"])
    }

    /// Working jobs show their stage and progress; plain call sites without a stage still read sensibly.
    @Test func jobStageDefaultsToNil() {
        let job = HomeJob(id: "a", title: "JPG", subject: "a.heic", state: .working(0))
        #expect(job.stage == nil)
        #expect(HomeJob(id: "a", title: "JPG", subject: "a.heic", state: .working(0), stage: "Reading").stage == "Reading")
    }

    /// The choices for a PNG come from the real registry and never offer video, audio or PDF-only actions.
    @Test func pngChoicesAreImageConversionsOnly() throws {
        let png = try Self.fixtures().appendingPathComponent("Holiday photo.png")
        let ids = try Self.realItems(for: png).map(\.id.rawValue)
        #expect(!ids.isEmpty)
        #expect(!ids.contains { $0.hasPrefix("video.") || $0.hasPrefix("audio.") }, "\(ids)")
        #expect(!ids.contains("pdf.compress"), "\(ids)")
        #expect(!ids.contains("image.to-png"), "a PNG is never offered PNG: \(ids)")
    }

    @Test func recentNameCountsBatches() {
        let date = Date()
        let one = HomeRecent(outputs: [URL(fileURLWithPath: "/tmp/a.jpg")], actionTitle: "JPG", date: date, count: 1)
        let many = HomeRecent(outputs: [URL(fileURLWithPath: "/tmp/b.jpg")], actionTitle: "JPG", date: date, count: 4)
        #expect(one.name == "a.jpg")
        #expect(many.name == "b.jpg + 3 more")
        // Identity is stable across refreshes and distinct per result.
        #expect(one.id == HomeRecent(outputs: one.outputs, actionTitle: "JPG", date: date, count: 1).id)
        #expect(one.id != many.id)
    }

    @Test func choosingClearsTheChoiceAndPassesTheFiles() {
        let model = HomeModel()
        var got: (ActionID, [URL])?
        model.onChoose = { got = ($0, $1) }
        let file = URL(fileURLWithPath: "/tmp/a.png")
        model.choice = HomeChoice(files: [file], subject: "a.png", items: Self.items)
        model.choose("image.to-jpg")
        #expect(model.choice == nil)
        #expect(got?.0 == "image.to-jpg")
        #expect(got?.1 == [file])
        model.choose("image.to-jpg") // nothing pending: no second call
        #expect(got?.1 == [file])
    }
}
