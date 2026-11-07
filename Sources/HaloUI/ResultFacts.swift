import Foundation
import HaloCore

/// A finished conversion, as the result card shows it: what was made, where it went and how big it is.
public struct ConversionResult: Equatable, Sendable {
    /// "Saved photo.jpg", "Saved 12 files".
    public var title: String
    /// What Open, Show in Finder, Copy and drag act on. Sorted by name.
    public var outputs: [URL]
    /// The action, e.g. "JPG". Empty for results that don't come from an action.
    public var actionTitle: String
    /// Total size of the inputs and of the outputs, in bytes. Nil when unknown (a folder output, a missing file).
    public var inputBytes: Int64?
    public var outputBytes: Int64?
    /// The folder the outputs were saved in ("Desktop"), when they all share one.
    public var folderName: String?
    /// Inputs that couldn't be converted.
    public var failures: Int

    public init(title: String, outputs: [URL], actionTitle: String = "", inputBytes: Int64? = nil,
                outputBytes: Int64? = nil, folderName: String? = nil, failures: Int = 0) {
        self.title = title
        self.outputs = outputs
        self.actionTitle = actionTitle
        self.inputBytes = inputBytes
        self.outputBytes = outputBytes
        self.folderName = folderName
        self.failures = failures
    }

    /// Measures `outputs` and `inputs` on disk (sizes and folder names only, never contents).
    /// Beyond `measureLimit` files on a side, that side's size is left unknown.
    public static func measure(title: String, actionTitle: String, outputs: [URL], inputs: [URL], failures: Int = 0,
                               measureLimit: Int = 200) -> ConversionResult {
        let folders = Set(outputs.map { $0.deletingLastPathComponent().standardizedFileURL })
        let folderName = folders.count == 1 ? folders.first.map { FileManager.default.displayName(atPath: $0.path) } : nil
        return ConversionResult(title: title, outputs: outputs, actionTitle: actionTitle,
                                inputBytes: totalSize(of: inputs, limit: measureLimit),
                                outputBytes: totalSize(of: outputs, limit: measureLimit),
                                folderName: folderName, failures: failures)
    }

    /// Sum of the files' sizes, or nil if any is a folder or missing, or there are more than `limit`.
    static func totalSize(of urls: [URL], limit: Int) -> Int64? {
        guard !urls.isEmpty, urls.count <= limit else { return nil }
        var total: Int64 = 0
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  values.isDirectory != true, let size = values.fileSize else { return nil }
            total += Int64(size)
        }
        return total
    }

    /// "photo.jpg", "photo.jpg and 2 more".
    public var name: String {
        guard let first = outputs.first?.lastPathComponent else { return title }
        return outputs.count == 1 ? first : "\(first) and \(outputs.count - 1) more"
    }

    /// "2.4 MB → 380 KB" when both sizes are known, else just the output size, else nil. When some inputs failed the
    /// before size would include files that made no output and overstate the saving, so only the output size shows.
    public var sizeLine: String? {
        guard let outputBytes else { return nil }
        let after = Self.format(outputBytes)
        guard let inputBytes, failures == 0 else { return after }
        return "\(Self.format(inputBytes)) → \(after)"
    }

    /// "Saved in Desktop", plus how many inputs failed.
    public var placeLine: String {
        failureLine.map { "\(savedLine). \($0)" } ?? savedLine
    }

    /// "Saved in Desktop" or "Saved next to the originals".
    public var savedLine: String {
        folderName.map { "Saved in \($0)" } ?? "Saved next to the originals"
    }

    /// "2 couldn't be converted", or nil when everything converted. The card shows it on its own line, in orange.
    public var failureLine: String? {
        failures > 0 ? "\(failures) couldn't be converted" : nil
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// The plain-language line under a running conversion. Honest about waits: it never promises a time it can't keep,
/// and when nothing has moved for a while it says so, whether the job is at 0 % or stalled partway.
public enum JobStage {
    /// How long progress may sit still (at 0 % or partway) before the line admits it is taking a while.
    public static let slowAfter: TimeInterval = 8
    /// How long the first text recognition may prepare before the "about a minute" line would no longer be true.
    public static let firstRecognitionWait: TimeInterval = 75

    /// - Parameters:
    ///   - firstRun: the user has never finished this action before. Text recognition loads its model the first time,
    ///     which took about a minute on the founder's Mac (1 Nov 2026).
    ///   - elapsed: seconds since the job started.
    ///   - sinceProgress: seconds since the fraction last moved. When nil, a job at 0 % has been still since it started
    ///     (`elapsed`) and a started job counts as just moved.
    public static func line(for action: ActionID, fraction: Double, elapsed: TimeInterval,
                            sinceProgress: TimeInterval? = nil, firstRun: Bool) -> String {
        let family = action.rawValue.split(separator: ".").first.map(String.init) ?? ""
        let started = fraction > 0
        let stalled = (sinceProgress ?? (started ? 0 : elapsed)) >= slowAfter
        if action == "text.ocr-image" {
            if started { return stalled ? "Still reading the text…" : "Reading text…" }
            if firstRun && elapsed < firstRecognitionWait { return "Preparing text recognition. The first time can take about a minute." }
            return stalled ? "Still preparing text recognition…" : "Preparing text recognition…"
        }
        if stalled {
            return started ? "Still working on this step…" : "Still working. Big files take a little longer."
        }
        switch family {
        case "video": return started ? "Converting video…" : "Opening the video…"
        case "audio": return "Converting audio…"
        case "pdf": return started ? "Working through the pages…" : "Opening the PDF…"
        case "document": return "Converting the document…"
        case "archive" where action == "archive.unzip": return started ? "Unzipping…" : "Opening the zip…"
        case "archive": return started ? "Zipping…" : "Gathering the files…"
        default: return "Converting…"
        }
    }
}
