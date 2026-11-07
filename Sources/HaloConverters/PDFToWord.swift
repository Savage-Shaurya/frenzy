import AppKit
import Foundation
import HaloCore
import PDFKit

/// PDF to Word: the text and basic structure only. macOS has no route that keeps a PDF's layout, so this doesn't pretend to.
/// The ring says "Word, text only", and this is what the result holds:
///
/// - **Kept:** the words in PDFKit's reading order, paragraphs (from the spacing between lines), line breaks (a line that
///   ends well before the text's right edge is a real break, kept as a Word line break; only lines that ran into the
///   right edge are joined back into one paragraph), headings (from size), bold and italic, one Word page break per PDF page. Scanned pages go through on-device OCR, like To Text.
/// - **Not kept:** page layout, columns, tables, images, headers placed where they were, exact fonts or positions.
enum PDFToWord {
    static var action: ConversionAction {
        ConversionAction(
            id: "pdf.to-word", title: "Word", subtitle: "Text only", symbolName: "doc.text",
            category: .pdf, inputTypes: [.pdf], defaultRank: 7,
            converter: ClosureConverter(convert))
    }

    /// One run of text on a line.
    struct Run: Equatable, Sendable {
        var text: String
        var size: Double
        var isBold: Bool
        var isItalic: Bool
    }

    /// One line of a page, with where it sits (PDF coordinates: y grows upward).
    struct Line: Equatable, Sendable {
        var runs: [Run]
        var top: Double
        var bottom: Double
        var left: Double
        /// Where the line's last character ends. nil when unknown: the line is then treated as wrapped.
        var right: Double? = nil

        var text: String { runs.map(\.text).joined() }
        var height: Double { max(1, top - bottom) }
        /// The size most of the line's characters have.
        var mainSize: Double {
            var counts: [Double: Int] = [:]
            for run in runs { counts[run.size, default: 0] += run.text.count }
            return counts.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key ?? 12
        }
    }

    enum Block: Equatable, Sendable {
        case paragraph([Run], heading: Bool)
        case pageBreak
    }

    /// Lines into paragraphs: a new one where the gap is bigger than the line spacing suggests or the size changes. Inside
    /// a paragraph, a line that was wrapped (it ran into the right edge of the text) is joined with a space, or with
    /// nothing after a hyphen, which is usually a word split across lines. A line that stopped short of the right edge
    /// ended on purpose (an address, a list, a poem, a log), so the break stays, as a Word line break (U+2028).
    /// `page` is the page's crop box: with it, the text's right edge is taken as mirroring its left margin.
    static func paragraphs(_ lines: [Line], bodySize: Double, page: CGRect? = nil) -> [Block] {
        let columnRight = columnRight(lines, page: page)
        var blocks: [Block] = []
        var current: [Run] = []
        var previous: Line?
        func flush(_ size: Double) {
            guard !current.isEmpty else { return }
            blocks.append(.paragraph(current, heading: size >= bodySize * 1.2))
            current = []
        }
        for line in lines {
            if let last = previous {
                let gap = last.bottom - line.top
                let sizeChanged = abs(line.mainSize - last.mainSize) > 0.5
                if gap > 0.8 * max(line.height, last.height) || gap < -line.height || sizeChanged {
                    flush(last.mainSize)
                } else if let tail = current.indices.last {
                    if !wrapped(last, into: line, columnRight: columnRight) {
                        current[tail].text += "\u{2028}"
                    } else if current[tail].text.hasSuffix("-") {
                        current[tail].text.removeLast()
                    } else if !current[tail].text.hasSuffix(" ") {
                        current[tail].text += " "
                    }
                }
            }
            for run in line.runs where !run.text.isEmpty {
                if let tail = current.indices.last, current[tail].size == run.size, current[tail].isBold == run.isBold, current[tail].isItalic == run.isItalic {
                    current[tail].text += run.text
                } else {
                    current.append(run)
                }
            }
            previous = line
        }
        if let previous { flush(previous.mainSize) }
        return blocks
    }

    /// The right edge of the text on a page: the furthest any line reaches, or the left margin mirrored on the page,
    /// whichever is further. nil when no line knows where it ends.
    static func columnRight(_ lines: [Line], page: CGRect?) -> Double? {
        guard let furthest = lines.compactMap(\.right).max() else { return nil }
        guard let page, let minLeft = lines.map(\.left).min(), minLeft >= Double(page.minX) else { return furthest }
        return max(furthest, Double(page.maxX) - (minLeft - Double(page.minX)))
    }

    /// Whether `last` ended only because the next line's first word didn't fit after it.
    static func wrapped(_ last: Line, into next: Line, columnRight: Double?) -> Bool {
        guard let right = last.right, let columnRight else { return true }
        let slack = columnRight - right
        if slack <= 0 { return true }
        let nextText = next.text.trimmingCharacters(in: .whitespaces)
        guard !nextText.isEmpty, let nextRight = next.right, nextRight > next.left else { return true }
        let charWidth = (nextRight - next.left) / Double(max(1, next.text.count))
        let firstWord = nextText.prefix { !$0.isWhitespace }.count
        // A space plus the first word would have run past the edge, with some room for kerning and justification.
        return slack < Double(firstWord + 1) * charWidth * 1.2 + 1
    }

    /// The size most characters in the document have: everything a good deal larger is a heading.
    static func bodySize(_ pages: [[Line]]) -> Double {
        var counts: [Double: Int] = [:]
        for page in pages {
            for line in page {
                for run in line.runs { counts[(run.size * 2).rounded() / 2, default: 0] += run.text.count }
            }
        }
        return counts.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key ?? 12
    }

    static func lines(of page: PDFPage) -> [Line] {
        guard let selection = page.selection(for: page.bounds(for: .cropBox)) else { return [] }
        return selection.selectionsByLine().compactMap { lineSelection in
            guard let text = lineSelection.attributedString, text.length > 0 else { return nil }
            let bounds = lineSelection.bounds(for: page)
            var runs: [Run] = []
            text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
                let piece = text.attributedSubstring(from: range).string
                    .replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
                guard !piece.isEmpty else { return }
                let font = attributes[.font] as? NSFont
                let traits = font?.fontDescriptor.symbolicTraits ?? []
                // Subset fonts often lose the trait flags but keep the word in the name ("ABCDEE+Arial-BoldMT").
                let name = font?.fontName.lowercased() ?? ""
                runs.append(Run(text: piece, size: Double(font?.pointSize ?? 12),
                                isBold: traits.contains(.bold) || name.contains("bold") || name.contains("black"),
                                isItalic: traits.contains(.italic) || name.contains("italic") || name.contains("oblique")))
            }
            guard !runs.isEmpty else { return nil }
            return Line(runs: runs, top: Double(bounds.maxY), bottom: Double(bounds.minY), left: Double(bounds.minX),
                        right: Double(bounds.maxX))
        }
    }

    /// Word's own fonts stand in: a PDF's embedded fonts are usually subsets that aren't on the reader's Mac.
    static func attributedString(_ blocks: [Block], bodySize: Double) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body = NSFontDescriptor(name: "Helvetica", size: 12)
        for block in blocks {
            switch block {
            case .pageBreak:
                result.append(NSAttributedString(string: "\u{0C}"))
            case .paragraph(let runs, let heading):
                let style = NSMutableParagraphStyle()
                style.paragraphSpacing = heading ? 8 : 6
                style.paragraphSpacingBefore = heading ? 12 : 0
                let start = result.length
                for run in runs {
                    var traits: NSFontDescriptor.SymbolicTraits = []
                    if run.isBold || heading { traits.insert(.bold) }
                    if run.isItalic { traits.insert(.italic) }
                    // Body text takes one size, so a PDF's stray 10.98 and 11.04 don't show up as a mess of sizes in Word.
                    let size = heading ? min(32, max(13, run.size.rounded())) : min(12, max(9, 12 * run.size / bodySize)).rounded()
                    let font = NSFont(descriptor: body.withSymbolicTraits(traits), size: size) ?? NSFont.systemFont(ofSize: size)
                    result.append(NSAttributedString(string: run.text, attributes: [.font: font]))
                }
                result.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
                result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: result.length - start))
            }
        }
        return result
    }

    @Sendable static func convert(_ job: ConversionJob) async throws -> [URL] {
        try await VideoActions.eachInput(job) { input, progress in
            let text = try read(input, progress: progress)
            let out = try job.makeOutput(for: input, pathExtension: "docx")
            let tmp = out.temporaryURL
            try await DocumentWorker.run { flag in
                try flag.check()
                do {
                    let data = try text.text.data(from: NSRange(location: 0, length: text.text.length),
                                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
                    try data.write(to: tmp)
                } catch {
                    throw ConversionError.writeFailed(tmp, (error as NSError).localizedDescription)
                }
            }
            try Task.checkCancellation()
            return try out.commit()
        }
    }

    private static func read(_ input: InputFile, progress: @Sendable (Double) -> Void) throws -> DocumentSupport.Loaded {
        let document = try PDFSupport.open(input)
        try PDFSupport.checkPageCount(document, input: input)
        var pages: [[Line]] = []
        var boxes: [CGRect] = []
        var scanned: [Int: String] = [:]
        for p in 0..<document.pageCount {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let page = document.page(at: p) else { pages.append([]); boxes.append(.zero); return }
                boxes.append(page.bounds(for: .cropBox))
                let found = lines(of: page).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
                pages.append(found)
                if found.isEmpty, PDFSupport.hasUsableSize(page) {
                    let longest = max(page.bounds(for: .cropBox).width, page.bounds(for: .cropBox).height)
                    let scale = min(4, max(1, 3_000 / longest))
                    scanned[p] = try OCRRecognizer.recognizeText(in: PDFSupport.render(page, scale: scale, pageNumber: p + 1))
                }
            }
            progress(Double(p + 1) / Double(document.pageCount) * 0.8)
        }
        let size = bodySize(pages)
        var blocks: [Block] = []
        for (p, page) in pages.enumerated() {
            if p > 0 { blocks.append(.pageBreak) }
            if let text = scanned[p] {
                for piece in text.components(separatedBy: "\n") where !piece.trimmingCharacters(in: .whitespaces).isEmpty {
                    blocks.append(.paragraph([Run(text: piece, size: size, isBold: false, isItalic: false)], heading: false))
                }
            } else {
                blocks += paragraphs(page, bodySize: size, page: boxes[p])
            }
        }
        guard blocks.contains(where: { if case .paragraph = $0 { true } else { false } }) else {
            throw ConversionError.engine("No text found in \(input.url.lastPathComponent).")
        }
        return DocumentSupport.Loaded(text: attributedString(blocks, bodySize: size))
    }
}
