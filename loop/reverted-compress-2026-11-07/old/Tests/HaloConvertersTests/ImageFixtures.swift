import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import HaloConverters
@testable import HaloCore

/// Runtime-generated fixtures shared by the Image, PDF and Text tests. Nothing binary is committed.
enum Fixtures {
    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-conv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Pixels

    /// A gradient with noise (realistic for compression), optionally with a transparent region.
    /// If `splitColors` is set, the left half is red and the right half blue instead (for orientation checks).
    static func image(width: Int, height: Int, alpha: Bool = false, splitColors: Bool = false,
                      space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> CGImage {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)!
        let buffer = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var seed: UInt32 = 7
        for y in 0..<height {
            for x in 0..<width {
                let p = buffer + y * ctx.bytesPerRow + x * 4
                if splitColors {
                    let left = x < width / 2
                    p[0] = left ? 255 : 0; p[1] = 0; p[2] = left ? 0 : 255; p[3] = 255
                    continue
                }
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = UInt8(truncatingIfNeeded: seed >> 24) / 6
                let a: UInt8 = alpha && x < width / 4 ? 0 : 255
                let scale = Double(a) / 255
                p[0] = UInt8(Double(UInt8((x * 200) / max(1, width)) &+ noise) * scale)
                p[1] = UInt8(Double(UInt8((y * 200) / max(1, height)) &+ noise) * scale)
                p[2] = UInt8(Double(120 &+ noise) * scale)
                p[3] = a
            }
        }
        return ctx.makeImage()!
    }

    /// Black text on white, big enough for OCR.
    static func textImage(_ text: String, width: Int = 1600, height: Int = 400, fontSize: CGFloat = 96) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        drawText(text, in: ctx, at: CGPoint(x: 60, y: CGFloat(height) / 2 - fontSize / 3), size: fontSize)
        return ctx.makeImage()!
    }

    static func drawText(_ text: String, in ctx: CGContext, at point: CGPoint, size: CGFloat) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }

    // MARK: Image files

    /// Writes `image` as `type`, with optional orientation and identifying metadata (GPS, camera, date).
    @discardableResult
    static func writeImage(_ image: CGImage, to url: URL, type: UTType, orientation: Int = 1, personalInfo: Bool = false,
                           quality: Double = 1.0) throws -> InputFile {
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var props: [CFString: Any] = [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: quality]
        if personalInfo {
            props[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.0, kCGImagePropertyGPSLongitudeRef: "W",
            ]
            props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "Frenzy", kCGImagePropertyTIFFModel: "HaloCam", kCGImagePropertyTIFFOrientation: orientation]
            props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: "2026:01:02 03:04:05"]
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        try #require(CGImageDestinationFinalize(dest))
        return try #require(InputFile(url: url))
    }

    /// Writes `image` as `type` loaded with every kind of identifying metadata: GPS, camera EXIF (date, serial, lens,
    /// owner), TIFF (make, model, software, artist, copyright, host), IPTC (byline, city, country), PNG text chunks,
    /// an EXIF thumbnail, and XMP (dc:creator, xmpMM:DocumentID, xmp:CreatorTool, photoshop:City).
    @discardableResult
    static func writeDirtyImage(_ image: CGImage, to url: URL, type: UTType, orientation: Int = 1) throws -> InputFile {
        let staging = url.deletingLastPathComponent().appendingPathComponent("staging-\(UUID().uuidString).\(url.pathExtension)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let dest = try #require(CGImageDestinationCreateWithURL(staging as CFURL, type.identifier as CFString, 1, nil))
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImageDestinationEmbedThumbnail: true,
            kCGImageDestinationLossyCompressionQuality: 1.0,
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.0, kCGImagePropertyGPSLongitudeRef: "W", kCGImagePropertyGPSAltitude: 42.0,
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "HaloMake", kCGImagePropertyTIFFModel: "HaloCam", kCGImagePropertyTIFFSoftware: "SecretTool 9",
                kCGImagePropertyTIFFArtist: "Jane Doe", kCGImagePropertyTIFFCopyright: "Jane Copyright",
                kCGImagePropertyTIFFHostComputer: "Janes-MacBook", kCGImagePropertyTIFFDateTime: "2026:01:02 03:04:05",
                kCGImagePropertyTIFFOrientation: orientation,
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:01:02 03:04:05", kCGImagePropertyExifBodySerialNumber: "SN-998877",
                kCGImagePropertyExifLensModel: "HaloLens 50mm", kCGImagePropertyExifCameraOwnerName: "Jane Owner",
                kCGImagePropertyExifUserComment: "secret exif comment",
            ],
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCByline: ["Jane Byline"], kCGImagePropertyIPTCCity: "Cupertino",
                kCGImagePropertyIPTCCountryPrimaryLocationName: "Narnia", kCGImagePropertyIPTCKeywords: ["private-keyword"],
            ],
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGAuthor: "Jane Author", kCGImagePropertyPNGDescription: "secret description",
                kCGImagePropertyPNGComment: "secret png comment", kCGImagePropertyPNGSoftware: "SecretTool 9",
                kCGImagePropertyPNGTitle: "secret title", kCGImagePropertyPNGCreationTime: "2026-01-02T03:04:05Z",
            ],
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        try #require(CGImageDestinationFinalize(dest))

        // Second pass: add XMP on top of everything above.
        let source = try #require(CGImageSourceCreateWithURL(staging as CFURL, nil))
        let xmp = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(xmp, "http://purl.org/dc/elements/1.1/" as CFString, "dc" as CFString, nil)
        CGImageMetadataRegisterNamespaceForPrefix(xmp, "http://ns.adobe.com/xap/1.0/mm/" as CFString, "xmpMM" as CFString, nil)
        CGImageMetadataSetValueWithPath(xmp, nil, "dc:creator" as CFString, ["Jane XMP Creator"] as CFArray)
        CGImageMetadataSetValueWithPath(xmp, nil, "xmpMM:DocumentID" as CFString, "uuid:halo-doc-1234" as CFString)
        CGImageMetadataSetValueWithPath(xmp, nil, "xmp:CreatorTool" as CFString, "SecretXMPTool" as CFString)
        CGImageMetadataSetValueWithPath(xmp, nil, "photoshop:City" as CFString, "Cupertino" as CFString)
        let final = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        let copied = CGImageDestinationCopyImageSource(final, source, [
            kCGImageDestinationMetadata: xmp, kCGImageDestinationMergeMetadata: true,
        ] as CFDictionary, nil)
        if !copied {
            // Formats without lossless copy: re-add the image with the merged metadata.
            try? FileManager.default.removeItem(at: url)
            let original = try #require(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
            let merged = try #require(CGImageMetadataCreateMutableCopy(original))
            CGImageMetadataEnumerateTagsUsingBlock(xmp, nil, nil) { path, tag in
                CGImageMetadataSetTagWithPath(merged, nil, path, tag); return true
            }
            let again = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
            let pixels = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            CGImageDestinationAddImageAndMetadata(again, pixels, merged, nil)
            try #require(CGImageDestinationFinalize(again))
        }
        if type == .jpeg { try injectJPEGExtras(url) }
        return try #require(InputFile(url: url))
    }

    /// Adds a JPEG comment segment right after SOI and an appended fake second image after EOI (like MPF gain maps).
    static func injectJPEGExtras(_ url: URL) throws {
        var bytes = [UInt8](try Data(contentsOf: url))
        let comment = Array("secret jpeg comment".utf8)
        let length = comment.count + 2
        bytes.insert(contentsOf: [0xFF, 0xFE, UInt8(length >> 8), UInt8(length & 0xFF)] + comment, at: 2)
        bytes += [0xFF, 0xD8, 0xFF, 0xFE, 0x00, 0x0E] + Array("hidden image".utf8) + [0xFF, 0xD9]
        try Data(bytes).write(to: url)
    }

    /// Strings planted by `writeDirtyImage` that must never survive "Strip Info".
    static let plantedStrings = [
        "HaloMake", "HaloCam", "SecretTool", "Jane", "Janes-MacBook", "SN-998877", "HaloLens", "secret", "Cupertino",
        "Narnia", "private-keyword", "uuid:halo-doc-1234", "SecretXMPTool", "hidden image",
    ]

    static func containsBytes(_ url: URL, _ text: String) throws -> Bool {
        try Data(contentsOf: url).range(of: Data(text.utf8)) != nil
    }

    /// A PNG that declares `width` x `height` grey pixels but holds only zeros (ImageIO wants roughly 1 byte of IDAT
    /// per 9,000 pixels before it reports a size). Decoding it for real would need width x height x 4 bytes.
    static func writePNGBomb(to url: URL, width: UInt32, height: UInt32) throws -> InputFile {
        func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let t = Array(type.utf8)
            return be32(UInt32(body.count)) + t + body + be32(crc32(t + body))
        }
        let idat = [0x78, 0x9C] + [UInt8](repeating: 0, count: Int(UInt64(width) * UInt64(height) / 9_000))
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes += chunk("IHDR", be32(width) + be32(height) + [8, 0, 0, 0, 0]) + chunk("IDAT", idat) + chunk("IEND", [])
        try Data(bytes).write(to: url)
        return try #require(InputFile(url: url))
    }

    /// A 300-byte TIFF that declares `size` x `size` deflate-compressed grey pixels.
    static func writeTIFFBomb(to url: URL, size: UInt32) throws -> InputFile {
        func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func entry(_ tag: UInt16, _ type: UInt16, _ value: UInt32) -> [UInt8] {
            [UInt8(tag >> 8), UInt8(tag & 0xFF), 0, UInt8(type)] + be32(1)
                + (type == 3 ? [UInt8(value >> 8), UInt8(value & 0xFF), 0, 0] : be32(value))
        }
        let entries = [entry(256, 4, size), entry(257, 4, size), entry(258, 3, 8), entry(259, 3, 8), entry(262, 3, 1),
                       entry(273, 4, 200), entry(277, 3, 1), entry(278, 4, size), entry(279, 4, 100)]
        var bytes: [UInt8] = Array("MM".utf8) + [0, 42] + be32(8) + [0, UInt8(entries.count)] + entries.flatMap { $0 } + be32(0)
        bytes += [UInt8](repeating: 0, count: 300 - bytes.count)
        try Data(bytes).write(to: url)
        return try #require(InputFile(url: url))
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            c ^= UInt32(b)
            for _ in 0..<8 { c = (c >> 1) ^ (0xEDB8_8320 & (0 &- (c & 1))) }
        }
        return ~c
    }

    /// Peak resident memory of this test process so far, in MB.
    static func peakMemoryMB() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return usage.ru_maxrss / 1_048_576
    }

    /// A one-page PDF with a JavaScript link, a Launch link, a web link and a document-level JavaScript OpenAction.
    static func writeScriptedPDF(to url: URL) throws -> InputFile {
        try writeRawPDF(to: url, objects: [
            "<< /Type /Catalog /Pages 2 0 R /OpenAction 5 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R 6 0 R 7 0 R] >>",
            "<< /Type /Annot /Subtype /Link /Rect [10 10 200 200] /Border [0 0 0] /A << /S /JavaScript /JS (app.alert\\(1\\)) >> >>",
            "<< /S /JavaScript /JS (app.alert\\(2\\)) >>",
            "<< /Type /Annot /Subtype /Link /Rect [210 10 400 200] /Border [0 0 0] /A << /S /Launch /F (calc.exe) >> >>",
            "<< /Type /Annot /Subtype /Link /Rect [410 10 600 200] /Border [0 0 0] /A << /S /URI /URI (https://example.com/) >> >>",
        ])
    }

    /// Two pages: page 1 has real text, page 2 has a zero-size media box.
    static func writeZeroSizePagePDF(to url: URL) throws -> InputFile {
        let content = "BT /F1 24 Tf 72 700 Td (Sized page text) Tj ET"
        return try writeRawPDF(to: url, objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << /Font << /F1 6 0 R >> >> >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 0 0] >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ])
    }

    /// Writes numbered PDF objects with a correct cross-reference table.
    static func writeRawPDF(to url: URL, objects: [String]) throws -> InputFile {
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(i + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        try Data(pdf.utf8).write(to: url)
        return try #require(InputFile(url: url))
    }

    /// Every file inside an output folder, sorted by name.
    static func folderContents(_ folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// An animated GIF with `frames` frames.
    static func writeGIF(to url: URL, frames: Int, width: Int, height: Int) throws -> InputFile {
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil))
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for i in 0..<frames {
            CGImageDestinationAddImage(dest, image(width: width, height: height, splitColors: i % 2 == 0),
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        try #require(CGImageDestinationFinalize(dest))
        return try #require(InputFile(url: url))
    }

    // MARK: PDFs

    /// A Letter-sized PDF. Each page shows `"<label> page N"` as real (vector) text; optionally a large photo too.
    @discardableResult
    static func writePDF(to url: URL, pages: Int, label: String = "Frenzy", bigImage: Bool = false,
                         imageOnlyText: String? = nil) throws -> InputFile {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for n in 1...pages {
            ctx.beginPDFPage(nil)
            drawText("\(label) page \(n)", in: ctx, at: CGPoint(x: 60, y: 700), size: 36)
            if bigImage { ctx.draw(image(width: 2400, height: 2400), in: CGRect(x: 56, y: 100, width: 500, height: 500)) }
            ctx.endPDFPage()
        }
        if let imageOnlyText {
            // A "scanned" page: the text exists only as pixels.
            ctx.beginPDFPage(nil)
            ctx.draw(textImage(imageOnlyText), in: CGRect(x: 6, y: 300, width: 600, height: 150))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return try #require(InputFile(url: url))
    }

    static func writeLockedPDF(to url: URL) throws -> InputFile {
        let plain = url.deletingLastPathComponent().appendingPathComponent("plain-\(UUID().uuidString).pdf")
        try writePDF(to: plain, pages: 1)
        let document = try #require(PDFDocument(url: plain))
        try #require(document.write(to: url, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "owner"]))
        try FileManager.default.removeItem(at: plain)
        return try #require(InputFile(url: url))
    }

    // MARK: Checks

    /// Every regular file under `dir` (recursively) with its contents, for "originals untouched" checks.
    static func snapshot(_ files: [InputFile]) throws -> [URL: Data] {
        try Dictionary(uniqueKeysWithValues: files.map { ($0.url, try Data(contentsOf: $0.url)) })
    }

    static func expectUnchanged(_ snapshot: [URL: Data]) throws {
        for (url, data) in snapshot { #expect(try Data(contentsOf: url) == data, "\(url.lastPathComponent) was modified") }
    }

    /// Hidden `.halo-*` temp files anywhere under `dir`.
    static func leftovers(in dir: URL) -> [String] {
        let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).map(\.lastPathComponent).filter { $0.hasPrefix(".halo-") }
    }

    static func action(_ id: ActionID) throws -> ConversionAction {
        try #require((ImageActions.all + PDFActions.all + TextActions.all).first { $0.id == id }, "missing \(id)")
    }

    /// Runs an action's converter directly (like the runner does for one group) and returns committed outputs.
    static func run(_ id: ActionID, _ inputs: [InputFile]) async throws -> [URL] {
        let action = try action(id)
        #expect(action.accepts(inputs), "\(id) should accept \(inputs.map(\.url.lastPathComponent))")
        let job = ConversionJob(actionID: id, inputs: inputs)
        do {
            let urls = try await action.converter.run(job)
            job.outputs.discardUncommitted()
            return urls
        } catch {
            job.outputs.discardUncommitted()
            throw error
        }
    }

    static func runner() -> ConversionRunner {
        ConversionRunner(registry: ActionRegistry(actions: ImageActions.all + PDFActions.all + TextActions.all, usage: MemoryUsageStore()))
    }

    static func imageInfo(_ url: URL) throws -> (type: String, width: Int, height: Int, frames: Int, props: [CFString: Any]) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil) as? [CFString: Any])
        return (CGImageSourceGetType(source) as String? ?? "", props[kCGImagePropertyPixelWidth] as? Int ?? 0,
                props[kCGImagePropertyPixelHeight] as? Int ?? 0, CGImageSourceGetCount(source), props)
    }

    /// RGBA of the pixel at (x, y), y measured from the top.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self) + y * ctx.bytesPerRow + x * 4
        return [p[0], p[1], p[2], p[3]]
    }

    static func decode(_ url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil))
    }
}
