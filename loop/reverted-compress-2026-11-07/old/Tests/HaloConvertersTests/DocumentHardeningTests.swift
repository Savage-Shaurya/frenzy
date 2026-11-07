import AppKit
import Foundation
import HaloCore
@testable import HaloConverters
import PDFKit
import Testing
import UniformTypeIdentifiers

/// Adversarial HTML, cancellation, caps and no-silent-truncation tests for document conversions.
@Suite("Document hardening")
struct DocumentHardeningTests {
    // MARK: - Helpers

    private static func clean(_ html: String) -> String {
        String(decoding: HTMLSanitizer.clean(Data(html.utf8)), as: UTF8.self)
    }

    /// Every tag in the output is a bare allowlisted tag (optionally numeric colspan/rowspan), the shell tags, or the
    /// doctype; so no attribute, URL, style or script can be present in markup.
    private static func expectInert(_ out: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let allowed = HTMLSanitizer.allowed.union(["html", "body"])
        var i = out.startIndex
        while let lt = out[i...].firstIndex(of: "<") {
            guard let gt = out[lt...].firstIndex(of: ">") else {
                Issue.record("unterminated tag in output", sourceLocation: sourceLocation); return
            }
            let tag = String(out[out.index(after: lt)..<gt])
            i = out.index(after: gt)
            if tag == "!doctype html" { continue }
            var parts = tag.split(separator: " ").map(String.init)
            var name = parts.removeFirst()
            if name.hasPrefix("/") { name.removeFirst(); #expect(parts.isEmpty, "attrs on end tag: <\(tag)>", sourceLocation: sourceLocation) }
            #expect(allowed.contains(name), "disallowed tag <\(tag)>", sourceLocation: sourceLocation)
            for p in parts {
                let ok = (p.hasPrefix("colspan=\"") || p.hasPrefix("rowspan=\"")) && p.hasSuffix("\"")
                    && p.dropFirst(9).dropLast().allSatisfy(\.isNumber) && (name == "td" || name == "th")
                #expect(ok, "unexpected attribute \(p) in <\(tag)>", sourceLocation: sourceLocation)
            }
        }
        // Raw `<` only ever starts one of the tags checked above; text can mention these words only escaped.
        let lower = out.lowercased()
        for bad in ["<script", "<img", "<link", "<base", "<meta", "<svg", "<image", "<style", "<iframe"] {
            #expect(!lower.contains(bad), "\(bad) survived: \(out.prefix(300))", sourceLocation: sourceLocation)
        }
    }

    /// Output must not mention the remote host, any URL scheme, or the local file names at all.
    private static func expectNoReferences(_ out: String, sourceLocation: SourceLocation = #_sourceLocation) {
        expectInert(out, sourceLocation: sourceLocation)
        let lower = out.lowercased()
        for bad in ["evil", "http:", "https:", "http", "file:", "secret", "private", "//", "src=", "href=", "url(",
                    "@import", "style=", "http-equiv", "refresh", "srcset", "xlink", "image-set"] {
            #expect(!lower.contains(bad), "'\(bad)' survived: \(out.prefix(300))", sourceLocation: sourceLocation)
        }
    }

    // MARK: - Every known bypass of the old regex sanitizer

    /// Each case hides a remote or local reference somewhere only a resource loader would see it.
    static let bypasses: [(String, String)] = [
        ("base href", #"<base href="https://evil.example/"><img src="x.png"><p>t</p>"#),
        ("srcset second URL", #"<img src="a.png" srcset="a.png 1x, https://evil.example/b.png 2x"><p>t</p>"#),
        ("srcset no scheme", #"<img srcset="//evil.example/b.png 2x">"#),
        ("rule recombination", #"<li<link rel=stylesheet href=https://evil.example/x.css>>t</li>"#),
        ("import without space", #"<style>@import"https://evil.example/a.css";body{color:red}</style><p>t</p>"#),
        ("import url()", #"<style>@import url(https://evil.example/a.css);</style>"#),
        ("entity-encoded scheme", #"<img src="&#104;ttps://evil.example/a.png"><img src="&#x68;ttp://evil.example/b.png">"#),
        ("entity-encoded colon", #"<img src="https&#58;//evil.example/a.png"><img src="https&colon;//evil.example/a.png">"#),
        ("tab in scheme", "<img src=\"ht\ttps://evil.example/a.png\">"),
        ("newline in scheme", "<img src=\"htt\np://evil.example/a.png\"><iframe src=\"ht\rtp://evil.example\"></iframe>"),
        ("svg image href", #"<svg><image href="https://evil.example/a.png"/></svg><p>t</p>"#),
        ("svg xlink:href", #"<svg xmlns:xlink="http://www.w3.org/1999/xlink"><image xlink:href="https://evil.example/b.png"/><use xlink:href="https://evil.example/s.svg#a"/></svg>"#),
        ("css image-set", #"<div style="background-image:image-set('https://evil.example/a.png' 1x)">t</div>"#),
        ("css escaped url", #"<div style="background:u\72l(https://evil.example/a.png)">t</div><style>p{background:\75rl(https://evil.example/b.png)}</style>"#),
        ("meta refresh", #"<meta http-equiv="refresh" content="0;url=https://evil.example/"><p>t</p>"#),
        ("absolute file image", #"<img src="file:///Users/me/secret.png"><img src="FILE:///etc/private">"#),
        ("relative local image", #"<img src="secret.png"><img src="../private/photo.jpg"><img src=secret.jpg>"#),
        ("background attribute", #"<body background="https://evil.example/bg.png"><table background="secret.png"><tr><td background="https://evil.example/c.png">t</td></tr></table></body>"#),
        ("scripts", #"<script>fetch('https://evil.example')</script><SCRIPT src=https://evil.example/a.js></SCRIPT><script/>fetch('https://evil.example')</script>"#),
        ("frames and objects", #"<iframe src="https://evil.example/"></iframe><object data="https://evil.example/o"></object><embed src="https://evil.example/e"><frameset><frame src="https://evil.example/f"></frameset>"#),
        ("media", #"<video poster="https://evil.example/p.png" src="secret.mp4"><source src="https://evil.example/v.mp4"><track src="https://evil.example/t.vtt"></video><audio src="https://evil.example/a.mp3"></audio>"#),
        ("picture", #"<picture><source srcset="https://evil.example/a.webp"><img src="secret.png"></picture><p>t</p>"#),
        ("link preload", #"<link rel="preload" href="https://evil.example/a.woff2" as="font"><link rel=icon href=secret.ico>"#),
        ("form input image", #"<form action="https://evil.example/"><input type="image" src="https://evil.example/i.png"><button formaction="https://evil.example/">b</button></form>"#),
        ("event handlers and style", #"<p onclick="fetch('https://evil.example')" style="background:url(secret.png)" onload=x>t</p>"#),
        ("comment tricks", #"<!--><img src=https://evil.example/a.png>--><!-- --!><img src="secret.png"><!--x-->t"#),
        ("quoted gt in attribute", #"<p title="><img src=https://evil.example/a.png>">t</p></p foo="<img src=secret.png>">"#),
        ("noscript and template", #"<noscript><img src="https://evil.example/n.png"></noscript><template><img src="secret.png"></template><textarea><img src=https://evil.example/t></textarea>"#),
        ("math", #"<math><mi xlink:href="https://evil.example/m">x</mi><mglyph src="secret.png"/></math>"#),
        ("uppercase and mixed", #"<IMG SRC="HTTPS://EVIL.EXAMPLE/A.PNG"><LiNk HrEf=HTTPS://EVIL.EXAMPLE/B.CSS>"#),
        ("unterminated tag", #"<p>t<img src="https://evil.example/a.png"#),
        ("unterminated script", #"<p>t</p><script>fetch('https://evil.example')"#),
        ("svg foreign script", #"<svg><script href="https://evil.example/a.js"/><foreignObject><img src="secret.png"></foreignObject></svg>"#),
        ("style tag", #"<style>body{background:url("https://evil.example/a.png")}@font-face{src:url(secret.woff)}</style>"#),
        ("anchor with dangerous href", #"<a href="javascript:fetch('https://evil.example')">t</a><a href="file:///Users/me/secret.txt">u</a><a href="&#104;ttps://evil.example">v</a>"#),
    ]

    @Test(arguments: bypasses.map(\.0))
    func bypassIsNeutralised(_ name: String) throws {
        let html = try #require(Self.bypasses.first { $0.0 == name }?.1)
        Self.expectNoReferences(Self.clean(html))
    }

    @Test func ruleRecombinationNeverCreatesATag() {
        // The old regex removed `<link x>` and left `<link ...>` behind. Now the odd tag is dropped and what
        // follows is escaped text.
        let out = Self.clean(#"<li<link x>nk rel=stylesheet href=https://evil.example/x.css>"#)
        Self.expectInert(out)
        #expect(!out.lowercased().contains("<link") && !out.contains("<li"))
        #expect(out.contains("nk rel=stylesheet href=https://evil.example/x.css&gt;"))
    }

    @Test func entitiesDecodeOnlyToText() {
        let out = Self.clean(#"<p>&lt;img src=x&gt; &#60;script&#62; &#x3C;b&#x3e; caf&eacute; &amp;amp; &#0; &#xD800; &bogus &copy;</p>"#)
        Self.expectInert(out)
        #expect(out.contains("&lt;img src=x&gt;"))
        #expect(out.contains("&lt;script&gt;") && out.contains("&lt;b&gt;"))
        #expect(out.contains("caf&eacute;"))       // unknown-to-us named entity passed through, still only text
        #expect(out.contains("&amp;amp;"))
        #expect(out.contains("\u{FFFD} \u{FFFD}"))
        #expect(out.contains("&amp;bogus") && out.contains("©"))
    }

    @Test func structureIsKeptAttributesAreNot() {
        let out = Self.clean(#"<h2 id=x class=y>Head</h2><table border=1><tr><td colspan="2" rowspan=x style="color:red">a</td><th rowspan=3>b</th></tr></table><section><p>p<b>bold<i>both</b>it</i></p></section><pre>  keep   spaces</pre>"#)
        Self.expectInert(out)
        #expect(out.contains("<h2>Head</h2>"))
        #expect(out.contains(#"<td colspan="2">a</td>"#) && out.contains(#"<th rowspan="3">b</th>"#))
        #expect(out.contains("<div><p>p<b>bold<i>both</i></b>it</p></div>"))
        #expect(out.contains("<pre>  keep   spaces</pre>"))
    }

    @Test func linkTargetsAreTextOnly() {
        let out = Self.clean(#"<a href="https://example.org/doc">Docs</a> <a href=" mailto:a@b.c ">mail</a> <a href="https://example.org">https://example.org</a> <a href="secret.html">local</a>"#)
        Self.expectInert(out)
        #expect(out.contains("<a>Docs</a> (https://example.org/doc)"))
        #expect(out.contains("<a>mail</a> (mailto:a@b.c)"))
        #expect(out.contains("<a>https://example.org</a> <a>"))   // not repeated
        #expect(out.contains("<a>local</a></body>") && !out.contains("secret"))
    }

    @Test func nestingIsCapped() {
        let deep = String(repeating: "<div>", count: 10_000) + "deep" + String(repeating: "</div>", count: 10_000)
        let out = Self.clean(deep)
        #expect(out.components(separatedBy: "<div>").count - 1 == HTMLSanitizer.maxDepth)
        #expect(out.components(separatedBy: "</div>").count - 1 == HTMLSanitizer.maxDepth)
        #expect(out.contains("deep"))
    }

    // MARK: - Performance

    /// Inputs that made the old regexes (or a naive tokenizer) quadratic. Each is ~2 MB.
    static let pathological: [String: String] = [
        "script-open": "<script ",
        "nested-lt": "<a<a",
        "comment-open": "<!--",
        "end-tag-open": "</",
        "entity-open": "&#",
        "attr-quote": "<p a=\"",
        "svg-open": "<svg>",
        "b-then-i": "<b></i>",
        "comments": "<!---->",
        "a-href": "<a href=https://x>",
    ]

    /// This thread's CPU seconds. Unlike the wall clock it doesn't count time spent waiting for a core, so
    /// other suites running in parallel can't make a linear pass look quadratic.
    private static func threadCPUSeconds() -> Double {
        var t = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
        return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
    }

    /// A scaling test, not a time budget: an absolute limit flakes under full-suite parallel load.
    /// 4x the input must cost under 6x the CPU time (quadratic would be ~16x). Sizes are interleaved and the
    /// minimum of a few runs is kept, so cache contention hits both sizes and is mostly filtered out.
    @Test(arguments: Array(pathological.keys).sorted())
    func cleanIsLinear(_ name: String) throws {
        let unit = try #require(Self.pathological[name])
        let small = Data(String(repeating: unit, count: 500_000 / unit.utf8.count).utf8)
        let large = Data(String(repeating: unit, count: 2_000_000 / unit.utf8.count).utf8)
        let clock = ContinuousClock()
        func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
        var out = Data()
        var best = (small: Double.infinity, large: Double.infinity)
        func cpu(_ body: () -> Void) -> Double {
            let start = Self.threadCPUSeconds()
            body()
            return Self.threadCPUSeconds() - start
        }
        let total = clock.measure {
            for _ in 0..<3 {
                best.small = min(best.small, cpu { _ = HTMLSanitizer.clean(small) })
                best.large = min(best.large, cpu { out = HTMLSanitizer.clean(large) })
            }
        }
        let ratio = best.large / best.small
        print("HTMLSanitizer \(name): \(small.count) bytes in \(String(format: "%.3f", best.small)) s, \(large.count) in \(String(format: "%.3f", best.large)) s, ratio \(String(format: "%.2f", ratio))")
        // Under 50 ms for 2 MB cannot be quadratic, and there the ratio is mostly scheduler noise.
        #expect(ratio < 6 || best.large < 0.05, "\(name) scaled \(ratio)x for 4x input (\(best.small) s -> \(best.large) s)")
        #expect(seconds(total) < 60, "\(name) hang guard: \(seconds(total)) s")
        Self.expectInert(String(decoding: out, as: UTF8.self))
    }

    // MARK: - End to end: no local files embedded, nothing loaded

    @Test func htmlImportEmbedsNoLocalOrRemoteResources() async throws {
        let dir = try AVFixtures.tempDir()
        // A real local image next to the HTML, referenced relatively and absolutely.
        let image = NSImage(size: NSSize(width: 40, height: 40), flipped: false) { r in NSColor.red.setFill(); r.fill(); return true }
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let secret = dir.appendingPathComponent("secret.png")
        try png.write(to: secret)
        let corpus = Self.bypasses.map(\.1).joined(separator: "\n")
        let html = "<p>Visible marker</p><img src=\"secret.png\"><img src=\"\(secret.absoluteString)\">" + corpus
        let url = dir.appendingPathComponent("page.html")
        try html.write(to: url, atomically: true, encoding: .utf8)

        let text = try await DocumentSupport.load(InputFile(url: url, type: .html))
        #expect(text.string.contains("Visible marker"))
        var attachments = 0
        var links = 0
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, _, _ in
            if attrs[.attachment] != nil { attachments += 1 }
            if attrs[.link] != nil { links += 1 }
        }
        #expect(attachments == 0, "local image was embedded")
        #expect(links == 0)
        #expect(!text.string.contains("\u{FFFC}"))

        // And through the real action: the PDF has no image XObjects.
        let outcome = await AVFixtures.run("document.to-pdf", on: url, type: .html)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let out = try #require(outcome.outputs.first)
        let raw = try Data(contentsOf: out)
        #expect(raw.range(of: Data("/Subtype /Image".utf8)) == nil)
        #expect(PDFDocument(url: out)?.string?.contains("Visible marker") == true)
    }

    @Test func concurrentHTMLImportsAreSerializedAndAllSucceed() async throws {
        let dir = try AVFixtures.tempDir()
        let urls = try (0..<6).map { i -> URL in
            let u = dir.appendingPathComponent("p\(i).html")
            try "<h1>Page \(i)</h1><p>marker-\(i)</p>".write(to: u, atomically: true, encoding: .utf8)
            return u
        }
        let texts = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (i, u) in urls.enumerated() {
                group.addTask { (i, try await DocumentSupport.load(InputFile(url: u, type: .html)).string) }
            }
            var all: [Int: String] = [:]
            for try await (i, s) in group { all[i] = s }
            return all
        }
        for i in 0..<6 { #expect(texts[i]?.contains("marker-\(i)") == true) }
    }

    // MARK: - Caps

    private func sparse(_ name: String, bytes: UInt64) throws -> URL {
        let url = try AVFixtures.tempDir().appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: bytes)
        try h.close()
        return url
    }

    @Test(arguments: [
        ("big.html", UInt64(5_000_001), "document.to-txt", "HTML files larger than 5 MB"),
        ("big.txt", UInt64(20_000_001), "document.to-pdf", "Text files larger than 20 MB"),
        ("big.docx", UInt64(50_000_001), "document.to-txt", "Documents larger than 50 MB"),
        ("big.odt", UInt64(50_000_001), "document.to-pdf", "Documents larger than 50 MB"),
        ("big.rtf", UInt64(50_000_001), "document.to-txt", "Documents larger than 50 MB"),
    ])
    func oversizedInputsFailCleanly(_ name: String, _ size: UInt64, _ action: String, _ message: String) async throws {
        let url = try sparse(name, bytes: size)
        let ext = url.pathExtension
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await AVFixtures.run(ActionID(rawValue: action), on: url, type: UTType(filenameExtension: ext)!)
        // Only a hang guard: the sparse file reads fast anyway, and a busy machine can take seconds to schedule this.
        // The refusal message below is what proves the size check ran.
        #expect(clock.now - start < .seconds(30), "should fail before reading the file")
        #expect(outcome.outputs.isEmpty)
        #expect(outcome.failures.first?.message.contains(message) == true, "\(outcome.failures.map(\.message))")
        #expect(AVFixtures.leftovers(in: url.deletingLastPathComponent()).isEmpty)
    }

    // MARK: - No silent truncation

    private static func lines(_ n: Int) -> NSAttributedString {
        let s = (1...n).map { "Line \($0) of the long document." }.joined(separator: "\n")
        return NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 12)])
    }

    @Test func pageCapThrowsInsteadOfTruncating() throws {
        let url = try AVFixtures.tempDir().appendingPathComponent("cap.pdf")
        #expect(throws: ConversionError.self) {
            try DocumentSupport.renderPDF(Self.lines(400), to: url, title: "cap", maxPages: 3)
        }
        // Without the cap the same text fits and every line is there.
        let pages = try DocumentSupport.renderPDF(Self.lines(400), to: url, title: "cap")
        #expect(pages > 3)
        #expect(PDFDocument(url: url)?.string?.contains("Line 400 of") == true)
    }

    private static func tallImage(_ size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { r in NSColor.blue.setFill(); r.fill(); return true }
    }

    private static func pngData(_ size: NSSize) throws -> Data {
        let tiff = try #require(tallImage(size).tiffRepresentation)
        return try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    }

    private static func withAttachment(_ attachment: NSTextAttachment) -> NSAttributedString {
        let text = NSMutableAttributedString(string: "BEFORE marker\n", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        text.append(NSAttributedString(attachment: attachment))
        text.append(NSAttributedString(string: "\nAFTER marker", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        return text
    }

    @Test(arguments: ["image", "bounds", "fileWrapper", "rtfd"])
    func oversizedAttachmentIsScaledNotDropped(_ style: String) throws {
        let size = NSSize(width: 900, height: 4000)
        var text: NSAttributedString
        switch style {
        case "image":
            let a = NSTextAttachment(data: nil, ofType: nil)
            a.image = NSImage(data: try Self.pngData(size))
            text = Self.withAttachment(a)
        case "bounds":
            let a = NSTextAttachment(data: nil, ofType: nil)
            a.image = NSImage(data: try Self.pngData(NSSize(width: 90, height: 400)))
            a.bounds = CGRect(origin: .zero, size: size)
            text = Self.withAttachment(a)
        default:
            let wrapper = FileWrapper(regularFileWithContents: try Self.pngData(size))
            wrapper.preferredFilename = "tall.png"
            text = Self.withAttachment(NSTextAttachment(fileWrapper: wrapper))
            if style == "rtfd" {
                // Through a real RTFD file, the way a user's document arrives.
                let dir = try AVFixtures.tempDir()
                let rtfd = dir.appendingPathComponent("tall.rtfd")
                let range = NSRange(location: 0, length: text.length)
                try text.fileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
                    .write(to: rtfd, options: .atomic, originalContentsURL: nil)
                text = try NSAttributedString(url: rtfd, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
            }
        }
        let url = try AVFixtures.tempDir().appendingPathComponent("tall.pdf")
        let pages = try DocumentSupport.renderPDF(text, to: url, title: "tall")
        let pdf = try #require(PDFDocument(url: url))
        #expect(pdf.pageCount == pages && pages <= 3)
        let s = pdf.string ?? ""
        #expect(s.contains("BEFORE marker") && s.contains("AFTER marker"), "\(style): \(s)")
        // The picture itself is drawn (as an image), not dropped.
        let raw = try Data(contentsOf: url)
        #expect(raw.range(of: Data("/Subtype /Image".utf8)) != nil, "\(style): image missing from PDF")
    }

    /// A bare cell (no image data to rescale) either fits or fails loudly; it never yields a PDF missing content.
    @MainActor @Test func unscalableAttachmentNeverTruncatesSilently() throws {
        let a = NSTextAttachment(data: nil, ofType: nil)
        a.attachmentCell = NSTextAttachmentCell(imageCell: Self.tallImage(NSSize(width: 900, height: 4000)))
        let url = try AVFixtures.tempDir().appendingPathComponent("cell.pdf")
        do {
            try DocumentSupport.renderPDF(Self.withAttachment(a), to: url, title: "cell")
            #expect(PDFDocument(url: url)?.string?.contains("AFTER marker") == true)
        } catch let error as ConversionError {
            #expect(error.localizedDescription.contains("too large to fit"))
        }
    }

    // MARK: - Cancellation

    @Test func preCancelledRenderStopsImmediately() throws {
        let url = try AVFixtures.tempDir().appendingPathComponent("c.pdf")
        #expect(throws: CancellationError.self) {
            try DocumentSupport.renderPDF(Self.lines(50), to: url, title: "c", cancellation: DocumentCancellation(cancelled: true))
        }
    }

    @Test func cancellingTheTaskStopsALongRender() async throws {
        let url = try AVFixtures.tempDir().appendingPathComponent("long.pdf")
        let text = DocumentSupport.Loaded(text: Self.lines(150_000))  // thousands of pages
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task {
            try await DocumentWorker.run { flag in
                try DocumentSupport.renderPDF(text.text, to: url, title: "long", cancellation: flag)
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let elapsed = clock.now - started
        print("Document render cancelled after \(elapsed)")
        #expect(elapsed < .seconds(5))
    }
}
