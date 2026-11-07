import AVFoundation
import Foundation
import HaloCore
@testable import HaloConverters
import Testing
import UniformTypeIdentifiers

@Suite("Audio actions")
struct AudioActionTests {
    private struct Decoded {
        let formatID: AudioFormatID
        let bits: UInt32
        let bigEndian: Bool
        let seconds: Double
        let channels: UInt32
    }

    private func decode(_ url: URL) throws -> Decoded {
        let file = try AVAudioFile(forReading: url)
        let asbd = file.fileFormat.streamDescription.pointee
        return Decoded(formatID: asbd.mFormatID, bits: asbd.mBitsPerChannel,
                       bigEndian: asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0,
                       seconds: Double(file.length) / file.fileFormat.sampleRate, channels: asbd.mChannelsPerFrame)
    }

    private func convert(_ id: ActionID, _ source: URL) async throws -> URL {
        let dir = try AVFixtures.tempDir()
        let original = try AVFixtures.copy(source, into: dir)
        let before = try AVFixtures.sha(original)
        let outcome = await AVFixtures.run(id, on: original)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        #expect(try AVFixtures.sha(original) == before)
        #expect(AVFixtures.leftovers(in: dir).isEmpty)
        return try #require(outcome.outputs.first)
    }

    @Test func wavToM4A() async throws {
        let out = try await convert("audio.to-m4a", try AVFixtures.tone(ext: "wav"))
        #expect(out.lastPathComponent == "tone.m4a")
        let d = try decode(out)
        #expect(d.formatID == kAudioFormatMPEG4AAC)
        #expect(abs(d.seconds - 1.5) < 0.1)
        #expect(abs(try await AVFixtures.duration(of: out) - 1.5) < 0.1)
    }

    @Test func wavToAIFF() async throws {
        let out = try await convert("audio.to-aiff", try AVFixtures.tone(ext: "wav"))
        #expect(out.pathExtension == "aiff")
        let d = try decode(out)
        #expect(d.formatID == kAudioFormatLinearPCM && d.bits == 16 && d.bigEndian && d.channels == 2)
        #expect(abs(d.seconds - 1.5) < 0.01)
    }

    @Test func aiffToWAV() async throws {
        let out = try await convert("audio.to-wav", try AVFixtures.tone(ext: "aiff"))
        let d = try decode(out)
        #expect(out.pathExtension == "wav")
        #expect(d.formatID == kAudioFormatLinearPCM && d.bits == 16 && !d.bigEndian)
        #expect(abs(d.seconds - 1.5) < 0.01)
    }

    @Test func m4aToWAV() async throws {
        let m4a = try AVFixtures.tone(ext: "m4a", settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVEncoderBitRateKey: 128_000])
        let out = try await convert("audio.to-wav", m4a)
        let d = try decode(out)
        #expect(d.formatID == kAudioFormatLinearPCM && d.bits == 16)
        #expect(abs(d.seconds - 1.5) < 0.1)
    }

    @Test func floatCAFToAIFFUses24Bit() async throws {
        let caf = try AVFixtures.tone(ext: "caf", settings: [AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true])
        let out = try await convert("audio.to-aiff", caf)
        let d = try decode(out)
        #expect(d.bits == 24 && d.bigEndian)
        #expect(abs(d.seconds - 1.5) < 0.01)
    }

    /// Without the media engine: Apple's three. With it, MP3 and FLAC join (each checked end to end in
    /// EngineFormatTests.everyOfferedAudioChoiceWorks). Never a file's own format.
    @Test(arguments: [false, true])
    func noSameFormatActions(engine: Bool) {
        let registry = ActionRegistry(actions: AudioActions.actions(engine: engine), usage: MemoryUsageStore())
        func ids(_ ext: String) -> Set<String> {
            let url = URL(fileURLWithPath: "/x/a.\(ext)")
            return Set(registry.actions(for: [InputFile(url: url, type: UTType(filenameExtension: ext)!)], limit: 99).map(\.id.rawValue))
        }
        let mp3: Set<String> = engine ? ["audio.to-mp3"] : []
        let flac: Set<String> = engine ? ["audio.to-flac"] : []
        #expect(ids("wav") == Set(["audio.to-m4a", "audio.to-aiff"]).union(mp3).union(flac))
        #expect(ids("m4a") == Set(["audio.to-wav", "audio.to-aiff"]).union(mp3).union(flac))
        #expect(ids("aiff") == Set(["audio.to-m4a", "audio.to-wav"]).union(mp3).union(flac))
        #expect(ids("aif") == Set(["audio.to-m4a", "audio.to-wav"]).union(mp3).union(flac))
        #expect(ids("mp3") == Set(["audio.to-m4a", "audio.to-wav", "audio.to-aiff"]).union(flac))
        #expect(ids("caf") == Set(["audio.to-m4a", "audio.to-wav", "audio.to-aiff"]).union(mp3).union(flac))
        #expect(ids("flac") == Set(["audio.to-m4a", "audio.to-wav", "audio.to-aiff"]).union(mp3))
        #expect(ids("ogg") == (engine ? ["audio.to-mp3", "audio.to-m4a", "audio.to-wav", "audio.to-aiff", "audio.to-flac"] : []))
    }

    @Test func garbageAudioFailsCleanly() async throws {
        let dir = try AVFixtures.tempDir()
        let bogus = dir.appendingPathComponent("noise.wav")
        try Data(repeating: 7, count: 2048).write(to: bogus)
        let outcome = await AVFixtures.run("audio.to-aiff", on: bogus)
        #expect(outcome.outputs.isEmpty && !outcome.failures.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["noise.wav"])
    }
}
