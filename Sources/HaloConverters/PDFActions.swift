import CoreGraphics
import Foundation
import HaloCore
import PDFKit
import Quartz

/// PDF actions built on PDFKit. Inputs are never modified: documents are loaded, changed in memory and written to a
/// new file.
enum PDFActions {
    static var all: [ConversionAction] {
        [
            ConversionAction(
                id: "pdf.compress", title: "Compress", subtitle: "Smaller file", symbolName: "rectangle.compress.vertical",
                category: .pdf, inputTypes: [.pdf], defaultRank: 1,
                converter: ClosureConverter { job in try ImageActions.eachInput(job) { try compress($0, job: job) } }
            ),
            ConversionAction(
                id: "pdf.merge", title: "Merge", subtitle: "Into one PDF", symbolName: "doc.on.doc",
                category: .pdf, inputTypes: [.pdf], cardinality: .combined(min: 2), defaultRank: 2,
                converter: ClosureConverter { job in try [merge(job)] }
            ),
            ConversionAction(
                id: "pdf.to-images", title: "Images", subtitle: "PNG per page", symbolName: "photo.on.rectangle.angled",
                category: .pdf, inputTypes: [.pdf], defaultRank: 3,
                converter: ClosureConverter { job in try ImageActions.eachInput(job) { try toImages($0, job: job) } }
            ),
            ConversionAction(
                id: "pdf.to-text", title: "To Text", subtitle: "Plain text", symbolName: "doc.plaintext",
                category: .pdf, inputTypes: [.pdf], defaultRank: 4,
                converter: ClosureConverter { job in try ImageActions.eachInput(job) { try toText($0, job: job) } }
            ),
            ConversionAction(
                id: "pdf.split", title: "Split", subtitle: "PDF per page", symbolName: "scissors",
                category: .pdf, inputTypes: [.pdf], defaultRank: 5,
                converter: ClosureConverter { job in try ImageActions.eachInput(job) { try split($0, job: job) } }
            ),
            ConversionAction(
                id: "pdf.rotate-right", title: "Rotate", subtitle: "90° clockwise", symbolName: "rotate.right",
                category: .pdf, inputTypes: [.pdf], defaultRank: 6,
                converter: ClosureConverter { job in try ImageActions.eachInput(job) { try rotateRight($0, job: job) } }
            ),
            PDFToWord.action,
        ]
    }

    // MARK: Compress

    /// Image settings for the Quartz filter: re-sample images above 150 dpi down to 150 dpi and re-encode them as
    /// JPEG at quality 0.6. Text, vector art and fonts are untouched, so text stays sharp and selectable.
    static var compressFilterProperties: [String: Any] { [
        "Name": "Frenzy Compress",
        "FilterType": 1,
        "Domains": ["Applications": true, "Printing": false],
        "FilterData": [
            "ColorSettings": [
                "ImageSettings": [
                    "Compression Quality": 0.6,
                    "ImageCompression": "ImageJPEGCompress",
                    "ImageScaleSettings": [
                        "ImageResolution": 150,
                        "ImageScaleFactor": 0.0,
                        "ImageScaleInterpolate": true,
                        "ImageSizeMax": 0,
                        "ImageSizeMin": 128,
                    ],
                ],
            ],
        ],
    ] }

    static func compress(_ input: InputFile, job: ConversionJob) throws -> URL {
        let document = try PDFSupport.open(input)
        guard let filter = QuartzFilter(properties: compressFilterProperties) else {
            throw ConversionError.engine("PDF compression isn't available on this Mac.")
        }
        job.progress(0.1)
        try Task.checkCancellation()
        let target = try job.makeOutput(for: input, pathExtension: "pdf", suffix: "compressed")
        try PDFSupport.write(document, to: target.temporaryURL, options: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter])
        try Task.checkCancellation()
        guard ImageWriter.byteCount(of: target.temporaryURL) < ImageWriter.byteCount(of: input.url) else {
            throw ConversionError.alreadySmall(input.url.lastPathComponent)
        }
        return try target.commit()
    }

    // MARK: Merge, split, rotate

    /// Pages are copied without JavaScript or Launch actions (see `PDFSupport.removeActiveContent`).
    static func merge(_ job: ConversionJob) throws -> URL {
        guard let first = job.inputs.first else { throw ConversionError.unsupportedInput("No PDFs were dropped.") }
        let merged = PDFDocument()
        for (i, input) in job.inputs.enumerated() {
            try Task.checkCancellation()
            let document = try PDFSupport.open(input)
            for p in 0..<document.pageCount {
                try autoreleasepool {
                    guard let page = document.page(at: p)?.copy() as? PDFPage else { throw ConversionError.unreadable(input.url) }
                    PDFSupport.removeActiveContent(page)
                    merged.insert(page, at: merged.pageCount)
                }
            }
            job.progress(Double(i + 1) / Double(job.inputs.count + 1))
        }
        let target = try job.makeOutput(named: "\(PDFSupport.baseName(first)) merged", in: first.url.deletingLastPathComponent(), pathExtension: "pdf")
        try PDFSupport.write(merged, to: target.temporaryURL)
        return try target.commit()
    }

    /// One PDF per page, all inside a single new "<name> pages" folder (the job's one output). The folder only
    /// appears once every page is written, so a failure or cancellation leaves nothing behind.
    static func split(_ input: InputFile, job: ConversionJob) throws -> URL {
        let document = try PDFSupport.open(input)
        try PDFSupport.checkPageCount(document, input: input)
        let base = PDFSupport.baseName(input)
        let folder = try job.makeOutputFolder(named: "\(base) pages", in: input.url.deletingLastPathComponent())
        for p in 0..<document.pageCount {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let page = document.page(at: p)?.copy() as? PDFPage else { throw ConversionError.unreadable(input.url) }
                PDFSupport.removeActiveContent(page)
                let single = PDFDocument()
                single.insert(page, at: 0)
                try PDFSupport.write(single, to: folder.temporaryURL.appendingPathComponent("\(base) page \(p + 1).pdf"))
            }
            job.progress(Double(p + 1) / Double(document.pageCount + 1))
        }
        return try folder.commit()
    }

    static func rotateRight(_ input: InputFile, job: ConversionJob) throws -> URL {
        let document = try PDFSupport.open(input)
        for p in 0..<document.pageCount {
            guard let page = document.page(at: p) else { continue }
            page.rotation = (page.rotation + 90) % 360
        }
        try Task.checkCancellation()
        let target = try job.makeOutput(for: input, pathExtension: "pdf", suffix: "rotated")
        try PDFSupport.write(document, to: target.temporaryURL)
        return try target.commit()
    }

    // MARK: Images and text

    static let imageScale = 2.0

    /// One PNG per page at 2x, inside a single new "<name> pages" folder, committed once when every page is done.
    static func toImages(_ input: InputFile, job: ConversionJob) throws -> URL {
        let document = try PDFSupport.open(input)
        try PDFSupport.checkPageCount(document, input: input)
        let base = PDFSupport.baseName(input)
        let folder = try job.makeOutputFolder(named: "\(base) pages", in: input.url.deletingLastPathComponent())
        for p in 0..<document.pageCount {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let page = document.page(at: p) else { throw ConversionError.unreadable(input.url) }
                let image = try PDFSupport.render(page, scale: imageScale, pageNumber: p + 1)
                try PDFSupport.writePNG(image, dpi: 72 * imageScale, to: folder.temporaryURL.appendingPathComponent("\(base) page \(p + 1).png"))
            }
            job.progress(Double(p + 1) / Double(document.pageCount + 1))
        }
        return try folder.commit()
    }

    /// Uses the PDF's text layer; pages without one (scans) are rendered and read with on-device OCR.
    static func toText(_ input: InputFile, job: ConversionJob) throws -> URL {
        let document = try PDFSupport.open(input)
        try PDFSupport.checkPageCount(document, input: input)
        var pages: [String] = []
        for p in 0..<document.pageCount {
            try Task.checkCancellation()
            let text: String = try autoreleasepool {
                guard let page = document.page(at: p) else { return "" }
                let layer = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                // Only pages without a text layer (scans) are OCR'd; pages with no size have nothing to read.
                guard layer.isEmpty, PDFSupport.hasUsableSize(page) else { return layer }
                // ~300 dpi for a letter-sized page is plenty for Vision.
                let longest = max(page.bounds(for: .cropBox).width, page.bounds(for: .cropBox).height)
                let scale = min(4, max(1, 3_000 / longest))
                return try OCRRecognizer.recognizeText(in: PDFSupport.render(page, scale: scale, pageNumber: p + 1))
            }
            pages.append(text)
            job.progress(Double(p + 1) / Double(document.pageCount + 1))
        }
        guard pages.contains(where: { !$0.isEmpty }) else {
            throw ConversionError.engine("No text found in \(input.url.lastPathComponent).")
        }
        let target = try job.makeOutput(for: input, pathExtension: "txt")
        try Data((pages.joined(separator: "\n\n") + "\n").utf8).write(to: target.temporaryURL)
        return try target.commit()
    }
}
