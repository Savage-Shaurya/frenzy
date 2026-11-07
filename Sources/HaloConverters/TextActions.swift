import Foundation
import HaloCore

/// Text recognition (OCR) actions. Output is a UTF-8 `.txt` next to the image.
enum TextActions {
    /// Vision works best at a few thousand pixels; larger images are downsampled first to bound memory.
    static let maxOCRPixels = 6_000

    static var all: [ConversionAction] {
        [
            ConversionAction(
                id: "text.ocr-image", title: "To Text", subtitle: "Recognize text", symbolName: "text.viewfinder",
                category: .text, inputTypes: ImageCodecs.readableInputs, defaultRank: 7,
                converter: ClosureConverter { job in try ImageActions.eachInput(job) { try ocrImage($0, job: job) } }
            ),
        ]
    }

    static func ocrImage(_ input: InputFile, job: ConversionJob) throws -> URL {
        let file = try ImageFile(url: input.url)
        // Downsampled through the thumbnail API; still refuses decompression bombs (see `ImageLimits`).
        let image = try file.uprightImage(maxPixelSize: maxOCRPixels)
        job.progress(0.2)
        try Task.checkCancellation()
        let text = try OCRRecognizer.recognizeText(in: image)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionError.engine("No text found in \(input.url.lastPathComponent).")
        }
        let target = try job.makeOutput(for: input, pathExtension: "txt")
        try Data((text + "\n").utf8).write(to: target.temporaryURL)
        return try target.commit()
    }
}
