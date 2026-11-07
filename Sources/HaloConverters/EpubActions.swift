import AppKit
import Foundation
import HaloCore
import UniformTypeIdentifiers

/// EPUB in: an EPUB is a zip of web pages, so it goes through Frenzy's own zip reader and HTML sanitizer into the same writers
/// as any document. The chapters' text and basic styling come through. Pictures don't (the sanitizer strips every outside
/// reference, by design), and a book's page layout isn't kept, so the ring says "no images".
///
/// Copy-protected books are refused. Nothing here tries to get around that.
enum EpubActions {
    static let epub = UTType("org.idpf.epub-container") ?? UTType(filenameExtension: "epub") ?? .data

    static var all: [ConversionAction] {
        [
            ConversionAction(
                id: "document.epub-to-pdf", title: "PDF", subtitle: "Text, no images", symbolName: "doc.richtext",
                category: .document, inputTypes: [epub], defaultRank: 10,
                converter: ClosureConverter { try await convert($0, ext: "pdf") { text, title, url, flag, progress in
                    try DocumentSupport.renderPDF(text, to: url, title: title, cancellation: flag, progress: progress)
                } }),
            ConversionAction(
                id: "document.epub-to-docx", title: "Word", subtitle: "Text, no images", symbolName: "doc.text",
                category: .document, inputTypes: [epub], defaultRank: 20,
                converter: ClosureConverter { try await convert($0, ext: "docx") { text, _, url, _, _ in
                    let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
                    try data.write(to: url)
                } }),
            ConversionAction(
                id: "document.epub-to-txt", title: "TXT", subtitle: "Plain text", symbolName: "doc.plaintext",
                category: .document, inputTypes: [epub], defaultRank: 30,
                converter: ClosureConverter { try await convert($0, ext: "txt") { text, _, url, _, _ in
                    let plain = text.string.replacingOccurrences(of: "\u{FFFC}", with: "")
                        .replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n")
                    try Data(plain.utf8).write(to: url)
                } }),
        ]
    }

    /// Caps: a real book is far inside these. Chapters also pass `DocumentSupport`'s HTML cap.
    static let maxEntries = 20_000
    static let maxChapters = 2_000
    static let maxTotalBytes: Int64 = 100_000_000
    static let maxMetaBytes: Int64 = 2_000_000

    static let damaged = ConversionError.unsupportedInput("It looks damaged, or isn't really an EPUB.")
    static let protected = ConversionError.unsupportedInput("It's copy-protected (DRM), so it can't be converted.")

    private static func convert(_ job: ConversionJob, ext: String,
                                _ write: @escaping @Sendable (NSAttributedString, String, URL, DocumentCancellation, @escaping @Sendable (Double) -> Void) throws -> Void) async throws -> [URL] {
        try await VideoActions.eachInput(job) { input, progress in
            let text = try await read(input, job: job) { progress(0.7 * $0) }
            try Task.checkCancellation()
            let out = try job.makeOutput(for: input, pathExtension: ext)
            let tmp = out.temporaryURL
            let title = input.url.deletingPathExtension().lastPathComponent
            try await DocumentWorker.run { flag in
                do {
                    try write(text.text, title, tmp, flag) { progress(0.7 + 0.3 * $0) }
                } catch let error as ConversionError {
                    throw error
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw ConversionError.writeFailed(tmp, (error as NSError).localizedDescription)
                }
            }
            return try out.commit()
        }
    }

    /// The chapters' paths inside the zip, in reading order.
    static func spinePaths(container: Data, package: (String) throws -> Data) throws -> [String] {
        guard let root = RootfileParser.parse(container), let rootParts = ArchiveActions.safeComponents(root) else { throw damaged }
        let opf = try package(rootParts.joined(separator: "/"))
        let parsed = PackageParser.parse(opf)
        guard !parsed.spine.isEmpty else { throw damaged }
        let base = rootParts.dropLast()
        var paths: [String] = []
        for id in parsed.spine.prefix(maxChapters) {
            guard let href = parsed.manifest[id] else { continue }
            // Hrefs are URLs relative to the package. A chapter can't point outside the book.
            let decoded = href.removingPercentEncoding ?? href
            var parts = Array(base)
            for piece in decoded.split(separator: "/").map(String.init) where piece != "." {
                if piece == ".." {
                    guard !parts.isEmpty else { throw damaged }
                    parts.removeLast()
                } else {
                    parts.append(piece)
                }
            }
            guard ArchiveActions.safeComponents(parts.joined(separator: "/")) != nil, !parts.isEmpty else { throw damaged }
            paths.append(parts.joined(separator: "/"))
        }
        guard !paths.isEmpty else { throw damaged }
        return paths
    }

    private static func read(_ input: InputFile, job: ConversionJob?, progress: @Sendable (Double) -> Void) async throws -> DocumentSupport.Loaded {
        let reader: ZipReader
        do { reader = try ZipReader(url: input.url, maxEntries: maxEntries) } catch { throw damaged }
        var byName: [String: ZipReader.Entry] = [:]
        for entry in reader.entries where !entry.isDirectory {
            guard let name = entry.name else { continue }
            byName[name] = entry
        }

        let scratch = try ConverterScratch.folder("epub", job: job)
        defer { try? FileManager.default.removeItem(at: scratch) }

        func extract(_ name: String, limit: Int64) throws -> Data {
            guard let entry = byName[name] else { throw damaged }
            guard entry.size <= limit else { throw damaged }
            let file = scratch.appendingPathComponent(UUID().uuidString)
            guard FileManager.default.createFile(atPath: file.path, contents: nil), let handle = try? FileHandle(forWritingTo: file) else {
                throw ConversionError.engine("Frenzy couldn't read this book.")
            }
            defer {
                try? handle.close()
                try? FileManager.default.removeItem(at: file)
            }
            do { try reader.extract(entry, to: handle) { _ in } } catch { throw damaged }
            return try Data(contentsOf: file)
        }

        let container = try extract("META-INF/container.xml", limit: maxMetaBytes)
        let paths = try spinePaths(container: container) { try extract($0, limit: maxMetaBytes) }

        // Fonts may be lightly obfuscated, and that's fine. A chapter listed as encrypted means DRM.
        if byName["META-INF/rights.xml"] != nil { throw protected }
        if byName["META-INF/encryption.xml"] != nil {
            let listed = EncryptionParser.parse(try extract("META-INF/encryption.xml", limit: maxMetaBytes))
            if paths.contains(where: { listed.contains($0) }) { throw protected }
        }

        let total = Int64(paths.compactMap { byName[$0]?.size }.reduce(0, +))
        guard total <= maxTotalBytes else { throw DocumentSupport.tooLarge("Books", Int(maxTotalBytes)) }

        let result = NSMutableAttributedString()
        for (i, path) in paths.enumerated() {
            try Task.checkCancellation()
            // A chapter that's missing is damage. A picture-only page just adds nothing.
            let page = try extract(path, limit: Int64(DocumentSupport.maxHTMLBytes))
            let cleaned = HTMLSanitizer.clean(page)
            let chapter = try await DocumentSupport.importHTML(cleaned, url: input.url)
            if chapter.text.length > 0 {
                if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
                result.append(chapter.text)
            }
            progress(Double(i + 1) / Double(paths.count))
        }
        guard result.string.contains(where: { !$0.isWhitespace && $0 != "\u{FFFC}" }) else {
            throw ConversionError.engine("No text found in \(input.url.lastPathComponent).")
        }
        return DocumentSupport.Loaded(text: result)
    }
}

// MARK: - The three small XML files

/// `XMLParser` here has external entities off (its default, stated anyway) and these delegates only collect attributes.
private func parse(_ data: Data, delegate: any XMLParserDelegate) {
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    parser.delegate = delegate
    parser.parse()
}

private final class RootfileParser: NSObject, XMLParserDelegate {
    private var path: String?
    static func parse(_ data: Data) -> String? {
        let delegate = RootfileParser()
        HaloConverters.parse(data, delegate: delegate)
        return delegate.path
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name.hasSuffix("rootfile"), path == nil { path = attributes["full-path"] }
    }
}

private final class PackageParser: NSObject, XMLParserDelegate {
    private var manifest: [String: String] = [:]
    private var spine: [String] = []
    static func parse(_ data: Data) -> (manifest: [String: String], spine: [String]) {
        let delegate = PackageParser()
        HaloConverters.parse(data, delegate: delegate)
        return (delegate.manifest, delegate.spine)
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name.hasSuffix("item"), let id = attributes["id"], let href = attributes["href"], manifest.count < EpubActions.maxChapters * 10 {
            manifest[id] = href
        } else if name.hasSuffix("itemref"), let id = attributes["idref"], attributes["linear"] != "no", spine.count < EpubActions.maxChapters {
            spine.append(id)
        }
    }
}

private final class EncryptionParser: NSObject, XMLParserDelegate {
    private var uris = Set<String>()
    static func parse(_ data: Data) -> Set<String> {
        let delegate = EncryptionParser()
        HaloConverters.parse(data, delegate: delegate)
        return delegate.uris
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name.hasSuffix("CipherReference"), let uri = attributes["URI"], uris.count < 100_000 {
            uris.insert(uri.removingPercentEncoding ?? uri)
        }
    }
}
