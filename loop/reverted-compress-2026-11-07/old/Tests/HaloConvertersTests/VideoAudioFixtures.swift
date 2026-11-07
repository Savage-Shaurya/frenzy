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
        try await cache.get(spec) { try writeMovie(spec) }
    }

    private static func writeMovie(_ spec: MovieSpec) throws -> URL {
        let ext = spec.fileType == .mp4 ? "mp4" : "mov"
        let url = try tempDir().appendingPathComponent("clip.\(ext)")
        let writer = try AVAssetWriter(outputURL: url, fileType: spec.fileType)
        let isProRes = spec.codec.rawValue.hasPrefix("ap")
        var compression: [String: Any] = isProRes ? [:] : [AVVideoAverageBitRateKey: spec.bitRate]
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: spec.codec,
            AVVideoWidthKey: spec.width,
            AVVideoHeightKey: spec.height,
        ]
        if let hdr = spec.hdr {
            videoSettings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: transfer(hdr),
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
            if spec.codec == .hevc { compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String }
            if hdr == .pq, spec.codec == .hevc {
                compression[kVTCompressionPropertyKey_MasteringDisplayColorVolume as String] = mdcv
                compression[kVTCompressionPropertyKey_ContentLightLevelInfo as String] = cll
            }
        }
        if !compression.isEmpty { videoSettings[AVVideoCompressionPropertiesKey] = compression }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: spec.hdr == nil ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: spec.width,
            kCVPixelBufferHeightKey as String: spec.height,
        ])
        writer.add(videoIn)

        let sampleRate = 44_100.0, channels: UInt32 = 2
        var audioIn: AVAssetWriterInput?
        var audioFormat: CMAudioFormatDescription?
        if spec.audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioIn = input
            var asbd = AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
                mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                           magicCookie: nil, extensions: nil, formatDescriptionOut: &audioFormat)
        }

        guard writer.startWriting() else { throw writer.error ?? ConversionError.engine("fixture") }
        writer.startSession(atSourceTime: .zero)

        let frames = Int(spec.seconds * Double(spec.fps))
        let audioFrames = Int(spec.seconds * sampleRate)
        var frame = 0, audioDone = 0
        let noise = makeNoise(count: spec.width * spec.height + 8192 * 64)
        while frame < frames || (audioIn != nil && audioDone < audioFrames) {
            var progressed = false
            if frame < frames, videoIn.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool {
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                guard let pb else { throw ConversionError.engine("pixel buffer") }
                if let hdr = spec.hdr {
                    fillNoise10(pb, frame: frame, noise: noise)
                    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
                    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, transfer(hdr) as CFString, .shouldPropagate)
                    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
                } else {
                    fillNoise(pb, frame: frame, noise: noise)
                }
                adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(spec.fps)))
                frame += 1
                // Finish each input as soon as it's exhausted, or the writer stalls waiting to interleave it.
                if frame == frames { videoIn.markAsFinished() }
                progressed = true
            }
            if let audioIn, let audioFormat, audioDone < audioFrames, audioIn.isReadyForMoreMediaData {
                let n = min(1024, audioFrames - audioDone)
                if let sample = sineBuffer(start: audioDone, frames: n, sampleRate: sampleRate, channels: Int(channels), format: audioFormat) {
                    audioIn.append(sample)
                }
                audioDone += n
                if audioDone >= audioFrames { audioIn.markAsFinished() }
                progressed = true
            }
            if !progressed { Thread.sleep(forTimeInterval: 0.002) }
        }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? ConversionError.engine("fixture") }
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
                Self.queue.async { continuation.resume(with: Result { try make() }) }
            }
        }
        tasks[spec] = t
        return try await t.value
    }
}
