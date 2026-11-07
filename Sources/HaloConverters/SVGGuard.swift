import Foundation
import HaloCore

/// Decides whether an SVG may reach CoreSVG (`NSImage`). An allowlist, not a list of bad words.
///
/// CoreSVG really does load pictures from outside the file: measured on macOS 27, `<image href="pic.png">`,
/// `href="/Users/…/pic.png"` and `href="file:///…"` all draw the other file into the result (see
/// `SVGGuardTests.coreSVGLoadsAnOutsidePicture`). In the worker that could pull any picture the worker can read into the
/// output. So:
/// - **UTF-8 only.** A UTF-16 or UTF-32 file, a byte-order mark other than UTF-8's, a NUL byte, or an XML declaration
///   naming another encoding is refused. Every check below then reads the same characters the renderer will.
/// - **No DOCTYPE, no entities.** The one exception: the standard W3C SVG 1.0 / 1.1 public DOCTYPE with no internal
///   subset, which Illustrator and older Inkscape write. It is cut out of the bytes before anything parses them, so no
///   parser ever sees a DOCTYPE. Anything else starting with `<!` (other than a comment or CDATA) is refused.
/// - **Parsed, not searched.** `XMLParser` reads the file with external entities off; entity references in attribute
///   values are decoded before they're checked, so `&#102;ile:` is `file:`.
/// - **Every link is checked.** Any attribute named `href` or `src` (with any prefix, on any element) and every CSS
///   `url(…)` in any attribute or `<style>` must start with `#` (same file) or `data:image/` (not `data:image/svg`, which
///   could nest another SVG with its own links). Relative paths, absolute paths and every scheme are refused.
/// - **No CSS tricks.** `@import`, `image-set(`, `image(`, `src(`, `cross-fade(`, `element(` and CSS escapes
///   (a backslash) in style text are refused, as are processing instructions such as `<?xml-stylesheet?>` and
///   animations that target `href`.
enum SVGGuard {
    static let damaged = ConversionError.unsupportedInput("It looks damaged, or isn't really an SVG.")
    static let outside = ConversionError.unsupportedInput("It points to files or web pages outside itself, so Frenzy won't open it.")
    static let entities = ConversionError.unsupportedInput("It declares its own entities, which Frenzy won't open in an SVG.")
    static let encoding = ConversionError.unsupportedInput("It isn't saved as UTF-8, so Frenzy won't open it. Save it as UTF-8 and try again.")

    /// Returns the bytes to render (the input, minus a standard DOCTYPE), or throws.
    static func sanitized(_ data: Data) throws -> Data {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xFE, 0xFF]) || bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0x00, 0x00]) {
            throw encoding
        }
        guard !data.contains(0), var text = String(data: data, encoding: .utf8) else { throw encoding }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        try checkDeclaration(text)
        text = try withoutStandardDoctype(text)
        try checkMarkupDeclarations(text)

        let clean = Data(text.utf8)
        let parser = XMLParser(data: clean)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        let inspector = Inspector()
        parser.delegate = inspector
        let parsed = parser.parse()
        if let refusal = inspector.refusal { throw refusal }
        guard parsed, inspector.sawRoot else { throw damaged }
        return clean
    }

    // MARK: Encoding

    /// `<?xml … encoding="…"?>` may only name UTF-8 (or its ASCII subset).
    private static func checkDeclaration(_ text: String) throws {
        guard text.hasPrefix("<?xml"), let end = text.range(of: "?>") else { return }
        let declaration = text[..<end.lowerBound].lowercased()
        guard let range = declaration.range(of: #"encoding\s*=\s*["']([^"']*)["']"#, options: .regularExpression) else { return }
        let value = declaration[range].split(whereSeparator: { $0 == "\"" || $0 == "'" }).dropFirst().first.map(String.init) ?? ""
        guard ["utf-8", "utf8", "us-ascii", "ascii"].contains(value) else { throw encoding }
    }

    // MARK: DOCTYPE

    /// The public DOCTYPEs W3C defined for SVG 1.0 and 1.1, with no internal subset.
    private static let standardDoctype = try! NSRegularExpression(
        pattern: #"<!DOCTYPE\s+svg\s+PUBLIC\s+"-//W3C//DTD SVG 1\.[01]( Tiny| Basic)?//EN"\s+"http://www\.w3\.org/(Graphics/SVG/1\.1/DTD/svg11(-tiny|-basic)?\.dtd|TR/2001/REC-SVG-20010904/DTD/svg10\.dtd)"\s*>"#)

    /// Cuts out one standard DOCTYPE that comes before the first element. Any other DOCTYPE stays, and is refused next.
    static func withoutStandardDoctype(_ text: String) throws -> String {
        let ns = text as NSString
        let matches = standardDoctype.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let match = matches.first else { return text }
        guard matches.count == 1 else { throw entities }
        // Only in the prolog: nothing but the declaration, comments and white space may come before it.
        let before = ns.substring(to: match.range.location)
        guard before.range(of: #"^\s*(<\?xml[^>]*\?>)?(\s|<!--[\s\S]*?-->)*$"#, options: .regularExpression) != nil else {
            throw entities
        }
        return ns.replacingCharacters(in: match.range, with: "")
    }

    /// After the standard DOCTYPE is gone, `<!` may only open a comment or a CDATA section.
    private static func checkMarkupDeclarations(_ text: String) throws {
        var rest = text[...]
        while let open = rest.range(of: "<!") {
            let after = rest[open.upperBound...]
            if after.hasPrefix("--") {
                guard let close = after.range(of: "-->") else { throw damaged }
                rest = after[close.upperBound...]
            } else if after.hasPrefix("[CDATA[") {
                guard let close = after.range(of: "]]>") else { throw damaged }
                rest = after[close.upperBound...]
            } else {
                throw entities
            }
        }
    }

    // MARK: Links

    /// `#id` in this file, or an embedded raster picture.
    static func isSafeReference(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if v.hasPrefix("#") { return v.count > 1 }
        return v.hasPrefix("data:image/") && !v.hasPrefix("data:image/svg")
    }

    private static let blockedFunctions = ["@import", "image-set(", "image(", "src(", "cross-fade(", "element("]
    private static let urlFunction = try! NSRegularExpression(pattern: #"url\s*\("#, options: [.caseInsensitive])

    /// CSS in an attribute value or a `<style>`: every `url(…)` must be a safe reference.
    /// `strict` (style text and `style` attributes) also refuses any CSS escape, which could spell `url` or a scheme.
    static func checkCSS(_ text: String, strict: Bool) throws {
        let lower = text.lowercased()
        let compact = String(lower.filter { !$0.isWhitespace })
        if blockedFunctions.contains(where: { compact.contains($0) }) { throw outside }
        if text.contains("\\"), strict || text.contains("(") { throw outside }
        let ns = text as NSString
        for match in urlFunction.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let start = match.range.location + match.range.length
            var argument = ns.substring(from: start)
            argument = argument.trimmingCharacters(in: .whitespacesAndNewlines)
            if let quote = argument.first, quote == "\"" || quote == "'" {
                argument.removeFirst()
                guard let end = argument.firstIndex(of: quote) else { throw outside }
                argument = String(argument[..<end])
            } else {
                guard let end = argument.firstIndex(of: ")") else { throw outside }
                argument = String(argument[..<end])
            }
            guard isSafeReference(argument) else { throw outside }
        }
    }

    private static func localName(_ qualified: String) -> String {
        (qualified.split(separator: ":").last.map(String.init) ?? qualified).lowercased()
    }

    /// Walks the parsed document and keeps the first refusal.
    private final class Inspector: NSObject, XMLParserDelegate {
        var refusal: (any Error)?
        var sawRoot = false
        private var styleDepth = 0
        private var styleText = ""

        private func refuse(_ parser: XMLParser, _ error: any Error) {
            if refusal == nil { refusal = error }
            parser.abortParsing()
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            sawRoot = true
            let element = SVGGuard.localName(elementName)
            if element == "style" { styleDepth += 1 }
            do {
                for (name, value) in attributes {
                    let local = SVGGuard.localName(name)
                    if local == "href" || local == "src" {
                        guard SVGGuard.isSafeReference(value) else { throw SVGGuard.outside }
                    }
                    if local == "attributename", ["href", "src"].contains(SVGGuard.localName(value.trimmingCharacters(in: .whitespaces))) {
                        throw SVGGuard.outside
                    }
                    try SVGGuard.checkCSS(value, strict: local == "style")
                }
            } catch {
                refuse(parser, error)
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            guard SVGGuard.localName(elementName) == "style", styleDepth > 0 else { return }
            styleDepth -= 1
            guard styleDepth == 0 else { return }
            do { try SVGGuard.checkCSS(styleText, strict: true) } catch { refuse(parser, error) }
            styleText = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if styleDepth > 0 { styleText += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if styleDepth > 0 { styleText += String(decoding: CDATABlock, as: UTF8.self) }
        }

        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
            refuse(parser, SVGGuard.outside)
        }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            refuse(parser, SVGGuard.entities)
        }

        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
            refuse(parser, SVGGuard.entities)
        }

        func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?, systemID: String?,
                    notationName: String?) {
            refuse(parser, SVGGuard.entities)
        }

        func parser(_ parser: XMLParser, foundNotationDeclarationWithName name: String, publicID: String?, systemID: String?) {
            refuse(parser, SVGGuard.entities)
        }

        func parser(_ parser: XMLParser, foundElementDeclarationWithName elementName: String, model: String) {
            refuse(parser, SVGGuard.entities)
        }

        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
            refuse(parser, SVGGuard.entities)
            return nil
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
            if refusal == nil { refusal = SVGGuard.damaged }
        }
    }
}
