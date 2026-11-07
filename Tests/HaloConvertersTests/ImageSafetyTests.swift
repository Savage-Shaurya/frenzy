import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HaloConverters
@testable import HaloCore

@Suite struct ImageSafetyTests {
    /// Decoding either bomb for real would need 3.6 GB (grey) to 14 GB (RGBA). Each action must refuse from the header.
    @Test func decompressionBombsFailFastWithLowMemory() async throws {
        let dir = try Fixtures.tempDir()
        let png = try Fixtures.writePNGBomb(to: dir.appendingPathComponent("bomb.png"), width: 60_000, height: 60_000)
        let tiff = try Fixtures.writeTIFFBomb(to: dir.appendingPathComponent("bomb.tiff"), size: 60_000)
        #expect(ImageWriter.byteCount(of: png.url) < 500_000 && ImageWriter.byteCount(of: tiff.url) == 300)
        for bomb in [png, tiff] {
            let file = try ImageFile(url: bomb.url)
            #expect(file.pixelWidth == 60_000 && file.pixelHeight == 60_000, "ImageIO should report the declared size")
        }
        let runner = Fixtures.runner()
        let memoryBefore = Fixtures.peakMemoryMB()
        let start = Date()
        let actions: [ActionID] = ["image.to-jpg", "image.to-heic", "image.compress", "image.resize-half",
                                   "image.strip-metadata", "image.to-pdf", "text.ocr-image"]
        for bomb in [png, tiff] {
            for id in actions {
                let outcome = await runner.run(id, on: [bomb])
                #expect(!outcome.succeeded, "\(id) accepted \(bomb.url.lastPathComponent)")
                let message = outcome.failures.first?.message ?? ""
                #expect(message.contains("too large") && message.contains("60000 x 60000"), "\(id): \(message)")
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        let grew = Fixtures.peakMemoryMB() - memoryBefore
        // Peak memory and elapsed time are per process, so other suites running in parallel add to them. Decoding
        // one of these would need about 14 GB, so 3 GB still catches a real decode.
        #expect(elapsed < 30, "took \(elapsed)s")
        #expect(grew < 3_000, "peak memory grew by \(grew) MB")
        print("bomb test: 14 refusals in \(String(format: "%.3f", elapsed))s, peak memory \(memoryBefore) -> \(Fixtures.peakMemoryMB()) MB")
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)) == ["bomb.png", "bomb.tiff"])
    }

    /// ImageIO's GIF encoder keeps every frame until it finishes, so the total frame area of an animation is capped.
    /// (ImageIO won't even report the size of a header-only GIF, so the cap is exercised with a small limit.)
    @Test func animationFrameBudgetIsEnforced() throws {
        let dir = try Fixtures.tempDir()
        let input = try Fixtures.writeGIF(to: dir.appendingPathComponent("anim.gif"), frames: 10, width: 100, height: 100)
        let file = try ImageFile(url: input.url)
        #expect(throws: Never.self) { try ImageWriter.checkAnimation(file, limit: 100_000) }
        #expect(throws: ConversionError.self) { try ImageWriter.checkAnimation(file, limit: 99_999) }
        #expect(throws: Never.self) { try ImageWriter.checkAnimation(file, scale: 0.5, limit: 25_000) }
    }

    /// The single-draw orient + flatten path must match ImageIO's own orientation transform for all 8 orientations.
    @Test(arguments: 1...8)
    func flattenWithOrientationMatchesImageIO(_ orientation: Int) throws {
        let dir = try Fixtures.tempDir()
        // 40 x 20 with four coloured quadrants.
        let ctx = try #require(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for (rect, color) in [(CGRect(x: 0, y: 10, width: 20, height: 10), (1.0, 0.0, 0.0)), (CGRect(x: 20, y: 10, width: 20, height: 10), (0.0, 1.0, 0.0)),
                              (CGRect(x: 0, y: 0, width: 20, height: 10), (0.0, 0.0, 1.0)), (CGRect(x: 20, y: 0, width: 20, height: 10), (1.0, 1.0, 0.0))] {
            ctx.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
            ctx.fill(rect)
        }
        let input = try Fixtures.writeImage(try #require(ctx.makeImage()), to: dir.appendingPathComponent("q.png"), type: .png, orientation: orientation)
        let file = try ImageFile(url: input.url)
        let expected = try file.uprightImage()
        let actual = try ImageWriter.flattened(try file.lazyImage(), orientation: file.orientation)
        #expect(actual.width == expected.width && actual.height == expected.height)
        for (fx, fy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
            let x = Int(Double(expected.width) * fx), y = Int(Double(expected.height) * fy)
            #expect(Fixtures.pixel(actual, x: x, y: y) == Fixtures.pixel(expected, x: x, y: y), "orientation \(orientation) at \(fx),\(fy)")
        }
    }

    @Test func rotatedTransparentPNGToJPGIsUprightAndOnWhite() async throws {
        let dir = try Fixtures.tempDir()
        // Stored 200 x 100 with a transparent left quarter; orientation 6 turns it so that quarter ends up on top.
        let input = try Fixtures.writeImage(Fixtures.image(width: 200, height: 100, alpha: true), to: dir.appendingPathComponent("r.png"),
                                            type: .png, orientation: 6)
        let output = try #require(try await Fixtures.run("image.to-jpg", [input]).first)
        let info = try Fixtures.imageInfo(output)
        #expect(info.width == 100 && info.height == 200)
        let top = Fixtures.pixel(try Fixtures.decode(output), x: 50, y: 10)
        #expect(top[0] > 240 && top[1] > 240 && top[2] > 240, "transparent area should be white, got \(top)")
    }

    @Test func halfSizeGIFKeepsEveryFrameDelay() async throws {
        let dir = try Fixtures.tempDir()
        let input = try Fixtures.writeGIF(to: dir.appendingPathComponent("anim.gif"), frames: 5, width: 80, height: 60)
        let output = try #require(try await Fixtures.run("image.resize-half", [input]).first)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 5)
        for i in 0..<5 {
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            #expect((gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0) > 0.05)
            #expect(props?[kCGImagePropertyPixelWidth] as? Int == 40)
        }
    }
}
