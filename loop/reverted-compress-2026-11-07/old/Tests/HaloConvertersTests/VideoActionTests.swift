import AppKit
import AVFoundation
import CoreMedia
import Foundation
import HaloCore
@testable import HaloConverters
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite("Video actions")
struct VideoActionTests {
    private func codec(_ url: URL) async throws -> FourCharCode? {
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        return await AVSupport.codec(of: track)
    }

    /// Copies the standard fixture into a fresh folder, runs `id`, checks cleanup + original untouched, returns output.
    private func convert(_ id: ActionID, spec: AVFixtures.MovieSpec = .init(), name: String? = nil) async throws -> (URL, URL, ConversionOutcome) {
        let dir = try AVFixtures.tempDir()
        let original = try AVFixtures.copy(try await AVFixtures.movie(spec), into: dir, name: name)
        let before = try AVFixtures.sha(original)
        let outcome = await AVFixtures.run(id, on: original)
        #expect(try AVFixtures.sha(original) == before, "original modified")
        #expect(AVFixtures.leftovers(in: dir).isEmpty, "temp files left behind")
        return (original, dir, outcome)
    }

    @Test func movToMP4PassesThroughH264() async throws {
        let (original, _, outcome) = try await convert("video.to-mp4")
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let out = try #require(outcome.outputs.first)
        #expect(out.lastPathComponent == "clip.mp4")
        #expect(out.deletingLastPathComponent() == original.deletingLastPathComponent())
        #expect(abs(try await AVFixtures.duration(of: out) - 2.5) < 0.2)
        #expect(try await codec(out) == kCMVideoCodecType_H264)
        #expect(!(try await AVURLAsset(url: out).loadTracks(withMediaType: .audio)).isEmpty)
    }

    @Test func hevcMovToMP4ReencodesToH264() async throws {
        var spec = AVFixtures.MovieSpec()
        spec.codec = .hevc; spec.audio = false; spec.seconds = 1.5
        let (_, _, outcome) = try await convert("video.to-mp4", spec: spec)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let out = try #require(outcome.outputs.first)
        #expect(try await codec(out) == kCMVideoCodecType_H264)
        #expect(abs(try await AVFixtures.duration(of: out) - 1.5) < 0.2)
    }

    @Test func toHEVC() async throws {
        let (_, _, outcome) = try await convert("video.to-hevc")
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let out = try #require(outcome.outputs.first)
        #expect(out.lastPathComponent == "clip (HEVC).mp4")
        #expect(try await codec(out) == kCMVideoCodecType_HEVC)
        #expect(abs(try await AVFixtures.duration(of: out) - 2.5) < 0.2)
    }

    @Test func toHEVCRefusesHEVC() async throws {
        var spec = AVFixtures.MovieSpec()
        spec.codec = .hevc; spec.audio = false; spec.seconds = 1.5
        let (_, dir, outcome) = try await convert("video.to-hevc", spec: spec)
        #expect(outcome.outputs.isEmpty)
        #expect(outcome.failures.first?.message.contains("already HEVC") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 1)
    }

    @Test func compressMakesSmallerFile() async throws {
        let (original, _, outcome) = try await convert("video.compress")
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let out = try #require(outcome.outputs.first)
        #expect(out.lastPathComponent == "clip (compressed).mp4")
        #expect(AVSupport.fileSize(out) < AVSupport.fileSize(original))
        #expect(abs(try await AVFixtures.duration(of: out) - 2.5) < 0.2)
        let asset = AVURLAsset(url: out)
        #expect(!(try await asset.loadTracks(withMediaType: .audio)).isEmpty)
    }

    @Test func compressCapsAt1080p() async throws {
        var spec = AVFixtures.MovieSpec()
        spec.width = 2560; spec.height = 1440; spec.fps = 10; spec.seconds = 1; spec.audio = false; spec.bitRate = 20_000_000
        let (original, _, outcome) = try await convert("video.compress", spec: spec)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let out = try #require(outcome.outputs.first)
        let track = try #require(try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size.width == 1920 && size.height == 1080)
        #expect(AVSupport.fileSize(out) < AVSupport.fileSize(original))
    }

    @Test func gifHasManyFramesAndLoops() async throws {
        let (_, _, outcome) = try await convert("video.to-gif")
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let out = try #require(outcome.outputs.first)
        #expect(out.pathExtension == "gif")
        let source = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.gif.identifier)
        let count = CGImageSourceGetCount(source)
        #expect(count >= 25 && count <= 31, "frames: \(count)")
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width <= 480 && image.width >= 470)
        let props = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        #expect((gif?[kCGImagePropertyGIFLoopCount] as? Int) == 0)
    }

    @Test func extractAudio() async throws {
        let (_, _, outcome) = try await convert("video.extract-audio")
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let out = try #require(outcome.outputs.first)
        #expect(out.pathExtension == "m4a")
        let asset = AVURLAsset(url: out)
        #expect(try await asset.loadTracks(withMediaType: .video).isEmpty)
        #expect(!(try await asset.loadTracks(withMediaType: .audio)).isEmpty)
        #expect(abs(try await asset.load(.duration).seconds - 2.5) < 0.2)
    }

    @Test func extractAudioRefusesSilentVideo() async throws {
        var spec = AVFixtures.MovieSpec()
        spec.codec = .hevc; spec.audio = false; spec.seconds = 1.5
        let (_, _, outcome) = try await convert("video.extract-audio", spec: spec)
        #expect(outcome.outputs.isEmpty)
        #expect(outcome.failures.first?.message.contains("no sound") == true)
    }

    @Test func unreadableMovieGivesClearError() async throws {
        let dir = try AVFixtures.tempDir()
        let bogus = dir.appendingPathComponent("broken.mov")
        try Data(repeating: 0x42, count: 4096).write(to: bogus)
        let outcome = await AVFixtures.run("video.to-gif", on: bogus)
        #expect(outcome.outputs.isEmpty)
        let message = outcome.failures.first?.message ?? ""
        #expect(message.contains("damaged"), "\(message)")
        #expect(AVFixtures.leftovers(in: dir).isEmpty)
    }

    @Test func cancellationCleansUp() async throws {
        var spec = AVFixtures.MovieSpec()
        spec.width = 2560; spec.height = 1440; spec.fps = 10; spec.seconds = 1; spec.audio = false; spec.bitRate = 20_000_000
        let dir = try AVFixtures.tempDir()
        let original = try AVFixtures.copy(try await AVFixtures.movie(spec), into: dir)
        let task = Task { await AVFixtures.run("video.compress", on: original) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        let outcome = await task.value
        #expect(!outcome.succeeded)
        #expect(outcome.failures.first?.message == "Cancelled.")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["clip.mov"])
    }

    @Test func noMP4ActionForMP4() async throws {
        let mp4 = InputFile(url: URL(fileURLWithPath: "/x/a.mp4"), type: .mpeg4Movie)
        let mov = InputFile(url: URL(fileURLWithPath: "/x/a.mov"), type: .quickTimeMovie)
        let m4v = InputFile(url: URL(fileURLWithPath: "/x/a.m4v"), type: AVSupport.m4v)
        let ids = { (f: InputFile) in Set(AVFixtures.registry.actions(for: [f], limit: 99).map(\.id.rawValue)) }
        #expect(!ids(mp4).contains("video.to-mp4"))
        #expect(ids(mp4).isSuperset(of: ["video.compress", "video.to-gif", "video.extract-audio", "video.to-hevc"]))
        #expect(ids(mov).contains("video.to-mp4"))
        #expect(ids(m4v).contains("video.to-mp4"))
        // Audio files never get video actions.
        #expect(ids(InputFile(url: URL(fileURLWithPath: "/x/a.m4a"), type: .mpeg4Audio)).allSatisfy { !$0.hasPrefix("video.") })
    }

    @Test(arguments: VideoActions.all + AudioActions.all + DocumentActions.all)
    func actionMetadata(_ action: ConversionAction) {
        #expect(action.title.count <= 10)
        #expect((action.subtitle ?? "").count <= 14)
        #expect(NSImage(systemSymbolName: action.symbolName, accessibilityDescription: nil) != nil, "\(action.symbolName)")
        let family = action.id.rawValue.split(separator: ".").first.map(String.init)
        #expect(family == action.category.rawValue)
    }
}
