import AVFoundation
import CoreMedia
import Foundation
import HaloCore
@testable import HaloConverters
import Testing
import UniformTypeIdentifiers
import VideoToolbox

/// What "Compress" and "Smaller" promise: nothing changes but the file size (Compress), the size cap is stated
/// (Smaller), every track and tag survives, and long jobs stay honest, cancellable and safe on a full disk.
@Suite("Video compression")
struct VideoCompressionTests {
    private func convert(_ id: ActionID, _ original: URL) async throws -> (URL, ConversionOutcome) {
        let dir = original.deletingLastPathComponent()
        let before = try AVFixtures.sha(original)
        let outcome = await AVFixtures.run(id, on: original)
        #expect(try AVFixtures.sha(original) == before, "original modified")
        #expect(AVFixtures.leftovers(in: dir).isEmpty, "temp files left behind")
        return (dir, outcome)
    }

    private func fresh(_ spec: AVFixtures.MovieSpec) async throws -> URL {
        try AVFixtures.copy(try await AVFixtures.movie(spec), into: try AVFixtures.tempDir())
    }

    private func videoFacts(_ url: URL) async throws -> (size: CGSize, transform: CGAffineTransform, frames: [CMTime]) {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        var times: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { times.append(CMSampleBufferGetPresentationTimeStamp(sample)) }
        }
        return (size, transform, times.sorted { $0 < $1 })
    }

    // MARK: Plans and ring wording

    @Test func compressNeverCapsTheSize() {
        #expect(AVTranscoder.Plan.compress.maxLongEdge == nil && AVTranscoder.Plan.compress.maxShortEdge == nil)
        let (w, h) = AVTranscoder.outputSize(width: 7680, height: 4320, plan: .compress)
        #expect(w == 7680 && h == 4320)
    }

    @Test func smallerFitsInside1080pEitherWayRound() {
        let wide = AVTranscoder.outputSize(width: 3840, height: 2160, plan: .smaller)
        #expect(wide == (1920, 1080))
        let tall = AVTranscoder.outputSize(width: 2160, height: 3840, plan: .smaller)
        #expect(tall == (1080, 1920))
        let small = AVTranscoder.outputSize(width: 1280, height: 720, plan: .smaller)
        #expect(small == (1280, 720), "never upscales")
    }

    @Test func oddSizesLoseOnePixelAtMost() {
        let (w, h) = AVTranscoder.outputSize(width: 1081, height: 1921, plan: .compress)
        #expect(w == 1080 && h == 1920)
    }

    @Test func ringWordsStateTheDifference() throws {
        let actions = Dictionary(uniqueKeysWithValues: VideoActions.all.map { ($0.id.rawValue, $0) })
        let compress = try #require(actions["video.compress"]), smaller = try #require(actions["video.smaller"])
        #expect(compress.title == "Compress" && compress.subtitle == "Looks the same")
        #expect(smaller.title == "Smaller")
        #expect(smaller.subtitle?.contains("1080p") == true, "the downscale is stated on the bubble")
        #expect(compress.defaultRank < smaller.defaultRank)
    }

    // MARK: Rate control

    @Test func rateDecisionKeepsConstantQualityWhileItFits() {
        let plan = AVTranscoder.Plan.compress
        #expect(AVTranscoder.rateDecision(sampled: 5e6, sourceRate: 20e6, sourceIsEfficient: false, plan: plan) == .constantQuality)
        #expect(AVTranscoder.rateDecision(sampled: nil, sourceRate: 20e6, sourceIsEfficient: false, plan: plan) == .constantQuality)
        #expect(AVTranscoder.rateDecision(sampled: 5e6, sourceRate: 0, sourceIsEfficient: false, plan: plan) == .constantQuality)
    }

    @Test func rateDecisionCapsACostlyPictureBelowTheSource() {
        let plan = AVTranscoder.Plan.compress
        #expect(AVTranscoder.rateDecision(sampled: 30e6, sourceRate: 20e6, sourceIsEfficient: false, plan: plan) == .average(16e6))
        #expect(AVTranscoder.rateDecision(sampled: 17e6, sourceRate: 20e6, sourceIsEfficient: true, plan: plan) == .average(16e6))
    }

    @Test func rateDecisionLeavesAnEfficientFileAloneOnlyForCompress() {
        #expect(AVTranscoder.rateDecision(sampled: 25e6, sourceRate: 20e6, sourceIsEfficient: true, plan: .compress) == .leaveAlone)
        #expect(AVTranscoder.rateDecision(sampled: 25e6, sourceRate: 20e6, sourceIsEfficient: true, plan: .smaller) == .average(12e6))
    }

    @Test func samplesSpreadAcrossLongClipsAndStayShortOnShortOnes() {
        #expect(AVTranscoder.sampleRanges(duration: 0) == [])
        #expect(AVTranscoder.sampleRanges(duration: 1.5) == [0...1.5])
        #expect(AVTranscoder.sampleRanges(duration: 10).count == 1)
        let long = AVTranscoder.sampleRanges(duration: 600)
        #expect(long.count == 3)
        #expect(long.allSatisfy { $0.upperBound - $0.lowerBound == 2 && $0.lowerBound >= 0 && $0.upperBound <= 600 })
        #expect(long[0].upperBound <= long[1].lowerBound && long[1].upperBound <= long[2].lowerBound)
    }

    @Test func sizeGuardOnlyGivesUpWhenItIsSure() {
        #expect(AVTranscoder.isHopeless(written: 100, fraction: 0.1, limit: 100))
        #expect(!AVTranscoder.isHopeless(written: 50, fraction: 0.1, limit: 100), "an early busy part proves nothing")
        #expect(!AVTranscoder.isHopeless(written: 60, fraction: 0.5, limit: 100))
        #expect(AVTranscoder.isHopeless(written: 90, fraction: 0.5, limit: 100))
    }

    // MARK: Picture

    @Test func compressKeepsResolutionAndFrames() async throws {
        var spec = AVFixtures.MovieSpec()
        spec.width = 2560; spec.height = 1440; spec.fps = 10; spec.seconds = 1; spec.audio = false; spec.bitRate = 20_000_000
        let original = try await fresh(spec)
        let (_, outcome) = try await convert("video.compress", original)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let out = try #require(outcome.outputs.first)
        #expect(out.lastPathComponent == "clip (compressed).mp4")
        let facts = try await videoFacts(out)
        #expect(facts.size == CGSize(width: 2560, height: 1440))
        #expect(facts.frames.count == 10)
        #expect(AVSupport.fileSize(out) < AVSupport.fileSize(original))
    }

    @Test func smallerCapsAt1080pAndNamesTheFile() async throws {
        var spec = AVFixtures.MovieSpec()
        spec.width = 2560; spec.height = 1440; spec.fps = 10; spec.seconds = 1; spec.audio = false; spec.bitRate = 20_000_000
        let original = try await fresh(spec)
        let (_, outcome) = try await convert("video.smaller", original)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let out = try #require(outcome.outputs.first)
        #expect(out.lastPathComponent == "clip (smaller).mp4")
        let facts = try await videoFacts(out)
        #expect(facts.size == CGSize(width: 1920, height: 1080))
        #expect(facts.frames.count == 10, "frame rate is kept")
        #expect(AVSupport.fileSize(out) < AVSupport.fileSize(original))
    }

    @Test func smallerKeepsHDR() async throws {
        var spec = AVFixtures.MovieSpec.hdr(.hlg)
        spec.width = 2560; spec.height = 1440; spec.bitRate = 30_000_000; spec.seconds = 1
        let original = try await fresh(spec)
        let (_, outcome) = try await convert("video.smaller", original)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let out = try #require(outcome.outputs.first)
        let color = try await AVFixtures.color(of: out)
        #expect(color.isHDR && color.bitsPerComponent == 10)
    }

    @Test func portraitRotationSurvives() async throws {
        let dir = try AVFixtures.tempDir()
        let rotated = dir.appendingPathComponent("portrait.mov")
        let transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0)
        try await TrackFixtures.export(video: try await AVFixtures.movie(), audio: [], transform: transform, to: rotated)
        let (_, outcome) = try await convert("video.compress", rotated)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let facts = try await videoFacts(try #require(outcome.outputs.first))
        #expect(facts.transform == transform)
        #expect(facts.size == CGSize(width: 640, height: 360))
    }

    @Test func variableFrameRateKeepsEveryTimestamp() async throws {
        let source = try TrackFixtures.variableFrameRateMovie(in: try AVFixtures.tempDir())
        let expected = try await videoFacts(source).frames
        let (_, outcome) = try await convert("video.compress", source)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let got = try await videoFacts(try #require(outcome.outputs.first)).frames
        #expect(got.count == expected.count)
        for (a, b) in zip(got, expected) { #expect(abs((a - b).seconds) < 0.002, "\(a.seconds) vs \(b.seconds)") }
    }

    @Test func alphaStaysAlphaInAMOV() async throws {
        var spec = AVFixtures.MovieSpec()
        spec.codec = .proRes4444; spec.seconds = 0.5; spec.audio = false
        let original = try await fresh(spec)
        let source = try await AVFixtures.color(of: original)
        try #require(source.hasAlpha, "fixture has no alpha")
        let (_, outcome) = try await convert("video.compress", original)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let out = try #require(outcome.outputs.first)
        #expect(out.pathExtension == "mov")
        let color = try await AVFixtures.color(of: out)
        #expect(color.hasAlpha, "alpha was flattened")
        #expect(color.codec == kCMVideoCodecType_HEVCWithAlpha)
    }

    // MARK: Sound

    @Test func everyAudioTrackAndItsStateSurvive() async throws {
        let dir = try AVFixtures.tempDir()
        let source = dir.appendingPathComponent("tracks.mov")
        let movie = try await AVFixtures.movie()
        let extra = try AVFixtures.tone(ext: "m4a", seconds: 2.5)
        try await TrackFixtures.export(video: movie, audio: [(movie, true, "eng"), (extra, false, "fra")], to: source)
        let (_, outcome) = try await convert("video.compress", source)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let asset = AVURLAsset(url: try #require(outcome.outputs.first))
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(tracks.count == 2)
        let states = try await tracks.asyncStates()
        #expect(states.map(\.enabled) == [true, false])
        #expect(states.map(\.language) == ["eng", "fra"])
        #expect(states.map(\.codec) == [kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC], "AAC is copied, never mixed down")
    }

    @Test func pcmBecomesAACAndStaysInSync() async throws {
        let dir = try AVFixtures.tempDir()
        let source = dir.appendingPathComponent("pcm.mov")
        let movie = try await AVFixtures.movie()
        try await TrackFixtures.export(video: movie, audio: [(try AVFixtures.tone(ext: "wav", seconds: 2.5), true, nil)], to: source)
        let (_, outcome) = try await convert("video.compress", source)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let out = try #require(outcome.outputs.first)
        #expect(out.pathExtension == "mp4")
        let track = try #require(try await AVURLAsset(url: out).loadTracks(withMediaType: .audio).first)
        #expect(await AVSupport.codec(of: track) == kAudioFormatMPEG4AAC)
        let range = try await track.load(.timeRange)
        #expect(abs(range.duration.seconds - 2.5) < 0.05)
        #expect(abs(range.start.seconds) < 0.05)
    }

    @Test func theSmallerActionCarriesEveryTrackToo() async throws {
        let dir = try AVFixtures.tempDir()
        let source = dir.appendingPathComponent("tracks.mov")
        let movie = try await AVFixtures.movie()
        let extra = try AVFixtures.tone(ext: "m4a", seconds: 2.5)
        try await TrackFixtures.export(video: movie, audio: [(movie, true, "eng"), (extra, false, "fra")], to: source)
        let (_, outcome) = try await convert("video.smaller", source)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let tracks = try await AVURLAsset(url: try #require(outcome.outputs.first)).loadTracks(withMediaType: .audio)
        #expect(tracks.count == 2)
    }

    // MARK: Metadata

    @Test func creationDateSurvivesEvenInAnMP4() async throws {
        let dir = try AVFixtures.tempDir()
        let source = dir.appendingPathComponent("dated.mov")
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataCreationDate
        item.value = "2024-03-05T10:20:30+0530" as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        let movie = try await AVFixtures.movie()
        try await TrackFixtures.export(video: movie, audio: [(movie, true, nil)], metadata: [item], to: source)
        let (_, outcome) = try await convert("video.compress", source)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let out = try #require(outcome.outputs.first)
        #expect(out.pathExtension == "mp4")
        let date = try await AVSupport.creationDateText(of: AVURLAsset(url: out))
        #expect(date == "2024-03-05T10:20:30+0530", "\(String(describing: date))")
    }

    @Test func locationIsDroppedButTheDateStays() async throws {
        let dir = try AVFixtures.tempDir()
        let source = dir.appendingPathComponent("placed.mov")
        func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = id
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            return item
        }
        let movie = try await AVFixtures.movie()
        try await TrackFixtures.export(video: movie, audio: [(movie, true, nil)], metadata: [
            item(.quickTimeMetadataCreationDate, "2024-03-05T10:20:30+0530"),
            item(.quickTimeMetadataLocationISO6709, "+28.6139+077.2090+000.000/"),
            item(.quickTimeMetadataModel, "iPhone"),
        ], to: source)
        let placed = try await AVURLAsset(url: source).load(.metadata)
        #expect(placed.contains(where: AVSupport.isLocation), "fixture should carry a location")
        let (_, outcome) = try await convert("video.compress", source)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let asset = AVURLAsset(url: try #require(outcome.outputs.first))
        let items = try await asset.load(.metadata)
        #expect(!items.contains(where: AVSupport.isLocation), "\(items.map { $0.identifier?.rawValue ?? "?" })")
        #expect(items.contains { $0.identifier == .quickTimeMetadataModel })
        #expect(try await AVSupport.creationDateText(of: asset) == "2024-03-05T10:20:30+0530")
    }

    @Test func everyLocationKeySpaceIsRecognised() {
        for id: AVMetadataIdentifier in [.quickTimeMetadataLocationISO6709, .quickTimeUserDataLocationISO6709, .commonIdentifierLocation,
                                         .quickTimeMetadataLocationName, .identifier3GPUserDataLocation] {
            let item = AVMutableMetadataItem()
            item.identifier = id
            #expect(AVSupport.isLocation(item), "\(id.rawValue)")
        }
        let date = AVMutableMetadataItem()
        date.identifier = .quickTimeMetadataCreationDate
        #expect(!AVSupport.isLocation(date))
    }

    // MARK: Honest results

    @Test func alreadyEfficientFileIsLeftAloneCalmly() async throws {
        var spec = AVFixtures.MovieSpec()
        spec.codec = .hevc; spec.bitRate = 120_000; spec.seconds = 1.5; spec.audio = false
        let original = try await fresh(spec)
        let (dir, outcome) = try await convert("video.compress", original)
        #expect(outcome.outputs.isEmpty)
        let message = try #require(outcome.failures.first?.message)
        #expect(ConversionError.isAlreadySmall(message), "\(message)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["clip.mov"])
    }

    @Test func aResultIsNeverLargerThanTheSource() async throws {
        var spec = AVFixtures.MovieSpec()
        spec.bitRate = 100_000; spec.seconds = 1.5; spec.audio = false
        let original = try await fresh(spec)
        let (dir, outcome) = try await convert("video.compress", original)
        if let out = outcome.outputs.first {
            #expect(AVSupport.fileSize(out) < AVSupport.fileSize(original))
        } else {
            let message = try #require(outcome.failures.first?.message)
            #expect(ConversionError.isAlreadySmall(message), "\(message)")
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["clip.mov"])
        }
    }

    @Test func progressClimbsInStepsAndEndsAtOne() async throws {
        var spec = AVFixtures.MovieSpec()
        spec.width = 1280; spec.height = 720; spec.seconds = 3
        let original = try await fresh(spec)
        let values = ProgressLog()
        let input = try #require(InputFile(url: original))
        let outcome = await ConversionRunner(registry: AVFixtures.registry, maxConcurrent: 1)
            .run("video.compress", on: [input], progress: { values.add($0) })
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let seen = values.all
        #expect(seen.count >= 3)
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 <= $1 }, "progress went backwards")
        #expect(seen.last == 1)
        #expect(seen.count <= 90 + 110, "\(seen.count) updates for 90 frames: throttled to ten a second or one per cent")
    }

    // MARK: Disk and cancel

    @Test func diskGuardGivesAClearMessage() throws {
        let tight = DiskGuard { _ in 300 << 20 }
        #expect(throws: Never.self) { try tight.requireRoom(100 << 20, in: [URL(fileURLWithPath: "/tmp")]) }
        do {
            try tight.requireRoom(2 << 30, in: [URL(fileURLWithPath: "/tmp")])
            Issue.record("should have refused")
        } catch {
            let text = error.localizedDescription
            #expect(text.contains("free space") && text.contains("2.1 GB") && text.contains("315 MB"), "\(text)")
            #expect(!text.contains("\u{2014}"), "no em dashes in copy")
        }
        let unknown = DiskGuard { _ in nil }
        #expect(throws: Never.self) { try unknown.requireRoom(1 << 40, in: [URL(fileURLWithPath: "/tmp")]) }
    }

    @Test func diskFillingUpMidwayStopsCleanly() async throws {
        let source = try await longMovie()
        let dir = try AVFixtures.tempDir()
        let out = dir.appendingPathComponent("out.mp4")
        let media = try await AVSupport.open(source, requireVideo: true)
        let prepared = try await AVTranscoder.prepare(media, plan: .compress)
        let guards = AVTranscoder.Guards(disk: DiskGuard { _ in 20 << 20 }, watchedFolders: [dir])
        do {
            try await AVTranscoder.transcode(prepared, to: out, guards: guards, progress: { _ in })
            Issue.record("should have stopped")
        } catch {
            #expect(error.localizedDescription == DiskGuard.ranOutError.localizedDescription)
        }
    }

    @Test func cancelIsFastAndLeavesNothing() async throws {
        let source = try await longMovie()
        let dir = try AVFixtures.tempDir()
        let original = try AVFixtures.copy(source, into: dir)
        let started = ProgressLog()
        let input = try #require(InputFile(url: original))
        let task = Task {
            await ConversionRunner(registry: AVFixtures.registry, maxConcurrent: 1).run("video.compress", on: [input], progress: { started.add($0) })
        }
        // Wait until real encoding is under way, past the sampling.
        while (started.all.last ?? 0) < 0.03, !task.isCancelled {
            try await Task.sleep(for: .milliseconds(10))
            if started.all.count > 2000 { break }
        }
        let cancelledAt = Date()
        task.cancel()
        let outcome = await task.value
        let took = Date().timeIntervalSince(cancelledAt)
        #expect(outcome.failures.first?.message == "Cancelled.", "\(outcome.failures.map(\.message))")
        #expect(took < 2, "cancel took \(took) s")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["clip.mov"])
    }

    /// A movie long and heavy enough that encoding it takes seconds, not milliseconds.
    private func longMovie() async throws -> URL {
        var spec = AVFixtures.MovieSpec()
        spec.width = 1920; spec.height = 1080; spec.seconds = 8; spec.audio = false; spec.bitRate = 40_000_000
        return try await AVFixtures.movie(spec)
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ v: Double) { lock.withLock { values.append(v) } }
    var all: [Double] { lock.withLock { values } }
}

private struct TrackState { var enabled: Bool; var language: String?; var codec: FourCharCode? }

private extension Array where Element == AVAssetTrack {
    func asyncStates() async throws -> [TrackState] {
        var out: [TrackState] = []
        for track in self {
            let (enabled, language) = try await track.load(.isEnabled, .languageCode)
            out.append(TrackState(enabled: enabled, language: language, codec: await AVSupport.codec(of: track)))
        }
        return out
    }
}

/// Fixtures that need more than one track, a rotation, metadata or uneven timing.
enum TrackFixtures {
    /// A passthrough export of `video`'s picture with the given audio tracks, rotation and metadata.
    static func export(video: URL, audio: [(url: URL, enabled: Bool, language: String?)], transform: CGAffineTransform? = nil,
                       metadata: [AVMetadataItem] = [], to url: URL) async throws {
        let composition = AVMutableComposition()
        let source = AVURLAsset(url: video)
        let videoTrack = try #require(try await source.loadTracks(withMediaType: .video).first)
        let range = try await videoTrack.load(.timeRange)
        let target = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try target.insertTimeRange(range, of: videoTrack, at: .zero)
        let sourceTransform = try await videoTrack.load(.preferredTransform)
        target.preferredTransform = transform ?? sourceTransform
        var alternates: [AVMutableCompositionTrack] = []
        for part in audio {
            let asset = AVURLAsset(url: part.url)
            let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
            let trackRange = try await track.load(.timeRange)
            let added = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            try added.insertTimeRange(CMTimeRange(start: trackRange.start, duration: min(trackRange.duration, range.duration)), of: track, at: .zero)
            added.isEnabled = part.enabled
            if let language = part.language { added.languageCode = language }
            alternates.append(added)
        }
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        session.metadata = metadata
        try await session.export(to: url, as: .mov)
    }

    /// 40 frames at uneven intervals, like a screen recording that only writes when something changes.
    static func variableFrameRateMovie(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("vfr.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var generator = SystemRandomNumberGenerator()
        var time = CMTime.zero
        for frame in 0..<40 {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            for i in 0..<CVPixelBufferGetDataSize(pixels) { base[i] = UInt8.random(in: 0...255, using: &generator) }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            #expect(adaptor.append(pixels, withPresentationTime: time))
            // 1/60 s, 1/30 s, 1/10 s in turn.
            time = time + CMTime(value: [1, 2, 6][frame % 3], timescale: 60)
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        #expect(writer.status == .completed, "\(String(describing: writer.error))")
        return url
    }
}
