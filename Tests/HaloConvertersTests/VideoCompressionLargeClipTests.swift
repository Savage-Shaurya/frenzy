import AVFoundation
import CoreMedia
import Foundation
import HaloCore
@testable import HaloConverters
import Testing

/// VIDEO (hardware encoder), LARGE clips: 720p to 1440p, up to 8 s. Run LAST, only after every tiny-clip suite
/// ("Video compression, tiny clips", "Video actions", "Video HDR", "Video hardening") passed, one test at a time, with
/// FRENZY_VIDEO_TESTS=1 and the founder's OK in the current chat.
@Suite("Video compression, LARGE clips (run last)", .enabled(if: HardwareVideoTests.allowed), .serialized)
struct VideoCompressionLargeClipTests {
    private func spec(_ w: Int, _ h: Int, seconds: Double, fps: Int = 10, bitRate: Int = 20_000_000) -> AVFixtures.MovieSpec {
        var spec = AVFixtures.MovieSpec()
        spec.width = w; spec.height = h; spec.fps = fps; spec.seconds = seconds; spec.audio = false; spec.bitRate = bitRate
        return spec
    }

    @Test func compressKeeps1440p() async throws {
        let original = try await VideoCheck.fresh(spec(2560, 1440, seconds: 1))
        let outcome = try await VideoCheck.convert("video.compress", original)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let out = try #require(outcome.outputs.first)
        let facts = try await VideoCheck.videoFacts(out)
        #expect(facts.size == CGSize(width: 2560, height: 1440))
        #expect(facts.frames.count == 10)
        #expect(AVSupport.fileSize(out) < AVSupport.fileSize(original))
    }

    @Test func smallerCaps1440pAt1080p() async throws {
        let original = try await VideoCheck.fresh(spec(2560, 1440, seconds: 1))
        let outcome = try await VideoCheck.convert("video.smaller", original)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let out = try #require(outcome.outputs.first)
        #expect(out.lastPathComponent == "clip (smaller).mp4")
        let facts = try await VideoCheck.videoFacts(out)
        #expect(facts.size == CGSize(width: 1920, height: 1080))
        #expect(facts.frames.count == 10, "frame rate is kept")
        #expect(AVSupport.fileSize(out) < AVSupport.fileSize(original))
    }

    @Test func smallerKeepsHDRWhileDownscaling() async throws {
        var hdr = AVFixtures.MovieSpec.hdr(.hlg)
        hdr.width = 2560; hdr.height = 1440; hdr.bitRate = 30_000_000; hdr.seconds = 1
        let original = try await VideoCheck.fresh(hdr)
        let outcome = try await VideoCheck.convert("video.smaller", original)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let out = try #require(outcome.outputs.first)
        let color = try await AVFixtures.color(of: out)
        #expect(color.isHDR && color.bitsPerComponent == 10)
        #expect(try await VideoCheck.videoFacts(out).size == CGSize(width: 1920, height: 1080))
    }

    @Test func progressStaysSmoothOn720p() async throws {
        let original = try await VideoCheck.fresh(spec(1280, 720, seconds: 3, fps: 30, bitRate: 8_000_000))
        let values = VideoProgressLog()
        let input = try #require(InputFile(url: original))
        let outcome = await ConversionRunner(registry: AVFixtures.registry, maxConcurrent: 1)
            .run("video.compress", on: [input], progress: { values.add($0) })
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let seen = values.all
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 <= $1 }, "progress went backwards")
        #expect(seen.last == 1)
        #expect(seen.count <= 90 + 110, "\(seen.count) updates for 90 frames: throttled")
    }

    /// The disk is nearly full (simulated): the engine's output cap stops x264 cleanly with the plain message, the
    /// partial file is gone, and no engine is left running. CPU only: Apple's encoder is never involved.
    @Test func diskFillingUpMidwayStopsCleanly() async throws {
        let source = try await longMovie()
        let dir = try AVFixtures.tempDir()
        let out = dir.appendingPathComponent("out.mp4")
        let probe = try await MediaEngine.probe(source)
        let color = await AVColorInfo.of(try #require(try await AVURLAsset(url: source).loadTracks(withMediaType: .video).first))
        do {
            // 257 MB "free": the engine keeps 256 MB for macOS, so it may write about 1 MB.
            try await MediaEngine.convert(input: source, output: out, outputArguments:
                                            X264Compress.arguments(X264Compress.formatSettings(color, codec: .h264), audio: probe.audio),
                                          expectedSeconds: probe.seconds, checkLength: true,
                                          freeSpace: { _ in 257 << 20 }, progress: { _ in })
            Issue.record("should have stopped")
        } catch {
            #expect(error.localizedDescription.contains("enough free space"), "\(error.localizedDescription)")
        }
        #expect(!HardwareEncodeGate.shared.isEncoding)
    }

    /// Cancel mid-encode: quick, nothing left behind, and the gate is only freed once the writer has stopped.
    @Test func cancelIsFastAndLeavesNothing() async throws {
        let source = try await longMovie()
        let dir = try AVFixtures.tempDir()
        let original = try AVFixtures.copy(source, into: dir)
        let started = VideoProgressLog()
        let input = try #require(InputFile(url: original))
        let task = Task {
            await ConversionRunner(registry: AVFixtures.registry, maxConcurrent: 1).run("video.compress", on: [input], progress: { started.add($0) })
        }
        while (started.all.last ?? 0) < 0.05 {
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
        #expect(!HardwareEncodeGate.shared.isEncoding)
    }

    /// Long and heavy enough that encoding takes seconds, not milliseconds.
    private func longMovie() async throws -> URL {
        try await AVFixtures.movie(spec(1920, 1080, seconds: 8, fps: 30, bitRate: 40_000_000))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { defer { n += 1 }; return n } }
}
