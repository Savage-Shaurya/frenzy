import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import HaloConverters
@testable import HaloCore

@Suite struct TextActionTests {
    @Test func ocrFindsKnownWords() async throws {
        let dir = try Fixtures.tempDir()
        let input = try Fixtures.writeImage(Fixtures.textImage("HALO INVOICE 2026"), to: dir.appendingPathComponent("note.png"), type: .png)
        let before = try Fixtures.snapshot([input])
        let outcome = await Fixtures.runner().run("text.ocr-image", on: [input])
        #expect(outcome.succeeded, "\(outcome.failures.map(\.message))")
        let output = try #require(outcome.outputs.first)
        #expect(output.lastPathComponent == "note.txt")
        let text = try String(contentsOf: output, encoding: .utf8)
        #expect(text.uppercased().contains("INVOICE"), "got: \(text)")
        try Fixtures.expectUnchanged(before)
        #expect(Fixtures.leftovers(in: dir).isEmpty)
    }

    @Test func ocrOnRotatedPhotoAppliesOrientation() async throws {
        let dir = try Fixtures.tempDir()
        // Store the text rotated 90° counter-clockwise and tag orientation 6, so it only reads correctly upright.
        let upright = Fixtures.textImage("ORBIT SAMPLE")
        let ctx = CGContext(data: nil, width: upright.height, height: upright.width, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.translateBy(x: CGFloat(upright.height), y: 0)
        ctx.rotate(by: .pi / 2)
        ctx.draw(upright, in: CGRect(x: 0, y: 0, width: upright.width, height: upright.height))
        let input = try Fixtures.writeImage(ctx.makeImage()!, to: dir.appendingPathComponent("rotated.jpg"), type: .jpeg, orientation: 6)
        let output = try #require(try await Fixtures.run("text.ocr-image", [input]).first)
        let text = try String(contentsOf: output, encoding: .utf8)
        #expect(text.uppercased().contains("SAMPLE"), "got: \(text)")
    }

    @Test func blankImageFailsCleanly() async throws {
        let dir = try Fixtures.tempDir()
        let input = try Fixtures.writeImage(Fixtures.image(width: 200, height: 200, splitColors: true), to: dir.appendingPathComponent("blank.png"), type: .png)
        let outcome = await Fixtures.runner().run("text.ocr-image", on: [input])
        #expect(!outcome.succeeded)
        #expect(outcome.failures.first?.message.contains("No text found") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["blank.png"])
    }

    @Test func linesAreOrderedTopToBottom() {
        let lines: [(box: CGRect, text: String)] = [
            (CGRect(x: 0.5, y: 0.8, width: 0.2, height: 0.05), "top right"),
            (CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05), "bottom"),
            (CGRect(x: 0.1, y: 0.81, width: 0.2, height: 0.05), "top left"),
        ]
        #expect(OCRRecognizer.orderedLines(lines) == ["top left", "top right", "bottom"])
    }

    /// B overlaps both A and C vertically but A and C don't overlap: a pairwise comparator is not a strict weak
    /// ordering here, so the old sort could give different answers for different input orders.
    @Test func lineOrderIsDeterministicForAnyInputOrder() {
        let a = (box: CGRect(x: 0.6, y: 0.48, width: 0.2, height: 0.04), text: "A")
        let b = (box: CGRect(x: 0.1, y: 0.465, width: 0.2, height: 0.04), text: "B")
        let c = (box: CGRect(x: 0.3, y: 0.45, width: 0.2, height: 0.04), text: "C")
        let d = (box: CGRect(x: 0.1, y: 0.10, width: 0.2, height: 0.04), text: "D")
        let all = [a, b, c, d]
        var results: Set<[String]> = []
        func permute(_ items: [(box: CGRect, text: String)], _ chosen: [(box: CGRect, text: String)]) {
            if items.isEmpty { results.insert(OCRRecognizer.orderedLines(chosen)); return }
            for i in items.indices {
                var rest = items
                let item = rest.remove(at: i)
                permute(rest, chosen + [item])
            }
        }
        permute(all, [])
        #expect(results.count == 1, "\(results)")
        // Row 1 is anchored on A (top): B is within half a line height of A, C isn't, so C starts row 2.
        #expect(results.first == ["B", "A", "C", "D"])
    }
}
