import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import HaloConverters
@testable import HaloCore

@Suite struct PDFActionTests {
    @Test func compressShrinksImagesAndKeepsText() async throws {
        let dir = try Fixtures.tempDir()
        let input = try Fixtures.writePDF(to: dir.appendingPathComponent("scan.pdf"), pages: 2, label: "Invoice", bigImage: true)
        let before = try Fixtures.snapshot([input])
        let output = try #require(try await Fixtures.run("pdf.compress", [input]).first)
        #expect(output.lastPathComponent == "scan (compressed).pdf")
        let original = ImageWriter.byteCount(of: input.url), compressed = ImageWriter.byteCount(of: output)
        #expect(compressed * 4 < original, "expected a big reduction: \(original) -> \(compressed)")
        let doc = try #require(PDFDocument(url: output))
        #expect(doc.pageCount == 2)
        #expect(doc.page(at: 1)?.string?.contains("Invoice page 2") == true, "text layer kept")
        try Fixtures.expectUnchanged(before)
        #expect(Fixtures.leftovers(in: dir).isEmpty)
    }

    @Test func compressRefusesWhenNothingToGain() async throws {
        let dir = try Fixtures.tempDir()
        let input = try Fixtures.writePDF(to: dir.appendingPathComponent("tiny.pdf"), pages: 1)
        let outcome = await Fixtures.runner().run("pdf.compress", on: [input])
        #expect(!outcome.succeeded)
        #expect(outcome.failures.first?.message.contains("already as small") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["tiny.pdf"])
    }

    @Test func mergeKeepsDropOrder() async throws {
        let dir = try Fixtures.tempDir()
        let b = try Fixtures.writePDF(to: dir.appendingPathComponent("b.pdf"), pages: 2, label: "Bee")
        let a = try Fixtures.writePDF(to: dir.appendingPathComponent("a.pdf"), pages: 3, label: "Ay")
        let before = try Fixtures.snapshot([a, b])
        let outcome = await Fixtures.runner().run("pdf.merge", on: [b, a])
        #expect(outcome.succeeded, "\(outcome.failures.map(\.message))")
        let output = try #require(outcome.outputs.first)
        #expect(output.lastPathComponent == "b merged.pdf")
        let doc = try #require(PDFDocument(url: output))
        #expect(doc.pageCount == 5)
        let texts = (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
        #expect(texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ==
                ["Bee page 1", "Bee page 2", "Ay page 1", "Ay page 2", "Ay page 3"])
        try Fixtures.expectUnchanged(before)
        #expect(Fixtures.leftovers(in: dir).isEmpty)
        // Merge needs two files.
        #expect(!(try Fixtures.action("pdf.merge")).accepts([a]))
    }

    @Test func splitMakesOnePDFPerPageInANewFolder() async throws {
        let dir = try Fixtures.tempDir()
        let input = try Fixtures.writePDF(to: dir.appendingPathComponent("report.pdf"), pages: 3, label: "Report")
        let before = try Fixtures.snapshot([input])
        let outputs = try await Fixtures.run("pdf.split", [input])
        // One output: the folder, so the app reveals one item.
        let folder = try #require(outputs.first)
        #expect(outputs.count == 1)
        #expect(folder.lastPathComponent == "report pages")
        let pages = try Fixtures.folderContents(folder)
        #expect(pages.map(\.lastPathComponent) == ["report page 1.pdf", "report page 2.pdf", "report page 3.pdf"])
        for (i, url) in pages.enumerated() {
            let doc = try #require(PDFDocument(url: url))
            #expect(doc.pageCount == 1)
            #expect(doc.page(at: 0)?.string?.contains("Report page \(i + 1)") == true)
        }
        // A second run never reuses the existing folder.
        let again = try await Fixtures.run("pdf.split", [input])
        #expect(again.map(\.lastPathComponent) == ["report pages 2"])
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)) == ["report.pdf", "report pages", "report pages 2"])
        try Fixtures.expectUnchanged(before)
        #expect(Fixtures.leftovers(in: dir).isEmpty)
    }

    @Test func toImagesRendersEveryPageAt2x() async throws {
        let dir = try Fixtures.tempDir()
        let input = try Fixtures.writePDF(to: dir.appendingPathComponent("deck.pdf"), pages: 2)
        let before = try Fixtures.snapshot([input])
        let outputs = try await Fixtures.run("pdf.to-images", [input])
        #expect(outputs.map(\.lastPathComponent) == ["deck pages"])
        let pages = try Fixtures.folderContents(try #require(outputs.first))
        #expect(pages.map(\.lastPathComponent) == ["deck page 1.png", "deck page 2.png"])
        for url in pages {
            let info = try Fixtures.imageInfo(url)
            #expect(UTType(info.type) == .png)
            #expect(info.width == 1224 && info.height == 1584)
        }
        // Background is white, not transparent.
        #expect(Fixtures.pixel(try Fixtures.decode(pages[0]), x: 2, y: 1500) == [255, 255, 255, 255])
        try Fixtures.expectUnchanged(before)
        #expect(Fixtures.leftovers(in: dir).isEmpty)
    }

    @Test func rotateRightTurnsEveryPage() async throws {
        let dir = try Fixtures.tempDir()
        let input = try Fixtures.writePDF(to: dir.appendingPathComponent("form.pdf"), pages: 2)
        let before = try Fixtures.snapshot([input])
        let output = try #require(try await Fixtures.run("pdf.rotate-right", [input]).first)
        #expect(output.lastPathComponent == "form (rotated).pdf")
        let doc = try #require(PDFDocument(url: output))
        #expect(doc.pageCount == 2)
        #expect((0..<2).allSatisfy { doc.page(at: $0)?.rotation == 90 })
        #expect(PDFDocument(url: input.url)?.page(at: 0)?.rotation == 0)
        // Rendering a rotated page gives landscape images.
        let images = try await Fixtures.run("pdf.to-images", [try #require(InputFile(url: output))])
        let folder = try #require(images.first)
        let info = try Fixtures.imageInfo(try #require(try Fixtures.folderContents(folder).first))
        #expect(info.width == 1584 && info.height == 1224)
        try Fixtures.expectUnchanged(before)
    }

    @Test func toTextUsesTextLayerAndOCRsScannedPages() async throws {
        let dir = try Fixtures.tempDir()
        let input = try Fixtures.writePDF(to: dir.appendingPathComponent("mixed.pdf"), pages: 1, label: "Vector", imageOnlyText: "SCANNED RECEIPT")
        let before = try Fixtures.snapshot([input])
        let output = try #require(try await Fixtures.run("pdf.to-text", [input]).first)
        #expect(output.lastPathComponent == "mixed.txt")
        let text = try String(contentsOf: output, encoding: .utf8)
        #expect(text.contains("Vector page 1"))
        #expect(text.uppercased().contains("RECEIPT"), "OCR text missing in: \(text)")
        try Fixtures.expectUnchanged(before)
    }

    @Test func lockedPDFGivesAClearError() async throws {
        let dir = try Fixtures.tempDir()
        let input = try Fixtures.writeLockedPDF(to: dir.appendingPathComponent("secret.pdf"))
        let before = try Fixtures.snapshot([input])
        for id: ActionID in ["pdf.compress", "pdf.to-images", "pdf.split", "pdf.rotate-right", "pdf.to-text"] {
            let outcome = await Fixtures.runner().run(id, on: [input])
            #expect(outcome.failures.first?.message == "This PDF is password-protected.", "\(id)")
            #expect(outcome.outputs.isEmpty)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["secret.pdf"], "no folders or temp files left")
        try Fixtures.expectUnchanged(before)
    }
}
