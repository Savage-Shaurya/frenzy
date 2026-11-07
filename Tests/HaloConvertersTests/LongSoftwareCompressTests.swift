import AVFoundation
import IOKit
import Foundation
import HaloCore
import Testing
@testable import HaloConverters

/// The founder's bar (7 Nov 2026): a 1-second clip proves nothing, Compress must hold up on a clip of 5 and then
/// 10 minutes. This runs the app's real Compress (`AVTranscoder.prepare` + `transcode`) on a long 1080p clip, pinned to
/// Apple's software encoder, and proves the hardware encoder (the one that panicked the Mac) is never opened.
///
/// ENCODES VIDEO. Only with FRENZY_VIDEO_TESTS=1 and FRENZY_LONG_VIDEO_MINUTES=<minutes>, after the founder's yes,
/// alone, inside scripts/video-safety-probe.sh:
///   FRENZY_VIDEO_TESTS=1 FRENZY_LONG_VIDEO_MINUTES=5 scripts/video-safety-probe.sh watch -- \
///     scripts/test.sh --filter LongSoftwareCompress
@Suite("Long software compress", .enabled(if: HardwareVideoTests.allowed && (LongVideo.minutes != nil || LongVideo.realSource != nil)), .serialized)
struct LongSoftwareCompressTests {
    /// The source: a real file (FRENZY_LONG_VIDEO_SOURCE, copied to temp, the original only read), or software H.264
    /// 1080p30 moving noise (no hardware anywhere).
    private func source() async throws -> (url: URL, bytes: Int, seconds: Double, shownFrames: Int, audioTracks: Int) {
        let clock = Date()
        let source: URL
        if let real = LongVideo.realSource {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-longvideo-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            source = dir.appendingPathComponent(real.lastPathComponent)
            try FileManager.default.copyItem(at: real, to: source)
        } else {
            let minutes = try #require(LongVideo.minutes)
            source = try SoftwareMovieWriter.write(codec: .h264, width: 1920, height: 1080, fps: 30, seconds: minutes * 60,
                                                   tenBit: false, fastFill: true)
        }
        let bytes = LongVideo.size(source)
        // Formats macOS can't open (WebM, MKV, AVI...) would hang AVFoundation: read them with the engine's probe.
        if ["webm", "mkv", "avi", "flv", "wmv", "ogv", "ts"].contains(source.pathExtension.lowercased()) {
            let probe = try await MediaEngine.probe(source)
            print("[long-video] source: \(source.lastPathComponent), \(String(format: "%.1f", probe.seconds)) s (engine probe), "
                  + "\(probe.audio.count) sound track(s), \(LongVideo.mb(bytes))")
            return (source, bytes, probe.seconds, -1, probe.audio.count)
        }
        let asset = AVURLAsset(url: source)
        let seconds = try await asset.load(.duration).seconds
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let fps = Double(try await track.load(.nominalFrameRate))
        let audio = try await asset.loadTracks(withMediaType: .audio).count
        print("[long-video] source: \(source.lastPathComponent), \(String(format: "%.1f", seconds)) s at \(String(format: "%.2f", fps)) fps, "
              + "\(audio) sound track(s), \(LongVideo.mb(bytes)), ready in \(LongVideo.secs(clock))")
        return (source, bytes, seconds, Int((seconds * fps).rounded()), audio)
    }

    private func startWatch() -> LongVideo.Peak {
        #expect(AVEWatch.userClientCount() == 0, "start from a quiet Mac: no app may hold the hardware encoder")
        let watch = LongVideo.Peak()
        Thread { while !watch.stopped { watch.note(AVEWatch.userClientCount()); usleep(5_000) } }.start()
        return watch
    }

    private func check(_ out: URL, took: Double, source: (url: URL, bytes: Int, seconds: Double, shownFrames: Int, audioTracks: Int),
                       watch: LongVideo.Peak, label: String, mustShrink: Bool = true) async throws {
        usleep(300_000)
        watch.stop()
        let peak = watch.value
        if let keep = LongVideo.keepOutput { try? FileManager.default.removeItem(at: keep); try FileManager.default.copyItem(at: out, to: keep) }
        if peak > 0 { print("[long-video] hardware encoder held by: \(watch.seenHolders)") }
        let outBytes = LongVideo.size(out)
        let asset = AVURLAsset(url: out)
        let duration = try await asset.load(.duration).seconds
        let frames = try await LongVideo.sampleCount(asset)
        let audio = try await asset.loadTracks(withMediaType: .audio).count
        print("[long-video] \(label): \(LongVideo.mb(source.bytes)) -> \(LongVideo.mb(outBytes)) "
              + "(\(String(format: "%.0f", 100 * (1 - Double(outBytes) / Double(max(1, source.bytes)))))% smaller) in \(String(format: "%.1f", took)) s "
              + "(\(String(format: "%.0f", Double(frames) / took)) fps, \(String(format: "%.1f", source.seconds / took))x real time), "
              + "\(frames) frames, \(String(format: "%.2f", duration)) s, \(audio) sound track(s), AVE peak \(peak)")
        #expect(peak == 0, "the hardware encoder was opened during a software-only compress")
        #expect(abs(duration - source.seconds) < 0.5)
        if source.shownFrames >= 0 { #expect(abs(frames - source.shownFrames) <= 2) }
        #expect(audio >= source.audioTracks, "every sound track macOS sees is kept (MP3-in-MP4 becomes audible AAC)")
        #expect(outBytes > 0)
        if mustShrink { #expect(outBytes < source.bytes, "Compress must make the file smaller") }
        #expect(!HardwareEncodeGate.shared.isEncoding)
    }

    /// A whole video action, exactly as the app runs it: "video.compress" unless FRENZY_LONG_VIDEO_ACTION names another
    /// (video.smaller, video.to-hevc, video.to-mp4, video.foreign-to-mp4, video.foreign-to-hevc).
    @Test func compressALongClipLikeTheApp() async throws {
        try #require(MediaEngine.isAvailable, "the media engine is needed: scripts/build-media-engine.sh")
        let action = ProcessInfo.processInfo.environment["FRENZY_LONG_VIDEO_ACTION"] ?? "video.compress"
        let src = try await source()
        let watch = startWatch()
        let clock = Date()
        // The app's own registry with the engine, so the foreign-video actions are there too.
        let registry = ActionRegistry(actions: DefaultActions.all(engine: true), usage: MemoryUsageStore())
        let input = try #require(InputFile(url: src.url))
        let outcome = await ConversionRunner(registry: registry, maxConcurrent: 1).run(ActionID(rawValue: action), on: [input])
        let took = Date().timeIntervalSince(clock)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let out = try #require(outcome.outputs.first)
        try await check(out, took: took, source: src, watch: watch, label: action,
                        mustShrink: ["video.compress", "video.smaller"].contains(action))
    }

    /// Apple's software H.264 through AVTranscoder, kept to compare (FRENZY_LONG_VIDEO_APPLE=1).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FRENZY_LONG_VIDEO_APPLE"] == "1"))
    func compressALongClipWithApplesSoftwareEncoder() async throws {
        let src = try await source()
        let watch = startWatch()
        let clock = Date()
        let media = try await AVSupport.open(src.url, requireVideo: true)
        let prepared = try await AVTranscoder.prepare(media, plan: .compress)
        let softwareOnly = EncoderAvailability(openHardwareSessions: { nil }, patience: .zero, pollEvery: .milliseconds(10))
        let out = src.url.deletingLastPathComponent().appendingPathComponent("compressed-apple.mp4")
        try await AVTranscoder.transcode(prepared, to: out, availability: softwareOnly, progress: { _ in })
        try await check(out, took: Date().timeIntervalSince(clock), source: src, watch: watch, label: "Apple software H.264")
    }
}

/// Which step of Compress opens the hardware encoder, even for a moment? Each step runs alone with a 2 ms sampler.
/// Run with FRENZY_VIDEO_TESTS=1 FRENZY_AVE_DIAG=1 inside the probe. Prints one line per step; it never encodes frames
/// with hardware (the worst a step can do is open an encoder briefly to check settings, which is what it measures).
@Suite("Hardware encoder diagnosis", .enabled(if: HardwareVideoTests.allowed && LongVideo.diagnose), .serialized)
struct HardwareEncoderDiagnosisTests {
    private func peak(during step: () async throws -> Void) async rethrows -> Int {
        let state = LongVideo.Peak()
        let thread = Thread {
            while !state.stopped { state.note(AVEWatch.userClientCount()); usleep(2_000) }
        }
        thread.start()
        try await step()
        usleep(300_000) // a session closing late still counts
        state.stop()
        return state.value
    }

    @Test func whichStepOpensTheHardwareEncoder() async throws {
        let source = try SoftwareMovieWriter.write(codec: .h264, width: 1920, height: 1080, fps: 30, seconds: 2,
                                                   tenBit: false, fastFill: true)
        let media = try await AVSupport.open(source, requireVideo: true)
        let out = source.deletingLastPathComponent()

        let open = try await peak { _ = try await AVSupport.open(source, requireVideo: true) }
        print("[ave-diag] open source: peak \(open)")

        var prepared: AVTranscoder.Prepared?
        let prep = try await peak { prepared = try await AVTranscoder.prepare(media, plan: .compress) }
        print("[ave-diag] prepare (plan, bitrate): peak \(prep)")
        let p = try #require(prepared)

        // videoSetup is where Compress checks its settings with canApply, before the route pins them to software.
        var setup: AVTranscoder.VideoSetup?
        let hw = try await peak {
            let w = try AVAssetWriter(outputURL: out.appendingPathComponent("a.mp4"), fileType: .mp4)
            setup = try AVTranscoder.videoSetup(color: p.color, plan: p.plan, width: p.width, height: p.height,
                                                scaled: p.needsScaling, fps: p.fps, writer: w) { codec, tenBit in
                AVTranscoder.videoBitRate(p.rate, plan: p.plan, tenBit: tenBit, h264: codec == .h264)
            }
        }
        print("[ave-diag] videoSetup (canApply, hardware allowed): peak \(hw)")
        let writerSettings = try #require(setup).writerSettings

        let sw = try await peak {
            let w = try AVAssetWriter(outputURL: out.appendingPathComponent("b.mp4"), fileType: .mp4)
            let pinned = try SoftwareVideoEncoding.forcingSoftware(writerSettings)
            _ = w.canApply(outputSettings: pinned, forMediaType: .video)
        }
        print("[ave-diag] canApply, pinned to software: peak \(sw)")

        let decode = try await peak {
            let reader = try AVAssetReader(asset: media.asset)
            let output = AVAssetReaderTrackOutput(track: p.videoTrack, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
            reader.add(output)
            reader.startReading()
            while output.copyNextSampleBuffer() != nil {}
        }
        print("[ave-diag] decode only: peak \(decode)")
    }
}

enum LongVideo {
    /// A real clip to compress instead of the made-up one (read only; the test works on a copy in temp).
    static var realSource: URL? { ProcessInfo.processInfo.environment["FRENZY_LONG_VIDEO_SOURCE"].map { URL(fileURLWithPath: $0) } }
    /// Where to copy the compressed result for the quality comparison (outside the project).
    static var keepOutput: URL? { ProcessInfo.processInfo.environment["FRENZY_LONG_VIDEO_KEEP"].map { URL(fileURLWithPath: $0) } }

    static var diagnose: Bool { ProcessInfo.processInfo.environment["FRENZY_AVE_DIAG"] == "1" }

    /// Who holds the hardware encoder right now: the `IOUserClientCreator` ("pid 123, Name") of each client under the
    /// AVE driver. Read-only IOKit lookups.
    static func aveHolders() -> [String] {
        var holders: [String] = []
        for driverClass in ["AppleAVE2Driver", "AppleAVEDriver"] {
            var drivers: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(driverClass), &drivers) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(drivers) }
            while case let driver = IOIteratorNext(drivers), driver != 0 {
                defer { IOObjectRelease(driver) }
                var kids: io_iterator_t = 0
                guard IORegistryEntryGetChildIterator(driver, kIOServicePlane, &kids) == KERN_SUCCESS else { continue }
                defer { IOObjectRelease(kids) }
                while case let kid = IOIteratorNext(kids), kid != 0 {
                    defer { IOObjectRelease(kid) }
                    if let creator = IORegistryEntryCreateCFProperty(kid, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? String { holders.append(creator) }
                }
            }
        }
        return holders
    }

    final class Peak: @unchecked Sendable {
        private let lock = NSLock()
        private var peak = 0, done = false
        private(set) var holders: Set<String> = []
        func note(_ n: Int) {
            let who = n > 0 ? LongVideo.aveHolders() : []
            lock.withLock { peak = max(peak, n); holders.formUnion(who) }
        }
        var seenHolders: [String] { lock.withLock { holders.sorted() } }
        func stop() { lock.withLock { done = true } }
        var stopped: Bool { lock.withLock { done } }
        var value: Int { lock.withLock { peak } }
    }

    static var minutes: Double? {
        ProcessInfo.processInfo.environment["FRENZY_LONG_VIDEO_MINUTES"].flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil }
    }

    static func size(_ url: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 }
    static func mb(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }
    static func secs(_ since: Date) -> String { String(format: "%.1f s", Date().timeIntervalSince(since)) }

    /// Counts the video samples straight from the file (no decoding, so no video hardware is touched).
    static func sampleCount(_ asset: AVURLAsset) async throws -> Int {
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var count = 0
        while let sample = output.copyNextSampleBuffer() { count += CMSampleBufferGetNumSamples(sample) }
        return count
    }

    final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var latest = 0.0
        func set(_ v: Double) { lock.withLock { latest = max(latest, v) } }
        var value: Double { lock.withLock { latest } }
    }
}
