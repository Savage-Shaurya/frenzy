import AppKit
import Foundation
import HaloCore
@testable import HaloConverters
import PDFKit
import Testing
import UniformTypeIdentifiers

@Suite("Document actions")
struct DocumentActionTests {
    static let marker = "Frenzy quokka marmalade"

    private static func sample() -> NSAttributedString {
        let s = NSMutableAttributedString(string: "Title line\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 20)])
        s.append(NSAttributedString(string: "\(marker) body paragraph with café and ✓ characters.\n",
                                    attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        return s
    }

    /// Writes a fixture of the given kind into a fresh temp dir.
    private func fixture(_ ext: String) throws -> URL {
        let dir = try AVFixtures.tempDir()
        let url = dir.appendingPathComponent("letter.\(ext)")
        let s = Self.sample()
        let range = NSRange(location: 0, length: s.length)
        switch ext {
        case "txt":
            let long = (1...220).map { "Line \($0): \(Self.marker) lorem ipsum dolor sit amet." }.joined(separator: "\n")
            try long.write(to: url, atomically: true, encoding: .utf8)
        case "html":
            let html = """
            <!doctype html><html><head><meta charset="utf-8"><title>T</title>
            <link rel="stylesheet" href="https://example.invalid/x.css"><script>document.write('JS RAN')</script></head>
            <body><h1>Heading</h1><p>\(Self.marker) in <b>HTML</b> — café</p><img src="https://example.invalid/a.png"></body></html>
            """
            try html.write(to: url, atomically: true, encoding: .utf8)
        case "rtf": try s.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: url)
        case "docx": try s.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: url)
        case "doc": try s.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.docFormat]).write(to: url)
        case "odt": try s.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.openDocument]).write(to: url)
        case "rtfd":
            let wrapper = try s.fileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        default: Issue.record("unknown fixture \(ext)")
        }
        return url
    }

    private func type(for ext: String) -> UTType {
        ext == "rtfd" ? .rtfd : UTType(filenameExtension: ext)!
    }

    private func convert(_ id: ActionID, _ ext: String) async throws -> URL {
        let original = try fixture(ext)
        let dir = original.deletingLastPathComponent()
        let before = ext == "rtfd" ? nil : try Data(contentsOf: original)
        let outcome = await AVFixtures.run(id, on: original, type: type(for: ext))
        #expect(outcome.failures.isEmpty, "\(ext): \(outcome.failures.map(\.message))")
        if let before { #expect(try Data(contentsOf: original) == before) }
        #expect(AVFixtures.leftovers(in: dir).isEmpty)
        return try #require(outcome.outputs.first)
    }

    private func read(_ url: URL, _ type: NSAttributedString.DocumentType) throws -> String {
        try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil).string
    }

    @Test(arguments: ["rtf", "txt", "html", "docx", "doc", "odt", "rtfd"])
    func toPDF(_ ext: String) async throws {
        let out = try await convert("document.to-pdf", ext)
        #expect(out.lastPathComponent == "letter.pdf")
        let pdf = try #require(PDFDocument(url: out))
        #expect(pdf.pageCount >= 1)
        let text = pdf.string ?? ""
        #expect(text.contains(Self.marker), "\(ext) PDF text: \(text.prefix(200))")
        let bounds = try #require(pdf.page(at: 0)).bounds(for: .mediaBox)
        #expect([612, 595.28].contains { abs($0 - bounds.width) < 1 })
        if ext == "txt" { #expect(pdf.pageCount >= 3, "220 lines should paginate") }
        if ext == "html" { #expect(!text.contains("JS RAN")) }
    }

    @Test(arguments: ["rtf", "html", "docx", "odt"])
    func toTXT(_ ext: String) async throws {
        let out = try await convert("document.to-txt", ext)
        #expect(out.pathExtension == "txt")
        let text = try String(contentsOf: out, encoding: .utf8)
        #expect(text.contains(Self.marker) && text.contains("café"))
    }

    @Test(arguments: ["txt", "html", "docx", "rtfd"])
    func toRTF(_ ext: String) async throws {
        let out = try await convert("document.to-rtf", ext)
        #expect(out.pathExtension == "rtf")
        #expect(try read(out, .rtf).contains(Self.marker))
    }

    @Test(arguments: ["rtf", "txt", "html", "doc"])
    func toDOCXRoundTrips(_ ext: String) async throws {
        let out = try await convert("document.to-docx", ext)
        #expect(out.pathExtension == "docx")
        let back = try NSAttributedString(url: out, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        #expect(back.string.contains(Self.marker))
        if ext == "rtf" {
            // Formatting survives: the title stays bold.
            let font = back.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        }
    }

    @Test func noSameFormatActions() {
        func ids(_ ext: String) -> Set<String> {
            let file = InputFile(url: URL(fileURLWithPath: "/x/a.\(ext)"), type: type(for: ext))
            return Set(AVFixtures.registry.actions(for: [file], limit: 99).map(\.id.rawValue))
        }
        #expect(ids("txt") == ["document.to-pdf", "document.to-docx", "document.to-rtf"])
        #expect(ids("md") == ["document.to-pdf", "document.to-docx", "document.to-rtf"])
        #expect(ids("rtf") == ["document.to-pdf", "document.to-docx", "document.to-txt"])
        #expect(ids("docx") == ["document.to-pdf", "document.to-txt", "document.to-rtf"])
        #expect(ids("html") == ["document.to-pdf", "document.to-docx", "document.to-txt", "document.to-rtf"])
        #expect(ids("pdf").isEmpty)
    }

    @Test func offlineHTMLStripsRemoteResources() {
        let html = #"<link rel=stylesheet href="https://a/b.css"><img src='http://x/y.png'><div style="background:url(https://q/r.png)">ok</div><script>x()</script><a href="https://keep.me">l</a>"#
        let out = String(decoding: HTMLSanitizer.clean(Data(html.utf8)), as: UTF8.self)
        #expect(!out.contains("https://a") && !out.contains("http://x") && !out.contains("https://q") && !out.contains("<script"))
        // The link target survives only as visible text, never as an attribute.
        #expect(out.contains("<a>l</a> (https://keep.me)"))
        #expect(!out.contains("href"))
    }
}
