import AVFoundation
import Foundation
import HaloCore
@testable import HaloConverters
import Testing
import UniformTypeIdentifiers

/// Security and robustness of the AV plumbing: external references, cancellation races, resource release.
@Suite("Video hardening")
struct VideoHardeningTests {
    // MARK: External references

    @Test(arguments: ["video.compress", "video.to-gif", "video.to-mp4", "video.to-hevc", "video.extract-audio"] as [ActionID])
    func referenceMovieIsRejected(_ id: ActionID) async throws {
        let dir = try AVFixtures.tempDir()
        // The referenced media lives in another folder, like a crafted movie pointing at someone's other files.
        let target = try AVFixtures.copy(try await AVFixtures.movie(), into: try AVFixtures.tempDir())
        let ref = dir.appendingPathComponent("ref.mov")
        try await AVFixtures.referenceMovie(to: target, at: ref)
        #expect(AVSupport.fileSize(ref) < 20_000, "fixture should be a header only")

        let outcome = await AVFixtures.run(id, on: ref)
        #expect(outcome.outputs.isEmpty)
        let message = outcome.failures.first?.message ?? ""
        #expect(message.contains("reference movie"), "\(message)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["ref.mov"])
    }

    @Test(arguments: ["audio.to-wav", "audio.to-aiff"] as [ActionID])
    func referenceMovieRenamedM4AIsRejectedByAudioActions(_ id: ActionID) async throws {
        let dir = try AVFixtures.tempDir()
        let target = try AVFixtures.copy(try await AVFixtures.movie(), into: try AVFixtures.tempDir())
        // AVFoundation only writes the header under a movie extension; rename it afterwards, as an attacker would.
        let mov = dir.appendingPathComponent("ref.mov"), ref = dir.appendingPathComponent("ref.m4a")
        try await AVFixtures.referenceMovie(to: target, at: mov)
        try FileManager.default.moveItem(at: mov, to: ref)
        let outcome = await AVFixtures.run(id, on: ref, type: .mpeg4Audio)
        #expect(outcome.outputs.isEmpty)
        #expect(outcome.failures.first?.message.contains("reference movie") == true, "\(outcome.failures.map(\.message))")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["ref.m4a"])
    }

    @Test func hlsPlaylistRenamedMovIsRejected() async throws {
        let dir = try AVFixtures.tempDir()
        let local = try await AVFixtures.movie()
        let playlist = dir.appendingPathComponent("stream.mov")
        try """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:10
        #EXTINF:10.0,
        \(local.absoluteString)
        #EXTINF:10.0,
        https://example.invalid/segment1.ts
        #EXT-X-ENDLIST

        """.write(to: playlist, atomically: true, encoding: .utf8)
        for id in ["video.compress", "video.to-mp4", "video.to-gif"] as [ActionID] {
            let outcome = await AVFixtures.run(id, on: playlist, type: .quickTimeMovie)
            #expect(outcome.outputs.isEmpty)
            #expect(!outcome.failures.isEmpty)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["stream.mov"])
    }

    @Test func normalFilesAreSelfContained() async throws {
        let media = try await AVSupport.open(try await AVFixtures.movie(), requireVideo: true)
        #expect(!media.videoTracks.isEmpty && !media.audioTracks.isEmpty)
        try await AVSupport.requireSelfContained(try AVFixtures.tone(ext: "wav"))
    }

    // MARK: Cancellation

    /// Cancels compress at many points (before start, mid-encode, around finishWriting). Any misordered AVFoundation
    /// call would raise an Objective-C exception and crash the test process.
    @Test func cancelAtManyMomentsNeverCrashesOrLeaks() async throws {
        var spec = AVFixtures.MovieSpec()
        spec.seconds = 1; spec.audio = true
        let source = try await AVFixtures.movie(spec)
        for delay in [0, 1, 3, 10, 25, 50, 100, 200, 400] {
            let dir = try AVFixtures.tempDir()
            let original = try AVFixtures.copy(source, into: dir)
            let task = Task { await AVFixtures.run("video.compress", on: original) }
            if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
            task.cancel()
            let outcome = await task.value
            // Late cancels may legitimately finish first; either way nothing half-done is left behind.
            if outcome.succeeded {
                #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["clip (compressed).mp4", "clip.mov"])
            } else {
                #expect(outcome.failures.first?.message == "Cancelled.", "delay \(delay): \(outcome.failures.map(\.message))")
                #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["clip.mov"], "delay \(delay)")
            }
            try await expectPumpReleased(in: dir)
        }
    }

    @Test func pumpIsReleasedAfterSuccess() async throws {
        var spec = AVFixtures.MovieSpec()
        spec.seconds = 1
        let dir = try AVFixtures.tempDir()
        let original = try AVFixtures.copy(try await AVFixtures.movie(spec), into: dir)
        let outcome = await AVFixtures.run("video.compress", on: original)
        #expect(outcome.succeeded, "\(outcome.failures.map(\.message))")
        try await expectPumpReleased(in: dir)
    }

    private func expectPumpReleased(in dir: URL, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        // AVFoundation may hold the pull block briefly on its own queues after finishing; allow a moment.
        for _ in 0..<100 where AVTranscoder.live.contains(inDirectory: dir) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!AVTranscoder.live.contains(inDirectory: dir), "transcode pump (reader/writer) leaked", sourceLocation: sourceLocation)
    }

    /// The macOS 14 export path: a cancel that lands before `exportAsynchronously` must stop the export from ever
    /// starting (it used to run to completion).
    @Test func legacyExportCancelledBeforeStartNeverRuns() async throws {
        let dir = try AVFixtures.tempDir()
        let asset = AVURLAsset(url: try await AVFixtures.movie())
        let out = dir.appendingPathComponent("out.mp4")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let session = try #require(AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality))
            try await Self.runLegacy(session, to: out)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func legacyExportCancelledMidwayStops() async throws {
        let dir = try AVFixtures.tempDir()
        var spec = AVFixtures.MovieSpec()
        spec.width = 2560; spec.height = 1440; spec.fps = 10; spec.seconds = 1; spec.audio = false; spec.bitRate = 20_000_000
        let asset = AVURLAsset(url: try await AVFixtures.movie(spec))
        let out = dir.appendingPathComponent("out.mp4")
        let task = Task {
            let session = try #require(AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVCHighestQuality))
            try await Self.runLegacy(session, to: out)
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        // Either it was stopped, or (fast machine) it had already finished; it must never hang or crash.
        do { try await task.value } catch { #expect(error is CancellationError, "\(error)") }
    }

    @available(macOS, deprecated: 15)
    private static func runLegacy(_ session: AVAssetExportSession, to url: URL) async throws {
        try await LegacyExport.run(session, to: url, as: .mp4, progress: { _ in })
    }

    @Test func exportGateOrdering() {
        let early = ExportGate()
        #expect(!early.cancel(), "nothing started yet")
        #expect(!early.markStarted(), "a cancel before start forbids starting")
        let late = ExportGate()
        #expect(late.markStarted())
        #expect(late.cancel(), "a cancel after start must cancel the running export")
        #expect(late.isCancelled)
    }

    // MARK: Blocking work

    @Test func blockingWorkRunsOffTheCooperativePoolAndCancels() async throws {
        let started = AVCancelFlag()
        let task = Task {
            try await AVSupport.runBlocking { cancel -> Int in
                #expect(!Thread.isMainThread)
                started.cancel() // used as a "started" signal
                var spins = 0
                while true {
                    try cancel.check()
                    Thread.sleep(forTimeInterval: 0.005)
                    spins += 1
                    if spins > 2_000 { return spins } // 10 s safety net: the test fails below if reached
                }
            }
        }
        while !started.isCancelled { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func blockingWorkReturnsValue() async throws {
        let v = try await AVSupport.runBlocking { _ in 42 }
        #expect(v == 42)
    }

    @Test func audioCancellationCleansUp() async throws {
        let dir = try AVFixtures.tempDir()
        let original = try AVFixtures.copy(try AVFixtures.tone(ext: "wav", seconds: 120), into: dir)
        let task = Task { await AVFixtures.run("audio.to-aiff", on: original) }
        try await Task.sleep(for: .milliseconds(15))
        task.cancel()
        let outcome = await task.value
        if !outcome.succeeded {
            #expect(outcome.failures.first?.message == "Cancelled.", "\(outcome.failures.map(\.message))")
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["tone.wav"])
        }
    }
}
