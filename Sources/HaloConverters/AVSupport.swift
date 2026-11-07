import AVFoundation
import CoreMedia
import Foundation
import HaloCore
import UniformTypeIdentifiers

/// Shared AVFoundation plumbing for the video and audio families: opening media safely, running export
/// sessions with progress + cancellation on macOS 14 and 15+, and turning AVFoundation errors into
/// messages people can act on.
enum AVSupport {
    /// Containers AVFoundation reads natively that are movies. Kept explicit (rather than `.movie`) so the ring never
    /// offers a conversion for AVI/MKV/WebM files that AVFoundation can't open.
    static let threeGPP = UTType("public.3gpp") ?? .mpeg4Movie
    static let threeGPP2 = UTType("public.3gpp2") ?? .mpeg4Movie
    static let m4v = UTType("com.apple.m4v-video") ?? .mpeg4Movie
    static let caf = UTType("com.apple.coreaudio-format") ?? .audio
    static let flac = UTType("org.xiph.flac")
    /// `public.aiff-audio` conforms to this, so listing it covers both AIFF and AIFC.
    static let aifc = UTType("public.aifc-audio") ?? .aiff

    /// Media types the video family accepts.
    static let videoInputs: [UTType] = [.quickTimeMovie, .mpeg4Movie, threeGPP, threeGPP2]

    /// What's known about an input once it has been opened and vetted.
    struct Media: @unchecked Sendable {
        // AVURLAsset is immutable once created and documented as safe to use across threads.
        let asset: AVURLAsset
        let duration: CMTime
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]

        var seconds: Double {
            let s = duration.seconds
            return s.isFinite && s > 0 ? s : 0
        }
    }

    /// The only way Halo creates an `AVURLAsset`: precise timing, and every kind of external reference forbidden.
    static func makeAsset(_ url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
            // Defence in depth only: on macOS 27 a local reference movie still reads its external samples with
            // `.forbidAll`, so `open` also requires every track to be self-contained.
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
            AVURLAssetAllowsCellularAccessKey: false,
            AVURLAssetAllowsExpensiveNetworkAccessKey: false,
            AVURLAssetAllowsConstrainedNetworkAccessKey: false,
        ])
    }

    static let referenceMovieMessage = "It's a reference movie that points to media in other files or online, so Frenzy won't open it."

    /// Opens `url` and checks it can be decoded: readable, not DRM-protected, every track's media stored inside the file
    /// (no reference movies), and has the tracks the action needs.
    static func open(_ url: URL, requireVideo: Bool = false, requireAudio: Bool = false) async throws -> Media {
        let asset = makeAsset(url)
        let duration: CMTime, readable: Bool, protected: Bool
        let all: [AVAssetTrack], video: [AVAssetTrack], audio: [AVAssetTrack]
        var selfContained = true
        do {
            (duration, readable, protected) = try await asset.load(.duration, .isReadable, .hasProtectedContent)
            all = try await asset.load(.tracks)
            for track in all where !(try await track.load(.isSelfContained)) { selfContained = false }
            video = try await asset.loadTracks(withMediaType: .video)
            audio = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            // Anything other than DRM/cancellation at open time means we simply can't read it.
            let m = mapped(error, url: url)
            if case ConversionError.engine = m { throw ConversionError.unsupportedInput("It looks damaged, or macOS can't read this format.") }
            throw m
        }
        guard selfContained else { throw ConversionError.unsupportedInput(referenceMovieMessage) }
        if protected {
            throw ConversionError.unsupportedInput("It's copy-protected (DRM), so it can't be converted.")
        }
        guard readable else { throw ConversionError.unreadable(url) }
        if requireVideo && video.isEmpty {
            throw ConversionError.unsupportedInput("It has no video track.")
        }
        if requireAudio && audio.isEmpty {
            throw ConversionError.unsupportedInput("It has no sound.")
        }
        return Media(asset: asset, duration: duration, videoTracks: video, audioTracks: audio)
    }

    /// For inputs read by something other than AVAsset (AVAudioFile): refuses reference movies. Files AVFoundation
    /// can't parse at all are left for the caller's own decoder to judge.
    static func requireSelfContained(_ url: URL) async throws {
        let asset = makeAsset(url)
        guard let tracks = try? await asset.load(.tracks) else { return }
        for track in tracks where (try? await track.load(.isSelfContained)) == false {
            throw ConversionError.unsupportedInput(referenceMovieMessage)
        }
    }

    /// The four-char codec of a track's first format description, e.g. `kCMVideoCodecType_H264`.
    static func codec(of track: AVAssetTrack) async -> FourCharCode? {
        guard let descriptions = try? await track.load(.formatDescriptions), let first = descriptions.first else { return nil }
        return CMFormatDescriptionGetMediaSubType(first)
    }

    // MARK: - Metadata

    /// The text of an asset's creation date, however the file stores it. Nil when it has none.
    static func creationDateText(of asset: AVAsset) async throws -> String? {
        let items = try await asset.load(.metadata)
        let dates = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .quickTimeMetadataCreationDate)
            + AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierCreationDate)
        if let first = dates.first, let text = try await first.load(.stringValue) { return text }
        return try await asset.load(.creationDate)?.load(.stringValue)
    }

    /// `items` without anything that says where the video was shot (ISO 6709 coordinates, place names, the 3GPP
    /// `loci` box). Frenzy has no setting to keep location, so shared copies never carry it, like image Compress.
    static func withoutLocation(_ items: [AVMetadataItem]) -> [AVMetadataItem] {
        items.filter { !isLocation($0) }
    }

    /// Matched on the identifier text, so every key space (common, QuickTime, user data, 3GPP) is covered.
    static func isLocation(_ item: AVMetadataItem) -> Bool {
        if item.commonKey == .commonKeyLocation { return true }
        let id = (item.identifier?.rawValue ?? "").lowercased()
        // "\u{A9}xyz" is QuickTime user data's ISO 6709 box; "loci" is 3GPP's.
        return id.contains("location") || id.contains("%a9xyz") || id.contains("\u{A9}xyz") || id.hasSuffix("/loci")
    }

    /// One folder per volume, first come first kept. Unknown volumes count as different, so nothing goes unchecked.
    static func distinctVolumes(_ folders: [URL]) -> [URL] {
        var seen: Set<String> = [], result: [URL] = []
        for folder in folders {
            let id = (try? folder.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier.map { "\($0)" } ?? folder.path
            if seen.insert(id).inserted { result.append(folder) }
        }
        return result
    }

    // MARK: - Export sessions

    /// Runs `session` into `url`, forwarding progress and cancelling the export when the surrounding task is cancelled.
    static func export(_ session: AVAssetExportSession, to url: URL, as fileType: AVFileType,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation()
        if #available(macOS 15, *) {
            let box = SessionBox(session)
            let monitor = Task.detached {
                for await state in box.session.states(updateInterval: 0.1) {
                    if case .exporting(let p) = state { progress(p.fractionCompleted) }
                }
            }
            defer { monitor.cancel() }
            do {
                try await session.export(to: url, as: fileType)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw mapped(error, url: url)
            }
        } else {
            try await LegacyExport.run(session, to: url, as: fileType, progress: progress)
        }
        progress(1)
    }

    /// Creates an export session or explains why the preset can't be used for this file.
    static func session(for asset: AVAsset, preset: String, fileType: AVFileType) async throws -> AVAssetExportSession {
        guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: fileType),
              let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionError.unsupportedInput("macOS can't convert this file to that format.")
        }
        return session
    }

    // MARK: - Errors

    /// Turns an AVFoundation/Core Media error into a `ConversionError` with a human sentence.
    static func mapped(_ error: any Error, url: URL) -> any Error {
        if error is ConversionError || error is CancellationError { return error }
        let ns = error as NSError
        if ns.domain == AVFoundationErrorDomain, let code = AVError.Code(rawValue: ns.code) {
            switch code {
            case .contentIsProtected, .contentIsNotAuthorized, .applicationIsNotAuthorized:
                return ConversionError.unsupportedInput("It's copy-protected (DRM), so it can't be converted.")
            case .fileFormatNotRecognized, .failedToParse, .decoderNotFound, .formatUnsupported, .noDataCaptured:
                return ConversionError.unsupportedInput("macOS can't decode this file's format.")
            case .diskFull:
                return ConversionError.writeFailed(url, "The disk is full.")
            case .operationCancelled:
                return CancellationError()
            default:
                break
            }
        }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError || ns.code == NSFileReadNoPermissionError {
            return ConversionError.unreadable(url)
        }
        if ns.domain == NSOSStatusErrorDomain, ns.code == -54 /* permErr: sandbox/DRM */ {
            return ConversionError.unreadable(url)
        }
        let reason = ns.localizedFailureReason ?? ns.localizedDescription
        return ConversionError.engine("Conversion failed: \(reason)")
    }

    /// AVAssetWriter's fast-start pass can leave a "<name>.sb-XXXX" scratch file beside the output; remove it.
    static func removeWriterScratch(for url: URL) {
        let dir = url.deletingLastPathComponent(), prefix = url.lastPathComponent + ".sb-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// Byte size of a file, 0 when unknown.
    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// `AVAssetExportSession` isn't declared `Sendable` on every SDK we target; it is safe to observe its
/// state stream from another task.
private struct SessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

/// The macOS 14 path: completion-handler export with progress polling and `cancelExport()` on task cancellation.
/// Marked deprecated so the (intentional) calls to APIs deprecated in macOS 15 don't warn.
enum LegacyExport {
    @available(macOS, deprecated: 15, message: "Only used before macOS 15.")
    static func run(_ session: AVAssetExportSession, to url: URL, as fileType: AVFileType,
                    progress: @escaping @Sendable (Double) -> Void) async throws {
        let box = SessionBox(session)
        let gate = ExportGate()
        session.outputURL = url
        session.outputFileType = fileType
        let poller = Task.detached {
            while !Task.isCancelled {
                progress(Double(box.session.progress))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { poller.cancel() }
        try await withTaskCancellationHandler {
            let started: Bool = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                // A cancel that landed before this point (even before the handler was installed) wins: never start.
                guard gate.markStarted() else { return done.resume(returning: false) }
                box.session.exportAsynchronously { done.resume(returning: true) }
                // A cancel that raced `exportAsynchronously` may have called `cancelExport()` too early; repeat it now
                // that the export has really started (cancelExport is idempotent).
                if gate.isCancelled { box.session.cancelExport() }
            }
            guard started else { throw CancellationError() }
            switch box.session.status {
            case .completed:
                if gate.isCancelled { throw CancellationError() }
                return
            case .cancelled: throw CancellationError()
            default:
                if Task.isCancelled || gate.isCancelled { throw CancellationError() }
                throw AVSupport.mapped(box.session.error ?? ConversionError.engine("The export failed."), url: url)
            }
        } onCancel: {
            if gate.cancel() { box.session.cancelExport() }
        }
    }
}

/// Orders "start export" against "cancel" for `LegacyExport`.
final class ExportGate: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var cancelled = false

    /// Records the start; false when a cancel already happened (the export must not start).
    func markStarted() -> Bool {
        lock.withLock {
            if cancelled { return false }
            started = true
            return true
        }
    }

    /// Records the cancel; true when the export has started and so needs `cancelExport()`.
    func cancel() -> Bool {
        lock.withLock {
            cancelled = true
            return started
        }
    }

    var isCancelled: Bool { lock.withLock { cancelled } }
}

// MARK: - Blocking work

/// Set when the awaiting task is cancelled; polled by blocking loops that run outside Swift concurrency.
final class AVCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
    func check() throws { if isCancelled { throw CancellationError() } }
}

extension AVSupport {
    /// Threads for blocking decode/encode loops. Not the cooperative pool: GCD can add threads while these block.
    private static let blockingQueue = DispatchQueue(label: "halo.av.blocking", qos: .userInitiated, attributes: .concurrent)

    /// Runs blocking `body` on a dedicated queue, bridged with a checked continuation. Task cancellation sets the flag
    /// passed to `body`, which must poll it (`try flag.check()`) in its loop.
    static func runBlocking<T: Sendable>(_ body: @escaping @Sendable (AVCancelFlag) throws -> T) async throws -> T {
        let flag = AVCancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, any Error>) in
                blockingQueue.async {
                    do {
                        try flag.check()
                        c.resume(returning: try body(flag))
                    } catch {
                        c.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }
}
