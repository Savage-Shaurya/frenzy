import CoreGraphics
import Foundation
import HaloCore
import Vision

/// On-device text recognition with Vision (accurate mode, language correction on). Never uses the network.
enum OCRRecognizer {
    /// Recognised text in reading order, one line per text line. Empty when the image has no text.
    static func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw ConversionError.engine("Text recognition failed: \(error.localizedDescription)")
        }
        let observations = request.results ?? []
        return orderedLines(observations.compactMap { observation in
            observation.topCandidates(1).first.map { (box: observation.boundingBox, text: $0.string) }
        }).joined(separator: "\n")
    }

    /// Puts lines in reading order: rows top-to-bottom, then left-to-right within a row (Vision's own order isn't
    /// guaranteed). Bounding boxes are normalised with the origin at the bottom left.
    ///
    /// Lines are first sorted by a total order (top, then left, then text), then grouped into rows: a line joins the
    /// current row when its centre is within half a line height of the row's first line. Anchoring on the first line
    /// (instead of comparing neighbours pairwise) keeps rows from chaining down a slanted page and makes the result
    /// the same for any input order.
    static func orderedLines(_ lines: [(box: CGRect, text: String)]) -> [String] {
        let byTop = lines.sorted { a, b in
            if a.box.midY != b.box.midY { return a.box.midY > b.box.midY }
            if a.box.minX != b.box.minX { return a.box.minX < b.box.minX }
            return a.text < b.text
        }
        var rows: [[(box: CGRect, text: String)]] = []
        for line in byTop {
            if let anchor = rows.last?.first,
               abs(anchor.box.midY - line.box.midY) <= min(anchor.box.height, line.box.height) / 2 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.flatMap { row in
            row.sorted { a, b in
                if a.box.minX != b.box.minX { return a.box.minX < b.box.minX }
                if a.box.midY != b.box.midY { return a.box.midY > b.box.midY }
                return a.text < b.text
            }.map(\.text)
        }
    }
}
