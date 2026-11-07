import Foundation

/// Rebuilds untrusted HTML as a clean, resource-free document before it reaches WebKit.
///
/// Approach: a small single-pass tokenizer over the UTF-8 bytes (no regex, no backtracking; every byte is visited a
/// bounded number of times, so the cost is linear in the input), then a rebuild from an allowlist of text/structure
/// tags. Nothing from the input is copied verbatim into markup: allowed tags are re-emitted by name with no
/// attributes (only numeric `colspan`/`rowspan` on cells), and all text is re-escaped. Unknown tags are unwrapped
/// (their text is kept); resource-loading and scriptable elements are dropped together with their content. The
/// output therefore cannot reference any URL (remote or local), stylesheet, script, frame, or refresh.
enum HTMLSanitizer {
    /// Inline and block tags that are re-emitted (bare, no attributes).
    static let allowed: Set<String> = [
        "p", "br", "h1", "h2", "h3", "h4", "h5", "h6", "b", "strong", "i", "em", "u", "s", "sub", "sup",
        "ul", "ol", "li", "blockquote", "pre", "code", "table", "thead", "tbody", "tr", "th", "td", "hr",
        "a", "span", "div",
    ]

    /// Unknown-but-common tags mapped onto an allowed one so paragraph and emphasis structure survives.
    static let aliases: [String: String] = [
        "article": "div", "section": "div", "header": "div", "footer": "div", "nav": "div", "main": "div",
        "aside": "div", "figure": "div", "figcaption": "div", "address": "div", "center": "div", "dl": "div",
        "dt": "div", "dd": "div", "details": "div", "summary": "div", "caption": "div", "fieldset": "div",
        "legend": "div", "hgroup": "div", "tfoot": "tbody", "strike": "s", "del": "s", "ins": "u",
        "kbd": "code", "samp": "code", "tt": "code", "var": "i", "cite": "i", "dfn": "i", "mark": "b",
        "listing": "pre", "xmp": "pre",
    ]

    /// Elements whose body is raw text up to the matching end tag; dropped with their content.
    static let rawTextDropped: Set<String> = [
        "script", "style", "title", "textarea", "iframe", "noembed", "noframes", "noscript", "template",
    ]

    /// Elements dropped together with their (normally parsed) content.
    static let subtreeDropped: Set<String> = [
        "svg", "math", "video", "audio", "picture", "object", "applet", "canvas", "map", "select", "frameset",
        "button", "datalist", "dialog", "portal", "fencedframe",
    ]

    /// Tags never emitted that have no end tag (or whose end tag is meaningless): img, link, meta, base, input...
    /// Everything else not allowed is simply unwrapped, so these are listed only for documentation and tests.
    static let voidDropped: Set<String> = [
        "img", "image", "source", "track", "link", "meta", "base", "input", "embed", "param", "area", "frame",
        "basefont", "bgsound", "keygen", "col", "wbr",
    ]

    /// Nesting cap for emitted elements: keeps end-tag matching O(1) per tag and protects the importer from
    /// pathological depth. Deeper opening tags are dropped (their text is kept).
    static let maxDepth = 256

    private static let named: [String: UInt32] = [
        "amp": 38, "lt": 60, "gt": 62, "quot": 34, "apos": 39, "nbsp": 160, "copy": 169, "reg": 174,
        "trade": 8482, "hellip": 8230, "mdash": 8212, "ndash": 8211, "lsquo": 8216, "rsquo": 8217,
        "ldquo": 8220, "rdquo": 8221, "bull": 8226, "middot": 183, "deg": 176, "plusmn": 177, "times": 215,
        "divide": 247, "euro": 8364, "pound": 163, "yen": 165, "cent": 162, "sect": 167, "para": 182,
        "laquo": 171, "raquo": 187, "shy": 173, "iexcl": 161, "iquest": 191,
    ]

    // MARK: - Entry point

    /// Decodes `data` (UTF-8, UTF-16 with BOM, else Latin-1) and returns clean UTF-8 HTML.
    static func clean(_ data: Data) -> Data {
        Data(clean(decode(data)).utf8)
    }

    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            if let s = String(data: data, encoding: .utf16) { return s }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    /// What to do with a tag name. One dictionary lookup per tag; everything else is array indexing.
    enum Kind { case rawText, subtree, emit(Int) }

    /// Emitted names, indexed by `Kind.emit`.
    static let emitNames: [String] = allowed.sorted()
    private static let openBytes: [[UInt8]] = emitNames.map { Array("<\($0)>".utf8) }
    private static let closeBytes: [[UInt8]] = emitNames.map { Array("</\($0)>".utf8) }
    private static let brIndex = emitNames.firstIndex(of: "br")!
    private static let hrIndex = emitNames.firstIndex(of: "hr")!
    private static let aIndex = emitNames.firstIndex(of: "a")!
    private static let tdIndex = emitNames.firstIndex(of: "td")!
    private static let thIndex = emitNames.firstIndex(of: "th")!

    static let kinds: [String: Kind] = {
        var k: [String: Kind] = [:]
        for (i, n) in emitNames.enumerated() { k[n] = .emit(i) }
        for (from, to) in aliases { k[from] = .emit(emitNames.firstIndex(of: to)!) }
        for n in subtreeDropped { k[n] = .subtree }
        for n in rawTextDropped { k[n] = .rawText }
        return k
    }()

    private static let shellOpen = Array("<!doctype html><html><body>".utf8)
    private static let shellClose = Array("</body></html>".utf8)

    static func clean(_ html: String) -> String {
        var t = Tokenizer(Array(html.utf8))
        var out: [UInt8] = []
        out.reserveCapacity(min(t.bytes.count, 1 << 20) + 128)
        out.append(contentsOf: shellOpen)
        var stack: [Int] = []
        // How many of each name are open, so an end tag for a name that isn't open costs O(1) (no stack scan);
        // a scan only happens when it will pop, so the total cost stays linear.
        var openCount = [Int](repeating: 0, count: emitNames.count)
        // For each open `<a>`: its http(s)/mailto target and where its text started, so the target can be shown as
        // plain text after the link (it is never emitted as an attribute, so nothing can load it).
        var links: [(href: [UInt8], textStart: Int)] = []
        // Subtree being dropped: its element name and nesting depth of that name.
        var skipping: (name: String, depth: Int)?

        func close(_ index: Int) {
            openCount[index] -= 1
            out.append(contentsOf: closeBytes[index])
            if index == aIndex, let link = links.popLast() { appendLinkTarget(link, to: &out) }
        }

        while let token = t.next() {
            switch token {
            case .text(let range):
                if skipping == nil { appendText(t.bytes[range], to: &out) }
            case .start(let rawName, let selfClosing, let attrs):
                let kind = kinds[rawName]
                if var s = skipping {
                    if rawName == s.name && !selfClosing { s.depth += 1; skipping = s }
                    // HTML ignores `/>` on these, so `<script/>` still opens raw text.
                    if case .rawText = kind { t.skipRawText(rawName) }
                    continue
                }
                switch kind {
                case .none: continue // unknown: unwrap (drop the tag, keep its text)
                case .rawText: t.skipRawText(rawName)
                case .subtree: if !selfClosing { skipping = (rawName, 1) }
                case .emit(let index):
                    if index == brIndex || index == hrIndex { out.append(contentsOf: openBytes[index]); continue }
                    if stack.count >= maxDepth { continue }
                    if index == tdIndex || index == thIndex, !attrs.isEmpty {
                        var tag = "<\(emitNames[index])"
                        for key in ["colspan", "rowspan"] {
                            if let v = attrs[key], let n = span(v) { tag += " \(key)=\"\(n)\"" }
                        }
                        out.append(contentsOf: Array((tag + ">").utf8))
                    } else {
                        out.append(contentsOf: openBytes[index])
                    }
                    stack.append(index)
                    openCount[index] += 1
                    if index == aIndex { links.append((visibleHref(attrs["href"]), out.count)) }
                }
            case .end(let rawName):
                if var s = skipping {
                    if rawName == s.name {
                        s.depth -= 1
                        skipping = s.depth == 0 ? nil : s
                    }
                    continue
                }
                guard case .emit(let index) = kinds[rawName] else { continue }
                if index == brIndex { out.append(contentsOf: openBytes[index]); continue } // `</br>` acts as `<br>`
                guard openCount[index] > 0, let idx = stack.lastIndex(of: index) else { continue }
                while stack.count > idx { close(stack.removeLast()) }
            }
        }
        while let index = stack.popLast() { close(index) }
        out.append(contentsOf: shellClose)
        return String(decoding: out, as: UTF8.self)
    }

    /// The href to print after a link: only plain http(s)/mailto targets up to 2 KB, else nothing.
    private static func visibleHref(_ raw: [UInt8]?) -> [UInt8] {
        guard let raw, raw.count <= 2048 else { return [] }
        let trimmed = raw.drop { $0 <= 0x20 }.reversed().drop { $0 <= 0x20 }.reversed()
        let lower = String(decoding: trimmed.prefix(8).map { (0x41...0x5A).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
        guard ["http://", "https://", "mailto:"].contains(where: { lower.hasPrefix($0) }) else { return [] }
        guard !trimmed.contains(where: { $0 < 0x20 }) else { return [] }
        return Array(trimmed)
    }

    private static func appendLinkTarget(_ link: (href: [UInt8], textStart: Int), to out: inout [UInt8]) {
        guard !link.href.isEmpty else { return }
        var shown: [UInt8] = []
        appendText(link.href[...], to: &shown)
        // Skip it when the link text already is exactly the URL (cost is linear in the href).
        let start = min(link.textStart, out.count)
        let closeTag = 4 // "</a>"
        let text = out[start..<max(start, out.count - closeTag)]
        if text.elementsEqual(shown) { return }
        out.append(contentsOf: Array(" (".utf8))
        out.append(contentsOf: shown)
        out.append(0x29)
    }

    private static func span(_ value: [UInt8]) -> Int? {
        var n = 0
        var digits = 0
        for b in value where !(b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D) {
            guard (0x30...0x39).contains(b), digits < 4 else { return nil }
            n = n * 10 + Int(b - 0x30)
            digits += 1
        }
        guard digits > 0 else { return nil }
        return min(max(n, 1), 1000)
    }

    // MARK: - Text and entities

    private static let ltBytes = Array("&lt;".utf8)
    private static let gtBytes = Array("&gt;".utf8)
    private static let ampBytes = Array("&amp;".utf8)

    /// Escapes markup characters; decodes numeric and common named entities, keeps other well-formed named entity
    /// references as-is (they can only ever decode to text), and escapes any stray `&`.
    private static func appendText(_ text: ArraySlice<UInt8>, to out: inout [UInt8]) {
        var i = text.startIndex
        let end = text.endIndex
        while i < end {
            let b = text[i]
            switch b {
            case 0x3C: out.append(contentsOf: ltBytes); i += 1
            case 0x3E: out.append(contentsOf: gtBytes); i += 1
            case 0x00: i += 1
            case 0x26:
                let (consumed, scalar, verbatim) = entity(text, at: i)
                if let scalar {
                    appendScalar(scalar, to: &out)
                } else if verbatim {
                    out.append(contentsOf: text[i..<(i + consumed)])
                } else {
                    out.append(contentsOf: ampBytes)
                }
                i += consumed
            default: out.append(b); i += 1
            }
        }
    }

    /// Parses an entity starting at `&`. Returns bytes consumed, a decoded scalar, or `verbatim` for an unknown but
    /// well-formed named reference. Consumes 1 byte (the `&`) when it isn't an entity.
    private static func entity(_ s: ArraySlice<UInt8>, at start: Int) -> (Int, UInt32?, Bool) {
        var i = start + 1
        let end = s.endIndex
        guard i < end else { return (1, nil, false) }
        if s[i] == 0x23 { // '#'
            i += 1
            var hex = false
            if i < end, s[i] == 0x78 || s[i] == 0x58 { hex = true; i += 1 }
            var value: UInt32 = 0
            var digits = 0
            while i < end, digits < 8, let d = digit(s[i], hex: hex) {
                value = value &* (hex ? 16 : 10) &+ d
                digits += 1
                i += 1
            }
            guard digits > 0 else { return (1, nil, false) }
            while i < end, digit(s[i], hex: hex) != nil { i += 1; value = 0x110000 } // absurdly long: invalid
            if i < end, s[i] == 0x3B { i += 1 }
            return (i - start, value, false)
        }
        var name: [UInt8] = []
        while i < end, name.count < 32, isAlnum(s[i]) { name.append(s[i]); i += 1 }
        guard !name.isEmpty, i < end, s[i] == 0x3B, isAlpha(name[0]) else { return (1, nil, false) }
        i += 1
        if let v = named[String(decoding: name, as: UTF8.self)] { return (i - start, v, false) }
        return (i - start, nil, true)
    }

    private static func appendScalar(_ value: UInt32, to out: inout [UInt8]) {
        let scalar: Unicode.Scalar
        switch value {
        case 0, 0xD800...0xDFFF, 0x110000...: scalar = "\u{FFFD}"
        case 0x01...0x08, 0x0B, 0x0E...0x1F, 0x7F...0x9F: scalar = "\u{FFFD}"
        default: scalar = Unicode.Scalar(value) ?? "\u{FFFD}"
        }
        switch scalar {
        case "<": out.append(contentsOf: ltBytes)
        case ">": out.append(contentsOf: gtBytes)
        case "&": out.append(contentsOf: ampBytes)
        default: out.append(contentsOf: Array(String(Character(scalar)).utf8))
        }
    }

    private static func digit(_ b: UInt8, hex: Bool) -> UInt32? {
        switch b {
        case 0x30...0x39: return UInt32(b - 0x30)
        case 0x61...0x66 where hex: return UInt32(b - 0x61 + 10)
        case 0x41...0x46 where hex: return UInt32(b - 0x41 + 10)
        default: return nil
        }
    }

    fileprivate static func isAlpha(_ b: UInt8) -> Bool { (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) }
    private static func isAlnum(_ b: UInt8) -> Bool { isAlpha(b) || (0x30...0x39).contains(b) }

    // MARK: - Tokenizer

    enum Token {
        case text(Range<Int>)
        /// Lower-cased name; attributes only for names we may keep (lower-cased keys, raw value bytes).
        case start(String, selfClosing: Bool, attrs: [String: [UInt8]])
        case end(String)
    }

    /// A forgiving HTML5-style tokenizer: tag names run to whitespace, `/` or `>` (so `<li<link` is one odd name),
    /// quoted attribute values may contain `>`, comments and `<!...>`/`<?...>` are skipped. Unterminated constructs
    /// swallow the rest of the input, as browsers do. Every loop only moves forward.
    struct Tokenizer {
        let bytes: [UInt8]
        private(set) var pos = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        private static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0C || b == 0x0D }

        mutating func next() -> Token? {
            let n = bytes.count
            while pos < n {
                if let token = step(n) { return token }
            }
            return nil
        }

        /// One step: returns a token, or nil after skipping a comment / bogus construct (never recurses).
        private mutating func step(_ n: Int) -> Token? {
            if bytes[pos] != 0x3C || !startsMarkup(at: pos) {
                let start = pos
                pos += 1
                while pos < n, !(bytes[pos] == 0x3C && startsMarkup(at: pos)) { pos += 1 }
                return .text(start..<pos)
            }
            // bytes[pos] == '<' and markup follows.
            let c = bytes[pos + 1]
            if c == 0x21 { // '!'
                if pos + 3 < n, bytes[pos + 2] == 0x2D, bytes[pos + 3] == 0x2D {
                    skipComment()
                } else {
                    skipPast(0x3E, from: pos + 2)
                }
                return nil
            }
            if c == 0x3F { skipPast(0x3E, from: pos + 2); return nil } // '<?'
            if c == 0x2F { // '</'
                if pos + 2 < n, HTMLSanitizer.isAlpha(bytes[pos + 2]) {
                    pos += 2
                    let name = readName()
                    _ = readAttributes(keep: false)
                    return .end(name)
                }
                skipPast(0x3E, from: pos + 2) // `</>` or bogus comment
                return nil
            }
            pos += 1
            let name = readName()
            let keep = name == "td" || name == "th" || name == "a"
            let (attrs, selfClosing) = readAttributes(keep: keep)
            return .start(name, selfClosing: selfClosing, attrs: attrs)
        }

        private func startsMarkup(at i: Int) -> Bool {
            guard i + 1 < bytes.count else { return false }
            let c = bytes[i + 1]
            return HTMLSanitizer.isAlpha(c) || c == 0x2F || c == 0x21 || c == 0x3F
        }

        private mutating func skipPast(_ byte: UInt8, from start: Int) {
            var i = start
            while i < bytes.count, bytes[i] != byte { i += 1 }
            pos = min(bytes.count, i + 1)
        }

        /// `<!--` ... `-->` (also accepts `--!>`); unterminated eats the rest.
        private mutating func skipComment() {
            var i = pos + 4
            let n = bytes.count
            if i < n, bytes[i] == 0x3E { pos = i + 1; return }                                   // <!-->
            if i + 1 < n, bytes[i] == 0x2D, bytes[i + 1] == 0x3E { pos = i + 2; return }          // <!--->
            while i < n {
                if bytes[i] == 0x2D, i + 2 < n, bytes[i + 1] == 0x2D {
                    if bytes[i + 2] == 0x3E { pos = i + 3; return }
                    if bytes[i + 2] == 0x21, i + 3 < n, bytes[i + 3] == 0x3E { pos = i + 4; return }
                }
                i += 1
            }
            pos = n
        }

        /// Reads a tag name (lower-cased ASCII) up to whitespace, `/` or `>`. Length is capped for the returned
        /// string, but the scan still consumes the whole name.
        private mutating func readName() -> String {
            let start = pos
            let n = bytes.count
            while pos < n {
                let b = bytes[pos]
                if Self.isSpace(b) || b == 0x2F || b == 0x3E { break }
                pos += 1
            }
            let slice = bytes[start..<min(pos, start + 32)]
            let lowered = slice.map { (0x41...0x5A).contains($0) ? $0 + 32 : $0 }
            // A name longer than 32 bytes can't match any known tag: make sure it never does by truncation.
            return pos - start > 32 ? "\u{1}" : String(decoding: lowered, as: UTF8.self)
        }

        /// Parses attributes until `>` (or end of input). Returns kept attributes and whether the tag ended `/>`.
        private mutating func readAttributes(keep: Bool) -> ([String: [UInt8]], Bool) {
            var attrs: [String: [UInt8]] = [:]
            let n = bytes.count
            var selfClosing = false
            while pos < n {
                let b = bytes[pos]
                if Self.isSpace(b) { pos += 1; continue }
                if b == 0x3E { pos += 1; return (attrs, selfClosing) }
                if b == 0x2F { selfClosing = true; pos += 1; continue }
                selfClosing = false
                // Attribute name: first char may be anything but space, '/', '>'; then up to space, '/', '>', '='.
                let nameStart = pos
                pos += 1
                while pos < n {
                    let c = bytes[pos]
                    if Self.isSpace(c) || c == 0x2F || c == 0x3E || c == 0x3D { break }
                    pos += 1
                }
                let nameEnd = pos
                while pos < n, Self.isSpace(bytes[pos]) { pos += 1 }
                var value: Range<Int> = pos..<pos
                if pos < n, bytes[pos] == 0x3D {
                    pos += 1
                    while pos < n, Self.isSpace(bytes[pos]) { pos += 1 }
                    if pos < n, bytes[pos] == 0x22 || bytes[pos] == 0x27 {
                        let quote = bytes[pos]
                        pos += 1
                        let vStart = pos
                        while pos < n, bytes[pos] != quote { pos += 1 }
                        value = vStart..<pos
                        if pos < n { pos += 1 }
                    } else {
                        let vStart = pos
                        while pos < n, !Self.isSpace(bytes[pos]), bytes[pos] != 0x3E { pos += 1 }
                        value = vStart..<pos
                    }
                }
                // Only `href` (4) and `colspan`/`rowspan` (7) are ever read; skip building other keys.
                if keep, nameEnd - nameStart == 4 || nameEnd - nameStart == 7 {
                    let key = String(decoding: bytes[nameStart..<nameEnd].map { (0x41...0x5A).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
                    if attrs[key] == nil { attrs[key] = Array(bytes[value]) }
                }
            }
            return (attrs, selfClosing)
        }

        /// After a raw-text start tag: skips to just past the matching `</name ...>`, or to the end of input.
        mutating func skipRawText(_ name: String) {
            let target = Array(name.utf8)
            let n = bytes.count
            var i = pos
            while i + 1 < n {
                if bytes[i] == 0x3C, bytes[i + 1] == 0x2F, i + 2 + target.count <= n {
                    var match = true
                    for (k, t) in target.enumerated() {
                        let b = bytes[i + 2 + k]
                        if (0x41...0x5A).contains(b) ? b + 32 != t : b != t { match = false; break }
                    }
                    let after = i + 2 + target.count
                    if match, after == n || Self.isSpace(bytes[after]) || bytes[after] == 0x2F || bytes[after] == 0x3E {
                        pos = after
                        _ = readAttributes(keep: false)
                        return
                    }
                }
                i += 1
            }
            pos = n
        }
    }
}
