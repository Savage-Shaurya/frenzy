import CoreGraphics
import Foundation
import HaloCore
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum PDFSupport {
    /// Opens a PDF for reading, refusing locked or empty ones with a clear message.
    static func open(_ input: InputFile) throws -> PDFDocument {
        guard let document = PDFDocument(url: input.url) else { throw ConversionError.unreadable(input.url) }
        guard !document.isLocked else { throw ConversionError.engine("This PDF is password-protected.") }
        guard document.pageCount > 0 else { throw ConversionError.engine("This PDF has no pages.") }
        return document
    }

    static func write(_ document: PDFDocument, to url: URL, options: [PDFDocumentWriteOption: Any] = [:]) throws {
        guard document.write(to: url, withOptions: options) else {
            throw ConversionError.writeFailed(url, "The PDF couldn't be saved.")
        }
    }

    /// Split, To Images and To Text work page by page; past this many pages they refuse with a clear message
    /// instead of running for a very long time or filling the disk.
    static let maxPages = 2_000

    static func checkPageCount(_ document: PDFDocument, input: InputFile) throws {
        guard document.pageCount <= maxPages else {
            throw ConversionError.engine("\(input.url.lastPathComponent) has \(document.pageCount) pages. Frenzy handles up to \(maxPages) pages for this.")
        }
    }

    /// Longest side of a rendered page, in pixels. 6,000 px is 2x a 36-inch poster side and about 140 MB of RGBA.
    static let maxRenderPixels = 6_000

    /// False for pages whose crop box is empty, negative or not a number (which would divide by zero when scaling).
    static func hasUsableSize(_ page: PDFPage) -> Bool {
        let size = page.bounds(for: .cropBox).size
        return size.width.isFinite && size.height.isFinite && size.width >= 1 && size.height >= 1
    }

    /// Renders a page (with its rotation and annotations) on white at `scale` x its point size,
    /// keeping the longer side at most `maxPixels`.
    static func render(_ page: PDFPage, scale: Double, maxPixels: Int = maxRenderPixels, pageNumber: Int = 1) throws -> CGImage {
        guard hasUsableSize(page), scale.isFinite, scale > 0 else {
            throw ConversionError.engine("Page \(pageNumber) has no size, so it can't be rendered.")
        }
        let bounds = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let pointSize = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let longest = max(pointSize.width, pointSize.height)
        let effectiveScale = min(scale, Double(maxPixels) / longest)
        let width = min(maxPixels, max(1, Int((pointSize.width * effectiveScale).rounded())))
        let height = min(maxPixels, max(1, Int((pointSize.height * effectiveScale).rounded())))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ConversionError.engine("Not enough memory to render this page.")
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: Double(width) / pointSize.width, y: Double(height) / pointSize.height)
        // PDFPage.draw applies the page's rotation and crop-box origin itself.
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { throw ConversionError.engine("Not enough memory to render this page.") }
        return image
    }

    /// Link schemes that may stay on pages copied into a new PDF.
    static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto", "tel"]

    /// Removes active content from a page copied into a new PDF: actions that run JavaScript, launch a program, submit
    /// or import data, play renditions, or open a non-web URL. PDFKit turns a copied Launch action into a `file://`
    /// link to the program, so URL actions are checked by scheme too. Document-level scripts (OpenAction, names tree)
    /// never travel, because pages are inserted into a fresh document.
    static func removeActiveContent(_ page: PDFPage) {
        let blockedTypes: Set<String> = ["JavaScript", "Launch", "ImportData", "Rendition", "SubmitForm", "Movie", "Sound"]
        for annotation in page.annotations {
            guard let action = annotation.action else { continue }
            let url = (action as? PDFActionURL)?.url
            let badURL = url != nil && !allowedLinkSchemes.contains(url?.scheme?.lowercased() ?? "")
            if blockedTypes.contains(action.type) || badURL {
                annotation.action = nil
            }
        }
    }

    /// Writes a rendered page as PNG, tagged with the DPI that keeps its physical size.
    static func writePNG(_ image: CGImage, dpi: Double, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ConversionError.writeFailed(url, "PNG encoding isn't available.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.writeFailed(url, "The image couldn't be encoded.") }
    }

    static func baseName(_ input: InputFile) -> String { input.url.deletingPathExtension().lastPathComponent }
}
