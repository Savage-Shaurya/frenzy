import CoreGraphics
import Foundation
import HaloCore
import ImageIO
import UniformTypeIdentifiers

/// Builds a PDF with one page per image, each page sized to the image's physical size (pixels at its DPI).
///
/// Photos are embedded as JPEG (Quartz passes JPEG data straight into the PDF, so an existing JPEG is stored
/// byte-for-byte and HEIC/RAW photos are stored at quality 0.9). Lossless sources (PNG, TIFF, GIF, BMP) and
/// anything with transparency are embedded losslessly so screenshots and line art stay crisp.
final class ImagePDFWriter {
    /// PDF pages can't exceed 200 inches (14,400 points) on a side.
    private static let maxPagePoints: Double = 14_400

    private let url: URL
    private let context: CGContext
    private var closed = false

    init(url: URL, title: String) throws {
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Frenzy"]
        guard let context = CGContext(url as CFURL, mediaBox: nil, info as CFDictionary) else {
            throw ConversionError.writeFailed(url, "The PDF couldn't be created.")
        }
        self.url = url
        self.context = context
    }

    deinit { close() }

    func addPage(_ file: ImageFile) throws {
        try file.checkDecodable()
        let image = try Self.embeddableImage(file)
        var scale = 72 / file.dpi
        let longest = Double(max(image.width, image.height)) * scale
        if longest > Self.maxPagePoints { scale *= Self.maxPagePoints / longest }
        var box = CGRect(x: 0, y: 0, width: Double(image.width) * scale, height: Double(image.height) * scale)
        let boxData = withUnsafeBytes(of: &box) { Data($0) }
        context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
        context.interpolationQuality = .high
        context.draw(image, in: box)
        context.endPDFPage()
    }

    func close() {
        guard !closed else { return }
        closed = true
        context.closePDF()
    }

    private static func embeddableImage(_ file: ImageFile) throws -> CGImage {
        let lossless: Set<ImageFormat> = [.png, .tiff, .gif, .bmp]
        let sourceType = (CGImageSourceGetType(file.source) as String?).flatMap(UTType.init)
        // An upright JPEG goes in untouched (Quartz embeds its DCT data directly).
        if file.orientation == .up, sourceType?.conforms(to: .jpeg) == true,
           let image = CGImageSourceCreateImageAtIndex(file.source, file.index, nil) {
            return image
        }
        let upright = try file.uprightImage()
        if let format = file.format, lossless.contains(format) { return upright }
        if ImageWriter.hasAlpha(upright) { return upright }
        let jpeg = try ImageWriter.jpegData(upright, quality: 0.9)
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return upright }
        return image
    }
}
