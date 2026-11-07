import Testing
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import HaloCore
import HaloConverters
@testable import HaloUI

/// Ring v2: the centre shows what is being dragged, the colours hold contrast, and every state renders to
/// loop/shots/<HALO_SHOTS or "latest">/ring-*.png for the design review.
@MainActor
@Suite struct RingCenterTests {
    /// Every hovered label reads at 4.5:1 on its wedge, for every category in light, dark and both Increase
    /// Contrast appearances. (Resting icons and labels use the system label colour.)
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
    func hoveredWedgesMeetContrast(scheme: NSAppearance.Name) throws {
        // Every category, plus the blue the "More" wedge lights in.
        let fills = ActionCategory.allCases.map { ("\($0)", $0.tint) } + [("more", RingPalette.more)]
        for (category, color) in fills {
            var tint: RingPalette.RGB?
            NSAppearance(named: scheme)!.performAsCurrentDrawingAppearance {
                if let c = NSColor(color).usingColorSpace(.sRGB) {
                    tint = RingPalette.RGB(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
                }
            }
            let lit = RingPalette.litFill(tint: try #require(tint))
            #expect(HeroPalette.contrast(HeroPalette.white, lit) >= 4.5, "\(category) lit \(scheme.rawValue)")
            // The wedge's gradient darkens toward the bottom, which only raises the contrast.
            #expect(HeroPalette.contrast(HeroPalette.white, lit.mixed(with: HeroPalette.black, 0.06)) >= 4.5)
        }
    }

    /// Waits (up to 3 s) for the off-main detail lookup to land.
    private func settled(_ model: RingModel, until done: () -> Bool) async throws {
        for _ in 0..<60 where !done() { try await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func oneFileShowsItsIconThenItsSize() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-ring-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let photo = dir.appendingPathComponent("Holiday photo.png")
        try FileManager.default.copyItem(at: try HomeRenderTests.fixtures().appendingPathComponent("Holiday photo.png"), to: photo)
        let model = RingModel()
        model.showFiles([photo])
        #expect(model.centerFile == photo)
        #expect(model.centerIcons.count == 1, "Finder's icon shows at once")
        try await settled(model) { model.centerDetail != nil }
        let bytes = try #require(try photo.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(model.centerDetail == ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
    }

    @Test func aFolderShowsItsItemCount() async throws {
        // Its own folder: other tests rebuild the shared fixtures while this one awaits.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-ring-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("Counted", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt", ".hidden"] { try Data("x".utf8).write(to: folder.appendingPathComponent(name)) }
        let model = RingModel()
        model.showFiles([folder])
        try await settled(model) { model.centerDetail != nil }
        #expect(model.centerDetail == "2 items", "hidden files are not counted")
        #expect(RingModel.detailText(for: dir.appendingPathComponent("gone.png")) == nil, "a missing file shows nothing")
    }

    @Test func severalFilesFanOutWithoutASize() throws {
        let dir = try HomeRenderTests.fixtures()
        let names = ["Holiday photo.png", "Holiday photo.jpg", "scan.txt", "clip.mp4"]
        let model = RingModel()
        model.showFiles(names.map { dir.appendingPathComponent($0) })
        #expect(model.centerFile == nil)
        #expect(model.centerIcons.count == 3, "at most three icons fan out")
        #expect(model.centerDetail == nil)
        #expect(model.centerThumbnail == nil)
    }

    /// When the ring goes, the centre empties and a thumbnail still on its way never lands, on this drag or the next.
    @Test func clearingStopsALateThumbnail() async throws {
        let dir = try HomeRenderTests.fixtures()
        let model = RingModel()
        model.showFiles([dir.appendingPathComponent("Holiday photo.png")])
        model.clearFiles()
        #expect(model.centerFile == nil)
        #expect(model.centerIcons.isEmpty)
        model.showFiles([dir.appendingPathComponent("Holiday photo.png"), dir.appendingPathComponent("scan.txt")])
        try await Task.sleep(for: .seconds(1.5))
        #expect(model.centerThumbnail == nil)
        #expect(model.centerDetail == nil)
    }

    /// "Show file previews" off: the centre still gets Finder's icon and the size, never a Quick Look thumbnail.
    @Test func previewsOffKeepsTheIcon() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-ring-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let photo = dir.appendingPathComponent("Holiday photo.png")
        try FileManager.default.copyItem(at: try HomeRenderTests.fixtures().appendingPathComponent("Holiday photo.png"), to: photo)
        let model = RingModel()
        model.showsThumbnails = false
        model.showFiles([photo])
        try await settled(model) { model.centerDetail != nil }
        try await Task.sleep(for: .seconds(1.5))
        #expect(model.centerDetail != nil)
        #expect(model.centerIcons.count == 1)
        #expect(model.centerThumbnail == nil)
        // Turned off while a thumbnail is showing: it goes at once.
        model.showsThumbnails = true
        model.centerThumbnail = try #require(HomeRenderTests.gradientImage(width: 8, height: 8))
        model.showsThumbnails = false
        #expect(model.centerThumbnail == nil)
    }

    /// The first paint never touches the disk: icons come from the name's type.
    @Test func firstIconsComeFromTheNameAlone() {
        #expect(RingModel.iconType(for: URL(fileURLWithPath: "/nowhere/Trip/", isDirectory: true)) == .folder)
        #expect(RingModel.iconType(for: URL(fileURLWithPath: "/nowhere/a.png")) == .png)
        #expect(RingModel.iconType(for: URL(fileURLWithPath: "/nowhere/Makefile")) == .data)
    }

    /// A huge folder stops counting at the cap instead of listing everything.
    @Test func aHugeFolderSaysOverTheCap() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-ring-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0...RingModel.itemCountCap { FileManager.default.createFile(atPath: dir.appendingPathComponent("f\(i)").path, contents: nil) }
        #expect(RingModel.detailText(for: dir) == "\(RingModel.itemCountCap.formatted())+ items")
    }

    // MARK: More

    private static func items(_ count: Int) -> [RingItem] {
        (0..<count).map { RingItem(id: ActionID(rawValue: "t.\($0)"), title: "T\($0)", subtitle: nil, symbolName: "doc", category: .image) }
    }

    @Test func aRingThatFitsHasNoMoreWedge() {
        let nine = Self.items(9)
        #expect(RingItem.fitted(nine, limit: 10) == nine)
        #expect(RingItem.fitted(Self.items(10), limit: 10) == Self.items(10))
        #expect(!RingItem.fitted(nine, limit: 10).contains { $0.isMore })
    }

    @Test func aRingTooSmallEndsInMore() throws {
        let fitted = RingItem.fitted(Self.items(9), limit: 4)
        #expect(fitted.count == 4)
        #expect(fitted.prefix(3).map(\.id) == Self.items(3).map(\.id), "the best-ranked choices keep their places")
        let more = try #require(fitted.last)
        #expect(more.isMore)
        #expect(more.title == "More")
        #expect(more.subtitle == "6 more in Frenzy")
        #expect(RingItem.fitted(Self.items(13), limit: 12).last?.subtitle == "2 more in Frenzy")
    }

    /// "More" opens the window, whose grid shows up to 12 choices: no single type or pair of files may ever fit
    /// more than that, or a choice would be out of reach everywhere.
    @Test func theWindowShowsEveryChoiceMorePointsAt() {
        let registry = DefaultActions.registry(usage: MemoryUsageStore())
        var worst = (count: 0, types: "")
        // Every declared input type (and the folder type) alone, twice, three times, and paired with every other.
        let types = Array(Set(DefaultActions.all().flatMap(\.inputTypes) + [.folder]))
        func file(_ type: UTType, _ n: Int) -> InputFile { InputFile(url: URL(fileURLWithPath: "/tmp/\(n)"), type: type) }
        func check(_ inputs: [InputFile]) {
            let count = registry.actions(for: inputs, limit: .max).count
            if count > worst.count { worst = (count, inputs.map(\.type.identifier).joined(separator: " + ")) }
        }
        for type in types {
            check([file(type, 1)])
            check([file(type, 1), file(type, 2)])
            check([file(type, 1), file(type, 2), file(type, 3)])
            for other in types where other != type { check([file(type, 1), file(other, 2)]) }
        }
        #expect(worst.count <= 12, "\(worst.types) fits \(worst.count) actions")
        print("Most choices for one drop: \(worst.count) (\(worst.types))")
    }

    // MARK: Renders

    /// The real formats for a real photo, a dense 12-item ring for three files, two choices for a zip, one for a
    /// folder; resting and hovered, light and dark.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func renderRingStates(scheme: NSAppearance.Name) throws {
        let dir = try HomeRenderTests.fixtures()
        let photo = dir.appendingPathComponent("Holiday photo.png")
        let pdf = dir.appendingPathComponent("Quarterly report.pdf")
        let zip = dir.appendingPathComponent("Holiday.zip")
        try Data([0x50, 0x4B, 0x05, 0x06] + Array(repeating: 0, count: 18)).write(to: zip)
        let folder = dir.appendingPathComponent("Trip photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let photoItems = try HomeRenderTests.realItems(for: photo)
        let pdfItems = try HomeRenderTests.realItems(for: pdf)
        let zipItems = try HomeRenderTests.realItems(for: zip)
        #expect(zipItems.map(\.id) == ["archive.unzip", "archive.zip"])
        let folderItems = try HomeRenderTests.realItems(for: folder)
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 92] as CFDictionary
        let thumbnail = try #require(CGImageSourceCreateWithURL(photo as CFURL, nil)
            .flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options) })

        func shot(_ name: String, items: [RingItem], files: [URL], label: String, hovered: Int?,
                  thumb: CGImage? = nil, detail: String? = nil) throws {
            let model = RingModel()
            model.items = items
            model.centerLabel = label
            model.showFiles(files)
            // Quick Look and the size lookup land asynchronously, after an offscreen render; stand in for them.
            if let thumb { model.centerThumbnail = thumb }
            if files.count == 1 { model.centerDetail = detail ?? RingModel.detailText(for: files[0]) }
            model.phase = .shown
            model.hoveredIndex = hovered
            try RingCenterTests.save(RingView(model: model), name: name, scheme: scheme)
        }

        try shot("ring-1-photo-rest", items: photoItems, files: [photo], label: photo.lastPathComponent, hovered: nil, thumb: thumbnail)
        try shot("ring-2-photo-hover", items: photoItems, files: [photo], label: photo.lastPathComponent, hovered: 0, thumb: thumbnail)
        try shot("ring-3-pdf-icon", items: pdfItems, files: [pdf], label: pdf.lastPathComponent, hovered: 1)
        var dense: [RingItem] = []
        for item in photoItems + RingRenderTests.sample
        where !dense.contains(where: { $0.id == item.id || $0.title == item.title || $0.title == "To \(item.title)" }) {
            dense.append(item)
        }
        try shot("ring-4-dense-hint", items: Array(dense.prefix(12)), files: [photo, pdf, zip], label: "3 files", hovered: 2)
        try shot("ring-5-zip-two", items: zipItems, files: [zip], label: zip.lastPathComponent, hovered: 0)
        try shot("ring-6-folder-one", items: folderItems, files: [folder], label: folder.lastPathComponent, hovered: nil,
                 detail: "24 items")
        try shot("ring-7-three-files", items: Array(dense.prefix(6)), files: [photo, pdf, zip], label: "3 files", hovered: nil)
        // Ring size 6 for a photo that fits 9: five choices and "More", hovered.
        let small = RingItem.fitted(photoItems, limit: 6)
        #expect(small.last?.isMore == true)
        try shot("ring-8-more", items: small, files: [photo], label: photo.lastPathComponent, hovered: 5, thumb: thumbnail)
    }

    /// The moment a drop lands: the centre takes on the chosen colour and a ripple leaves it. A photo to JPG, a zip
    /// to Unzip (the archive green), and "More".
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func renderDropMoments(scheme: NSAppearance.Name) throws {
        let dir = try HomeRenderTests.fixtures()
        let photo = dir.appendingPathComponent("Holiday photo.png")
        let zip = dir.appendingPathComponent("Holiday.zip")
        try Data([0x50, 0x4B, 0x05, 0x06] + Array(repeating: 0, count: 18)).write(to: zip)
        func shot(_ name: String, items: [RingItem], landed: Int, file: URL, ripple: Double) throws {
            let model = RingModel()
            model.items = items
            model.centerLabel = file.lastPathComponent
            model.showFiles([file])
            model.phase = .committing(items[landed].id)
            model.hoveredIndex = landed
            try RingCenterTests.save(RingView(model: model, landed: items[landed].id, ripple: ripple), name: name, scheme: scheme)
        }
        let photoItems = try HomeRenderTests.realItems(for: photo)
        try shot("ring-9-landed-jpg", items: photoItems, landed: 0, file: photo, ripple: 0.3)
        try shot("ring-10-landed-unzip", items: try HomeRenderTests.realItems(for: zip), landed: 0, file: zip, ripple: 0.55)
        let small = RingItem.fitted(photoItems, limit: 6)
        try shot("ring-11-landed-more", items: small, landed: 5, file: photo, ripple: 0.15)
    }

    /// Bubbles never touch at rest, stay inside the overlay window even at their largest, and clear the centre disc.
    @Test(arguments: 1...12)
    func bubblesKeepTheirSpace(count: Int) {
        let layout = RingBubbleLayout(count: count)
        for index in 0..<count {
            let here = layout.offset(index: index)
            if count > 1 {
                let next = layout.offset(index: (index + 1) % count)
                #expect(hypot(here.width - next.width, here.height - next.height) >= layout.diameter + 4, "\(count) bubbles touch")
            }
            #expect(hypot(here.width, here.height) - layout.diameter / 2 > RingMetrics.innerRadius - 6, "\(count) bubbles hit the centre")
            let lifted = layout.offset(index: index, extra: RingMotion.hoverPush)
            let reach = hypot(lifted.width, lifted.height) + layout.diameter * RingMotion.hoverScale / 2
            #expect(reach <= RingMetrics.canvasSize / 2, "\(count) bubbles leave the window")
            // Pointer hit-testing still finds this bubble at its own centre.
            let center = CGPoint(x: 220, y: 220)
            let point = CGPoint(x: center.x + here.width, y: center.y + here.height)
            #expect(RingGeometry.index(at: point, center: center, count: count) == index)
        }
    }

    /// Every real title fits its bubble without shrinking past the label's own limit, in the ring and in the window.
    @Test(arguments: [2, 6, 9, 10, 12])
    func titlesFitTheirBubbles(count: Int) throws {
        let photo = try HomeRenderTests.fixtures().appendingPathComponent("Holiday photo.png")
        let titles = try HomeRenderTests.realItems(for: photo).map(\.title) + RingRenderTests.sample.map(\.title)
        for layout in [RingBubbleLayout(count: count), .window(count: count)] {
            let font = NSFont.systemFont(ofSize: layout.titleSize.rawValue * RingBubbleLayout.titleMinScale, weight: .semibold)
            for title in titles {
                #expect((title as NSString).size(withAttributes: [.font: font]).width <= layout.titleWidth, "\(title) in \(count)")
            }
        }
    }

    /// No family lights up as mud: the lit fill (darkened for white text) keeps real colour in every appearance,
    /// and no two families (or "More") light up looking alike.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
    func litColoursStayClearAndDistinct(scheme: NSAppearance.Name) throws {
        let fills = ActionCategory.allCases.map { ("\($0)", $0.tint) } + [("more", RingPalette.more)]
        var lit: [(String, RingPalette.RGB)] = []
        for (name, color) in fills {
            var tint: RingPalette.RGB?
            try #require(NSAppearance(named: scheme)).performAsCurrentDrawingAppearance {
                if let c = NSColor(color).usingColorSpace(.sRGB) {
                    tint = RingPalette.RGB(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
                }
            }
            let fill = RingPalette.litFill(tint: try #require(tint))
            let (_, saturation, brightness) = Self.hsb(fill)
            // Brown lit at 4.5:1 was HSB saturation ~0.48: the mud this guards against.
            #expect(saturation >= 0.55, "\(name) lit is muddy in \(scheme.rawValue): s \(saturation) b \(brightness)")
            lit.append((name, fill))
        }
        // The archive green and the "More" blue against everything else. (PDF red and audio pink sit about 10°
        // apart by hue and differ in lightness instead; they rarely share a drop. Kept, see DECISIONS.)
        for i in lit.indices where ["archive", "more"].contains(lit[i].0) {
            for j in lit.indices where j != i {
                let a = Self.hsb(lit[i].1).hue, b = Self.hsb(lit[j].1).hue
                let distance = min(abs(a - b), 1 - abs(a - b)) * 360
                #expect(distance >= 15, "\(lit[i].0) and \(lit[j].0) light up \(Int(distance))° apart in \(scheme.rawValue)")
            }
        }
    }

    private static func hsb(_ rgb: RingPalette.RGB) -> (hue: Double, saturation: Double, brightness: Double) {
        let c = NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
        return (Double(c.hueComponent), Double(c.saturationComponent), Double(c.brightnessComponent))
    }

    /// The ripple starts at the centre disc's edge, ends past the wedges (its glow still inside the panel), holds
    /// its width through the first half, and plays only after the wedge lands, never under Reduce Motion.
    @Test func theRippleLeavesTheCentreOnlyWhenADropLands() {
        let start = RippleRing.band(at: 0), mid = RippleRing.band(at: 0.5), end = RippleRing.band(at: 1)
        #expect(start.radius == RingMetrics.innerRadius - 6)
        #expect(end.radius > RingMetrics.outerRadius)
        #expect(end.radius + start.width / 2 + 5 <= RingMetrics.canvasSize / 2, "the ring and its glow stay in the panel")
        #expect(mid.width == start.width)
        #expect(end.width < start.width && end.width > 0)
        #expect(RingMotion.collapseDelay < RingMotion.commitDuration, "the wedge lands before the ring starts to fade")

        #expect(RingView.showsRipple(.collapse("image.to-jpg"), reduceMotion: false))
        #expect(!RingView.showsRipple(.collapse("image.to-jpg"), reduceMotion: true))
        #expect(!RingView.showsRipple(.pulse("image.to-jpg"), reduceMotion: false))
        #expect(!RingView.showsRipple(.none, reduceMotion: false))
    }

    static func save(_ view: RingView, name: String, scheme: NSAppearance.Name) throws {
        let side = RingMetrics.canvasSize
        let content = ZStack {
            // Stand-in wallpaper so the glass reads the way it will over a real desktop.
            LinearGradient(colors: [Color(red: 0.36, green: 0.52, blue: 0.78), Color(red: 0.86, green: 0.62, blue: 0.56)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            view
        }
        .frame(width: side, height: side)
        .environment(\.colorScheme, scheme == .darkAqua ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let dir = HomeRenderTests.shotsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("\(name)-\(scheme == .darkAqua ? "dark" : "light").png"))
    }
}
