import AVFoundation
import Foundation
import HaloCore
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HaloConverters

/// Real files in every format the engine adds. They're made at run time by the developer's own FFmpeg (GPL builds are fine
/// here: it only makes test input and never ships). Results are checked by Apple's decoders, which share no code with the
/// engine, and by ffprobe. Without a dev FFmpeg or a built engine these tests don't run, and the run says so.
///
/// No fixture here touches the hardware video encoder (it kernel-panicked the founder's Mac, 7 Nov 2026): audio comes from
/// the dev FFmpeg's CPU audio encoders or AVAudioFile, and the few small test videos from its CPU video encoders
/// (libvpx, mpeg4, theora and friends). `make` refuses any VideoToolbox codec.
enum EngineFixtures {
    static let devBin = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin")
    static let devFFmpeg = devBin.appendingPathComponent("ffmpeg")
    static let devFFprobe = devBin.appendingPathComponent("ffprobe")
    static var ready: Bool {
        MediaEngine.isAvailable && FileManager.default.isExecutableFile(atPath: devFFmpeg.path)
            && FileManager.default.isExecutableFile(atPath: devFFprobe.path)
    }

    /// What the app offers with the engine in place.
    static let registry = DefaultActions.registry(engine: true, usage: MemoryUsageStore())

    static let cacheDir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("frenzy-engine-fixtures-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    struct Spec: Sendable, CustomTestStringConvertible {
        let name: String
        let ext: String
        let codec: [String]
        var isVideo = true
        var seconds = 3.0
        var size = "320x240"
        var fileName: String { "\(name).\(ext)" }
        var testDescription: String { fileName }
    }

    /// CPU encoders only. Small and short: they exist to be decoded.
    static let videos: [Spec] = [
        Spec(name: "vp9-opus", ext: "webm", codec: ["-c:v", "libvpx-vp9", "-b:v", "500k", "-cpu-used", "8", "-c:a", "libopus"]),
        Spec(name: "vp8-vorbis", ext: "webm", codec: ["-c:v", "libvpx", "-b:v", "500k", "-c:a", "libvorbis"]),
        Spec(name: "av1-opus", ext: "webm", codec: ["-c:v", "libsvtav1", "-preset", "12", "-c:a", "libopus"]),
        Spec(name: "h264-ac3", ext: "mkv", codec: ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "ac3"]),
        Spec(name: "vp9-vorbis", ext: "mkv", codec: ["-c:v", "libvpx-vp9", "-b:v", "500k", "-cpu-used", "8", "-c:a", "libvorbis"]),
        Spec(name: "hevc-aac", ext: "mkv", codec: ["-c:v", "libx265", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac"]),
        Spec(name: "mpeg4-mp3", ext: "avi", codec: ["-c:v", "mpeg4", "-q:v", "4", "-c:a", "libmp3lame"]),
        Spec(name: "flv1-mp3", ext: "flv", codec: ["-c:v", "flv", "-q:v", "4", "-c:a", "libmp3lame", "-ar", "44100"]),
        Spec(name: "wmv2-wma", ext: "wmv", codec: ["-c:v", "wmv2", "-q:v", "4", "-c:a", "wmav2"]),
        Spec(name: "mpeg2-mp2", ext: "mpg", codec: ["-c:v", "mpeg2video", "-q:v", "4", "-c:a", "mp2"]),
        Spec(name: "h264-aac", ext: "ts", codec: ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac"]),
        Spec(name: "theora-vorbis", ext: "ogv", codec: ["-c:v", "libtheora", "-q:v", "6", "-c:a", "libvorbis"]),
    ]

    /// Formats macOS can't read, and the ones it can (MP3, FLAC, M4A, WAV, AIFF) that now also get MP3 and FLAC out.
    static let audios: [Spec] = [
        Spec(name: "vorbis", ext: "ogg", codec: ["-c:a", "libvorbis"], isVideo: false),
        Spec(name: "opus", ext: "opus", codec: ["-c:a", "libopus"], isVideo: false),
        Spec(name: "wma", ext: "wma", codec: ["-c:a", "wmav2"], isVideo: false),
        Spec(name: "ac3", ext: "ac3", codec: ["-c:a", "ac3"], isVideo: false),
        Spec(name: "adts", ext: "aac", codec: ["-c:a", "aac"], isVideo: false),
        Spec(name: "mka-opus", ext: "mka", codec: ["-c:a", "libopus"], isVideo: false),
        Spec(name: "wavpack", ext: "wv", codec: ["-c:a", "wavpack"], isVideo: false),
        Spec(name: "lame", ext: "mp3", codec: ["-c:a", "libmp3lame", "-q:a", "2"], isVideo: false),
        Spec(name: "lossless", ext: "flac", codec: ["-c:a", "flac"], isVideo: false),
        Spec(name: "aac", ext: "m4a", codec: ["-c:a", "aac", "-b:a", "160k"], isVideo: false),
        Spec(name: "pcm", ext: "wav", codec: ["-c:a", "pcm_s16le"], isVideo: false),
        Spec(name: "pcm-be", ext: "aiff", codec: ["-c:a", "pcm_s16be"], isVideo: false),
    ]

    static func make(_ spec: Spec) throws -> URL {
        // The founder's rule, enforced: no fixture may reach the hardware video encoder.
        precondition(!spec.codec.contains { $0.contains("videotoolbox") || $0.hasSuffix("_vt") }, "no hardware video encoding: \(spec.name)")
        let url = cacheDir.appendingPathComponent(spec.fileName)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        var args = ["-hide_banner", "-loglevel", "error", "-y", "-threads", "2"]
        if spec.isVideo { args += ["-f", "lavfi", "-i", "testsrc2=s=\(spec.size):r=30:d=\(spec.seconds)"] }
        args += ["-f", "lavfi", "-i", "sine=f=440:r=48000:d=\(spec.seconds)"]
        if !spec.isVideo { args += ["-vn"] }
        args += spec.codec + ["-t", String(spec.seconds), url.path]
        let done = try shell(devFFmpeg, args)
        guard done.status == 0 else { throw ConversionError.engine("fixture \(spec.fileName): \(done.output)") }
        return url
    }

    /// A long mono WAV written by AVAudioFile: long enough for progress, cancelling and the limits to be seen.
    static let longWAV: URL = {
        let url = cacheDir.appendingPathComponent("long.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let rate = 22_050.0, minutes = 40.0
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let chunk = AVAudioFrameCount(rate * 10)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
        buffer.frameLength = chunk
        let p = buffer.floatChannelData![0]
        // 441 Hz fits 10 s chunks exactly, so the chunks join without a click.
        for i in 0..<Int(chunk) { p[i] = Float(sin(2 * Double.pi * 441 * Double(i) / rate) * 0.3) }
        do {
            let file = try! AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            for _ in 0..<Int(minutes * 6) { try! file.write(from: buffer) }
        }
        return url
    }()

    static func shell(_ tool: URL, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// (codec names by stream, in order)
    static func streams(_ url: URL) throws -> [String] {
        let done = try shell(devFFprobe, ["-v", "error", "-show_entries", "stream=codec_name", "-of", "csv=p=0", url.path])
        return done.output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ,")) }
    }

    static func run(_ id: ActionID, on file: URL, registry: ActionRegistry = registry,
                    progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> ConversionOutcome {
        let runner = ConversionRunner(registry: registry, maxConcurrent: 1)
        return await runner.run(id, on: [InputFile(url: file)!], progress: progress)
    }

    /// A fresh folder holding a copy of `source`, so outputs and leftovers belong to one test.
    static func isolated(_ source: URL, name: String? = nil) throws -> (dir: URL, file: URL) {
        let dir = try AVFixtures.tempDir()
        return (dir, try AVFixtures.copy(source, into: dir, name: name))
    }

    static func convert(_ id: ActionID, _ source: URL, registry: ActionRegistry = registry,
                        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> (out: URL, dir: URL) {
        let (dir, file) = try isolated(source)
        let before = try AVFixtures.sha(file)
        let outcome = await run(id, on: file, registry: registry, progress: progress)
        #expect(outcome.failures.isEmpty, "\(id): \(outcome.failures.map(\.message))")
        #expect(try AVFixtures.sha(file) == before, "the original must not change")
        #expect(AVFixtures.leftovers(in: dir).isEmpty)
        return (try #require(outcome.outputs.first), dir)
    }

    /// The loudest sample in a second of `url`, decoded by Apple: a 440 Hz tone at 0.3 has to come through.
    static func peak(_ url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000))
        // From the start: seeking some AAC files throws an Objective-C exception, and the tone is full height by 1 ms.
        try file.read(into: buffer, frameCount: min(48_000, AVAudioFrameCount(file.length)))
        let samples = try #require(buffer.floatChannelData?[0])
        return (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(samples[$1])) }
    }

    /// Average pixel of a frame in the middle, decoded by Apple's video stack.
    static func frameIsPicture(_ url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let duration = try await asset.load(.duration)
        let time = CMTime(seconds: duration.seconds / 2, preferredTimescale: 600)
        let image = try await generator.image(at: time).image
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        var seen = Set<UInt8>()
        for i in stride(from: 0, to: CFDataGetLength(data), by: 97) { seen.insert(bytes[i]) }
        return seen.count > 8
    }

    static func engineChildren() throws -> [String] {
        let done = try shell(URL(fileURLWithPath: "/usr/bin/pgrep"), ["-P", String(getpid()), "-x", MediaEngine.executableName])
        return done.output.split(whereSeparator: \.isNewline).map(String.init)
    }
}

/// Everything the engine does today. None of it encodes video, so it runs on every `swift test`.
@Suite("Media engine formats", .enabled(if: EngineFixtures.ready), .serialized)
struct EngineFormatTests {
    private func convert(_ id: ActionID, _ source: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> (out: URL, dir: URL) {
        try await EngineFixtures.convert(id, source, progress: progress)
    }

    // MARK: Audio: every choice the ring offers, end to end

    private static let expectedCodec: [String: (ext: String, codec: String)] = [
        "audio.to-mp3": ("mp3", "mp3"), "audio.to-m4a": ("m4a", "aac"), "audio.to-wav": ("wav", "pcm_s16le"),
        "audio.to-aiff": ("aiff", "pcm_s16be"), "audio.to-flac": ("flac", "flac"),
    ]

    /// Each audio choice the ring offers for the file, run for real and decoded by Apple: right container and codec,
    /// right length, and the tone still there.
    @Test(arguments: EngineFixtures.audios)
    func everyOfferedAudioChoiceWorks(spec: EngineFixtures.Spec) async throws {
        let source = try EngineFixtures.make(spec)
        let all = EngineFixtures.registry.actions(for: [try #require(InputFile(url: source))], limit: 99).map(\.id.rawValue)
        // Zip comes with every file, last; the archive tests cover it.
        #expect(all.last == "archive.zip", "\(all)")
        let offered = all.filter { $0 != "archive.zip" }
        #expect(offered.first == "audio.to-mp3" || spec.ext == "mp3", "\(spec.fileName): \(offered)")
        #expect(offered.allSatisfy { $0.hasPrefix("audio.") }, "\(offered)")
        #expect(offered.count >= 4, "\(spec.fileName): \(offered)")
        for id in offered {
            let expected = try #require(Self.expectedCodec[id], "\(id) has no expectation")
            #expect(expected.ext != spec.ext, "\(id) offered for its own format")
            let (out, _) = try await convert(ActionID(rawValue: id), source)
            #expect(out.pathExtension == expected.ext, "\(id)")
            #expect(try EngineFixtures.streams(out) == [expected.codec], "\(spec.fileName) \(id)")
            let file = try AVAudioFile(forReading: out)
            let seconds = Double(file.length) / file.fileFormat.sampleRate
            #expect(abs(seconds - spec.seconds) < 0.4, "\(spec.fileName) \(id) \(seconds)")
            #expect(try EngineFixtures.peak(out) > 0.02, "\(spec.fileName) \(id): silence")
        }
    }

    /// MP3 and FLAC out of a WAV written by Apple's own AVAudioFile.
    @Test func appleWAVToMP3AndFLAC() async throws {
        let wav = try AVFixtures.tone(ext: "wav")
        let (mp3, _) = try await convert("audio.to-mp3", wav)
        #expect(try EngineFixtures.streams(mp3) == ["mp3"])
        let (flac, _) = try await convert("audio.to-flac", wav)
        #expect(try EngineFixtures.streams(flac) == ["flac"])
        #expect(abs(try await AVFixtures.duration(of: mp3) - 1.5) < 0.2)
        #expect(try EngineFixtures.peak(flac) > 0.2)
    }

    /// An M4A made by Apple's AAC encoder (AVAudioFile) to MP3 and FLAC.
    @Test func appleM4AToMP3AndFLAC() async throws {
        let m4a = try AVFixtures.tone(ext: "m4a", settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVEncoderBitRateKey: 128_000])
        let (mp3, _) = try await convert("audio.to-mp3", m4a)
        #expect(try EngineFixtures.streams(mp3) == ["mp3"])
        let (flac, _) = try await convert("audio.to-flac", m4a)
        #expect(try EngineFixtures.streams(flac) == ["flac"])
        #expect(try EngineFixtures.peak(mp3) > 0.1)
    }

    /// 24-bit stays 24-bit in a lossless output.
    @Test func losslessKeepsBitDepth() async throws {
        let source = try EngineFixtures.make(.init(name: "deep", ext: "wv", codec: ["-c:a", "wavpack", "-sample_fmt", "s32p"], isVideo: false))
        let (wav, _) = try await convert("audio.to-wav", source)
        #expect(try EngineFixtures.streams(wav) == ["pcm_s24le"])
        let (flac, _) = try await convert("audio.to-flac", source)
        let probe = try EngineFixtures.shell(EngineFixtures.devFFprobe, ["-v", "error", "-show_entries", "stream=bits_per_raw_sample", "-of", "csv=p=0", flac.path])
        #expect(probe.output.trimmingCharacters(in: .whitespacesAndNewlines) == "24", "\(probe.output)")
    }

    /// 5.1 survives into M4A, and MP3 (stereo at most) folds down.
    @Test func surroundSound() async throws {
        let source = try EngineFixtures.make(.init(name: "surround", ext: "ac3", codec: ["-c:a", "ac3", "-ac", "6"], isVideo: false))
        let (m4a, _) = try await convert("audio.to-m4a", source)
        #expect(try AVAudioFile(forReading: m4a).fileFormat.channelCount == 6)
        let (mp3, _) = try await convert("audio.to-mp3", source)
        #expect(try AVAudioFile(forReading: mp3).fileFormat.channelCount == 2)
    }

    /// A drop of WAV and OGG together still offers every format they share.
    @Test func mixedDropGetsTheSameChoices() {
        let wav = InputFile(url: URL(fileURLWithPath: "/tmp/a.wav"), type: .wav)
        let ogg = InputFile(url: URL(fileURLWithPath: "/tmp/b.ogg"), type: UTType(filenameExtension: "ogg")!)
        let ids = Set(EngineFixtures.registry.actions(for: [wav, ogg], limit: 99).map(\.id.rawValue))
        #expect(ids.isSuperset(of: ["audio.to-mp3", "audio.to-m4a", "audio.to-aiff", "audio.to-flac"]), "\(ids)")
    }

    // MARK: Video in, still pictures and sound out (no video encoder)

    /// GIF is the engine's own CPU encoder; the source is only decoded.
    @Test(arguments: EngineFixtures.videos)
    func foreignVideoToGIF(spec: EngineFixtures.Spec) async throws {
        let source = try EngineFixtures.make(spec)
        let (out, _) = try await convert("video.foreign-to-gif", source)
        let file = try ImageFile(url: out)
        #expect(file.frameCount > 20, "\(spec.fileName): \(file.frameCount)")
        #expect(file.pixelWidth == 320 && file.pixelHeight == 240, "\(spec.fileName)")
    }

    /// The sound of a foreign video, as M4A and MP3.
    @Test(arguments: EngineFixtures.videos)
    func foreignVideoSoundOut(spec: EngineFixtures.Spec) async throws {
        let source = try EngineFixtures.make(spec)
        let (m4a, _) = try await convert("video.foreign-extract-audio", source)
        #expect(m4a.pathExtension == "m4a")
        #expect(try EngineFixtures.streams(m4a) == ["aac"], "\(spec.fileName)")
        #expect(abs(try await AVFixtures.duration(of: m4a) - spec.seconds) < 0.5, "\(spec.fileName)")
        let (mp3, _) = try await convert("video.to-mp3", source)
        #expect(try EngineFixtures.streams(mp3) == ["mp3"], "\(spec.fileName)")
        #expect(try EngineFixtures.peak(mp3) > 0.02, "\(spec.fileName)")
    }

    /// MP3 out of a video macOS reads itself. The MP4 is made with a CPU encoder, never AVAssetWriter.
    @Test func mp4ToMP3() async throws {
        let mp4 = try EngineFixtures.make(.init(name: "mpeg4-aac", ext: "mp4", codec: ["-c:v", "mpeg4", "-q:v", "5", "-c:a", "aac"]))
        let input = try #require(InputFile(url: mp4))
        #expect(EngineFixtures.registry.actions(for: [input], limit: 99).contains { $0.id == "video.to-mp3" })
        let (mp3, _) = try await convert("video.to-mp3", mp4)
        #expect(try EngineFixtures.streams(mp3) == ["mp3"])
        #expect(try AVAudioFile(forReading: mp3).length > 0)
    }

    @Test func silentVideoHasNoSoundToGive() async throws {
        let source = try EngineFixtures.make(.init(name: "silent", ext: "mkv", codec: ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-an"]))
        let (dir, file) = try EngineFixtures.isolated(source)
        let outcome = await EngineFixtures.run("video.to-mp3", on: file)
        #expect(outcome.outputs.isEmpty)
        #expect(outcome.failures.first?.message.contains("no sound") == true, "\(outcome.failures)")
        #expect(AVFixtures.leftovers(in: dir).isEmpty)
    }

    // MARK: Damage and hostile input

    @Test(arguments: ["webm", "mkv", "avi", "flv", "wmv", "ogv", "mpg", "ogg", "opus", "wma"])
    func randomBytesFailPlainly(ext: String) async throws {
        let dir = try AVFixtures.tempDir()
        let file = dir.appendingPathComponent("broken.\(ext)")
        var bytes = Data(count: 256_000)
        bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        try bytes.write(to: file)
        let audio = ["ogg", "opus", "wma"].contains(ext)
        let outcome = await EngineFixtures.run(audio ? "audio.to-mp3" : "video.foreign-to-gif", on: file)
        #expect(outcome.outputs.isEmpty)
        expectPlain(outcome)
        #expect(AVFixtures.leftovers(in: dir).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["broken.\(ext)"], "nothing else appears")
    }

    /// The first 40% of a real file whose header promises 8 s: the engine could squeeze out a short MP3, which isn't
    /// what was asked for.
    @Test func truncatedFileIsRefusedNotShortened() async throws {
        let source = try EngineFixtures.make(.init(name: "long", ext: "mka", codec: ["-c:a", "libopus", "-b:a", "128k"], isVideo: false, seconds: 8))
        let dir = try AVFixtures.tempDir()
        let file = dir.appendingPathComponent("cut.mka")
        let bytes = try Data(contentsOf: source)
        try bytes.prefix(bytes.count * 2 / 5).write(to: file)
        let outcome = await EngineFixtures.run("audio.to-mp3", on: file)
        #expect(outcome.outputs.isEmpty, "\(outcome.outputs)")
        expectPlain(outcome)
        #expect(AVFixtures.leftovers(in: dir).isEmpty)
    }

    /// A tiny file claiming an enormous frame doesn't get to allocate it. (One FFV1 frame, a CPU encoder.)
    @Test func hugeFrameIsRefused() async throws {
        let source = try EngineFixtures.make(.init(name: "huge", ext: "mkv", codec: ["-c:v", "ffv1", "-frames:v", "1", "-an"], seconds: 0.04, size: "9000x8000"))
        let (dir, file) = try EngineFixtures.isolated(source)
        let outcome = await EngineFixtures.run("video.foreign-to-gif", on: file)
        #expect(outcome.outputs.isEmpty)
        expectPlain(outcome)
        #expect(AVFixtures.leftovers(in: dir).isEmpty)
    }

    /// No engine text, no paths, nothing the file itself wrote.
    private func expectPlain(_ outcome: ConversionOutcome) {
        for failure in outcome.failures {
            let text = failure.message.lowercased()
            for word in ["ffmpeg", "matroska", "invalid data", "/", "error while", "demux", "libav"] {
                #expect(!text.contains(word), "\(failure.message)")
            }
        }
        #expect(!outcome.failures.isEmpty)
    }

    /// Names that would be options, protocols, patterns or shell tricks if anything read them as more than a name.
    @Test(arguments: ["-y.ogg", "-i evil.ogg", "concat:a|b.ogg", "http:--1.1.1.1-x.ogg", "%d %s.ogg", "$(touch pwned).ogg",
                      "a;touch pwned;.ogg", "`touch pwned`.ogg", "new\nline.ogg", "quo'te\"s.ogg", "пример звука.ogg"])
    func hostileNamesAreJustNames(name: String) async throws {
        let source = try EngineFixtures.make(EngineFixtures.audios[0])
        let (dir, file) = try EngineFixtures.isolated(source, name: name)
        let outcome = await EngineFixtures.run("audio.to-mp3", on: file)
        #expect(outcome.failures.isEmpty, "\(name): \(outcome.failures.map(\.message))")
        #expect(outcome.outputs.count == 1)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("pwned").path))
        #expect(!FileManager.default.fileExists(atPath: "pwned"))
    }

    @Test func argumentsAreFixedAndPathsAreFileURLs() {
        let url = URL(fileURLWithPath: "/tmp/-i http:x.webm")
        let args = MediaEngine.inputArguments(url, limits: .probe)
        #expect(args.last == "file:/tmp/-i http:x.webm")
        #expect(args[args.count - 2] == "-i")
        #expect(args.contains("-protocol_whitelist"))
        #expect(args[args.firstIndex(of: "-protocol_whitelist")! + 1] == "file,pipe")
        #expect(args.contains("-nostdin"))
        // A sub-second limit must not become a CPU limit of zero, which would kill the engine before it starts.
        let short = MediaEngine.inputArguments(url, limits: .init(maxRuntime: 0.3, stallTimeout: 1, maxFootprint: 1), cores: 1)
        #expect(short[short.firstIndex(of: "-timelimit")! + 1] == "1")
    }

    @Test func childEnvironmentIsSmall() {
        setenv("FFREPORT", "file=/tmp/x", 1)
        setenv("DYLD_INSERT_LIBRARIES", "/tmp/x", 1)
        defer {
            unsetenv("FFREPORT")
            unsetenv("DYLD_INSERT_LIBRARIES")
        }
        let child = MediaEngine.childEnvironment()
        #expect(!child.contains { $0.hasPrefix("FFREPORT") || $0.hasPrefix("DYLD_") }, "\(child)")
    }

    // MARK: Progress, cancelling, limits (40 minutes of audio, MP3 out)

    private final class Values: @unchecked Sendable {
        let lock = NSLock()
        var all: [Double] = []
        func add(_ v: Double) { lock.withLock { all.append(v) } }
        var snapshot: [Double] { lock.withLock { all } }
    }

    @Test func progressMovesSmoothly() async throws {
        let values = Values()
        let (out, _) = try await convert("audio.to-mp3", EngineFixtures.longWAV) { values.add($0) }
        #expect(FileManager.default.fileExists(atPath: out.path))
        let seen = values.snapshot
        #expect(seen.count >= 3, "\(seen)")
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 <= $1 }, "never backwards")
        #expect(seen.contains { $0 > 0.05 && $0 < 0.95 }, "something in between: \(seen)")
    }

    @Test func cancelKillsTheProcessAndLeavesNothing() async throws {
        let (dir, file) = try EngineFixtures.isolated(EngineFixtures.longWAV)
        let values = Values()
        let task = Task { await EngineFixtures.run("audio.to-mp3", on: file) { values.add($0) } }
        let start = Date()
        while values.snapshot.isEmpty, Date().timeIntervalSince(start) < 60 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(try !EngineFixtures.engineChildren().isEmpty, "the engine is running at this point")
        task.cancel()
        let cancelledAt = Date()
        let outcome = await task.value
        #expect(Date().timeIntervalSince(cancelledAt) < 3, "cancel takes effect at once")
        #expect(outcome.wasCancelled, "\(outcome.failures)")
        #expect(try EngineFixtures.engineChildren().isEmpty, "no engine process left")
        #expect(AVFixtures.leftovers(in: dir).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [file.lastPathComponent])
    }

    private func limited(_ limits: MediaEngine.Limits) async throws -> String {
        let dir = try AVFixtures.tempDir()
        let out = dir.appendingPathComponent(".halo-\(UUID().uuidString).mp3")
        do {
            try await MediaEngine.convert(input: EngineFixtures.longWAV, output: out,
                                          outputArguments: ["-map", "0:a:0", "-c:a", "libmp3lame", "-q:a", "2", "-f", "mp3"],
                                          expectedSeconds: 2400, checkLength: true, limits: limits) { _ in }
            return "no failure"
        } catch {
            #expect(try EngineFixtures.engineChildren().isEmpty, "the limit killed it")
            return (error as? ConversionError)?.errorDescription ?? "\(error)"
        }
    }

    @Test func timeLimitKills() async throws {
        let message = try await limited(.init(maxRuntime: 0.3, stallTimeout: 100, maxFootprint: MediaEngine.Limits.defaultFootprint))
        #expect(message.contains("too long"), "\(message)")
    }

    /// The engine reports its position every 0.2 s; a stall limit shorter than that sees "no movement" between reports.
    @Test func noProgressLimitKills() async throws {
        let message = try await limited(.init(maxRuntime: 100, stallTimeout: 0.05, maxFootprint: MediaEngine.Limits.defaultFootprint))
        #expect(message.contains("progress"), "\(message)")
    }

    @Test func memoryLimitKills() async throws {
        let message = try await limited(.init(maxRuntime: 100, stallTimeout: 100, maxFootprint: 1 << 20))
        #expect(message.contains("memory"), "\(message)")
    }

    /// What a parser crash looks like from here: killed by a signal, turned into a plain message.
    @Test func aCrashBecomesAPlainMessage() async throws {
        let result = try await MediaEngine.run(["-c", "kill -SEGV $$"], total: nil, limits: .probe, executable: URL(fileURLWithPath: "/bin/sh"))
        #expect(result.ending == .signalled(SIGSEGV), "\(result.ending)")
        let error = MediaEngine.failure(result, input: URL(fileURLWithPath: "/tmp/x"))
        #expect((error as? ConversionError) == MediaEngine.damaged)
    }

    /// A program that fills stderr can't wedge the reader, and the log can't grow past its cap.
    @Test func noisyChildCantStallOrBloat() async throws {
        let result = try await MediaEngine.run(["-c", "/usr/bin/yes 'stream of nonsense' | /usr/bin/head -c 8000000 >&2"], total: nil,
                                               limits: .probe, executable: URL(fileURLWithPath: "/bin/sh"))
        #expect(result.ending == .exited(0))
        #expect(result.log.utf8.count <= 1 << 20)
    }

    // MARK: Licence and build

    /// GPL v2 or later since 7 Nov 2026 (the founder chose open source for x264 / x265 quality). Never non-free, never v3-only
    /// parts, never other extra encoders, never the network.
    @Test func engineIsGPLWithX264AndHasNoNetwork() throws {
        let engine = try #require(MediaEngine.executableURL)
        let license = try EngineFixtures.shell(engine, ["-hide_banner", "-L"]).output
        #expect(license.contains("GNU General Public License"), "\(license)")
        let config = try EngineFixtures.shell(engine, ["-hide_banner", "-buildconf"]).output
        #expect(config.contains("--disable-network") && config.contains("--enable-gpl") && config.contains("--disable-nonfree"))
        #expect(config.contains("--enable-libx264") && config.contains("--enable-libx265"))
        for bad in ["--enable-nonfree", "--enable-version3", "libxvid", "libfdk"] { #expect(!config.contains(bad), "\(bad)") }
        let protocols = try EngineFixtures.shell(engine, ["-hide_banner", "-protocols"]).output
        for bad in ["tcp", "http", "https", "udp", "rtmp", "tls", "ftp", "data", "concat", "crypto", "subfile", "cache"] {
            #expect(!protocols.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == bad }, "\(bad)")
        }
        let imports = try EngineFixtures.shell(URL(fileURLWithPath: "/usr/bin/nm"), ["-u", engine.path]).output
        for bad in ["_socket", "_connect", "_getaddrinfo", "_gethostbyname"] {
            #expect(!imports.split(whereSeparator: \.isNewline).contains { String($0) == bad }, "\(bad)")
        }
    }

    /// CPU only: no VideoToolbox anywhere. Video encoders: x264 and x265 plus GIF and WebP, all CPU code.
    @Test func engineCantReachTheHardwareVideoEncoder() throws {
        let engine = try #require(MediaEngine.executableURL)
        let config = try EngineFixtures.shell(engine, ["-hide_banner", "-buildconf"]).output
        #expect(!config.contains("--enable-videotoolbox"), "\(config)")
        let encoders = try EngineFixtures.shell(engine, ["-hide_banner", "-encoders"]).output
        #expect(!encoders.lowercased().contains("videotoolbox"))
        let video = encoders.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let parts = line.split(separator: " ")
            guard parts.count > 1, parts[0].hasPrefix("V"), parts[1] != "=" else { return nil }
            return String(parts[1])
        }
        #expect(Set(video) == ["gif", "libwebp", "libx264", "libx265"], "\(video)")
        let links = try EngineFixtures.shell(URL(fileURLWithPath: "/usr/bin/otool"), ["-L", engine.path]).output
        #expect(!links.contains("VideoToolbox"), "\(links)")
        let hwaccels = try EngineFixtures.shell(engine, ["-hide_banner", "-hwaccels"]).output
        #expect(!hwaccels.contains("videotoolbox"), "\(hwaccels)")
    }

    @Test func engineCantBeSteeredToAnotherFile() throws {
        // A playlist in disguise: with no HLS or concat demuxer, this is just a bad file.
        let dir = try AVFixtures.tempDir()
        let secret = dir.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: secret)
        let playlist = dir.appendingPathComponent("list.webm")
        try Data("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:1,\nfile://\(secret.path)\n".utf8).write(to: playlist)
        let concat = dir.appendingPathComponent("concat.webm")
        try Data("ffconcat version 1.0\nfile \(secret.path)\n".utf8).write(to: concat)
        let engine = try #require(MediaEngine.executableURL)
        for list in [playlist, concat] {
            let done = try EngineFixtures.shell(engine, ["-hide_banner", "-nostdin", "-protocol_whitelist", "file,pipe", "-i", MediaEngine.path(list), "-f", "null", "-"])
            #expect(done.status != 0, "\(done.output)")
            #expect(done.output.contains("Invalid data"), "\(done.output)")
            #expect(!done.output.contains("secret"), "\(done.output)")
        }
    }
}

/// MP4 and HEVC out of foreign video through x264 / x265 (CPU). Gated with the other encoding tests (FRENZY_VIDEO_TESTS=1):
/// their fixtures are real encodes.
@Suite("Media engine video out (x264 / x265)", .enabled(if: EngineFixtures.ready),
       .enabled(if: HardwareVideoTests.allowed), .serialized)
struct EngineVideoOutTests {
    private static let registry = ActionRegistry(actions: DefaultActions.all(engine: true),
                                                 usage: MemoryUsageStore())

    private func convert(_ id: ActionID, _ source: URL) async throws -> (out: URL, dir: URL) {
        try await EngineFixtures.convert(id, source, registry: Self.registry)
    }

    @Test(arguments: EngineFixtures.videos)
    func videoToMP4(spec: EngineFixtures.Spec) async throws {
        let source = try EngineFixtures.make(spec)
        let (out, _) = try await convert("video.foreign-to-mp4", source)
        #expect(out.pathExtension == "mp4")
        let streams = try EngineFixtures.streams(out)
        #expect(streams.contains("h264"), "\(streams)")
        #expect(streams.contains("aac"), "\(streams)")
        #expect(streams.count == 2, "\(streams)")
        let duration = try await AVFixtures.duration(of: out)
        #expect(abs(duration - spec.seconds) < 0.6, "\(duration)")
        #expect(try await EngineFixtures.frameIsPicture(out))
    }

    @Test func webMToMP4KeepsThePicture() async throws {
        let source = try EngineFixtures.make(.init(name: "quality", ext: "webm",
                                                   codec: ["-c:v", "libvpx-vp9", "-crf", "20", "-b:v", "0", "-cpu-used", "8", "-c:a", "libopus"],
                                                   size: "1280x720"))
        let (out, _) = try await convert("video.foreign-to-mp4", source)
        let result = try EngineFixtures.shell(EngineFixtures.devFFmpeg, ["-hide_banner", "-i", out.path, "-i", source.path, "-lavfi", "ssim", "-f", "null", "-"])
        let match = try #require(result.output.firstMatch(of: /All:([0-9.]+)/))
        let ssim = try #require(Double(match.1))
        #expect(ssim > 0.93, "SSIM \(ssim)")
    }

    @Test func mkvWithH264IsRewrappedNotEncoded() async throws {
        let source = try EngineFixtures.make(EngineFixtures.videos.first { $0.name == "h264-ac3" }!)
        let (out, _) = try await convert("video.foreign-to-mp4", source)
        func hash(_ url: URL) throws -> String {
            try EngineFixtures.shell(EngineFixtures.devFFmpeg, ["-hide_banner", "-loglevel", "error", "-i", url.path, "-map", "0:v:0", "-c", "copy",
                                                                "-bsf:v", "h264_mp4toannexb", "-f", "md5", "-"]).output
        }
        #expect(try hash(out) == hash(source))
    }

    @Test func hevcTargetKeepsHEVCAndNamesIt() async throws {
        let source = try EngineFixtures.make(EngineFixtures.videos[0])
        let (out, _) = try await convert("video.foreign-to-hevc", source)
        #expect(out.lastPathComponent.contains("HEVC"))
        #expect(try EngineFixtures.streams(out).contains("hevc"))
    }

    @Test func hdrWebMStaysHDR() async throws {
        // 10-bit PQ AV1 in WebM (this developer FFmpeg's VP9 has no 10-bit). setparams labels the frames: FFmpeg takes the
        // colour tags from them, not from -color_* options.
        let source = try EngineFixtures.make(.init(name: "hdr-av1", ext: "webm", codec: [
            "-vf", "format=yuv420p10le,setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc",
            "-c:v", "libsvtav1", "-preset", "12", "-pix_fmt", "yuv420p10le", "-c:a", "libopus",
        ]))
        let (out, _) = try await convert("video.foreign-to-mp4", source)
        #expect(out.lastPathComponent.contains("HEVC"), "the name has to say what's inside")
        let done = try EngineFixtures.shell(EngineFixtures.devFFprobe, ["-v", "error", "-select_streams", "v:0", "-show_entries",
                                                                        "stream=codec_name,pix_fmt,color_transfer,color_primaries", "-of", "csv=p=0", out.path])
        #expect(done.output.contains("hevc"), "\(done.output)")
        #expect(done.output.contains("smpte2084"), "\(done.output)")
    }
}

/// Where the app and the worker look for the engine, and what the ring offers with and without it.
@Suite("Media engine location")
struct EngineLocationTests {
    private func fakeEngine(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test func appLooksInsideItsWorker() throws {
        let dir = try AVFixtures.tempDir()
        let app = dir.appendingPathComponent("Frenzy.app")
        let inWorker = app.appendingPathComponent("Contents/XPCServices/com.snappycrew.frenzy.worker.xpc/Contents/Helpers/frenzy-media-engine")
        #expect(MediaEngine.executableURL(bundle: app, developmentRoot: nil) == nil, "nothing there yet")
        // The old, wrong place: Contents/Helpers of the app itself. Never shipped there, so never found there.
        try fakeEngine(at: app.appendingPathComponent("Contents/Helpers/frenzy-media-engine"))
        #expect(MediaEngine.executableURL(bundle: app, developmentRoot: nil) == nil)
        try fakeEngine(at: inWorker)
        #expect(MediaEngine.executableURL(bundle: app, developmentRoot: nil)?.standardizedFileURL == inWorker.standardizedFileURL)
    }

    @Test func workerLooksInItsOwnHelpers() throws {
        let dir = try AVFixtures.tempDir()
        let worker = dir.appendingPathComponent("com.snappycrew.frenzy.worker.xpc")
        #expect(MediaEngine.executableURL(bundle: worker, developmentRoot: nil) == nil)
        let engine = worker.appendingPathComponent("Contents/Helpers/frenzy-media-engine")
        try fakeEngine(at: engine)
        #expect(MediaEngine.executableURL(bundle: worker, developmentRoot: nil)?.standardizedFileURL == engine.standardizedFileURL)
        // Present but not executable doesn't count.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: engine.path)
        #expect(MediaEngine.executableURL(bundle: worker, developmentRoot: nil) == nil)
    }

    @Test func outsideABundleOnlyTheSourceTreeBuild() throws {
        let dir = try AVFixtures.tempDir()
        let tool = dir.appendingPathComponent("debug")
        #expect(MediaEngine.executableURL(bundle: tool, developmentRoot: nil) == nil)
        #expect(MediaEngine.executableURL(bundle: tool, developmentRoot: dir) == nil)
        let built = dir.appendingPathComponent("vendor/build/arm64/bin/frenzy-media-engine")
        try fakeEngine(at: built)
        #expect(MediaEngine.executableURL(bundle: tool, developmentRoot: dir)?.standardizedFileURL == built.standardizedFileURL)
    }

    private static let engineOnly: Set<String> = ["audio.to-mp3", "audio.to-flac", "image.to-webp", "video.foreign-to-gif",
                                                  "video.foreign-extract-audio", "video.to-mp3"]

    @Test func withoutTheEngineNothingNeedsIt() {
        let ids = Set(DefaultActions.all(engine: false).map(\.id.rawValue))
        #expect(ids.isDisjoint(with: Self.engineOnly), "\(ids.intersection(Self.engineOnly))")
        // And no Apple action quietly takes foreign formats it would hand to the engine.
        let registry = DefaultActions.registry(engine: false, usage: MemoryUsageStore())
        for ext in ["ogg", "opus", "wma", "webm", "mkv", "avi"] {
            let input = InputFile(url: URL(fileURLWithPath: "/tmp/file.\(ext)"), type: UTType(filenameExtension: ext)!)
            let offered = registry.actions(for: [input], limit: 99).map(\.id.rawValue).filter { !$0.hasPrefix("archive.") }
            #expect(offered.isEmpty, "\(ext): \(offered)")
        }
        let png = InputFile(url: URL(fileURLWithPath: "/tmp/a.png"), type: .png)
        #expect(!registry.actions(for: [png], limit: 99).contains { $0.id == "image.to-webp" })
    }

    @Test func withTheEngineItsChoicesAppear() {
        let ids = Set(DefaultActions.all(engine: true).map(\.id.rawValue))
        #expect(ids.isSuperset(of: Self.engineOnly), "\(Self.engineOnly.subtracting(ids))")
    }

    /// MP4 and HEVC out of foreign video run on x264 / x265 (CPU): offered with the engine, never without it.
    @Test func videoOutComesWithTheEngine() {
        let videoOut = Set(EngineActions.videoOut.map(\.id.rawValue))
        #expect(videoOut == ["video.foreign-to-mp4", "video.foreign-to-hevc"])
        #expect(Set(DefaultActions.all(engine: true).map(\.id.rawValue)).isSuperset(of: videoOut))
        #expect(Set(DefaultActions.all(engine: false).map(\.id.rawValue)).isDisjoint(with: videoOut))
    }

    /// Every video argument list the engine can get: CPU encoders only, never the hardware encoder.
    @Test func videoOutNeverUsesTheVideoChip() {
        let video = MediaProbe.Video(codec: "vp9", pixelFormat: "yuv420p10le", width: 3840, height: 2160, isAttachedPicture: false, isHDR: true)
        let probe = MediaProbe(seconds: 10, video: [video], audio: [])
        for target in [EngineActions.VideoTarget.h264, .hevc] {
            let args = EngineActions.mp4Arguments(EngineActions.plan(probe, video: video, target: target), audio: nil)
            #expect(!args.joined(separator: " ").localizedCaseInsensitiveContains("videotoolbox"))
            #expect(args.contains("libx265") || args.contains("libx264"))
        }
    }

    /// The app's registry and the engine on disk agree: whatever this process found decides the choices.
    @Test func registryFollowsTheEngineOnDisk() {
        let ids = Set(DefaultActions.all().map(\.id.rawValue))
        #expect(ids.isSuperset(of: Self.engineOnly) == MediaEngine.isAvailable)
        #expect(ids.isDisjoint(with: Self.engineOnly) == !MediaEngine.isAvailable)
    }
}

@Suite("Media probe parsing")
struct MediaProbeTests {
    private static let sample = """
    Input #0, matroska,webm, from 'file:/x/a.webm':
      Metadata:
        ENCODER         : Lavf61
      Duration: 00:01:02.50, start: 0.000000, bitrate: 512 kb/s
      Stream #0:0: Video: vp9 (Profile 2), yuv420p10le(tv, bt2020nc/bt2020/smpte2084, progressive), 1920x1080, SAR 1:1 DAR 16:9, 30 fps, 1k tbn (default)
      Stream #0:1(eng): Audio: opus, 48000 Hz, stereo, fltp (default)
      Stream #0:2: Video: mjpeg (Baseline), yuvj420p(pc, bt470bg/unknown/unknown), 600x600 [SAR 1:1 DAR 1:1], 90k tbr, 90k tbn (attached pic)
    At least one output file must be specified
    """

    @Test func readsAFullListing() throws {
        let probe = try #require(MediaProbe.parse(Self.sample))
        #expect(abs(probe.seconds - 62.5) < 0.001)
        #expect(probe.video.count == 2)
        let main = try #require(probe.mainVideo)
        #expect(main.codec == "vp9" && main.pixelFormat == "yuv420p10le" && main.width == 1920 && main.height == 1080)
        #expect(main.isHDR && main.isTenBit && !main.is8Bit420 && !main.isAttachedPicture)
        #expect(probe.video[1].isAttachedPicture)
        #expect(probe.audio == [.init(codec: "opus", sampleRate: 48_000, channels: 2, bitDepth: 16)])
    }

    @Test func audioDetails() throws {
        let log = """
        Input #0, wav, from 'x':
          Duration: N/A, bitrate: N/A
          Stream #0:0: Audio: pcm_s24le ([1][0][0][0] / 0x0001), 96000 Hz, 5.1(side), s32 (24 bit), 13824 kb/s
        """
        let probe = try #require(MediaProbe.parse(log))
        #expect(probe.seconds == 0 && probe.mainVideo == nil)
        #expect(probe.audio == [.init(codec: "pcm_s24le", sampleRate: 96_000, channels: 6, bitDepth: 24)])
    }

    /// Tag values come indented, so a file can't invent a stream or a duration by writing one in its metadata.
    @Test func metadataCantFakeStreams() throws {
        let log = """
        Input #0, matroska,webm, from 'x':
          Metadata:
            title           : Duration: 99:00:00.00
                            :   Stream #0:9: Video: h264, yuv420p, 9x9
                            :   Duration: 99:00:00.00
          Duration: 00:00:03.00, start: 0.000000, bitrate: 1 kb/s
          Stream #0:0: Audio: opus, 48000 Hz, mono, fltp
        """
        let probe = try #require(MediaProbe.parse(log))
        #expect(probe.seconds == 3)
        #expect(probe.video.isEmpty)
        #expect(probe.audio.count == 1 && probe.audio[0].channels == 1)
    }

    @Test func nothingUsableIsNil() {
        #expect(MediaProbe.parse("") == nil)
        #expect(MediaProbe.parse("file:/x: Invalid data found when processing input") == nil)
        #expect(MediaProbe.parse("Input #0, wav, from 'x':\n  Duration: 00:00:01.00") == nil)
    }

    @Test func plansFollowTheStreams() {
        func video(_ codec: String, _ format: String, hdr: Bool = false) -> MediaProbe.Video {
            .init(codec: codec, pixelFormat: format, width: 640, height: 360, isAttachedPicture: false, isHDR: hdr)
        }
        func probe(_ audio: String?) -> MediaProbe {
            .init(seconds: 1, video: [], audio: audio.map { [.init(codec: $0, sampleRate: 48_000, channels: 2, bitDepth: 16)] } ?? [])
        }
        // H.264 8-bit rewraps; H.264 10-bit plays on nothing Apple, so it's encoded.
        #expect(EngineActions.plan(probe("aac"), video: video("h264", "yuv420p"), target: .h264).copyVideo)
        #expect(EngineActions.plan(probe("aac"), video: video("h264", "yuv420p"), target: .h264).copyAudio)
        #expect(!EngineActions.plan(probe("opus"), video: video("h264", "yuv420p"), target: .h264).copyAudio)
        #expect(!EngineActions.plan(probe(nil), video: video("h264", "yuv420p10le"), target: .h264).copyVideo)
        // The label says H.264, so HEVC doesn't pass through under it.
        #expect(!EngineActions.plan(probe(nil), video: video("hevc", "yuv420p"), target: .h264).copyVideo)
        #expect(EngineActions.plan(probe(nil), video: video("hevc", "yuv420p"), target: .hevc).copyVideo)
        let hdr = EngineActions.plan(probe(nil), video: video("vp9", "yuv420p10le", hdr: true), target: .h264)
        #expect(hdr.usesHEVC && hdr.isHDR && !hdr.copyVideo)
    }
}

@Suite("What the ring offers")
struct EngineRingTests {
    /// The ring as it is with the engine in the app. Without it, see `EngineLocationTests`.
    private let registry = DefaultActions.registry(engine: true, usage: MemoryUsageStore())

    private func ids(_ ext: String) -> [String] {
        let input = InputFile(url: URL(fileURLWithPath: "/tmp/file.\(ext)"), type: UTType(filenameExtension: ext)!)
        return registry.actions(for: [input], limit: 99).map(\.id.rawValue)
    }

    /// A foreign video leads with MP4 (x264, what people want from a WebM or MKV), then GIF and its sound; HEVC is there too.
    @Test(arguments: ["webm", "mkv", "avi", "flv", "wmv", "mpg", "ts", "ogv", "m2ts", "vob"])
    func foreignVideoLeadsWithMP4ThenGIFThenSound(ext: String) {
        let offered = ids(ext)
        #expect(Array(offered.prefix(4)) == ["video.foreign-to-mp4", "video.foreign-to-gif", "video.foreign-extract-audio", "video.to-mp3"], "\(offered)")
        #expect(offered.contains("video.foreign-to-hevc"), "\(offered)")
    }

    /// Common choices first: the ones people use most sit at the front, where the ring shows them.
    @Test func commonChoicesComeFirst() {
        #expect(Array(ids("wav").prefix(2)) == ["audio.to-mp3", "audio.to-m4a"], "\(ids("wav"))")
        #expect(ids("mp3").first == "audio.to-m4a", "\(ids("mp3"))")
        #expect(ids("flac").first == "audio.to-mp3", "\(ids("flac"))")
        let png = ids("png")
        #expect(Array(png.prefix(2)) == ["image.to-jpg", "image.to-pdf"] || png.first == "image.to-jpg", "\(png)")
        #expect(png.contains("image.to-webp"))
        #expect(png.last == "archive.zip", "\(png)")
    }

    @Test(arguments: ["ogg", "opus", "oga", "wma", "ac3", "aac", "mka"])
    func foreignAudioLeadsWithMP3(ext: String) {
        #expect(ids(ext).first == "audio.to-mp3", "\(ids(ext))")
        // A song never gets a video choice (WMA conforms to ASF, a video container).
        #expect(!ids(ext).contains { $0.hasPrefix("video.") }, "\(ids(ext))")
    }

    @Test func nothingIsOfferedItsOwnFormat() {
        #expect(!ids("mp3").contains("audio.to-mp3"))
        #expect(!ids("flac").contains("audio.to-flac"))
        #expect(!ids("webp").contains("image.to-webp"))
        #expect(!ids("avif").contains("image.to-avif"))
        #expect(!ids("mp4").contains("video.foreign-to-mp4"), "\(ids("mp4"))")
        #expect(!ids("mov").contains("video.foreign-to-mp4"), "\(ids("mov"))")
        #expect(!ids("m4v").contains("video.foreign-to-mp4"), "\(ids("m4v"))")
        #expect(!ids("3gp").contains("video.foreign-to-mp4"), "\(ids("3gp"))")
    }

    /// Every action can be reached. Between ring and "More" the window shows 12, so no drop may fit more than that.
    /// Checked for one, two and three files of every declared type, and every pair of types.
    @Test func everyChoiceStaysReachable() {
        let types = Array(Set(DefaultActions.all(engine: true).flatMap(\.inputTypes) + [.folder]))
        func file(_ type: UTType, _ n: Int) -> InputFile { InputFile(url: URL(fileURLWithPath: "/tmp/\(n)"), type: type) }
        var worst = 0
        var reached = Set<String>()
        func check(_ inputs: [InputFile]) {
            let fitted = registry.actions(for: inputs, limit: .max)
            worst = max(worst, fitted.count)
            #expect(fitted.count <= 12, "\(inputs.map(\.type.identifier)): \(fitted.map(\.id.rawValue))")
            reached.formUnion(fitted.map(\.id.rawValue))
        }
        for type in types {
            check([file(type, 1)])
            check([file(type, 1), file(type, 2)])
            check([file(type, 1), file(type, 2), file(type, 3)])
            for other in types where other != type { check([file(type, 1), file(other, 2)]) }
        }
        let every = Set(DefaultActions.all(engine: true).map(\.id.rawValue))
        #expect(reached == every, "unreachable: \(every.subtracting(reached))")
        print("Most choices for one drop: \(worst)")
    }

    /// The engine's outputs have to pass placement, or the app would refuse a finished conversion.
    @Test func everyNewOutputCanBePlaced() {
        for ext in ["mp4", "gif", "m4a", "mp3", "flac", "wav", "aiff", "webp", "avif", "ico", "png", "jpg", "pdf", "docx", "gz", "txt"] {
            #expect(StagedPlacement.allowedExtensions.contains(ext), "\(ext)")
        }
        #expect(StagedPlacement.extractionActions.contains("archive.unpack"))
        #expect(StagedPlacement.quarantineActions.isSuperset(of: ["archive.unpack", "archive.to-tgz"]))
    }
}
