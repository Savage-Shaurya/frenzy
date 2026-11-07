import AppKit
import CoreGraphics
import Foundation
import HaloCore
import ImageIO
import UniformTypeIdentifiers

/// SVG in, and ICO out, on Apple's frameworks. ImageIO doesn't read SVG, but AppKit's `NSImage` does (macOS's own CoreSVG).
///
/// A hostile SVG is refused before parsing if it pulls in anything from outside (other files, the web) or declares
/// entities, the classic "billion laughs" bomb. The size of the result is capped however big the SVG says it is.
enum VectorActions {
    static let svg = UTType("public.svg-image") ?? UTType(importedAs: "public.svg-image")
    private static let ico = "com.microsoft.ico"

    /// Fits this many pixels on the long side, whatever the file declares.
    static let maxEdge = 4_096.0
    /// SVGs are usually small drawings; rendered this much larger than their declared size so the result is sharp.
    static let renderScale = 2.0
    static let maxBytes = 20_000_000
    static let icoEdge = 256

    static var all: [ConversionAction] {
        var actions = [
            ConversionAction(
                id: "image.svg-to-png", title: "PNG", subtitle: "Sharp, 2x", symbolName: "photo.on.rectangle",
                category: .image, inputTypes: [svg], defaultRank: 1,
                converter: ClosureConverter { job in try ImageActions.eachInput(job) { try toPNG($0, job: job) } }),
            ConversionAction(
                id: "image.svg-to-jpg", title: "JPG", subtitle: "On white", symbolName: "photo",
                category: .image, inputTypes: [svg], defaultRank: 2,
                converter: ClosureConverter { job in try ImageActions.eachInput(job) { try toJPEG($0, job: job) } }),
            ConversionAction(
                id: "image.svg-to-pdf", title: "PDF", subtitle: "Stays vector", symbolName: "doc.richtext",
                category: .image, inputTypes: [svg], defaultRank: 3,
                converter: ClosureConverter { job in try ImageActions.eachInput(job) { try toPDF($0, job: job) } }),
        ]
        if ImageCodecs.encodable.contains(ico) {
            actions.append(ConversionAction(
                id: "image.to-ico", title: "ICO", subtitle: "256 px icon", symbolName: "app.dashed",
                // PNG and SVG only: an icon is made from artwork, not from a photo, and every extra choice crowds the ring.
                category: .image, inputTypes: [.png, svg], defaultRank: 12,
                converter: ClosureConverter { job in try ImageActions.eachInput(job) { try toICO($0, job: job) } }))
        }
        return actions
    }

    // MARK: Reading

    static func open(_ input: InputFile) throws -> NSImage {
        let url = input.url
        let bytes = AVSupport.fileSize(url)
        guard bytes <= maxBytes else { throw DocumentSupport.tooLarge("SVG files", maxBytes) }
        let raw: Data
        do { raw = try Data(contentsOf: url) } catch { throw ConversionError.unreadable(url) }
        let data = try sanitized(raw)
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw ConversionError.unsupportedInput("It looks damaged, or isn't really an SVG.")
        }
        return image
    }

    /// Refuses anything that reaches outside the file. A `data:` picture or a same-file `#reference` stays fine.
    static func checkSafe(_ data: Data) throws { _ = try SVGGuard.sanitized(data) }

    /// The bytes CoreSVG may see, or a refusal. See `SVGGuard`.
    static func sanitized(_ data: Data) throws -> Data { try SVGGuard.sanitized(data) }

    /// The image's pixel size at `scale`, fitted to the cap.
    static func pixelSize(of image: NSImage, scale: Double = renderScale, edge: Double = maxEdge) -> (width: Int, height: Int) {
        let width = Double(image.size.width), height = Double(image.size.height)
        let fit = min(scale, edge / max(width, height))
        return (max(1, Int((width * fit).rounded())), max(1, Int((height * fit).rounded())))
    }

    /// Draws into an 8-bit sRGB bitmap, `background` first if there is one.
    static func render(_ image: NSImage, width: Int, height: Int, background: CGColor? = nil) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError.engine("Couldn't draw this SVG.")
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if let background {
            context.setFillColor(background)
            context.fill(rect)
        }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: rect)
        NSGraphicsContext.current = previous
        guard let result = context.makeImage() else { throw ConversionError.engine("Couldn't draw this SVG.") }
        return result
    }

    // MARK: Converters

    static func toPNG(_ input: InputFile, job: ConversionJob) throws -> URL {
        let image = try open(input)
        let size = pixelSize(of: image)
        let rendered = try render(image, width: size.width, height: size.height)
        try Task.checkCancellation()
        let target = try job.makeOutput(for: input, pathExtension: "png")
        try ImageWriter.write(rendered, as: .png, to: target.temporaryURL)
        return try target.commit()
    }

    static func toJPEG(_ input: InputFile, job: ConversionJob) throws -> URL {
        let image = try open(input)
        let size = pixelSize(of: image)
        let rendered = try render(image, width: size.width, height: size.height, background: CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        try Task.checkCancellation()
        let target = try job.makeOutput(for: input, pathExtension: "jpg")
        try ImageWriter.write(rendered, as: .jpeg, to: target.temporaryURL, quality: ImageActions.convertQuality[.jpeg])
        return try target.commit()
    }

    /// One page the size the SVG declares (in points), drawn as vectors.
    static func toPDF(_ input: InputFile, job: ConversionJob) throws -> URL {
        let image = try open(input)
        let target = try job.makeOutput(for: input, pathExtension: "pdf")
        var box = CGRect(origin: .zero, size: image.size)
        guard let context = CGContext(target.temporaryURL as CFURL, mediaBox: &box, nil) else {
            throw ConversionError.writeFailed(target.temporaryURL, "Couldn't create the PDF.")
        }
        context.beginPDFPage(nil)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: box)
        NSGraphicsContext.current = previous
        context.endPDFPage()
        context.closePDF()
        return try target.commit()
    }

    /// A 256 x 256 ICO, the size every browser and Windows version reads, with the artwork centred on a transparent square.
    static func toICO(_ input: InputFile, job: ConversionJob) throws -> URL {
        let artwork: CGImage
        if input.type.conforms(to: svg) {
            let image = try open(input)
            let size = pixelSize(of: image, scale: 64, edge: Double(icoEdge))
            artwork = try render(image, width: size.width, height: size.height)
        } else {
            artwork = try ImageFile(url: input.url).uprightImage(maxPixelSize: icoEdge)
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: icoEdge, height: icoEdge, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError.engine("Couldn't draw this icon.")
        }
        let longest = max(artwork.width, artwork.height)
        let fit = Double(icoEdge) / Double(longest)
        let width = Double(artwork.width) * fit, height = Double(artwork.height) * fit
        context.interpolationQuality = .high
        context.draw(artwork, in: CGRect(x: (Double(icoEdge) - width) / 2, y: (Double(icoEdge) - height) / 2, width: width, height: height))
        guard let square = context.makeImage() else { throw ConversionError.engine("Couldn't draw this icon.") }
        try Task.checkCancellation()

        let target = try job.makeOutput(for: input, pathExtension: "ico")
        guard let destination = CGImageDestinationCreateWithURL(target.temporaryURL as CFURL, ico as CFString, 1, nil) else {
            throw ConversionError.writeFailed(target.temporaryURL, "This Mac can't write icons.")
        }
        CGImageDestinationAddImage(destination, square, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.writeFailed(target.temporaryURL, "The icon couldn't be encoded.")
        }
        return try target.commit()
    }
}
