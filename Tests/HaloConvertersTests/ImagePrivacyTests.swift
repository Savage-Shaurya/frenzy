import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HaloConverters
@testable import HaloCore

@Suite struct ImagePrivacyTests {
    /// HEIC only with FRENZY_HEIC_TESTS=1 (writing it uses the hardware video encoder).
    static let formats: [(String, UTType)] = [("jpg", .jpeg), ("png", .png), ("heic", .heic), ("tiff", .tiff)]
        .filter { $0.1 != .heic || Fixtures.chipWrites }

    private func dirtyInput(_ ext: String, _ type: UTType, in dir: URL, orientation: Int = 6) throws -> InputFile {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        return try Fixtures.writeDirtyImage(Fixtures.image(width: 200, height: 100, splitColors: true, space: p3),
                                            to: dir.appendingPathComponent("geo.\(ext)"), type: type, orientation: orientation)
    }

    @Test(arguments: formats)
    func fixtureReallyIsDirty(_ ext: String, _ type: UTType) throws {
        let dir = try Fixtures.tempDir()
        let input = try dirtyInput(ext, type, in: dir)
        let findings = ImageMetadataCheck.findings(in: input.url).map(\.detail).joined(separator: "\n")
        #expect(ImageMetadataCheck.hasLocation(input.url), "\(ext): \(findings)")
        #expect(findings.contains("XMP"), "\(ext) fixture has no XMP: \(findings)")
        #expect(try Fixtures.containsBytes(input.url, "uuid:halo-doc-1234"), "\(ext) fixture lacks the XMP DocumentID")
        #expect(try Fixtures.containsBytes(input.url, "Jane"))
        if type == .png {
            let png = try Fixtures.imageInfo(input.url).props[kCGImagePropertyPNGDictionary] as? [CFString: Any] ?? [:]
            // (ImageIO doesn't write PNG Comment or Creation Time chunks, so those can't be planted.)
            for key in [kCGImagePropertyPNGAuthor, kCGImagePropertyPNGDescription, kCGImagePropertyPNGSoftware,
                        kCGImagePropertyPNGTitle] {
                #expect(png[key] != nil, "PNG fixture lacks \(key)")
            }
        }
        if type == .jpeg { #expect(try Fixtures.containsBytes(input.url, "secret jpeg comment")) }
    }

    @Test(arguments: formats)
    func stripInfoRemovesEverything(_ ext: String, _ type: UTType) async throws {
        let dir = try Fixtures.tempDir()
        let input = try dirtyInput(ext, type, in: dir)
        let before = try Fixtures.snapshot([input])
        let output = try #require(try await Fixtures.run("image.strip-metadata", [input]).first)
        #expect(output.lastPathComponent == "geo (clean).\(ext == "jpg" ? "jpg" : ext)")
        let left = ImageMetadataCheck.findings(in: output)
        #expect(left.isEmpty, "\(ext) still has: \(left)")
        for planted in Fixtures.plantedStrings {
            #expect(!(try Fixtures.containsBytes(output, planted)), "\(ext) output still contains \"\(planted)\"")
        }
        // ImageIO's own view, every index.
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 1)
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyMakerAppleDictionary, kCGImagePropertyExifAuxDictionary] {
            #expect((props[key] as? [CFString: Any] ?? [:]).isEmpty, "\(ext): \(key) survived")
        }
        // Orientation kept (baked in, or as the only tag of a lossless JPEG) and the colour profile kept.
        let upright = try ImageFile(url: output).uprightSize
        #expect(upright.width == 100 && upright.height == 200, "\(ext) lost its orientation")
        let space = try Fixtures.decode(output).colorSpace?.name as String?
        #expect(space?.contains("P3") == true, "\(ext) colour profile was \(space ?? "nil")")
        try Fixtures.expectUnchanged(before)
        #expect(Fixtures.leftovers(in: dir).isEmpty)
    }

    @Test func jpegStripIsLossless() async throws {
        let dir = try Fixtures.tempDir()
        let input = try dirtyInput("jpg", .jpeg, in: dir, orientation: 1)
        let output = try #require(try await Fixtures.run("image.strip-metadata", [input]).first)
        // The compressed scan data is copied byte for byte, so the decoded pixels are identical.
        let a = try Fixtures.decode(input.url), b = try Fixtures.decode(output)
        for (x, y) in [(10, 10), (150, 50), (99, 99), (100, 0)] {
            #expect(Fixtures.pixel(a, x: x, y: y) == Fixtures.pixel(b, x: x, y: y))
        }
        #expect(ImageWriter.byteCount(of: output) < ImageWriter.byteCount(of: input.url))
    }

    @Test(arguments: [ImageFormat.jpeg, .png, .heic, .tiff, .gif].filter { $0 != .heic || Fixtures.chipWrites })
    func checkerDoesNotFlagPlainEncoderOutput(_ format: ImageFormat) throws {
        // Finding #25: tags the encoder writes itself (pixel dimensions, colour space, tiling) must not count.
        let dir = try Fixtures.tempDir()
        let url = dir.appendingPathComponent("plain.\(format.pathExtension)")
        try ImageWriter.write(Fixtures.image(width: 64, height: 48, alpha: format.supportsAlpha), as: format, to: url, quality: 0.9)
        #expect(ImageMetadataCheck.findings(in: url).isEmpty, "\(ImageMetadataCheck.findings(in: url))")
        // ...and a lossless-stripped JPEG with just an orientation tag is clean too.
        if format == .jpeg, let stripped = JPEGStripper.strip(try Data(contentsOf: url), orientation: .right) {
            let out = dir.appendingPathComponent("oriented.jpg")
            try stripped.write(to: out)
            #expect(ImageMetadataCheck.findings(in: out).isEmpty, "\(ImageMetadataCheck.findings(in: out))")
            #expect(try ImageFile(url: out).orientation == .right)
        }
    }

    @Test func checkerFlagsEachLayer() throws {
        let dir = try Fixtures.tempDir()
        let small = Fixtures.image(width: 32, height: 32)
        // GPS only -> location.
        let gps = try Fixtures.writeImage(small, to: dir.appendingPathComponent("gps.png"), type: .png, personalInfo: true)
        #expect(ImageMetadataCheck.hasLocation(gps.url))
        // A JPEG comment segment alone (ImageIO doesn't report it) is caught by the byte scan.
        let plain = try Fixtures.writeImage(small, to: dir.appendingPathComponent("c.jpg"), type: .jpeg)
        #expect(ImageMetadataCheck.findings(in: plain.url).isEmpty)
        try Fixtures.injectJPEGExtras(plain.url)
        let details = ImageMetadataCheck.findings(in: plain.url).map(\.detail)
        #expect(details.contains { $0.contains("comment") } && details.contains { $0.contains("after the JPEG") }, "\(details)")
        #expect(!ImageMetadataCheck.hasLocation(plain.url))
    }

    @Test(arguments: ["image.compress", "image.resize-half"])
    func sharingActionsDropLocationButKeepOtherMetadata(_ id: String) async throws {
        let dir = try Fixtures.tempDir()
        for (ext, type) in Self.formats {
            let input = try Fixtures.writeDirtyImage(Fixtures.image(width: 400, height: 300), to: dir.appendingPathComponent("trip-\(ext).\(ext)"), type: type)
            #expect(ImageMetadataCheck.hasLocation(input.url))
            let output = try #require(try await Fixtures.run(ActionID(rawValue: id), [input]).first)
            let findings = ImageMetadataCheck.findings(in: output)
            #expect(!findings.contains { $0.kind == .location }, "\(id) \(ext) kept location: \(findings.filter { $0.kind == .location })")
            #expect(!(try Fixtures.containsBytes(output, "Cupertino")), "\(id) \(ext) kept the city")
            // Other metadata stays: camera make and capture date.
            let info = try Fixtures.imageInfo(output)
            let tiff = info.props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            let exif = info.props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            #expect(tiff[kCGImagePropertyTIFFMake] as? String == "HaloMake", "\(id) \(ext) dropped the camera make")
            #expect(exif[kCGImagePropertyExifDateTimeOriginal] != nil, "\(id) \(ext) dropped the capture date")
        }
        #expect(Fixtures.leftovers(in: dir).isEmpty)
    }

    @Test func formatConversionsKeepLocation() async throws {
        let dir = try Fixtures.tempDir()
        let input = try Fixtures.writeDirtyImage(Fixtures.image(width: 64, height: 64), to: dir.appendingPathComponent("trip.jpg"), type: .jpeg)
        for id: ActionID in ["image.to-png", "image.to-heic", "image.to-tiff"] where id != "image.to-heic" || Fixtures.chipWrites {
            let output = try #require(try await Fixtures.run(id, [input]).first)
            #expect(ImageMetadataCheck.hasLocation(output), "\(id) should keep GPS")
        }
    }

    @Test func stripKeepsGIFAnimationAndIsClean() async throws {
        let dir = try Fixtures.tempDir()
        let input = try Fixtures.writeGIF(to: dir.appendingPathComponent("anim.gif"), frames: 4, width: 60, height: 40)
        let output = try #require(try await Fixtures.run("image.strip-metadata", [input]).first)
        let info = try Fixtures.imageInfo(output)
        #expect(info.frames == 4 && info.width == 60)
        #expect(ImageMetadataCheck.findings(in: output).isEmpty)
    }
}
