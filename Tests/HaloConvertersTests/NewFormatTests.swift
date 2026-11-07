import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import HaloConverters
@testable import HaloCore

// MARK: - PDF to Word

@Suite("PDF to Word")
struct PDFToWordTests {
    private let registry = DefaultActions.registry(usage: MemoryUsageStore())

    private func run(_ id: ActionID, on file: URL) async throws -> ConversionOutcome {
        await ConversionRunner(registry: registry, maxConcurrent: 1).run(id, on: [try #require(InputFile(url: file))])
    }

    /// A two-page PDF with a real text layer: a big bold heading, body paragraphs and italics.
    private func report(in dir: URL) async throws -> URL {
        let text = NSMutableAttributedString()
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 14
        func add(_ string: String, _ font: NSFont) { text.append(NSAttributedString(string: string, attributes: [.font: font, .paragraphStyle: style])) }
        add("Quarterly Report\n", .boldSystemFont(ofSize: 26))
        add("The first paragraph talks about revenue. It runs long enough that it wraps onto a second line when the page lays it out, and a third as well, because the words keep on going.\n", .systemFont(ofSize: 12))
        add("The second paragraph is about costs.\n", .systemFont(ofSize: 12))
        for i in 0..<60 { add("Filler line number \(i) to push the text over to another page.\n", .systemFont(ofSize: 12)) }
        add("The final paragraph closes the report.\n", .systemFont(ofSize: 12))
        let url = dir.appendingPathComponent("report.pdf")
        try DocumentSupport.renderPDF(text, to: url, title: "report", cancellation: DocumentCancellation()) { _ in }
        return url
    }

    @Test func offeredHonestly() throws {
        let action = try #require(registry.action("pdf.to-word"))
        #expect(action.title == "Word")
        // The ring must not suggest the layout survives.
        #expect(action.subtitle == "Text only")
        let fits = registry.actions(for: [InputFile(url: URL(fileURLWithPath: "/tmp/a.pdf"), type: .pdf)], limit: 99).map(\.id.rawValue)
        #expect(fits.contains("pdf.to-word"))
    }

    @Test func textAndStructureComeThrough() async throws {
        let dir = try Fixtures.tempDir()
        let pdf = try await report(in: dir)
        let pages = try #require(PDFDocument(url: pdf)).pageCount
        #expect(pages >= 2, "the fixture has to span pages")
        let outcome = try await run("pdf.to-word", on: pdf)
        #expect(outcome.failures.isEmpty, "\(outcome.failures)")
        let docx = try #require(outcome.outputs.first)
        #expect(docx.lastPathComponent == "report.docx")

        // Apple's reader opens it, and every word is there.
        let read = try NSAttributedString(url: docx, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        let string = read.string
        #expect(string.contains("Quarterly Report"))
        #expect(string.contains("The first paragraph talks about revenue."))
        #expect(string.contains("The final paragraph closes the report."))

        // A wrapped paragraph is one paragraph again, not one per line.
        let paragraph = try #require(string.components(separatedBy: .newlines).first { $0.contains("first paragraph") })
        #expect(paragraph.contains("a third as well"), "\(paragraph)")
        // Separate paragraphs stay separate.
        #expect(!paragraph.contains("The second paragraph"))

        // The heading is a heading: bigger and bold.
        let headingRange = (string as NSString).range(of: "Quarterly Report")
        let font = try #require(read.attribute(.font, at: headingRange.location, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize >= 20, "\(font.pointSize)")
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
        let bodyRange = (string as NSString).range(of: "The second paragraph")
        let body = try #require(read.attribute(.font, at: bodyRange.location, effectiveRange: nil) as? NSFont)
        #expect(!body.fontDescriptor.symbolicTraits.contains(.bold))

        // One page break per PDF page, in the Word file itself.
        let xml = try ArchiveFixtures.shell("/usr/bin/unzip", ["-p", docx.path, "word/document.xml"]).output
        #expect(xml.components(separatedBy: "w:br w:type=\"page\"").count - 1 == pages - 1)
        // A valid package with the parts Word needs.
        let parts = try ArchiveFixtures.shell("/usr/bin/unzip", ["-Z1", docx.path]).output
        for part in ["[Content_Types].xml", "_rels/.rels", "word/document.xml"] { #expect(parts.contains(part), "\(part)") }
        let textutil = try ArchiveFixtures.shell("/usr/bin/textutil", ["-convert", "txt", "-stdout", docx.path])
        #expect(textutil.status == 0 && textutil.output.contains("closes the report"))
    }

    /// Short lines at normal line spacing (a list, an address, a log) keep their breaks; they used to run together into
    /// one paragraph ("Page line 0 Page line 1 ..."). Page breaks stay page breaks, and every line is still there.
    @Test func shortLinesKeepTheirBreaks() async throws {
        let dir = try Fixtures.tempDir()
        let text = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 12)
        for i in 0..<120 { text.append(NSAttributedString(string: "Page line \(i) Frenzy\n", attributes: [.font: font])) }
        let url = dir.appendingPathComponent("lines.pdf")
        try DocumentSupport.renderPDF(text, to: url, title: "lines", cancellation: DocumentCancellation()) { _ in }
        let pages = try #require(PDFDocument(url: url)).pageCount
        #expect(pages >= 2, "the fixture has to span pages")

        let outcome = try await run("pdf.to-word", on: url)
        #expect(outcome.failures.isEmpty, "\(outcome.failures)")
        let docx = try #require(outcome.outputs.first)
        let plain = try ArchiveFixtures.shell("/usr/bin/textutil", ["-convert", "txt", "-stdout", docx.path]).output
        let lines = plain.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\u{0C}", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        #expect(lines.count == 120, "\(lines.prefix(5))")
        for i in [0, 1, 59, 119] { #expect(lines.contains("Page line \(i) Frenzy"), "line \(i)") }
        #expect(plain.components(separatedBy: "Frenzy").count - 1 == 120)
        let xml = try ArchiveFixtures.shell("/usr/bin/unzip", ["-p", docx.path, "word/document.xml"]).output
        #expect(xml.components(separatedBy: "w:br w:type=\"page\"").count - 1 == pages - 1)
        #expect(xml.contains("<w:br/>"), "line breaks are Word line breaks")
    }

    @Test func scannedPagesGoThroughOCR() async throws {
        let dir = try Fixtures.tempDir()
        let picture = Fixtures.textImage("HELLO SCANNED WORLD")
        let url = dir.appendingPathComponent("scan.pdf")
        var box = CGRect(x: 0, y: 0, width: picture.width, height: picture.height)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.draw(picture, in: box)
        context.endPDFPage()
        context.closePDF()
        let outcome = try await run("pdf.to-word", on: url)
        #expect(outcome.failures.isEmpty, "\(outcome.failures)")
        let read = try NSAttributedString(url: try #require(outcome.outputs.first),
                                          options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        #expect(read.string.uppercased().contains("SCANNED"), "\(read.string)")
    }

    @Test func corruptPDFFailsPlainly() async throws {
        let dir = try Fixtures.tempDir()
        let url = dir.appendingPathComponent("junk.pdf")
        var bytes = Data(count: 50_000)
        bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        try bytes.write(to: url)
        let outcome = try await run("pdf.to-word", on: url)
        #expect(outcome.outputs.isEmpty)
        #expect(!outcome.failures.isEmpty)
        #expect(Fixtures.leftovers(in: dir).isEmpty)
    }

    @Test func blankPDFSaysSo() async throws {
        let dir = try Fixtures.tempDir()
        let url = dir.appendingPathComponent("blank.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 300)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        let outcome = try await run("pdf.to-word", on: url)
        #expect(outcome.outputs.isEmpty)
        #expect(outcome.failures.first?.message.contains("No text") == true, "\(outcome.failures)")
    }

    // MARK: The paragraph rules on their own

    private func line(_ text: String, top: Double, size: Double = 12) -> PDFToWord.Line {
        .init(runs: [.init(text: text, size: size, isBold: false, isItalic: false)], top: top, bottom: top - size, left: 72)
    }

    @Test func linesJoinWithSpacesAndHyphensClose() {
        let blocks = PDFToWord.paragraphs([line("A hyphen-", top: 700), line("ated word and", top: 686), line("a space.", top: 672)], bodySize: 12)
        guard case .paragraph(let runs, heading: false)? = blocks.first else { Issue.record("\(blocks)"); return }
        #expect(runs.map(\.text).joined() == "A hyphenated word and a space.")
        #expect(blocks.count == 1)
    }

    private func line(_ text: String, top: Double, right: Double) -> PDFToWord.Line {
        .init(runs: [.init(text: text, size: 12, isBold: false, isItalic: false)], top: top, bottom: top - 12, left: 72, right: right)
    }

    @Test func wrappedLinesJoinShortLinesBreak() {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)  // text runs from 72 to 540
        let blocks = PDFToWord.paragraphs([
            line("A long line that ran right into the edge and", top: 700, right: 536),
            line("wrapped onto the next one.", top: 686, right: 230),
            line("Short line", top: 672, right: 130),
            line("Another short one", top: 658, right: 180),
        ], bodySize: 12, page: page)
        #expect(blocks.count == 1)
        guard case .paragraph(let runs, heading: false)? = blocks.first else { Issue.record("\(blocks)"); return }
        #expect(runs.map(\.text).joined() == "A long line that ran right into the edge and wrapped onto the next one.\u{2028}Short line\u{2028}Another short one")
    }

    @Test func aBigGapStartsAParagraph() {
        let blocks = PDFToWord.paragraphs([line("One.", top: 700), line("Two.", top: 660)], bodySize: 12)
        #expect(blocks.count == 2)
    }

    @Test func sizeMakesAHeading() {
        let blocks = PDFToWord.paragraphs([line("Big", top: 720, size: 24), line("Small body.", top: 690)], bodySize: 12)
        guard case .paragraph(_, let first)? = blocks.first, case .paragraph(_, let second)? = blocks.last else { Issue.record("\(blocks)"); return }
        #expect(first && !second)
    }
}

// MARK: - Images

@Suite("New image formats")
struct NewImageFormatTests {
    private let registry = DefaultActions.registry(usage: MemoryUsageStore())

    private func convert(_ id: ActionID, _ file: URL) async throws -> URL {
        let outcome = await ConversionRunner(registry: registry, maxConcurrent: 1).run(id, on: [try #require(InputFile(url: file))])
        #expect(outcome.failures.isEmpty, "\(id): \(outcome.failures.map(\.message))")
        return try #require(outcome.outputs.first)
    }

    /// RGBA of one pixel, decoded by ImageIO.
    private func pixel(_ url: URL, x: Int, y: Int) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return bytes
    }

    private func size(_ url: URL) throws -> (Int, Int) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }

    private func write(_ image: CGImage, _ type: String, to url: URL) throws {
        try Fixtures.refuseChipFormat(try #require(UTType(type)))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// Solid colours, so a colour check has a clear answer: red left, blue right.
    private func splitPNG(in dir: URL, name: String = "split.png", alpha: Bool = false) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let image = alpha ? Fixtures.image(width: 400, height: 300, alpha: true) : Fixtures.image(width: 400, height: 300, splitColors: true)
        try write(image, UTType.png.identifier, to: url)
        return url
    }

    private func isClose(_ a: UInt8, _ b: UInt8, _ tolerance: Int = 14) -> Bool { abs(Int(a) - Int(b)) <= tolerance }

    // MARK: WebP

    @Test(.enabled(if: MediaEngine.isAvailable)) func pngToWebP() async throws {
        let dir = try Fixtures.tempDir()
        let out = try await convert("image.to-webp", try splitPNG(in: dir))
        #expect(out.pathExtension == "webp")
        #expect(try size(out) == (400, 300))
        let left = try pixel(out, x: 50, y: 150), right = try pixel(out, x: 350, y: 150)
        #expect(isClose(left[0], 255) && isClose(left[2], 0), "\(left)")
        #expect(isClose(right[0], 0) && isClose(right[2], 255), "\(right)")
        // Real WebP, by its own header.
        let head = try FileHandle(forReadingFrom: out).read(upToCount: 16) ?? Data()
        #expect(head.starts(with: Data("RIFF".utf8)) && head.dropFirst(8).starts(with: Data("WEBP".utf8)))
        #expect(Fixtures.leftovers(in: dir).isEmpty)
    }

    @Test(.enabled(if: MediaEngine.isAvailable)) func webPKeepsTransparency() async throws {
        let dir = try Fixtures.tempDir()
        let out = try await convert("image.to-webp", try splitPNG(in: dir, alpha: true))
        // The fixture's left quarter is transparent.
        #expect(try pixel(out, x: 20, y: 150)[3] < 20)
        #expect(try pixel(out, x: 300, y: 150)[3] > 235)
    }

    @Test(.enabled(if: MediaEngine.isAvailable)) func heicAndJPEGToWebP() async throws {
        let dir = try Fixtures.tempDir()
        let picture = Fixtures.image(width: 240, height: 160)
        let heic = dir.appendingPathComponent("photo.heic"), jpeg = dir.appendingPathComponent("photo.jpg")
        // Without FRENZY_HEIC_TESTS=1 a shipped 356 x 356 HEIC stands in (writing one uses the hardware encoder).
        if Fixtures.chipWrites { try write(picture, UTType.heic.identifier, to: heic) } else { _ = try Fixtures.systemHEIC(to: heic) }
        try write(picture, UTType.jpeg.identifier, to: jpeg)
        let heicSize = Fixtures.chipWrites ? (240, 160) : (356, 356)
        #expect(try size(try await convert("image.to-webp", heic)) == heicSize)
        #expect(try size(try await convert("image.to-webp", jpeg)) == (240, 160))
    }

    /// The photo's orientation goes into the pixels, because the WebP has nowhere else to keep it.
    @Test(.enabled(if: MediaEngine.isAvailable)) func webPAppliesOrientation() async throws {
        let dir = try Fixtures.tempDir()
        let url = dir.appendingPathComponent("turned.jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, Fixtures.image(width: 400, height: 300, splitColors: true),
                                   [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        #expect(try size(try await convert("image.to-webp", url)) == (300, 400))
    }

    @Test(.enabled(if: MediaEngine.isAvailable)) func corruptImageToWebPFailsPlainly() async throws {
        let dir = try Fixtures.tempDir()
        let url = dir.appendingPathComponent("junk.png")
        var bytes = Data(count: 20_000)
        bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        try bytes.write(to: url)
        let outcome = await ConversionRunner(registry: registry, maxConcurrent: 1).run("image.to-webp", on: [InputFile(url: url, type: .png)])
        #expect(outcome.outputs.isEmpty && !outcome.failures.isEmpty)
        #expect(Fixtures.leftovers(in: dir).isEmpty)
    }

    // MARK: AVIF and ICO (Apple's encoders)

    /// AVIF goes through Frenzy's hardware-encoder gate: only with FRENZY_HEIC_TESTS=1.
    @Test(.enabled(if: Fixtures.chipWrites)) func jpegToAVIF() async throws {
        try #require(ImageFormat.avif.isEncodable)
        let dir = try Fixtures.tempDir()
        let jpeg = dir.appendingPathComponent("split.jpg")
        try write(Fixtures.image(width: 400, height: 300, splitColors: true), UTType.jpeg.identifier, to: jpeg)
        let out = try await convert("image.to-avif", jpeg)
        #expect(out.pathExtension == "avif")
        #expect(try size(out) == (400, 300))
        let left = try pixel(out, x: 50, y: 150)
        #expect(isClose(left[0], 255, 30) && isClose(left[2], 0, 30), "\(left)")
    }

    @Test func pngToICO() async throws {
        try #require(ImageCodecs.encodable.contains("com.microsoft.ico"))
        let dir = try Fixtures.tempDir()
        let out = try await convert("image.to-ico", try splitPNG(in: dir))
        #expect(out.pathExtension == "ico")
        #expect(try size(out) == (256, 256))
        // 400 x 300 fits inside the square with clear bands above and below.
        #expect(try pixel(out, x: 128, y: 2)[3] < 10)
        #expect(try pixel(out, x: 40, y: 128)[0] > 230)
        let bytes = [UInt8](try Data(contentsOf: out).prefix(4))
        #expect(bytes == [0, 0, 1, 0], "the ICO file signature")
    }

    // MARK: PSD, TGA, JP2, EXR, ICO, ICNS in (ImageIO reads them)

    @Test(arguments: [("psd", "com.adobe.photoshop-image"), ("tga", "com.truevision.tga-image"), ("jp2", "public.jpeg-2000"),
                      ("ico", "com.microsoft.ico"), ("icns", "com.apple.icns")])
    func readableFormatsConvert(ext: String, type: String) async throws {
        let dir = try Fixtures.tempDir()
        let url = dir.appendingPathComponent("in.\(ext)")
        try write(Fixtures.image(width: 256, height: 256), type, to: url)
        let input = try #require(InputFile(url: url))
        let fits = registry.actions(for: [input], limit: 99).map(\.id.rawValue)
        #expect(fits.contains("image.to-jpg"), "\(fits)")
        let out = try await convert("image.to-jpg", url)
        #expect(try size(out) == (256, 256))
        let png = try await convert("image.to-png", url)
        #expect(try size(png) == (256, 256))
    }

    @Test func corruptPSDFailsPlainly() async throws {
        let dir = try Fixtures.tempDir()
        let url = dir.appendingPathComponent("junk.psd")
        var bytes = Data(count: 20_000)
        bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        try bytes.write(to: url)
        let outcome = await ConversionRunner(registry: registry, maxConcurrent: 1).run("image.to-jpg", on: [try #require(InputFile(url: url))])
        #expect(outcome.outputs.isEmpty && !outcome.failures.isEmpty)
    }

    /// Camera RAW was already on the list. The type is checked here; no real camera file exists on this Mac to convert.
    @Test(arguments: ["cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2"])
    func rawIsOffered(ext: String) throws {
        let input = InputFile(url: URL(fileURLWithPath: "/tmp/x.\(ext)"), type: try #require(UTType(filenameExtension: ext)))
        #expect(registry.actions(for: [input], limit: 99).map(\.id.rawValue).contains("image.to-jpg"))
    }

    // MARK: SVG

    private let drawing = """
    <svg xmlns="http://www.w3.org/2000/svg" width="120" height="80" viewBox="0 0 120 80">
      <rect width="60" height="80" fill="#ff0000"/><rect x="60" width="60" height="80" fill="#0000ff"/>
    </svg>
    """

    private func svg(_ text: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("drawing.svg")
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func svgToPNG() async throws {
        let dir = try Fixtures.tempDir()
        let out = try await convert("image.svg-to-png", try svg(drawing, in: dir))
        #expect(try size(out) == (240, 160), "drawn at twice its size")
        let left = try pixel(out, x: 40, y: 80), right = try pixel(out, x: 200, y: 80)
        #expect(isClose(left[0], 255) && isClose(left[2], 0), "\(left)")
        #expect(isClose(right[0], 0) && isClose(right[2], 255), "\(right)")
    }

    @Test func svgToJPGAndPDF() async throws {
        let dir = try Fixtures.tempDir()
        let file = try svg(drawing, in: dir)
        #expect(try size(try await convert("image.svg-to-jpg", file)) == (240, 160))
        let pdf = try await convert("image.svg-to-pdf", file)
        let document = try #require(PDFDocument(url: pdf))
        #expect(document.pageCount == 1)
        let box = try #require(document.page(at: 0)).bounds(for: .mediaBox)
        #expect(box.width == 120 && box.height == 80)
    }

    @Test func svgSizeIsCapped() async throws {
        let dir = try Fixtures.tempDir()
        let out = try await convert("image.svg-to-png", try svg(##"<svg xmlns="http://www.w3.org/2000/svg" width="100000" height="50000"><rect width="100000" height="50000" fill="#00ff00"/></svg>"##, in: dir))
        #expect(try size(out) == (4096, 2048))
    }

    @Test func svgToICO() async throws {
        let dir = try Fixtures.tempDir()
        #expect(try size(try await convert("image.to-ico", try svg(drawing, in: dir))) == (256, 256))
    }

    @Test(arguments: [
        #"<!DOCTYPE svg [<!ENTITY a "aaaaaaaa"><!ENTITY b "&a;&a;&a;">]><svg xmlns="http://www.w3.org/2000/svg" width="9" height="9"><text>&b;</text></svg>"#,
        #"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="9" height="9"><image xlink:href="file:///etc/hosts"/></svg>"#,
        #"<svg xmlns="http://www.w3.org/2000/svg" width="9" height="9"><image href="https://example.com/x.png"/></svg>"#,
        #"<svg xmlns="http://www.w3.org/2000/svg" width="9" height="9"><style>@import 'https://example.com/x.css';</style></svg>"#,
        #"<svg xmlns="http://www.w3.org/2000/svg" width="9" height="9"><rect fill="url(http://example.com/x)"/></svg>"#,
    ])
    func hostileSVGsAreRefused(text: String) async throws {
        let dir = try Fixtures.tempDir()
        let file = try svg(text, in: dir)
        let outcome = await ConversionRunner(registry: registry, maxConcurrent: 1).run("image.svg-to-png", on: [try #require(InputFile(url: file))])
        #expect(outcome.outputs.isEmpty, "\(text)")
        #expect(!outcome.failures.isEmpty)
    }

    @Test func aDataPictureAndALocalReferenceAreFine() throws {
        try VectorActions.checkSafe(Data(##"<svg xmlns="http://www.w3.org/2000/svg"><image href="data:image/png;base64,AAAA"/><use href="#a"/><rect fill="url(#g)"/></svg>"##.utf8))
    }

    @Test func corruptSVGFailsPlainly() async throws {
        let dir = try Fixtures.tempDir()
        let file = try svg("<svg this is not xml at all", in: dir)
        let outcome = await ConversionRunner(registry: registry, maxConcurrent: 1).run("image.svg-to-png", on: [try #require(InputFile(url: file))])
        #expect(outcome.outputs.isEmpty && !outcome.failures.isEmpty, "\(outcome.outputs)")
        #expect(Fixtures.leftovers(in: dir).isEmpty)
    }
}


// MARK: - EPUB

@Suite("EPUB")
struct EpubActionTests {
    private let registry = DefaultActions.registry(usage: MemoryUsageStore())

    /// Builds a real EPUB with Frenzy's own zip writer. `chapters` go in spine order, deliberately not name order.
    private func book(in dir: URL, name: String = "book.epub", chapters: [(file: String, html: String)], extra: [(String, String)] = [],
                      opfDirectory: String = "OEBPS", hrefOverride: String? = nil) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let writer = try ZipWriter(creating: url)
        func add(_ path: String, _ text: String) throws {
            let scratch = dir.appendingPathComponent(UUID().uuidString)
            try Data(text.utf8).write(to: scratch)
            defer { try? FileManager.default.removeItem(at: scratch) }
            try writer.addFile(from: scratch, path: path, modified: Date(), permissions: 0o644, compress: true) { _ in }
        }
        try add("mimetype", "application/epub+zip")
        try add("META-INF/container.xml", """
        <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="\(opfDirectory)/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """)
        let items = chapters.enumerated().map { #"<item id="c\#($0.offset)" href="\#(hrefOverride ?? $0.element.file)" media-type="application/xhtml+xml"/>"# }.joined()
        let refs = chapters.indices.map { #"<itemref idref="c\#($0)"/>"# }.joined()
        try add("\(opfDirectory)/content.opf", """
        <?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata/><manifest>\(items)</manifest><spine>\(refs)</spine></package>
        """)
        for chapter in chapters { try add("\(opfDirectory)/\(chapter.file)", chapter.html) }
        for (path, text) in extra { try add(path, text) }
        try writer.finish()
        return url
    }

    private let story = [
        (file: "z-first.xhtml", html: "<html><body><h1>Chapter One</h1><p>It was a dark and <b>stormy</b> night.</p></body></html>"),
        (file: "a-second.xhtml", html: "<html><body><h1>Chapter Two</h1><p>Morning came at last.</p><img src='cover.jpg'/></body></html>"),
    ]

    private func run(_ id: ActionID, _ file: URL) async throws -> ConversionOutcome {
        await ConversionRunner(registry: registry, maxConcurrent: 1).run(id, on: [try #require(InputFile(url: file))])
    }

    @Test func toTextInSpineOrder() async throws {
        let dir = try Fixtures.tempDir()
        let outcome = try await run("document.epub-to-txt", try book(in: dir, chapters: story))
        #expect(outcome.failures.isEmpty, "\(outcome.failures)")
        let text = try String(contentsOf: try #require(outcome.outputs.first), encoding: .utf8)
        let one = try #require(text.range(of: "Chapter One")), two = try #require(text.range(of: "Chapter Two"))
        #expect(one.lowerBound < two.lowerBound, "reading order, not file name order")
        #expect(text.contains("stormy") && text.contains("Morning came"))
        #expect(Fixtures.leftovers(in: dir).isEmpty)
    }

    @Test func toPDF() async throws {
        let dir = try Fixtures.tempDir()
        let outcome = try await run("document.epub-to-pdf", try book(in: dir, chapters: story))
        #expect(outcome.failures.isEmpty, "\(outcome.failures)")
        let output = try #require(outcome.outputs.first)
        let document = try #require(PDFDocument(url: output))
        #expect(document.string?.contains("Morning came") == true)
    }

    @Test func toWord() async throws {
        let dir = try Fixtures.tempDir()
        let outcome = try await run("document.epub-to-docx", try book(in: dir, chapters: story))
        #expect(outcome.failures.isEmpty, "\(outcome.failures)")
        let read = try NSAttributedString(url: try #require(outcome.outputs.first),
                                          options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        #expect(read.string.contains("Chapter Two"))
    }

    @Test func corruptIsRefused() async throws {
        let dir = try Fixtures.tempDir()
        let file = dir.appendingPathComponent("junk.epub")
        var bytes = Data(count: 30_000)
        bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        try bytes.write(to: file)
        let outcome = try await run("document.epub-to-txt", file)
        #expect(outcome.outputs.isEmpty && !outcome.failures.isEmpty)
    }

    @Test func aPlainZipIsNotABook() async throws {
        let dir = try Fixtures.tempDir()
        let zip = try ZipWriter(creating: dir.appendingPathComponent("plain.epub"))
        try zip.finish()
        let outcome = try await run("document.epub-to-txt", dir.appendingPathComponent("plain.epub"))
        #expect(outcome.outputs.isEmpty && !outcome.failures.isEmpty)
    }

    @Test func drmIsRefusedPlainly() async throws {
        let dir = try Fixtures.tempDir()
        let encryption = #"<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#"><CipherData><CipherReference URI="OEBPS/z-first.xhtml"/></CipherData></EncryptedData></encryption>"#
        let outcome = try await run("document.epub-to-txt", try book(in: dir, chapters: story, extra: [("META-INF/encryption.xml", encryption)]))
        #expect(outcome.outputs.isEmpty)
        #expect(outcome.failures.first?.message.contains("copy-protected") == true, "\(outcome.failures)")
    }

    /// Obfuscated fonts aren't DRM: only the chapters count.
    @Test func obfuscatedFontsAreFine() async throws {
        let dir = try Fixtures.tempDir()
        let encryption = #"<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#"><CipherData><CipherReference URI="OEBPS/font.otf"/></CipherData></EncryptedData></encryption>"#
        let outcome = try await run("document.epub-to-txt", try book(in: dir, chapters: story, extra: [("META-INF/encryption.xml", encryption)]))
        #expect(outcome.failures.isEmpty, "\(outcome.failures)")
    }

    @Test func aChapterCantPointOutsideTheBook() async throws {
        let dir = try Fixtures.tempDir()
        let outcome = try await run("document.epub-to-txt", try book(in: dir, chapters: story, hrefOverride: "../../../../etc/hosts"))
        #expect(outcome.outputs.isEmpty && !outcome.failures.isEmpty, "\(outcome.outputs)")
    }
}
