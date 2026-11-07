import CoreGraphics
import Foundation
import HaloCore
import ImageIO
import UniformTypeIdentifiers

/// Image conversions built on ImageIO.
///
/// Behaviour shared by every action:
/// - EXIF orientation is applied to the pixels, and the output's orientation tag is reset to "up", so the result looks
///   the same in every viewer. The colour profile travels with the decoded image and is embedded in the output.
/// - Metadata (EXIF, GPS, IPTC, XMP) is kept by format conversions. "Compress" and "Half Size" make files for sharing,
///   so they drop the location (GPS and XMP/IPTC place fields) and keep the rest. "Strip Info" removes everything but
///   the colour profile (orientation is baked into the pixels, or kept as the only tag for a lossless JPEG).
/// - Images over 250 megapixels are refused before decoding (decompression bombs), see `ImageLimits`.
/// - Multi-image files: HEIC uses its primary image (depth, mattes and gain maps are not copied); GIF uses its first
///   frame, except "Half Size" and "Strip Info" on an animated GIF, which process every frame and keep the animation.
enum ImageActions {
    static var all: [ConversionAction] { actions(engine: MediaEngine.isAvailable) }

    /// `engine: false` leaves out WebP, the one image format only the media engine can write.
    static func actions(engine: Bool) -> [ConversionAction] {
        var actions: [ConversionAction] = []
        // Format conversions. Each lists concrete input types without its own format, so "JPG" never shows for a JPEG.
        let conversions: [(ImageFormat, String, String, String, Int)] = [
            (.jpeg, "JPG", "Compatible", "photo", 1),
            (.png, "PNG", "Lossless", "photo.on.rectangle", 2),
            (.heic, "HEIC", "Small, modern", "photo.stack", 5),
            (.tiff, "TIFF", "Print quality", "photo.artframe", 8),
            (.webp, "WebP", "For the web", "globe", 7),
            (.avif, "AVIF", "Smallest", "sparkles", 11),
        ]
        for (format, title, subtitle, symbol, rank) in conversions where format.isEncodable {
            actions.append(ConversionAction(
                id: ActionID(rawValue: "image.to-\(format == .jpeg ? "jpg" : format.rawValue)"),
                title: title, subtitle: subtitle, symbolName: symbol, category: .image,
                inputTypes: format == .avif ? ImageCodecs.avifInputs : ImageCodecs.inputs(excluding: format), defaultRank: rank,
                converter: ClosureConverter { job in try eachInput(job) { try convert($0, to: format, job: job) } }
            ))
        }
        // macOS reads WebP but can't write it, so the media engine does. If Apple adds an encoder, the loop above takes over.
        if !ImageFormat.webp.isEncodable && engine {
            actions.append(ConversionAction(
                id: "image.to-webp", title: "WebP", subtitle: "For the web", symbolName: "globe", category: .image,
                inputTypes: ImageCodecs.inputs(excluding: .webp), defaultRank: 7,
                converter: ClosureConverter(EngineActions.imageToWebP)))
        }
        actions += VectorActions.all
        let inputs = ImageCodecs.readableInputs
        actions += [
            ConversionAction(
                id: "image.to-pdf", title: "PDF", subtitle: "One per image", symbolName: "doc.richtext",
                category: .image, inputTypes: inputs, defaultRank: 3,
                converter: ClosureConverter { job in try eachInput(job) { try toPDF($0, job: job) } }
            ),
            ConversionAction(
                id: "image.combine-pdf", title: "One PDF", subtitle: "All images", symbolName: "doc.on.doc",
                category: .image, inputTypes: inputs, cardinality: .combined(min: 2), defaultRank: 3,
                converter: ClosureConverter { job in try [combinePDF(job)] }
            ),
            ConversionAction(
                id: "image.compress", title: "Compress", subtitle: "Small, no GPS", symbolName: "rectangle.compress.vertical",
                category: .image, inputTypes: inputs, defaultRank: 4,
                converter: ClosureConverter { job in try eachInput(job) { try compress($0, job: job) } }
            ),
            ConversionAction(
                id: "image.resize-half", title: "Half Size", subtitle: "50%, no GPS", symbolName: "arrow.down.right.and.arrow.up.left",
                category: .image, inputTypes: inputs, defaultRank: 6,
                converter: ClosureConverter { job in try eachInput(job) { try resizeHalf($0, job: job) } }
            ),
            ConversionAction(
                id: "image.strip-metadata", title: "Strip Info", subtitle: "No GPS or EXIF", symbolName: "location.slash",
                category: .image, inputTypes: inputs, defaultRank: 9,
                converter: ClosureConverter { job in try eachInput(job) { try stripMetadata($0, job: job) } }
            ),
        ]
        return actions
    }

    // MARK: Converters

    static let convertQuality: [ImageFormat: Double] = [.jpeg: 0.9, .heic: 0.85, .webp: 0.9, .avif: 0.8]
    static let compressQuality = 0.7

    static func convert(_ input: InputFile, to format: ImageFormat, job: ConversionJob) throws -> URL {
        let file = try ImageFile(url: input.url)
        let image = try file.uprightImage(for: format)
        try Task.checkCancellation()
        let target = try job.makeOutput(for: input, pathExtension: format.pathExtension)
        try ImageWriter.write(image, as: format, to: target.temporaryURL, quality: convertQuality[format],
                              metadata: file.uprightMetadata(width: image.width, height: image.height))
        return try target.commit()
    }

    static func toPDF(_ input: InputFile, job: ConversionJob) throws -> URL {
        let file = try ImageFile(url: input.url)
        let target = try job.makeOutput(for: input, pathExtension: "pdf")
        let writer = try ImagePDFWriter(url: target.temporaryURL, title: input.url.deletingPathExtension().lastPathComponent)
        try writer.addPage(file)
        writer.close()
        return try target.commit()
    }

    static func combinePDF(_ job: ConversionJob) throws -> URL {
        guard let first = job.inputs.first else { throw ConversionError.unsupportedInput("No images were dropped.") }
        let base = first.url.deletingPathExtension().lastPathComponent
        let target = try job.makeOutput(named: "\(base) combined", in: first.url.deletingLastPathComponent(), pathExtension: "pdf")
        let writer = try ImagePDFWriter(url: target.temporaryURL, title: base)
        for (i, input) in job.inputs.enumerated() {
            try Task.checkCancellation()
            try writer.addPage(try ImageFile(url: input.url))
            job.progress(Double(i + 1) / Double(job.inputs.count + 1))
        }
        writer.close()
        return try target.commit()
    }

    static func compress(_ input: InputFile, job: ConversionJob) throws -> URL {
        let file = try ImageFile(url: input.url)
        guard !file.isAnimatedGIF else { throw ConversionError.unsupportedInput("Animated GIFs can't be compressed yet.") }
        let format = compressedFormat(for: file)
        let image = try file.uprightImage(for: format)
        try Task.checkCancellation()
        let target = try job.makeOutput(for: input, pathExtension: format.pathExtension, suffix: "compressed")
        try ImageWriter.write(image, as: format, to: target.temporaryURL, quality: compressQuality,
                              metadata: file.uprightMetadata(width: image.width, height: image.height, dropLocation: true))
        try ensureNoLocation(target.temporaryURL, input: input)
        guard ImageWriter.byteCount(of: target.temporaryURL) < ImageWriter.byteCount(of: input.url) else {
            throw ConversionError.alreadySmall(input.url.lastPathComponent)
        }
        return try target.commit()
    }

    /// Sharing actions promise "no GPS": never commit a file that still says where it was taken.
    static func ensureNoLocation(_ url: URL, input: InputFile) throws {
        guard !ImageMetadataCheck.hasLocation(url) else {
            throw ConversionError.engine("Couldn't remove the location from \(input.url.lastPathComponent).")
        }
    }

    /// Lossy formats stay as they are; lossless ones become JPEG, or HEIC when they have transparency to keep.
    static func compressedFormat(for file: ImageFile) -> ImageFormat {
        if let format = file.format, format.isLossy, format.isEncodable { return format }
        if file.hasAlpha, ImageFormat.heic.isEncodable { return .heic }
        return .jpeg
    }

    static func resizeHalf(_ input: InputFile, job: ConversionJob) throws -> URL {
        let file = try ImageFile(url: input.url)
        let format = file.format.flatMap { $0.isEncodable ? $0 : nil } ?? .png
        let size = file.uprightSize
        let maxPixels = max(1, max(size.width, size.height) / 2)
        let target = try job.makeOutput(for: input, pathExtension: format.pathExtension, suffix: "50%")
        if file.isAnimatedGIF, format == .gif {
            try ImageWriter.checkAnimation(file, scale: 0.5)
            try ImageWriter.writeGIF(from: file, to: target.temporaryURL, progress: job.progress) { i in
                try file.uprightImage(frame: i, maxPixelSize: maxPixels)
            }
        } else {
            let image = try file.uprightImage(maxPixelSize: maxPixels)
            try ImageWriter.write(image, as: format, to: target.temporaryURL, quality: convertQuality[format],
                                  metadata: file.uprightMetadata(width: image.width, height: image.height, dropLocation: true))
        }
        try ensureNoLocation(target.temporaryURL, input: input)
        return try target.commit()
    }

    static func stripMetadata(_ input: InputFile, job: ConversionJob) throws -> URL {
        let file = try ImageFile(url: input.url)
        let format = file.format.flatMap { $0.isEncodable ? $0 : nil } ?? .png
        let target = try job.makeOutput(for: input, pathExtension: format.pathExtension, suffix: "clean")
        let url = target.temporaryURL
        if file.isAnimatedGIF, format == .gif {
            try ImageWriter.checkAnimation(file)
            try ImageWriter.writeGIF(from: file, to: url, progress: job.progress) { try file.lazyImage(frame: $0) }
        } else if format == .jpeg, file.format == .jpeg, losslessJPEGStrip(file, to: url), ImageMetadataCheck.findings(in: url).isEmpty {
            // Clean without re-encoding: the compressed pixels are copied byte for byte.
        } else {
            // Re-encode the decoded pixels with no metadata at all: only the colour profile travels with the image,
            // orientation is baked in, and depth maps, mattes, gain maps and thumbnails are left behind.
            try? FileManager.default.removeItem(at: url)
            try Task.checkCancellation()
            try ImageWriter.write(try file.uprightImage(for: format), as: format, to: url, quality: format.isLossy ? 0.95 : nil, metadata: nil)
        }
        let left = ImageMetadataCheck.findings(in: url)
        guard left.isEmpty else {
            throw ConversionError.engine("Couldn't remove all the info from \(input.url.lastPathComponent).")
        }
        return try target.commit()
    }

    /// Rewrites a JPEG's marker segments without re-encoding (no quality loss), keeping only what decoding needs,
    /// the ICC profile and an orientation tag. Returns false when the file can't be parsed.
    private static func losslessJPEGStrip(_ file: ImageFile, to url: URL) -> Bool {
        guard let data = try? Data(contentsOf: file.url, options: .alwaysMapped),
              let stripped = JPEGStripper.strip(data, orientation: file.orientation) else { return false }
        do { try stripped.write(to: url); return true } catch { return false }
    }

    /// Runs `body` once per input (the runner hands `.each` actions one file at a time).
    static func eachInput(_ job: ConversionJob, _ body: (InputFile) throws -> URL) throws -> [URL] {
        try job.inputs.enumerated().map { i, input in
            try Task.checkCancellation()
            let url = try body(input)
            job.progress(Double(i + 1) / Double(job.inputs.count))
            return url
        }
    }
}
