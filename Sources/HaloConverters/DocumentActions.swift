import AppKit
import Foundation
import HaloCore
import UniformTypeIdentifiers

/// Document conversions via the AppKit text system: PDF, Word (.docx), plain text, RTF.
///
/// No-op prevention: each action lists only the source formats it changes, and none of the listed types conform to
/// the target (e.g. "TXT" lists RTF/HTML/Word/ODT but not `public.plain-text`, so .txt/.md/.csv never see it).
enum DocumentActions {
    private static let rich: [UTType] = [.rtf, .rtfd, .flatRTFD, .html, DocumentSupport.docx, DocumentSupport.doc, DocumentSupport.odt]

    static var all: [ConversionAction] {
        [
            ConversionAction(
                id: "document.to-pdf", title: "PDF", subtitle: "Paginated", symbolName: "doc.richtext",
                category: .document, inputTypes: rich + [.plainText],
                defaultRank: 10, converter: ClosureConverter(toPDF)),
            ConversionAction(
                id: "document.to-docx", title: "Word", subtitle: "DOCX", symbolName: "doc.text",
                category: .document, inputTypes: rich.filter { $0 != DocumentSupport.docx } + [.plainText],
                defaultRank: 20, converter: ClosureConverter(toDOCX)),
            ConversionAction(
                id: "document.to-txt", title: "TXT", subtitle: "Plain text", symbolName: "doc.plaintext",
                category: .document, inputTypes: rich,
                defaultRank: 30, converter: ClosureConverter(toTXT)),
            ConversionAction(
                id: "document.to-rtf", title: "RTF", subtitle: "Rich text", symbolName: "textformat",
                // RTFD -> RTF is kept: it flattens a package into a single file (images are dropped).
                category: .document, inputTypes: rich.filter { $0 != .rtf } + [.plainText],
                defaultRank: 40, converter: ClosureConverter(toRTF)),
        ]
    }

    @Sendable static func toPDF(_ job: ConversionJob) async throws -> [URL] {
        try await convert(job, ext: "pdf") { text, input, url, cancellation, progress in
            let title = input.url.deletingPathExtension().lastPathComponent
            try DocumentSupport.renderPDF(text, to: url, title: title, cancellation: cancellation, progress: progress)
        }
    }

    @Sendable static func toTXT(_ job: ConversionJob) async throws -> [URL] {
        try await convert(job, ext: "txt") { text, _, url, _, _ in
            // Drop attachment placeholders (U+FFFC); normalise line separators.
            let plain = text.string
                .replacingOccurrences(of: "\u{FFFC}", with: "")
                .replacingOccurrences(of: "\u{2028}", with: "\n")
                .replacingOccurrences(of: "\u{2029}", with: "\n")
            try write(Data(plain.utf8), to: url)
        }
    }

    @Sendable static func toRTF(_ job: ConversionJob) async throws -> [URL] {
        try await convert(job, ext: "rtf") { text, _, url, _, _ in
            try write(try data(text, .rtf, url), to: url)
        }
    }

    @Sendable static func toDOCX(_ job: ConversionJob) async throws -> [URL] {
        try await convert(job, ext: "docx") { text, _, url, _, _ in
            try write(try data(text, .officeOpenXML, url), to: url)
        }
    }

    // MARK: - Helpers

    /// Loads each input, then runs `body` (the blocking writer) on `DocumentWorker`'s serial queue. Cancelling the
    /// job flips the flag `body` receives; `renderPDF` polls it per page.
    private static func convert(
        _ job: ConversionJob, ext: String,
        _ body: @escaping @Sendable (NSAttributedString, InputFile, URL, DocumentCancellation, @escaping @Sendable (Double) -> Void) throws -> Void
    ) async throws -> [URL] {
        try await VideoActions.eachInput(job) { input, progress in
            let text = DocumentSupport.Loaded(text: try await DocumentSupport.load(input))
            progress(0.2)
            try Task.checkCancellation()
            let out = try job.makeOutput(for: input, pathExtension: ext)
            let tmp = out.temporaryURL
            try await DocumentWorker.run { cancellation in
                try body(text.text, input, tmp, cancellation) { progress(0.2 + 0.8 * $0) }
            }
            try Task.checkCancellation()
            return try out.commit()
        }
    }

    private static func data(_ text: NSAttributedString, _ type: NSAttributedString.DocumentType, _ url: URL) throws -> Data {
        do {
            return try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type])
        } catch {
            throw ConversionError.writeFailed(url, (error as NSError).localizedDescription)
        }
    }

    private static func write(_ data: Data, to url: URL) throws {
        do { try data.write(to: url) } catch {
            throw ConversionError.writeFailed(url, (error as NSError).localizedDescription)
        }
    }
}
