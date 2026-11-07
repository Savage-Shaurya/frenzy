import CoreGraphics
import Foundation
import HaloCore
import ImageIO
import UniformTypeIdentifiers

// MARK: - Formats

/// An image format Halo can write. Whether it is actually offered depends on `isEncodable`, checked at runtime.
enum ImageFormat: String, CaseIterable, Sendable {
    case jpeg, png, heic, tiff, webp, gif, bmp, avif

    var utType: UTType {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        case .webp: ImageCodecs.webp
        case .gif: .gif
        case .bmp: .bmp
        case .avif: ImageCodecs.avif
        }
    }

    var pathExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .heic: "heic"
        case .tiff: "tiff"
        case .webp: "webp"
        case .gif: "gif"
        case .bmp: "bmp"
        case .avif: "avif"
        }
    }

    /// Whether ImageIO can write this format on this Mac (WebP, for one, is decode-only on macOS).
    var isEncodable: Bool { ImageCodecs.encodable.contains(utType.identifier) }

    /// Formats that can keep an alpha channel. Anything else gets flattened onto white.
    var supportsAlpha: Bool {
        switch self {
        case .jpeg, .bmp: false
        case .png, .heic, .tiff, .webp, .gif, .avif: true
        }
    }

    var isLossy: Bool {
        switch self {
        case .jpeg, .heic, .webp, .avif: true
        case .png, .tiff, .gif, .bmp: false
        }
    }

    /// Input types that already *are* this format, so "convert to this format" must not be offered for them.
    /// HEIF and HEIC are the same container for our purposes.
    var sameFormatTypes: [UTType] {
        switch self {
        case .heic: [.heic, .heif]
        default: [utType]
        }
    }

    /// The format of an input file, if it is one Halo can write back.
    init?(type: UTType) {
        if type.conforms(to: .heic) || type.conforms(to: .heif) { self = .heic; return }
        guard let match = ImageFormat.allCases.first(where: { type.conforms(to: $0.utType) }) else { return nil }
        self = match
    }
}

/// Runtime knowledge of what ImageIO can read and write.
enum ImageCodecs {
    static let webp = UTType("org.webmproject.webp") ?? UTType(importedAs: "org.webmproject.webp")
    static let avif = UTType("public.avif") ?? UTType(importedAs: "public.avif")

    static let encodable: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    static let decodable: Set<String> = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])

    /// Image types we offer actions for. A concrete list rather than `.image`, because `.image` also matches SVG,
    /// icons and other things ImageIO can't (or shouldn't) convert, and because format exclusion needs exact types.
    private static let candidates: [UTType] = [
        .jpeg, .png, .heic, .heif, .tiff, .gif, .bmp, webp,
        UTType("public.avif"), UTType("public.jpeg-xl"), .rawImage,
        UTType("com.adobe.photoshop-image"), UTType("com.microsoft.ico"), UTType("com.apple.icns"),
        UTType("com.truevision.tga-image"), UTType("public.jpeg-2000"),
    ].compactMap { $0 }

    /// Candidate types that ImageIO on this Mac can actually decode.
    static let readableInputs: [UTType] = candidates.filter { candidate in
        decodable.contains { UTType($0)?.conforms(to: candidate) == true }
    }

    /// AVIF is offered for photos only. It has to stay out somewhere: the window holds 12 choices, and a GIF, a PNG (which
    /// gets ICO) or a RAW file already fills them. JPEG and HEIC are also where AVIF's smaller files pay off most.
    static let avifInputs: [UTType] = readableInputs.filter { type in
        [UTType.jpeg, .heic, .heif, .tiff, webp].contains { type.conforms(to: $0) }
    }

    /// Readable inputs minus the ones that are already `format`.
    ///
    /// `ConversionAction.accepts` only checks conformance, so "don't offer JPG for a JPEG" is expressed by listing
    /// concrete input types and leaving out the target format (and anything it conforms to, e.g. HEIF for HEIC).
    static func inputs(excluding format: ImageFormat) -> [UTType] {
        readableInputs.filter { type in
            !format.sameFormatTypes.contains { type.conforms(to: $0) || $0.conforms(to: type) }
        }
    }
}

// MARK: - Limits

/// Guards against decompression bombs: a tiny file can declare 60,000 x 60,000 pixels and make a decoder allocate
/// tens of gigabytes. Sizes come from the file header (cheap) and are checked before any pixels are decoded.
enum ImageLimits {
    /// Largest image Halo decodes, in pixels (250 megapixels is about 1 GB of RGBA).
    static let maxPixels = 250_000_000
    /// Largest total for all frames of an animated GIF. ImageIO's GIF encoder keeps every frame until it finishes.
    static let maxAnimationPixels = 250_000_000

    static func tooLarge(_ url: URL, width: Int, height: Int) -> ConversionError {
        .engine("\(url.lastPathComponent) is too large (\(width) x \(height) pixels). Frenzy handles images up to 250 megapixels.")
    }
}

// MARK: - Reading

/// One decoded-on-demand image file. Opening is cheap; pixels are only decoded when asked for.
struct ImageFile {
    let url: URL
    let source: CGImageSource
    /// The image to use for single-image outputs: the primary image for HEIC, the first frame for GIF.
    let index: Int
    let frameCount: Int
    let properties: [CFString: Any]
    let orientation: CGImagePropertyOrientation
    /// Stored pixel size (before applying orientation).
    let pixelWidth: Int
    let pixelHeight: Int

    init(url: URL) throws {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(source) > 0 else { throw ConversionError.unreadable(url) }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let props = (CGImageSourceCopyPropertiesAtIndex(source, index, options) as? [CFString: Any]) ?? [:]
        guard let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw ConversionError.unreadable(url) }
        self.url = url
        self.source = source
        self.index = index
        self.frameCount = CGImageSourceGetCount(source)
        self.properties = props
        self.orientation = (props[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init) ?? .up
        self.pixelWidth = width
        self.pixelHeight = height
    }

    /// The format this file is in, if Halo can write it back.
    var format: ImageFormat? {
        (CGImageSourceGetType(source) as String?).flatMap(UTType.init).flatMap(ImageFormat.init(type:))
    }

    var isAnimatedGIF: Bool { format == .gif && frameCount > 1 }

    /// Size after applying the EXIF orientation.
    var uprightSize: (width: Int, height: Int) {
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored: (pixelHeight, pixelWidth)
        default: (pixelWidth, pixelHeight)
        }
    }

    var hasAlpha: Bool { (properties[kCGImagePropertyHasAlpha] as? Bool) ?? false }

    /// Throws a clear error when decoding this image would need too much memory.
    func checkDecodable() throws {
        let (area, overflow) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        guard !overflow, area <= ImageLimits.maxPixels else {
            throw ImageLimits.tooLarge(url, width: pixelWidth, height: pixelHeight)
        }
    }

    /// Size of frame `i` from its header (frames of a GIF can differ from the first one).
    func pixelSize(frame i: Int) -> (width: Int, height: Int) {
        guard i != index else { return (pixelWidth, pixelHeight) }
        let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
        return (props?[kCGImagePropertyPixelWidth] as? Int ?? pixelWidth, props?[kCGImagePropertyPixelHeight] as? Int ?? pixelHeight)
    }

    /// Dots per inch from the file, or 72 when it doesn't say.
    var dpi: Double {
        let value = (properties[kCGImagePropertyDPIWidth] as? Double) ?? 0
        return value > 1 ? value : 72
    }

    /// The image with its EXIF orientation applied to the pixels, optionally downsampled so its longer side is at most
    /// `maxPixelSize`. Downsampling goes through the thumbnail API, which never decodes the full-size image when the
    /// format allows it (JPEG, HEIC), so halving a 100-megapixel photo stays cheap. Images over `ImageLimits.maxPixels`
    /// are refused before decoding: PNG and TIFF thumbnails decode the whole image first.
    func uprightImage(frame: Int? = nil, maxPixelSize: Int? = nil) throws -> CGImage {
        try checkDecodable()
        let frame = frame ?? index
        let longest = max(pixelWidth, pixelHeight)
        if orientation == .up, maxPixelSize == nil || maxPixelSize! >= longest {
            return try lazyImage(frame: frame)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(maxPixelSize ?? longest, longest)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, frame, options as CFDictionary) else {
            throw ConversionError.unreadable(url)
        }
        return image
    }

    /// The stored image, not decoded until something draws or encodes it (and then not cached), so writing it
    /// streams through ImageIO without an extra full-size copy in Halo.
    func lazyImage(frame: Int? = nil) throws -> CGImage {
        try checkDecodable()
        guard let image = CGImageSourceCreateImageAtIndex(source, frame ?? index, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ConversionError.unreadable(url)
        }
        return image
    }

    /// The full-size upright image ready for `format`: one decode, at most one full-size bitmap. Orientation and
    /// flattening onto white (for formats without alpha) happen in a single draw instead of two copies.
    func uprightImage(for format: ImageFormat) throws -> CGImage {
        let stored = try lazyImage()
        let needsFlatten = !format.supportsAlpha && ImageWriter.hasAlpha(stored)
        if !needsFlatten { return orientation == .up ? stored : try uprightImage() }
        return try ImageWriter.flattened(stored, orientation: orientation)
    }

    /// The file's metadata (EXIF, IPTC, GPS, XMP...) adjusted for an upright image of `width` x `height`:
    /// orientation reset to "up" and the EXIF pixel dimensions updated.
    /// With `dropLocation`, GPS and every XMP/IPTC location field are removed (used by sharing actions).
    func uprightMetadata(width: Int, height: Int, dropLocation: Bool = false) -> CGImageMetadata? {
        guard let original = CGImageSourceCopyMetadataAtIndex(source, index, nil),
              let metadata = CGImageMetadataCreateMutableCopy(original) else { return nil }
        if dropLocation { ImageMetadataCheck.removeLocation(from: metadata) }
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, 1 as CFNumber)
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelXDimension, width as CFNumber)
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelYDimension, height as CFNumber)
        return metadata
    }

    /// Per-frame GIF properties (delay time) for frame `i`.
    func gifFrameProperties(_ i: Int) -> [CFString: Any] {
        let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
        guard let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return [:] }
        var kept: [CFString: Any] = [:]
        for key in [kCGImagePropertyGIFDelayTime, kCGImagePropertyGIFUnclampedDelayTime] { kept[key] = gif[key] }
        return [kCGImagePropertyGIFDictionary: kept]
    }

    /// File-level GIF properties (loop count).
    var gifFileProperties: [CFString: Any] {
        let props = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        guard let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return [:] }
        return [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: gif[kCGImagePropertyGIFLoopCount] ?? 0]]
    }
}

// MARK: - Writing

enum ImageWriter {
    /// Writes one image. Alpha is flattened onto white for formats without transparency.
    static func write(_ image: CGImage, as format: ImageFormat, to url: URL, quality: Double? = nil, metadata: CGImageMetadata? = nil) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw ConversionError.writeFailed(url, "This Mac can't write \(format.pathExtension.uppercased()) images.")
        }
        let prepared = format.supportsAlpha ? image : try flattened(image)
        var options: [CFString: Any] = [:]
        if let quality, format.isLossy { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImageAndMetadata(destination, prepared, metadata, options as CFDictionary)
        // HEIC and AVIF can reach the hardware encoder: one encode at a time, and never next to another app's session
        // (Apple FB23045975, see HardwareEncodeGate.swift).
        if HardwareImageEncode.needsGate(format), HardwareImageEncode.blockedInTests {
            throw ConversionError.engine(HardwareImageEncode.testBlockMessage)
        }
        let finished = try HardwareImageEncode.run(format) { CGImageDestinationFinalize(destination) }
        guard finished else { throw ConversionError.writeFailed(url, "The image couldn't be encoded.") }
    }

    /// Writes every frame of an animated GIF, keeping per-frame delays and the loop count and nothing else.
    /// Frames are produced one at a time by `frame` (inside an autorelease pool), so Halo never holds more than one.
    /// ImageIO's GIF encoder itself keeps the frames until `Finalize`, hence `ImageLimits.maxAnimationPixels`.
    static func writeGIF(from file: ImageFile, to url: URL, progress: (Double) -> Void = { _ in },
                         frame: (Int) throws -> CGImage) throws {
        let count = file.frameCount
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw ConversionError.writeFailed(url, "This Mac can't write GIF images.")
        }
        CGImageDestinationSetProperties(destination, file.gifFileProperties as CFDictionary)
        for i in 0..<count {
            try Task.checkCancellation()
            try autoreleasepool {
                CGImageDestinationAddImage(destination, try frame(i), file.gifFrameProperties(i) as CFDictionary)
            }
            progress(Double(i + 1) / Double(count + 1))
        }
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.writeFailed(url, "The GIF couldn't be encoded.") }
    }

    /// Throws when the frames of an animated GIF, at `scale` of their size, add up to too many pixels.
    static func checkAnimation(_ file: ImageFile, scale: Double = 1, limit: Int = ImageLimits.maxAnimationPixels) throws {
        var total = 0.0
        for i in 0..<file.frameCount {
            let size = file.pixelSize(frame: i)
            total += Double(size.width) * Double(size.height) * scale * scale
        }
        guard total <= Double(limit) else {
            throw ConversionError.engine("\(file.url.lastPathComponent) has too many frames to process (\(file.frameCount) frames of \(file.pixelWidth) x \(file.pixelHeight)).")
        }
    }

    /// Encodes `image` to in-memory JPEG data (used to embed photos in PDFs compactly).
    static func jpegData(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ConversionError.engine("JPEG encoding isn't available.")
        }
        CGImageDestinationAddImage(destination, try flattened(image), [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.engine("The image couldn't be encoded.") }
        return data as Data
    }

    /// File size in bytes, or 0 if unknown.
    static func byteCount(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// Composites an image with transparency onto white, keeping its colour space when that is RGB. With an
    /// `orientation`, the stored image is turned upright in the same draw (one bitmap instead of two).
    static func flattened(_ image: CGImage, orientation: CGImagePropertyOrientation = .up) throws -> CGImage {
        guard hasAlpha(image) || orientation != .up else { return image }
        let w = image.width, h = image.height
        let swaps = [.left, .leftMirrored, .right, .rightMirrored].contains(orientation)
        let (outW, outH) = swaps ? (h, w) : (w, h)
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ConversionError.engine("Not enough memory to process this image.")
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
        context.concatenate(uprightTransform(orientation, width: Double(w), height: Double(h)))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let result = context.makeImage() else { throw ConversionError.engine("Not enough memory to process this image.") }
        return result
    }

    /// Maps a stored image drawn at (0, 0, width, height) onto an upright canvas, in Core Graphics' bottom-left
    /// coordinates. Matches what ImageIO's `kCGImageSourceCreateThumbnailWithTransform` does (tested for all 8).
    static func uprightTransform(_ orientation: CGImagePropertyOrientation, width w: Double, height h: Double) -> CGAffineTransform {
        switch orientation {
        case .up: .identity
        case .upMirrored: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case .down: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case .downMirrored: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case .leftMirrored: CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case .right: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case .rightMirrored: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .left: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        }
    }
}
