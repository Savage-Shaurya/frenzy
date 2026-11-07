import AVFoundation
import CoreMedia
import Foundation
import HaloCore
@testable import HaloConverters
import Testing
import UniformTypeIdentifiers

/// VIDEO (hardware encoder). Off unless FRENZY_VIDEO_TESTS=1, and then only one test at a time with the founder's OK.
/// TINY clips only: 640 x 360, 1 to 3 s. The big ones live in `VideoCompressionLargeClipTests`, run after these pass.
///
/// What Compress and Smaller promise: same size and frame rate (Compress), a stated cap (Smaller), every track, the
/// rotation and the date survive, location doesn't, results are honest, and a full disk stops before any encoder.
@Suite("Video compression, tiny clips", .enabled(if: HardwareVideoTests.allowed), .serialized)
struct VideoCompressionTests {
    // MARK: Picture

    @Test func compressKeepsResolutionAndFrames() async throws {
        var spec = AVFixtures.MovieSpec()
        spec.seconds = 1; spec.audio = false
        let original = try await VideoCheck.fresh(spec)
        let outcome = try await VideoCheck.convert("video.compress", original)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let out = try #require(outcome.outputs.first)
        #expect(out.lastPathComponent == "clip (compressed).mp4")
        let facts = try await VideoCheck.videoFacts(out)
        #expect(facts.size == CGSize(width: 640, height: 360))
        #expect(facts.frames.count == 30)
        #expect(AVSupport.fileSize(out) < AVSupport.fileSize(original))
    }

    /// Constant quality (x264 CRF), so no fixed target: the video only has to come out clearly below the source's.
    @Test func compressIsQualityFirstAndSmaller() async throws {
        let original = try await VideoCheck.fresh(.init())
        let sourceTrack = try #require(try await AVURLAsset(url: original).loadTracks(withMediaType: .video).first)
        let sourceRate = Double(try await sourceTrack.load(.estimatedDataRate))
        let outcome = try await VideoCheck.convert("video.compress", original)
        let out = try #require(outcome.outputs.first)
        let track = try #require(try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first)
        let rate = Double(try await track.load(.estimatedDataRate))
        #expect(rate > 0 && rate < sourceRate * 0.95, "\(rate) vs source \(sourceRate)")
        #expect(CMFormatDescriptionGetMediaSubType(try #require(try await track.load(.formatDescriptions).first)) == kCMVideoCodecType_H264)
    }

    @Test func smallerOnAClipAlreadyUnder1080pKeepsItsSize() async throws {
        var spec = AVFixtures.MovieSpec()
        spec.seconds = 1; spec.audio = false
        let original = try await VideoCheck.fresh(spec)
        let outcome = try await VideoCheck.convert("video.smaller", original)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let out = try #require(outcome.outputs.first)
        #expect(out.lastPathComponent == "clip (smaller).mp4")
        #expect(try await VideoCheck.videoFacts(out).size == CGSize(width: 640, height: 360), "never upscales")
    }

    /// The downscale path on a tiny clip: the Smaller plan with a 320 x 180 cap instead of 1080p.
    @Test func smallerPlanDownscalesAndKeepsEveryFrame() async throws {
        var spec = AVFixtures.MovieSpec()
        spec.seconds = 1; spec.audio = false
        let original = try await VideoCheck.fresh(spec)
        var plan = AVTranscoder.Plan.smaller
        plan.maxLongEdge = 320; plan.maxShortEdge = 180
        let prepared = try await AVTranscoder.prepare(try await AVSupport.open(original, requireVideo: true), plan: plan)
        #expect(prepared.width == 320 && prepared.height == 180 && prepared.needsScaling)
        let out = original.deletingLastPathComponent().appendingPathComponent("small.mp4")
        _ = try await X264Compress.run(prepared, input: original, output: out, progress: { _ in })
        let facts = try await VideoCheck.videoFacts(out)
        #expect(facts.size == CGSize(width: 320, height: 180))
        #expect(facts.frames.count == 30, "frame rate is kept")
    }

    @Test func smallerKeepsHDR() async throws {
        var spec = AVFixtures.MovieSpec.hdr(.hlg)
        spec.bitRate = 20_000_000; spec.seconds = 1
        let original = try await VideoCheck.fresh(spec)
        let outcome = try await VideoCheck.convert("video.smaller", original)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let color = try await AVFixtures.color(of: try #require(outcome.outputs.first))
        #expect(color.isHDR && color.bitsPerComponent == 10)
    }

    @Test func portraitRotationSurvives() async throws {
        let dir = try AVFixtures.tempDir()
        let rotated = dir.appendingPathComponent("portrait.mov")
        let transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0)
        try await TrackFixtures.export(video: try await AVFixtures.movie(), audio: [], transform: transform, to: rotated)
        let outcome = try await VideoCheck.convert("video.compress", rotated)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let facts = try await VideoCheck.videoFacts(try #require(outcome.outputs.first))
        #expect(facts.transform == transform)
        #expect(facts.size == CGSize(width: 640, height: 360))
    }

    @Test func variableFrameRateKeepsEveryTimestamp() async throws {
        let source = try TrackFixtures.variableFrameRateMovie(in: try AVFixtures.tempDir())
        let expected = try await VideoCheck.videoFacts(source).frames
        let outcome = try await VideoCheck.convert("video.compress", source)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let got = try await VideoCheck.videoFacts(try #require(outcome.outputs.first)).frames
        #expect(got.count == expected.count)
        for (a, b) in zip(got, expected) { #expect(abs((a - b).seconds) < 0.002, "\(a.seconds) vs \(b.seconds)") }
    }

    // MARK: Sound

    @Test func everyAudioTrackAndItsStateSurvive() async throws {
        let dir = try AVFixtures.tempDir()
        let source = dir.appendingPathComponent("tracks.mov")
        let movie = try await AVFixtures.movie()
        let extra = try AVFixtures.tone(ext: "m4a", seconds: 2.5)
        try await TrackFixtures.export(video: movie, audio: [(movie, true, "eng"), (extra, false, "fra")], to: source)
        let outcome = try await VideoCheck.convert("video.compress", source)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let tracks = try await AVURLAsset(url: try #require(outcome.outputs.first)).loadTracks(withMediaType: .audio)
        #expect(tracks.count == 2)
        let states = try await VideoCheck.states(tracks)
        #expect(states.map(\.enabled) == [true, false])
        #expect(states.map(\.language) == ["eng", "fra"])
        #expect(states.map(\.codec) == [kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC], "AAC is copied, never mixed down")
    }

    @Test func aacIsCopiedByteForByte() async throws {
        let original = try await VideoCheck.fresh(.init())
        let outcome = try await VideoCheck.convert("video.compress", original)
        let out = try #require(outcome.outputs.first)
        #expect(try await VideoCheck.audioPackets(original) == (try await VideoCheck.audioPackets(out)), "audio was re-encoded")
    }

    @Test func pcmBecomesAACAndStaysInSync() async throws {
        let dir = try AVFixtures.tempDir()
        let source = dir.appendingPathComponent("pcm.mov")
        let movie = try await AVFixtures.movie()
        try await TrackFixtures.export(video: movie, audio: [(try AVFixtures.tone(ext: "wav", seconds: 2.5), true, nil)], to: source)
        let outcome = try await VideoCheck.convert("video.compress", source)
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
        let outcome = try await VideoCheck.convert("video.smaller", source)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        #expect(try await AVURLAsset(url: try #require(outcome.outputs.first)).loadTracks(withMediaType: .audio).count == 2)
    }

    // MARK: Metadata

    @Test func creationDateSurvivesEvenInAnMP4() async throws {
        let dir = try AVFixtures.tempDir()
        let source = dir.appendingPathComponent("dated.mov")
        let movie = try await AVFixtures.movie()
        try await TrackFixtures.export(video: movie, audio: [(movie, true, nil)],
                                       metadata: [VideoCheck.item(.quickTimeMetadataCreationDate, "2024-03-05T10:20:30+0530")], to: source)
        let outcome = try await VideoCheck.convert("video.compress", source)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let out = try #require(outcome.outputs.first)
        #expect(out.pathExtension == "mp4")
        let date = try await AVSupport.creationDateText(of: AVURLAsset(url: out))
        #expect(date == "2024-03-05T10:20:30+0530", "\(String(describing: date))")
    }

    @Test func locationIsDroppedButTheDateStays() async throws {
        let dir = try AVFixtures.tempDir()
        let source = dir.appendingPathComponent("placed.mov")
        let movie = try await AVFixtures.movie()
        try await TrackFixtures.export(video: movie, audio: [(movie, true, nil)], metadata: [
            VideoCheck.item(.quickTimeMetadataCreationDate, "2024-03-05T10:20:30+0530"),
            VideoCheck.item(.quickTimeMetadataLocationISO6709, "+28.6139+077.2090+000.000/"),
            VideoCheck.item(.quickTimeMetadataModel, "iPhone"),
        ], to: source)
        #expect(try await AVURLAsset(url: source).load(.metadata).contains(where: AVSupport.isLocation), "fixture should carry a location")
        let outcome = try await VideoCheck.convert("video.compress", source)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let asset = AVURLAsset(url: try #require(outcome.outputs.first))
        let items = try await asset.load(.metadata)
        #expect(!items.contains(where: AVSupport.isLocation), "\(items.map { $0.identifier?.rawValue ?? "?" })")
        #expect(items.contains { $0.identifier == .quickTimeMetadataModel })
        #expect(try await AVSupport.creationDateText(of: asset) == "2024-03-05T10:20:30+0530")
    }

    // MARK: Honest results

    /// Decided before encoding: the encoder is never started for it.
    @Test func alreadyLeanHEVCIsLeftAloneCalmly() async throws {
        var spec = AVFixtures.MovieSpec()
        spec.codec = .hevc; spec.bitRate = 120_000; spec.seconds = 1.5; spec.audio = false
        let original = try await VideoCheck.fresh(spec)
        let outcome = try await VideoCheck.convert("video.compress", original)
        #expect(outcome.outputs.isEmpty)
        let message = try #require(outcome.failures.first?.message)
        #expect(ConversionError.isAlreadySmall(message), "\(message)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: original.deletingLastPathComponent().path) == ["clip.mov"])
    }

    @Test func aResultIsNeverLargerThanTheSource() async throws {
        var spec = AVFixtures.MovieSpec()
        spec.bitRate = 100_000; spec.seconds = 1.5; spec.audio = false
        let original = try await VideoCheck.fresh(spec)
        let outcome = try await VideoCheck.convert("video.compress", original)
        if let out = outcome.outputs.first {
            #expect(AVSupport.fileSize(out) < AVSupport.fileSize(original))
        } else {
            let message = try #require(outcome.failures.first?.message)
            #expect(ConversionError.isAlreadySmall(message), "\(message)")
            #expect(try FileManager.default.contentsOfDirectory(atPath: original.deletingLastPathComponent().path) == ["clip.mov"])
        }
    }

    @Test func progressClimbsAndEndsAtOne() async throws {
        var spec = AVFixtures.MovieSpec()
        spec.seconds = 3
        let original = try await VideoCheck.fresh(spec)
        let values = VideoProgressLog()
        let input = try #require(InputFile(url: original))
        let outcome = await ConversionRunner(registry: AVFixtures.registry, maxConcurrent: 1)
            .run("video.compress", on: [input], progress: { values.add($0) })
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let seen = values.all
        #expect(seen.count >= 3)
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 <= $1 }, "progress went backwards")
        #expect(seen.last == 1)
        #expect(seen.count <= 90 + 110, "\(seen.count) updates for 90 frames")
    }

    // MARK: Safety

    /// A disk that is already nearly full: refused before a reader, writer or encoder exists.
    @Test func nearlyFullDiskNeverStartsTheEncoder() async throws {
        let original = try await VideoCheck.fresh(.init())
        let dir = try AVFixtures.tempDir()
        let out = dir.appendingPathComponent("out.mp4")
        let prepared = try await AVTranscoder.prepare(try await AVSupport.open(original, requireVideo: true), plan: .compress)
        let guards = AVTranscoder.Guards(disk: DiskGuard { _ in 20 << 20 }, watchedFolders: [dir])
        await #expect(throws: ConversionError.self) { try await AVTranscoder.transcode(prepared, to: out, guards: guards, progress: { _ in }) }
        #expect(!FileManager.default.fileExists(atPath: out.path))
        #expect(!HardwareEncodeGate.shared.isEncoding)
    }

    /// Two drops at once: the gate runs them one after the other, and both finish.
    @Test func twoJobsAtOnceTakeTurns() async throws {
        let a = try await VideoCheck.fresh(.init()), b = try await VideoCheck.fresh(.init())
        async let first = AVFixtures.run("video.compress", on: a)
        async let second = AVFixtures.run("video.smaller", on: b)
        let (x, y) = await (first, second)
        #expect(x.succeeded && y.succeeded, "\(x.failures.map(\.message)) \(y.failures.map(\.message))")
        #expect(!HardwareEncodeGate.shared.isEncoding)
    }

    // (The "busy encoder falls back to Apple's software encoder" test is gone with that path: Compress never uses
    // Apple's encoders now, so there is nothing to fall back from.)
}

// MARK: - Shared helpers for the compression suites

enum VideoCheck {
    static func fresh(_ spec: AVFixtures.MovieSpec) async throws -> URL {
        try AVFixtures.copy(try await AVFixtures.movie(spec), into: try AVFixtures.tempDir())
    }

    /// Runs `id` on `original`, checking the original is untouched and nothing temporary is left behind.
    static func convert(_ id: ActionID, _ original: URL) async throws -> ConversionOutcome {
        let dir = original.deletingLastPathComponent()
        let before = try AVFixtures.sha(original)
        let outcome = await AVFixtures.run(id, on: original)
        #expect(try AVFixtures.sha(original) == before, "original modified")
        #expect(AVFixtures.leftovers(in: dir).isEmpty, "temp files left behind")
        return outcome
    }

    /// Size, rotation and every frame's timestamp. Reads compressed samples only (no decode).
    static func videoFacts(_ url: URL) async throws -> (size: CGSize, transform: CGAffineTransform, frames: [CMTime]) {
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

    /// The first audio track's compressed packet sizes, to tell a copy from a re-encode.
    static func audioPackets(_ url: URL) async throws -> [Int] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        var sizes: [Int] = []
        // Per packet: how the reader groups packets into buffers depends on the file's chunking, not its sound.
        while let sample = output.copyNextSampleBuffer() {
            for i in 0..<CMSampleBufferGetNumSamples(sample) { sizes.append(CMSampleBufferGetSampleSize(sample, at: i)) }
        }
        return sizes
    }

    struct TrackState { var enabled: Bool; var language: String?; var codec: FourCharCode? }

    static func states(_ tracks: [AVAssetTrack]) async throws -> [TrackState] {
        var out: [TrackState] = []
        for track in tracks {
            let (enabled, language) = try await track.load(.isEnabled, .languageCode)
            out.append(TrackState(enabled: enabled, language: language, codec: await AVSupport.codec(of: track)))
        }
        return out
    }

    static func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = id
        item.value = value as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }
}

final class VideoProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ v: Double) { lock.withLock { values.append(v) } }
    var all: [Double] { lock.withLock { values } }
}

/// Fixtures that need more than one track, a rotation, metadata or uneven timing.
enum TrackFixtures {
    /// A passthrough export (no encoding) of `video`'s picture with the given audio tracks, rotation and metadata.
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
        for part in audio {
            let asset = AVURLAsset(url: part.url)
            let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
            let trackRange = try await track.load(.timeRange)
            let added = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            try added.insertTimeRange(CMTimeRange(start: trackRange.start, duration: min(trackRange.duration, range.duration)), of: track, at: .zero)
            added.isEnabled = part.enabled
            if let language = part.language { added.languageCode = language }
        }
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        session.metadata = metadata
        try await session.export(to: url, as: .mov)
    }

    /// 40 frames at uneven intervals (1/60, 1/30, 1/10 s in turn), like a screen recording that only writes when
    /// something changes. Made by the developer FFmpeg's x264 on the CPU, never Apple's writer (the hardware encoder):
    /// a 60 fps pattern keeps frames 0, 1 and 3 of every 9.
    static func variableFrameRateMovie(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("vfr.mov")
        let args = ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=640x360:r=60:d=3",
                    "-vf", "select=eq(mod(n\\,9)\\,0)+eq(mod(n\\,9)\\,1)+eq(mod(n\\,9)\\,3),noise=alls=60:allf=t,format=yuv420p",
                    "-fps_mode", "vfr", "-frames:v", "40", "-c:v", "libx264", "-preset", "ultrafast", "-b:v", "8M",
                    "-video_track_timescale", "600", "-f", "mov", url.path]
        let done = try EngineFixtures.shell(EngineFixtures.devFFmpeg, args)
        #expect(done.status == 0, "\(done.output)")
        return url
    }
}
