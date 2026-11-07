import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import HaloConverters
@testable import HaloCore

@Suite struct PDFSafetyTests {
    @Test func pageCountIsCappedWithAClearError() async throws {
        let dir = try Fixtures.tempDir()
        let input = try Fixtures.writePDF(to: dir.appendingPathComponent("huge.pdf"), pages: PDFSupport.maxPages + 1)
        for id: ActionID in ["pdf.split", "pdf.to-images", "pdf.to-text"] {
            let outcome = await Fixtures.runner().run(id, on: [input])
            #expect(outcome.failures.first?.message.contains("has \(PDFSupport.maxPages + 1) pages") == true, "\(id): \(outcome.failures.map(\.message))")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["huge.pdf"], "no folders or temp files left")
    }

    @Test func degeneratePagesDoNotDivideByZero() async throws {
        let dir = try Fixtures.tempDir()
        let input = try Fixtures.writeZeroSizePagePDF(to: dir.appendingPathComponent("odd.pdf"))
        let document = try #require(PDFDocument(url: input.url))
        let zero = try #require(document.page(at: 1))
        #expect(!PDFSupport.hasUsableSize(zero))
        #expect(throws: ConversionError.engine("Page 2 has no size, so it can't be rendered.")) {
            try PDFSupport.render(zero, scale: 2, pageNumber: 2)
        }
        // To Images refuses with that message and leaves nothing; To Text skips the empty page.
        let images = await Fixtures.runner().run("pdf.to-images", on: [input])
        #expect(images.failures.first?.message == "Page 2 has no size, so it can't be rendered.")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["odd.pdf"])
        let text = try #require(try await Fixtures.run("pdf.to-text", [input]).first)
        #expect(try String(contentsOf: text, encoding: .utf8).contains("Sized page text"))
    }

    @Test func renderIsCappedAt6000Pixels() throws {
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 14_400, height: 7_200), for: .mediaBox)
        let image = try PDFSupport.render(page, scale: 2)
        #expect(image.width == 6_000 && image.height == 3_000)
    }

    @Test func splitAndToImagesProduceOneFolderAndLeaveNothingOnFailure() async throws {
        let dir = try Fixtures.tempDir()
        let locked = try Fixtures.writeLockedPDF(to: dir.appendingPathComponent("secret.pdf"))
        let good = try Fixtures.writePDF(to: dir.appendingPathComponent("ok.pdf"), pages: 2)
        for id: ActionID in ["pdf.split", "pdf.to-images"] {
            let outcome = await Fixtures.runner().run(id, on: [good, locked])
            #expect(outcome.outputs.map(\.lastPathComponent) == ["ok pages"], "\(id): \(outcome.outputs)")
            #expect(outcome.failures.count == 1)
            try FileManager.default.removeItem(at: try #require(outcome.outputs.first))
        }
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)) == ["secret.pdf", "ok.pdf"])
    }

    @Test func mergeAndSplitDropScriptsAndLaunchActions() async throws {
        let dir = try Fixtures.tempDir()
        let scripted = try Fixtures.writeScriptedPDF(to: dir.appendingPathComponent("evil.pdf"))
        let plain = try Fixtures.writePDF(to: dir.appendingPathComponent("plain.pdf"), pages: 1)
        let document = try #require(PDFDocument(url: scripted.url))
        #expect(document.pageCount == 1 && document.page(at: 0)?.annotations.count == 3, "fixture should parse")

        // Control: copying the page with PDFKit alone keeps the scripts, so the check below means something.
        let control = PDFDocument()
        control.insert(try #require(document.page(at: 0)?.copy() as? PDFPage), at: 0)
        let controlURL = dir.appendingPathComponent("control.pdf")
        #expect(control.write(to: controlURL))
        // PDFKit already drops the JavaScript action on copy but turns Launch into a file:// link to the program.
        let controlKeepsScripts = try Fixtures.containsBytes(controlURL, "calc.exe")
        #expect(controlKeepsScripts, "control copy should still point at calc.exe")
        try FileManager.default.removeItem(at: controlURL)

        let merged = try #require(try await Fixtures.run("pdf.merge", [scripted, plain]).first)
        let splitFolder = try #require(try await Fixtures.run("pdf.split", [scripted]).first)
        let split = try Fixtures.folderContents(splitFolder)
        for url in [merged] + split {
            for needle in ["JavaScript", "/JS", "app.alert", "Launch", "calc.exe", "file://"] {
                #expect(!(try Fixtures.containsBytes(url, needle)), "\(url.lastPathComponent) still contains \(needle)")
            }
            // The plain web link survives.
            #expect(try Fixtures.containsBytes(url, "https://example.com/"), "\(url.lastPathComponent) lost the web link")
        }
    }
}
