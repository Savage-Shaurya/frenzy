import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import HaloCore
@testable import HaloConverters
import Testing
import UniformTypeIdentifiers
import VideoToolbox

/// Runtime-generated media fixtures shared by the Video/Audio/Document tests. Nothing binary is committed.
/// Video encoding tests drive the Mac's hardware video encoder. On macOS 27 they kernel-panicked the founder's Mac three
/// times (dart-ave0, 7 Nov 2026), so they never run unless someone opts in for that one run: FRENZY_VIDEO_TESTS=1.
enum HardwareVideoTests {
    static let allowed = ProcessInfo.processInfo.environment["FRENZY_VIDEO_TESTS"] == "1"
}

enum AVFixtures {
    /// A fresh, empty temp folder for one test.
    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-avtests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copies a cached fixture into `dir` so every test has its own original next to its outputs.
    static func copy(_ url: URL, into dir: URL, name: String? = nil) throws -> URL {
        let dest = dir.appendingPathComponent(name ?? url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    static func leftovers(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(".halo-") }
    }

    static let registry = ActionRegistry(actions: VideoActions.all + AudioActions.all + DocumentActions.all, usage: MemoryUsageStore())

    /// Runs `id` on `file` through the real runner (same cleanup path as the app) and returns the outputs.
    static func run(_ id: ActionID, on file: URL, type: UTType? = nil) async -> ConversionOutcome {
        let input = type.map { InputFile(url: file, type: $0) } ?? InputFile(url: file)!
        let runner = ConversionRunner(registry: registry, maxConcurrent: 1)
        return await runner.run(id, on: [input])
    }

    static func duration(of url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    // MARK: - Movie

    enum HDR: Hashable, Sendable { case hlg, pq }

    struct MovieSpec: Hashable, Sendable {
        var width = 640, height = 360, fps = 30, seconds = 2.5
        var codec = AVVideoCodecType.h264
        var bitRate = 8_000_000
        var audio = true
        var fileType = AVFileType.mov
        /// 10-bit BT.2020 HDR (HEVC Main10 or ProRes), tagged HLG or PQ. PQ also carries HDR10 static metadata.
        var hdr: HDR?

        static func hdr(_ kind: HDR, codec: AVVideoCodecType = .hevc, seconds: Double = 1.5, audio: Bool = false) -> MovieSpec {
            var spec = MovieSpec()
            spec.hdr = kind; spec.codec = codec; spec.seconds = seconds; spec.audio = audio
            return spec
        }
    }

    static let mdcv = Data([0x33, 0xC2, 0x86, 0xC4, 0x1D, 0x4C, 0x0B, 0xB8, 0x84, 0xD0, 0x3E, 0x80, 0x3D, 0x13, 0x40, 0x42,
                            0x00, 0x98, 0x96, 0x80, 0x00, 0x00, 0x00, 0x32])
    static let cll = Data([0x03, 0xE8, 0x01, 0x90])

    static func transfer(_ hdr: HDR) -> String {
        hdr == .hlg ? AVVideoTransferFunction_ITU_R_2100_HLG : AVVideoTransferFunction_SMPTE_ST_2084_PQ
    }

    private static let cache = FixtureCache()

    /// A noisy, colour-cycling test movie (noise makes the bitrate real, so "compress" has something to remove).
    static func movie(_ spec: MovieSpec = .init()) async throws -> URL {
        // Encoding a test movie uses the hardware encoder too.
        precondition(HardwareVideoTests.allowed, "Video encoding tests are off on this Mac: set FRENZY_VIDEO_TESTS=1 for one deliberate run")
        return try await cache.get(spec) { try writeMovie(spec) }
    }

    /// Written by the developer FFmpeg's CPU encoders (x264, x265, ProRes KS, AAC), never AVAssetWriter: Apple's writer
    /// drives the hardware video encoder, which kernel-panicked the founder's Mac three times (7 Nov 2026).
    /// A test pattern with grain on every frame, so the bitrate is real and "compress" has something to remove.
    private static func writeMovie(_ spec: MovieSpec) throws -> URL {
        let ext = spec.fileType == .mp4 ? "mp4" : "mov"
        let url = try tempDir().appendingPathComponent("clip.\(ext)")
        let seconds = String(spec.seconds)
        var args = ["-hide_banner", "-loglevel", "error", "-y", "-threads", "4",
                    "-f", "lavfi", "-i", "testsrc2=s=\(spec.width)x\(spec.height):r=\(spec.fps):d=\(seconds)"]
        if spec.audio { args += ["-f", "lavfi", "-i", "sine=f=440:r=44100:d=\(seconds)"] }
        args += ["-map", "0:v"] + (spec.audio ? ["-map", "1:a", "-c:a", "aac", "-b:a", "128k", "-ac", "2"] : [])
        let isProRes = spec.codec.rawValue.hasPrefix("ap")
        let tenBit = spec.hdr != nil
        var filter = "noise=alls=24:allf=t"
        filter += tenBit ? ",format=\(isProRes ? "yuv422p10le" : "yuv420p10le")" : ",format=\(isProRes ? "yuv422p10le" : "yuv420p")"
        if let hdr = spec.hdr {
            // FFmpeg takes colour labels from the frames: label them, or ProRes comes out half-tagged.
            filter += ",setparams=color_primaries=bt2020:color_trc=\(hdr == .hlg ? "arib-std-b67" : "smpte2084"):colorspace=bt2020nc"
        }
        args += ["-vf", filter]
        var x265 = "log-level=error"
        if let hdr = spec.hdr {
            let trc = hdr == .hlg ? "arib-std-b67" : "smpte2084"
            args += ["-color_primaries", "bt2020", "-color_trc", trc, "-colorspace", "bt2020nc"]
            x265 += ":colorprim=bt2020:transfer=\(trc):colormatrix=bt2020nc"
            if hdr == .pq {
                // The same HDR10 static metadata as `mdcv` / `cll`.
                x265 += ":hdr10=1:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50):max-cll=1000,400"
            }
        }
        switch spec.codec {
        case .hevc:
            args += ["-c:v", "libx265", "-preset", "ultrafast", "-b:v", String(spec.bitRate), "-tag:v", "hvc1", "-x265-params", x265]
            if tenBit { args += ["-profile:v", "main10"] }
        case _ where isProRes:
            args += ["-c:v", "prores_ks", "-profile:v", "2"]
        default:
            args += ["-c:v", "libx264", "-preset", "ultrafast", "-b:v", String(spec.bitRate)]
        }
        args += ["-movflags", "+write_colr", "-t", seconds, "-f", spec.fileType == .mp4 ? "mp4" : "mov", url.path]
        // The founder's rule, enforced: no fixture may reach the hardware video encoder.
        precondition(!args.contains { $0.contains("videotoolbox") || $0.hasSuffix("_vt") }, "no hardware video encoding")
        let done = try EngineFixtures.shell(EngineFixtures.devFFmpeg, args)
        guard done.status == 0 else { throw ConversionError.engine("fixture: \(done.output)") }
        return url
    }

    /// Copies a shifted window of one precomputed noise field into the frame: cheap, and every frame differs.
    private static func fillNoise(_ pb: CVPixelBuffer, frame: Int, noise: [UInt32]) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), stride = CVPixelBufferGetBytesPerRow(pb)
        let offset = (frame * 7919) % (noise.count - w * h)
        noise.withUnsafeBufferPointer { src in
            for y in 0..<h {
                memcpy(base + y * stride, src.baseAddress! + offset + y * w, w * 4)
            }
        }
    }

    /// 10-bit 4:2:0 biplanar video range (each sample in the top 10 bits of a UInt16): a luma ramp plus noise, so
    /// the picture has real detail and the HDR fixture has a real bitrate.
    private static func fillNoise10(_ pb: CVPixelBuffer, frame: Int, noise: [UInt32]) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let offset = (frame * 7919) % (noise.count / 2)
        for plane in 0..<CVPixelBufferGetPlaneCount(pb) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane)?.assumingMemoryBound(to: UInt16.self) else { continue }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane) / 2
            let samples = CVPixelBufferGetWidthOfPlane(pb, plane) * (plane == 0 ? 1 : 2)
            let rows = CVPixelBufferGetHeightOfPlane(pb, plane)
            for y in 0..<rows {
                for x in 0..<samples {
                    let n = Int(noise[(offset + y * samples + x) % noise.count] & 0x7F)
                    let v = plane == 0 ? 64 + (x * 700 / samples) + n : 448 + n
                    base[y * stride + x] = UInt16(min(940, v)) << 6
                }
            }
        }
    }

    private static func makeNoise(count: Int) -> [UInt32] {
        var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
        return [UInt32](unsafeUninitializedCapacity: count) { buf, n in
            for i in 0..<count {
                rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
                buf[i] = 0xFF00_0000 | UInt32(truncatingIfNeeded: rng)
            }
            n = count
        }
    }

    private static func sineBuffer(start: Int, frames: Int, sampleRate: Double, channels: Int, format: CMAudioFormatDescription) -> CMSampleBuffer? {
        var samples = [Float](repeating: 0, count: frames * channels)
        for i in 0..<frames {
            let v = Float(sin(2 * Double.pi * 440 * Double(start + i) / sampleRate) * 0.3)
            for c in 0..<channels { samples[i * channels + c] = v }
        }
        let bytes = samples.count * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sample)
        return sample
    }

    // MARK: - Audio

    /// A 440 Hz sine written with AVAudioFile. The container follows `ext` (wav, aiff, caf, m4a).
    static func tone(ext: String, seconds: Double = 1.5, settings extra: [String: Any] = [:]) throws -> URL {
        let url = try tempDir().appendingPathComponent("tone.\(ext)")
        let sampleRate = 44_100.0
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: ext == "aiff",
            AVLinearPCMIsNonInterleaved: false,
        ]
        settings.merge(extra) { $1 }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<2 {
            let p = buffer.floatChannelData![c]
            for i in 0..<Int(frames) { p[i] = Float(sin(2 * Double.pi * 440 * Double(i) / sampleRate) * 0.3) }
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        return url
    }

    // MARK: - Reference movies

    /// A QuickTime reference movie at `dest`: just a movie header whose sample tables point into `source`.
    static func referenceMovie(to source: URL, at dest: URL) async throws {
        let src = AVURLAsset(url: source)
        let movie = AVMutableMovie()
        try movie.insertTimeRange(CMTimeRange(start: .zero, duration: try await src.load(.duration)), of: src, at: .zero, copySampleData: false)
        try movie.writeHeader(to: dest, fileType: .mov, options: .addMovieHeaderToDestination)
    }

    /// The colour facts of the first video track of `url`.
    static func color(of url: URL) async throws -> AVColorInfo {
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        return await AVColorInfo.of(track)
    }

    /// Decodes every video frame of `url`; returns how many there were.
    static func decodedFrameCount(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        ])
        reader.add(output)
        #expect(reader.startReading())
        var n = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(sample) != nil { n += 1 }
        }
        #expect(reader.status == .completed, "\(String(describing: reader.error))")
        return n
    }

    static func sha(_ url: URL) throws -> Data { try Data(contentsOf: url) }
}

/// Builds each fixture once per test process, even when tests run in parallel.
/// Fixture writing blocks (busy loop + finishWriting wait), so it runs one at a time on its own serial queue,
/// never on Swift's cooperative pool: blocking every pool thread starved AVFoundation and hung the full suite.
private actor FixtureCache {
    private var tasks: [AVFixtures.MovieSpec: Task<URL, any Error>] = [:]
    private static let queue = DispatchQueue(label: "halo.tests.av-fixtures", qos: .userInitiated)

    func get(_ spec: AVFixtures.MovieSpec, make: @escaping @Sendable () throws -> URL) async throws -> URL {
        if let t = tasks[spec] { return try await t.value }
        let t = Task<URL, any Error> {
            try await withCheckedThrowingContinuation { continuation in
                // Fixture encodes take the app's hardware-encode gate too: never two encoder sessions at once.
                Self.queue.async { continuation.resume(with: Result { try HardwareEncodeGate.shared.withPermitBlocking(make) }) }
            }
        }
        tasks[spec] = t
        return try await t.value
    }
}
