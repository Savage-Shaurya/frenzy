import AppKit
import CoreGraphics
import Foundation
import HaloCore
import UniformTypeIdentifiers

/// Reading text documents into `NSAttributedString` and rendering them to paginated PDF with TextKit 1.
///
/// Threading: RTF/RTFD/DOCX/DOC/ODT/plain-text import and the layout/PDF drawing run on `DocumentWorker`'s
/// dedicated serial queue (not the cooperative pool), each conversion with its own text system objects, and poll a
/// cancellation flag. HTML import needs the main thread (it goes through WebKit and spins a nested run loop); those
/// imports are serialized through `HTMLImportGate`, use a short timeout, and only ever see sanitized markup with no
/// resource references and no base URL, so there is nothing for WebKit to fetch.
enum DocumentSupport {
    static let docx = UTType("org.openxmlformats.wordprocessingml.document") ?? .data
    static let doc = UTType("com.microsoft.word.doc") ?? .data
    static let odt = UTType("org.oasis-open.opendocument.text") ?? .data

    /// Input caps. Plain text is read whole into memory; HTML goes through the sanitizer and WebKit; rich formats
    /// (DOCX/ODT are zip containers) are capped on disk size as a first line of defence against zip bombs.
    static let maxHTMLBytes = 5_000_000
    static let maxPlainTextBytes = 20_000_000
    static let maxRichBytes = 50_000_000
    static let maxPDFPages = 10_000
    static let htmlImportTimeout: TimeInterval = 5

    /// A loaded document. `NSAttributedString` is immutable, so sharing it across tasks is safe.
    struct Loaded: @unchecked Sendable {
        let text: NSAttributedString
    }

    // MARK: - Reading

    static func load(_ input: InputFile) async throws -> NSAttributedString {
        let url = input.url
        let type = input.type
        if type.conforms(to: .html) {
            let cleaned = try await DocumentWorker.run { flag -> Data in
                try checkSize(url, limit: maxHTMLBytes, kind: "HTML files")
                let data: Data
                do { data = try Data(contentsOf: url) } catch { throw ConversionError.unreadable(url) }
                guard data.count <= maxHTMLBytes else { throw tooLarge("HTML files", maxHTMLBytes) }
                try flag.check()
                return HTMLSanitizer.clean(data)
            }
            return try await importHTML(cleaned, url: url).text
        }
        return try await DocumentWorker.run { flag in
            Loaded(text: try loadBlocking(url: url, type: type, cancellation: flag))
        }.text
    }

    /// Imports already-sanitized HTML on the main thread, one import at a time.
    static func importHTML(_ cleaned: Data, url: URL) async throws -> Loaded {
        try await HTMLImportGate.shared.withTurn {
            try await MainActor.run { () throws -> Loaded in
                try Task.checkCancellation()
                // No `.baseURL`: relative references (there are none left anyway) can't resolve to local files.
                let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                    .timeout: htmlImportTimeout,
                ]
                guard let s = try? NSAttributedString(data: cleaned, options: options, documentAttributes: nil) else {
                    throw ConversionError.unreadable(url)
                }
                return Loaded(text: s)
            }
        }
    }

    static func tooLarge(_ kind: String, _ limit: Int) -> ConversionError {
        .unsupportedInput("\(kind) larger than \(limit / 1_000_000) MB aren't supported.")
    }

    /// Fails cleanly when the file (or, for packages like RTFD, the sum of its files) is over `limit` bytes.
    static func checkSize(_ url: URL, limit: Int, kind: String) throws {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey]
        let values = try? url.resourceValues(forKeys: keys)
        var total = 0
        if values?.isDirectory == true {
            let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
            while let item = items?.nextObject() as? URL {
                total += (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if total > limit { break }
            }
        } else {
            total = values?.fileSize ?? 0
        }
        if total > limit { throw tooLarge(kind, limit) }
    }

    private static func loadBlocking(url: URL, type: UTType, cancellation: DocumentCancellation) throws -> NSAttributedString {
        if type.conforms(to: .plainText) {
            try checkSize(url, limit: maxPlainTextBytes, kind: "Text files")
            let data: Data
            do { data = try Data(contentsOf: url) } catch { throw ConversionError.unreadable(url) }
            guard data.count <= maxPlainTextBytes else { throw tooLarge("Text files", maxPlainTextBytes) }
            try cancellation.check()
            let text = decodePlainText(data)
            let font = type.conforms(to: .sourceCode)
                ? NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
                : NSFont.systemFont(ofSize: 12)
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        }
        let docType: NSAttributedString.DocumentType
        if type.conforms(to: .rtfd) || type.identifier == "com.apple.flat-rtfd" { docType = .rtfd }
        else if type.conforms(to: .rtf) { docType = .rtf }
        else if type.conforms(to: docx) { docType = .officeOpenXML }
        else if type.conforms(to: doc) { docType = .docFormat }
        else if type.conforms(to: odt) { docType = .openDocument }
        else { throw ConversionError.unsupportedInput("Unknown document type.") }
        try checkSize(url, limit: maxRichBytes, kind: "Documents")
        try cancellation.check()
        do {
            return try NSAttributedString(url: url, options: [.documentType: docType], documentAttributes: nil)
        } catch {
            throw ConversionError.unreadable(url)
        }
    }

    /// UTF-8 (with or without BOM), UTF-16 with BOM, else Latin-1, so any bytes produce text.
    static func decodePlainText(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) {
            return s
        }
        if var s = String(data: data, encoding: .utf8) {
            if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
            return s
        }
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: - PDF

    /// US Letter in regions that use it, A4 everywhere else.
    static var localePageSize: CGSize {
        let letterRegions: Set<String> = ["US", "CA", "MX", "PR", "PH", "CL", "CO", "VE", "CR", "GT", "PA", "DO", "SV", "NI", "HN", "BZ"]
        let region = Locale.current.region?.identifier ?? "US"
        return letterRegions.contains(region) ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89)
    }

    /// Lays `text` out page by page and writes a PDF to `url`. Returns the page count.
    ///
    /// Nothing is silently dropped: attachments larger than the page's content area are scaled down to fit, a page
    /// that still can't take any content fails the conversion, and so does going over `maxPages`.
    @discardableResult
    static func renderPDF(_ text: NSAttributedString, to url: URL, title: String, pageSize: CGSize = localePageSize,
                          margin: CGFloat = 72, maxPages: Int = maxPDFPages,
                          cancellation: DocumentCancellation = DocumentCancellation(),
                          progress: @Sendable (Double) -> Void = { _ in }) throws -> Int {
        let content = CGSize(width: pageSize.width - 2 * margin, height: pageSize.height - 2 * margin)
        let storage = NSTextStorage(attributedString: text)
        try fitAttachments(in: storage, to: content, cancellation: cancellation)
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = false
        storage.addLayoutManager(layout)

        // Paginate: keep adding page-sized containers until every glyph has a home.
        var containers: [NSTextContainer] = []
        let totalGlyphs = max(1, layout.numberOfGlyphs)
        while true {
            try cancellation.check()
            let container = NSTextContainer(size: content)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            let range = layout.glyphRange(for: container)
            if NSMaxRange(range) >= layout.numberOfGlyphs { break }
            // A page that takes nothing means some single line or object can't fit on any page; carrying on would
            // loop forever and stopping would drop the rest of the document.
            if range.length == 0 {
                throw ConversionError.engine("Part of this document is too large to fit on a page.")
            }
            if containers.count >= maxPages {
                throw ConversionError.engine("This document is too long to convert to PDF (more than \(maxPages) pages).")
            }
            progress(0.5 * Double(NSMaxRange(range)) / Double(totalGlyphs))
        }

        var box = CGRect(origin: .zero, size: pageSize)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Frenzy"]
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else {
            throw ConversionError.writeFailed(url, "Couldn't create the PDF.")
        }
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: true)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.current = previous }

        for (i, container) in containers.enumerated() {
            if cancellation.isCancelled { ctx.closePDF(); throw CancellationError() }
            let range = layout.glyphRange(for: container)
            if range.length == 0 && i > 0 { continue }
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: pageSize.height)
            ctx.scaleBy(x: 1, y: -1)
            let origin = CGPoint(x: margin, y: margin)
            layout.drawBackground(forGlyphRange: range, at: origin)
            layout.drawGlyphs(forGlyphRange: range, at: origin)
            ctx.restoreGState()
            ctx.endPDFPage()
            progress(0.5 + 0.5 * Double(i + 1) / Double(containers.count))
        }
        ctx.closePDF()
        return containers.count
    }

    /// Scales every attachment wider or taller than `content` (less a little room for the line) so it fits on a page,
    /// keeping its aspect ratio (as a resized image attachment).
    static func fitAttachments(in storage: NSTextStorage, to content: CGSize, cancellation: DocumentCancellation) throws {
        let limit = CGSize(width: content.width, height: max(1, content.height - 24))
        var changes: [(NSRange, NSTextAttachment)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if cancellation.isCancelled { stop.pointee = true; return }
            guard let attachment = value as? NSTextAttachment else { return }
            let size = naturalSize(of: attachment)
            guard size.width > limit.width || size.height > limit.height, size.width > 0, size.height > 0 else { return }
            let scale = min(limit.width / size.width, limit.height / size.height)
            let fitted = CGSize(width: max(1, floor(size.width * scale)), height: max(1, floor(size.height * scale)))
            if let replacement = resized(attachment, to: fitted) { changes.append((range, replacement)) }
        }
        try cancellation.check()
        guard !changes.isEmpty else { return }
        storage.beginEditing()
        for (range, attachment) in changes { storage.addAttribute(.attachment, value: attachment, range: range) }
        storage.endEditing()
    }

    private static func naturalSize(of attachment: NSTextAttachment) -> CGSize {
        if attachment.bounds.size.width > 0, attachment.bounds.size.height > 0 { return attachment.bounds.size }
        if let cell = attachment.attachmentCell { return cell.cellSize() }
        if let image = attachment.image { return image.size }
        return .zero
    }

    /// A copy of `attachment` showing the same picture at `size`, from its image or file contents. Nil when it has
    /// neither (a bare cell, only ever built in code): `NSCell` drawing is main-actor isolated, so that attachment is
    /// left as is, and if it still can't fit, pagination fails with a clear error instead of dropping content.
    private static func resized(_ attachment: NSTextAttachment, to size: CGSize) -> NSTextAttachment? {
        guard let image = attachment.image ?? attachment.fileWrapper?.regularFileContents.flatMap({ NSImage(data: $0) }),
              let scaled = image.copy() as? NSImage else { return nil }
        scaled.size = size
        let copy = NSTextAttachment(data: nil, ofType: nil)
        copy.image = scaled
        copy.bounds = CGRect(origin: .zero, size: size)
        return copy
    }
}
