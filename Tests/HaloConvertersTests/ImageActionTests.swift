import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import HaloConverters
@testable import HaloCore

@Suite struct ImageActionCatalogTests {
    private var mine: [ConversionAction] { ImageActions.all + PDFActions.all + TextActions.all }

    @Test func labelsAndSymbolsAreValid() {
        let ids = mine.map(\.id)
        #expect(Set(ids).count == ids.count)
        for action in mine {
            #expect(action.title.count <= 10, "\(action.id) title too long")
            #expect((action.subtitle ?? "").count <= 14, "\(action.id) subtitle too long")
            #expect(NSImage(systemSymbolName: action.symbolName, accessibilityDescription: nil) != nil, "\(action.id): no symbol \(action.symbolName)")
            #expect(!action.inputTypes.isEmpty)
        }
    }

    /// WebP is offered when macOS can write it, or when the media engine is in the app to write it instead.
    @Test func webPOnlyWhenSomethingCanWriteIt() {
        #expect(ImageActions.actions(engine: true).contains { $0.id == "image.to-webp" })
        #expect(ImageActions.actions(engine: false).contains { $0.id == "image.to-webp" } == ImageFormat.webp.isEncodable)
        #expect(ImageActions.all.contains { $0.id == "image.to-webp" } == (ImageFormat.webp.isEncodable || MediaEngine.isAvailable))
    }

    @Test func formatActionsHideTheInputsOwnFormat() throws {
        let dir = try Fixtures.tempDir()
        let registry = ActionRegistry(actions: mine, usage: MemoryUsageStore())
        let small = Fixtures.image(width: 8, height: 8)
        func ids(_ name: String, _ type: UTType) throws -> [ActionID] {
            let url = dir.appendingPathComponent(name)
            let input = type == .heic && !Fixtures.chipWrites ? try Fixtures.systemHEIC(to: url)
                                                               : try Fixtures.writeImage(small, to: url, type: type)
            return registry.actions(for: [input], limit: 50).map(\.id)
        }
        let jpeg = try ids("a.jpg", .jpeg)
        #expect(!jpeg.contains("image.to-jpg") && jpeg.contains("image.to-png") && jpeg.contains("image.to-pdf"))
        #expect(jpeg.first == "image.to-png")
        let png = try ids("a.png", .png)
        #expect(png.first == "image.to-jpg" && !png.contains("image.to-png"))
        let heic = try ids("a.heic", .heic)
        #expect(!heic.contains("image.to-heic") && heic.contains("image.to-jpg"))
        let tiff = try ids("a.tiff", .tiff)
        #expect(!tiff.contains("image.to-tiff"))
        #expect(!png.contains("image.combine-pdf"))
        // Combined actions only show for multiple files; PDFs don't get image actions.
        let two = [try #require(InputFile(url: dir.appendingPathComponent("a.png"))), try #require(InputFile(url: dir.appendingPathComponent("a.jpg")))]
        #expect(registry.actions(for: two, limit: 50).map(\.id).contains("image.combine-pdf"))
        let pdf = try Fixtures.writePDF(to: dir.appendingPathComponent("d.pdf"), pages: 1)
        let pdfIDs = registry.actions(for: [pdf], limit: 50).map(\.id)
        #expect(pdfIDs.first == "pdf.compress")
        #expect(pdfIDs.allSatisfy { $0.rawValue.hasPrefix("pdf.") })
    }
}

@Suite struct ImageConversionTests {
    @Test(arguments: [ImageFormat.jpeg, .png, .heic, .tiff, .webp].filter { $0 != .heic || Fixtures.chipWrites })
    func convertsToFormat(_ format: ImageFormat) async throws {
        guard format.isEncodable else { return }
        let dir = try Fixtures.tempDir()
        // A source that isn't the target format.
        let sourceType: UTType = format == .png ? .jpeg : .png
        let input = try Fixtures.writeImage(Fixtures.image(width: 320, height: 200, alpha: sourceType == .png), to: dir.appendingPathComponent("photo.\(sourceType.preferredFilenameExtension!)"), type: sourceType)
        let before = try Fixtures.snapshot([input])
        let id = ActionID(rawValue: "image.to-\(format == .jpeg ? "jpg" : format.rawValue)")
        let outputs = try await Fixtures.run(id, [input])
        let output = try #require(outputs.first)
        #expect(output.lastPathComponent == "photo.\(format.pathExtension)")
        let info = try Fixtures.imageInfo(output)
        #expect(UTType(info.type)?.conforms(to: format.utType) == true)
        #expect(info.width == 320 && info.height == 200)
        if format == .jpeg {
            // Transparent area flattened onto white, not black.
            let pixel = Fixtures.pixel(try Fixtures.decode(output), x: 5, y: 5)
            #expect(pixel[0] > 240 && pixel[1] > 240 && pixel[2] > 240)
        }
        try Fixtures.expectUnchanged(before)
        #expect(Fixtures.leftovers(in: dir).isEmpty)
    }

    @Test func appliesExifOrientation() async throws {
        let dir = try Fixtures.tempDir()
        // Stored 200x100, left red / right blue; orientation 6 = display rotated 90° clockwise, so red ends up on top.
        let input = try Fixtures.writeImage(Fixtures.image(width: 200, height: 100, splitColors: true),
                                            to: dir.appendingPathComponent("rotated.jpg"), type: .jpeg, orientation: 6)
        let output = try #require(try await Fixtures.run("image.to-png", [input]).first)
        let info = try Fixtures.imageInfo(output)
        #expect(info.width == 100 && info.height == 200)
        #expect((info.props[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        let image = try Fixtures.decode(output)
        let top = Fixtures.pixel(image, x: 50, y: 10), bottom = Fixtures.pixel(image, x: 50, y: 190)
        #expect(top[0] > 200 && top[2] < 60, "top should be red, got \(top)")
        #expect(bottom[2] > 200 && bottom[0] < 60, "bottom should be blue, got \(bottom)")
    }

    @Test func keepsColorProfileAndMetadata() async throws {
        let dir = try Fixtures.tempDir()
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let input = try Fixtures.writeImage(Fixtures.image(width: 64, height: 64, space: p3), to: dir.appendingPathComponent("p3.png"),
                                            type: .png, personalInfo: true)
        let output = try #require(try await Fixtures.run("image.to-jpg", [input]).first)
        let name = try Fixtures.decode(output).colorSpace?.name as String?
        #expect(name?.contains("P3") == true, "colour space was \(name ?? "nil")")
        #expect(ImageMetadataCheck.hasPersonalInfo(output), "to-jpg should keep metadata")
    }

    @Test func stripMetadataRemovesInfoButKeepsOrientation() async throws {
        let dir = try Fixtures.tempDir()
        // HEIC only with FRENZY_HEIC_TESTS=1: writing the fixture (and the result) uses the hardware video encoder.
        for (name, type) in [("geo.jpg", UTType.jpeg), ("geo.png", .png), ("geo.heic", .heic), ("geo.tiff", .tiff)]
            where type != .heic || Fixtures.chipWrites {
            let input = try Fixtures.writeImage(Fixtures.image(width: 200, height: 100, splitColors: true), to: dir.appendingPathComponent(name),
                                                type: type, orientation: 6, personalInfo: true)
            #expect(ImageMetadataCheck.hasPersonalInfo(input.url), "fixture \(name) should have info")
            let before = try Fixtures.snapshot([input])
            let output = try #require(try await Fixtures.run("image.strip-metadata", [input]).first)
            #expect(output.lastPathComponent == name.replacingOccurrences(of: "geo.", with: "geo (clean)."))
            #expect(!ImageMetadataCheck.hasPersonalInfo(output), "\(name) still has info")
            let info = try Fixtures.imageInfo(output)
            #expect(info.props[kCGImagePropertyGPSDictionary] == nil)
            let upright = try ImageFile(url: output).uprightSize
            #expect(upright.width == 100 && upright.height == 200, "\(name) lost its orientation")
            try Fixtures.expectUnchanged(before)
        }
        #expect(Fixtures.leftovers(in: dir).isEmpty)
    }

    @Test func resizeHalfDownsamples() async throws {
        let dir = try Fixtures.tempDir()
        let input = try Fixtures.writeImage(Fixtures.image(width: 400, height: 300), to: dir.appendingPathComponent("big.jpg"), type: .jpeg)
        let output = try #require(try await Fixtures.run("image.resize-half", [input]).first)
        #expect(output.lastPathComponent == "big (50%).jpg")
        let info = try Fixtures.imageInfo(output)
        #expect(info.width == 200 && info.height == 150)
    }

    @Test func resizeHalfKeepsGIFAnimation() async throws {
        let dir = try Fixtures.tempDir()
        let input = try Fixtures.writeGIF(to: dir.appendingPathComponent("anim.gif"), frames: 3, width: 120, height: 80)
        let output = try #require(try await Fixtures.run("image.resize-half", [input]).first)
        let info = try Fixtures.imageInfo(output)
        #expect(info.frames == 3 && info.width == 60 && info.height == 40)
        // First-frame-only for format changes.
        let jpg = try #require(try await Fixtures.run("image.to-jpg", [input]).first)
        #expect(try Fixtures.imageInfo(jpg).frames == 1)
        // Compress refuses animated GIFs rather than silently dropping the animation.
        await #expect(throws: ConversionError.self) { try await Fixtures.run("image.compress", [input]) }
    }

    @Test func compressMakesSmallerFiles() async throws {
        let dir = try Fixtures.tempDir()
        let jpeg = try Fixtures.writeImage(Fixtures.image(width: 1200, height: 900), to: dir.appendingPathComponent("shot.jpg"), type: .jpeg, quality: 1.0)
        let png = try Fixtures.writeImage(Fixtures.image(width: 600, height: 400), to: dir.appendingPathComponent("screen.png"), type: .png)
        let before = try Fixtures.snapshot([jpeg, png])
        let outJPEG = try #require(try await Fixtures.run("image.compress", [jpeg]).first)
        #expect(outJPEG.lastPathComponent == "shot (compressed).jpg")
        #expect(ImageWriter.byteCount(of: outJPEG) < ImageWriter.byteCount(of: jpeg.url))
        let outPNG = try #require(try await Fixtures.run("image.compress", [png]).first)
        #expect(outPNG.lastPathComponent == "screen (compressed).jpg")
        #expect(ImageWriter.byteCount(of: outPNG) < ImageWriter.byteCount(of: png.url))
        try Fixtures.expectUnchanged(before)
        #expect(Fixtures.leftovers(in: dir).isEmpty)
    }

    @Test func imageToPDFAndCombine() async throws {
        let dir = try Fixtures.tempDir()
        let a = try Fixtures.writeImage(Fixtures.image(width: 300, height: 200), to: dir.appendingPathComponent("a.jpg"), type: .jpeg)
        let b = try Fixtures.writeImage(Fixtures.image(width: 100, height: 400, alpha: true), to: dir.appendingPathComponent("b.png"), type: .png)
        // A rotated HEIC needs encoding one (hardware); without FRENZY_HEIC_TESTS=1 a shipped 356 x 356 HEIC stands in.
        let c = Fixtures.chipWrites
            ? try Fixtures.writeImage(Fixtures.image(width: 200, height: 100), to: dir.appendingPathComponent("c.heic"), type: .heic, orientation: 6)
            : try Fixtures.systemHEIC(to: dir.appendingPathComponent("c.heic"))
        let before = try Fixtures.snapshot([a, b, c])

        let single = try #require(try await Fixtures.run("image.to-pdf", [a]).first)
        #expect(single.lastPathComponent == "a.pdf")
        let doc = try #require(PDFDocument(url: single))
        #expect(doc.pageCount == 1)
        #expect(doc.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 300, height: 200))

        let combined = try #require(try await Fixtures.run("image.combine-pdf", [a, b, c]).first)
        #expect(combined.lastPathComponent == "a combined.pdf")
        let all = try #require(PDFDocument(url: combined))
        #expect(all.pageCount == 3)
        #expect(all.page(at: 1)?.bounds(for: .mediaBox).size == CGSize(width: 100, height: 400))
        // The stand-in is 356 px at 300 dpi, so its page is 356 x 72 / 300 points.
        let heicPage = Fixtures.chipWrites ? CGSize(width: 100, height: 200) : CGSize(width: 356.0 * 72 / 300, height: 356.0 * 72 / 300)
        let got = all.page(at: 2)?.bounds(for: .mediaBox).size ?? .zero
        #expect(abs(got.width - heicPage.width) < 0.5 && abs(got.height - heicPage.height) < 0.5, "HEIC page \(got) (orientation applied)")
        try Fixtures.expectUnchanged(before)
        #expect(Fixtures.leftovers(in: dir).isEmpty)
    }

    @Test func batchThroughRunner() async throws {
        let dir = try Fixtures.tempDir()
        let a = try Fixtures.writeImage(Fixtures.image(width: 50, height: 50), to: dir.appendingPathComponent("one.png"), type: .png)
        let b = Fixtures.chipWrites
            ? try Fixtures.writeImage(Fixtures.image(width: 60, height: 40), to: dir.appendingPathComponent("two.heic"), type: .heic)
            : try Fixtures.systemHEIC(to: dir.appendingPathComponent("two.heic"))
        // An existing "one.jpg" must not be overwritten.
        try Data("keep".utf8).write(to: dir.appendingPathComponent("one.jpg"))
        let before = try Fixtures.snapshot([a, b])
        let outcome = await Fixtures.runner().run("image.to-jpg", on: [a, b])
        #expect(outcome.succeeded, "\(outcome.failures.map(\.message))")
        #expect(Set(outcome.outputs.map(\.lastPathComponent)) == ["one 2.jpg", "two.jpg"])
        #expect(try String(contentsOf: dir.appendingPathComponent("one.jpg"), encoding: .utf8) == "keep")
        try Fixtures.expectUnchanged(before)
        #expect(Fixtures.leftovers(in: dir).isEmpty)
    }
}
