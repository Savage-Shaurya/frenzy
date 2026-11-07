import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import HaloCore
@testable import HaloConverters
import IOKit
import Testing
import VideoToolbox

// Approach B of the safe video plan: Apple's software H.264 / HEVC encoders, never AVE. See docs/VIDEO-SOFTWARE-PATH.md.
//
// Two suites:
// - "Software video settings" never encodes, decodes or calls VideoToolbox. Safe to run any time.
// - "Software video encoding" ENCODES. Off unless FRENZY_VIDEO_TESTS=1, and then run ONE test at a time, wrapped in
//   scripts/video-safety-probe.sh, in the order the doc gives. It never decodes either: sources are drawn in memory and
//   outputs are only checked by their container (format description), never played.

@Suite("Software video settings")
struct SoftwareVideoSettingsTests {
    @Test(arguments: SoftwareVideoEncoding.Codec.allCases)
    func specificationPinsTheSoftwareEncoder(codec: SoftwareVideoEncoding.Codec) {
        let spec = SoftwareVideoEncoding.encoderSpecification(codec)
        #expect(spec[kVTVideoEncoderSpecification_EncoderID as String] as? String == codec.softwareEncoderID)
        #expect(spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String] as? Bool == false)
        #expect(spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String] as? Bool == false)
        #expect(!SoftwareVideoEncoding.hardwareEncoderIDs.contains(codec.softwareEncoderID))
    }

    @Test(arguments: SoftwareVideoEncoding.Codec.allCases)
    func builtSettingsAreSoftwareOnly(codec: SoftwareVideoEncoding.Codec) {
        let settings = SoftwareVideoEncoding.writerSettings(.init(codec: codec, width: 320, height: 180, bitRate: 400_000, fps: 30))
        #expect(SoftwareVideoEncoding.violations(in: settings) == [])
        #expect(settings[AVVideoCodecKey] as? AVVideoCodecType == codec.avCodec)
        let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        #expect(compression?[AVVideoAverageBitRateKey] as? Int == 400_000)
    }

    @Test func tenBitHEVCAsksForMain10() {
        let settings = SoftwareVideoEncoding.writerSettings(.init(codec: .hevc, width: 320, height: 180, bitRate: 1, fps: 30, tenBit: true))
        let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        #expect(compression?[AVVideoProfileLevelKey] as? String == kVTProfileLevel_HEVC_Main10_AutoLevel as String)
    }

    @Test func plainSettingsAreRejected() {
        let plain: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: 320, AVVideoHeightKey: 180]
        #expect(SoftwareVideoEncoding.violations(in: plain) == [.noEncoderSpecification])
    }

    @Test func everyWayBackToHardwareIsCaught() {
        var settings = SoftwareVideoEncoding.writerSettings(.init(codec: .h264, width: 320, height: 180, bitRate: 1, fps: 30))
        settings[AVVideoEncoderSpecificationKey] = [
            kVTVideoEncoderSpecification_EncoderID as String: "com.apple.videotoolbox.videoencoder.ave.avc",
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
            kVTVideoEncoderSpecification_PreferredEncoderGPURegistryID as String: 1,
        ]
        let found = SoftwareVideoEncoding.violations(in: settings)
        #expect(found.contains(.hardwareNotDisabled))
        #expect(found.contains(.hardwareRequired))
        #expect(found.contains(.notTheSoftwareEncoder("com.apple.videotoolbox.videoencoder.ave.avc")))
        #expect(found.contains(.gpuEncoderRequested))

        settings[AVVideoEncoderSpecificationKey] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false,
        ]
        #expect(SoftwareVideoEncoding.violations(in: settings) == [.encoderNotPinned])
    }

    @Test func forcingSoftwareWrapsTranscoderStyleSettings() throws {
        // The shape AVTranscoder.videoSetup builds today (no encoder specification at all).
        let transcoder: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 3_000_000],
        ]
        #expect(!SoftwareVideoEncoding.isSoftwareOnly(transcoder))
        let forced = try SoftwareVideoEncoding.forcingSoftware(transcoder)
        #expect(SoftwareVideoEncoding.isSoftwareOnly(forced))
        #expect(forced[AVVideoScalingModeKey] as? String == AVVideoScalingModeResizeAspect)

        let proRes: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.proRes422, AVVideoWidthKey: 320, AVVideoHeightKey: 180]
        #expect(throws: ConversionError.self) { try SoftwareVideoEncoding.forcingSoftware(proRes) }
        #expect(SoftwareVideoEncoding.violations(in: proRes) == [.unsupportedCodec(AVVideoCodecType.proRes422.rawValue)])
    }

    @Test func bitRateFollowsTheTranscoderRules() {
        let hevc = SoftwareVideoEncoding.bitRate(codec: .hevc, width: 1920, height: 1080, fps: 30, sourceDataRate: 0)
        let h264 = SoftwareVideoEncoding.bitRate(codec: .h264, width: 1920, height: 1080, fps: 30, sourceDataRate: 0)
        #expect(h264 > hevc)
        #expect(SoftwareVideoEncoding.bitRate(codec: .hevc, width: 1920, height: 1080, fps: 30, sourceDataRate: 1_000_000) == 600_000)
        #expect(SoftwareVideoEncoding.bitRate(codec: .hevc, width: 16, height: 16, fps: 1, sourceDataRate: 0) == 150_000)
    }

    // Reads plug-in Info.plists from disk only: no VideoToolbox call, no plug-in loaded.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: SoftwareVideoEncoding.pluginsFolder.path)))
    func thisMacShipsBothSoftwareEncoders() {
        let installed = SoftwareVideoEncoding.installedEncoders()
        for codec in SoftwareVideoEncoding.Codec.allCases {
            let sw = installed.first { $0.id == codec.softwareEncoderID }
            #expect(sw != nil, "\(codec) software encoder missing")
            #expect(sw?.isHardware == false)
            #expect(sw?.codecTypes.contains(codec.fourCC) == true)
            #expect(SoftwareVideoEncoding.softwareEncoderInstalled(codec))
        }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: SoftwareVideoEncoding.pluginsFolder.path)))
    func everyHardwareH264AndHEVCEncoderIsKnown() {
        let hardware = SoftwareVideoEncoding.installedEncoders()
            .filter { $0.isHardware && !Set($0.codecTypes).isDisjoint(with: ["avc1", "hvc1"]) }
        #expect(!hardware.isEmpty)
        for encoder in hardware {
            #expect(SoftwareVideoEncoding.hardwareEncoderIDs.contains(encoder.id), "new hardware encoder: \(encoder.id)")
        }
    }

    @Test func readsAFakePluginFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-swvideo-\(UUID().uuidString)")
        let contents = dir.appendingPathComponent("Fake.bundle/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plist: [String: Any] = ["CMClassImplementations": [
            ["CMClassID": "com.apple.videotoolbox.videoencoder", "CMClassImplementationID": "x.hw",
             "VTEncoderName": "HW", "CMMatchingInfo": ["VTCodecType": "hvc1", "VTIsHardwareAccelerated": true]],
            ["CMClassID": "com.apple.videotoolbox.videoencoder", "CMClassImplementationID": "x.sw",
             "VTEncoderName": "SW", "CMMatchingInfo": ["VTCodecType": ["hvc1", "avc1"]]],
            ["CMClassID": "com.apple.videotoolbox.videodecoder", "CMClassImplementationID": "x.dec"],
        ]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let found = SoftwareVideoEncoding.installedEncoders(in: dir)
        #expect(found == [
            .init(id: "x.hw", name: "HW", codecTypes: ["hvc1"], isHardware: true, bundle: "Fake.bundle"),
            .init(id: "x.sw", name: "SW", codecTypes: ["hvc1", "avc1"], isHardware: false, bundle: "Fake.bundle"),
        ])
    }

    /// Reading the IORegistry is not video work; this only proves the counter can be read (the value depends on the Mac).
    @Test func aveUserClientCountIsReadable() {
        #expect(AVEStatus.userClientCount() != nil)
    }

    @Test func routeFallsBackToSoftwareWheneverAVEIsBusyOrUnknown() throws {
        typealias S = SoftwareVideoEncoding
        #expect(S.route(aveUserClients: 0) == .hardware)
        #expect(S.route(aveUserClients: 1) == .software(.encoderBusy(1)))
        #expect(S.route(aveUserClients: nil) == .software(.encoderStateUnknown))
        #expect(S.route(aveUserClients: 0, forceSoftware: true) == .software(.forced))

        let hw: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180]
        #expect(!S.isSoftwareOnly(try S.settings(hw, for: .hardware)))
        #expect(S.isSoftwareOnly(try S.settings(hw, for: .software(.encoderBusy(1)))))
    }
}

// MARK: - Encoding (gated)

/// ENCODES VIDEO. Run one test at a time, with FRENZY_VIDEO_TESTS=1, inside scripts/video-safety-probe.sh, after the
/// founder has said yes in the chat and saved their work. Order: tinyH264 -> tinyHEVC -> tinyHEVCMain10 -> throughput.
/// RETIRED PATH (8 Nov 2026): Frenzy encodes video with x264 / x265 in its engine and never calls Apple's encoders, so
/// these only matter for AVTranscoder, which the app no longer reaches. Apple's "software" encoder also opened the
/// hardware encoder for a moment in measurements, so they need their own switch on top: FRENZY_APPLE_ENCODER_TESTS=1.
@Suite("Software video encoding", .enabled(if: HardwareVideoTests.allowed
                                            && ProcessInfo.processInfo.environment["FRENZY_APPLE_ENCODER_TESTS"] == "1"), .serialized)
struct SoftwareVideoEncodingTests {
    /// Step 1. 1 s of 320x180 H.264 drawn in memory, written with the software encoder pinned. No decoding anywhere.
    @Test func tinyH264() async throws {
        try await encodeAndCheck(codec: .h264, width: 320, height: 180, seconds: 1)
    }

    /// Step 2. Same in HEVC.
    @Test func tinyHEVC() async throws {
        try await encodeAndCheck(codec: .hevc, width: 320, height: 180, seconds: 1)
    }

    /// Step 3. Whether the software HEVC encoder takes Main10 (decides whether HDR can stay HDR on this path).
    @Test func tinyHEVCMain10() async throws {
        try await encodeAndCheck(codec: .hevc, width: 320, height: 180, seconds: 1, tenBit: true)
    }

    /// Step 4, only after 1 to 3 were clean. 2 s of 1080p per codec; prints measured frames per second.
    @Test(arguments: SoftwareVideoEncoding.Codec.allCases)
    func throughput1080p(codec: SoftwareVideoEncoding.Codec) async throws {
        try await encodeAndCheck(codec: codec, width: 1920, height: 1080, seconds: 2)
    }

    private func encodeAndCheck(codec: SoftwareVideoEncoding.Codec, width: Int, height: Int, seconds: Double,
                                tenBit: Bool = false) async throws {
        let watch = AVEWatch()
        let baseline = AVEWatch.userClientCount()
        print("[sw-video] \(codec) \(width)x\(height) tenBit=\(tenBit): AVE user clients before = \(baseline)")
        watch.start()
        let started = Date()
        let url: URL
        do {
            url = try SoftwareMovieWriter.write(codec: codec, width: width, height: height, fps: 30, seconds: seconds, tenBit: tenBit)
        } catch {
            watch.stop()
            throw error
        }
        let elapsed = Date().timeIntervalSince(started)
        let peak = watch.stop()
        let frames = Int(seconds * 30)
        print("[sw-video] \(codec): \(frames) frames in \(String(format: "%.2f", elapsed)) s (incl. 1 s of hold-open pauses), "
              + "AVE user clients peak = \(peak), after = \(AVEWatch.userClientCount())")
        #expect(baseline == 0, "start from a quiet Mac: quit apps that encode (Chrome, FaceTime, OBS) first")
        #expect(peak == baseline, "an AVE user client appeared during a software encode")

        // Container checks only (no decoder): the track exists, has the right codec and roughly the right duration.
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let desc = try #require(try await track.load(.formatDescriptions).first)
        let subtype = CMFormatDescriptionGetMediaSubType(desc)
        #expect(subtype == (codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC))
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - seconds) < 0.2)
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print("[sw-video] \(codec): output \(size) bytes at \(url.path)")
        #expect(size > 0)
    }
}

// MARK: - Helpers

/// Samples `AVEStatus.userClientCount()` every 20 ms on a background thread while a test encodes.
final class AVEWatch: @unchecked Sendable {
    /// -1 when the count can't be read, so a test fails loudly instead of passing blind.
    static func userClientCount() -> Int { AVEStatus.userClientCount() ?? -1 }

    private let lock = NSLock()
    private var running = false
    private var peak = 0

    func start() {
        lock.withLock { running = true; peak = Self.userClientCount() }
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let n = Self.userClientCount()
                lock.withLock { peak = max(peak, n) }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
    }

    /// Stops sampling and returns the highest count seen.
    @discardableResult
    func stop() -> Int {
        let n = Self.userClientCount()
        return lock.withLock { running = false; peak = max(peak, n); return peak }
    }
}

/// Draws frames in memory and writes them with the software encoder pinned. Never reads or decodes a movie.
enum SoftwareMovieWriter {
    static func write(codec: SoftwareVideoEncoding.Codec, width: Int, height: Int, fps: Int, seconds: Double,
                      tenBit: Bool, fastFill: Bool = false) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-swvideo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sw-\(codec.rawValue).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let color: [String: String] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        let settings = SoftwareVideoEncoding.writerSettings(.init(
            codec: codec, width: width, height: height,
            bitRate: SoftwareVideoEncoding.bitRate(codec: codec, width: width, height: height, fps: Double(fps), sourceDataRate: 0),
            fps: Double(fps), colorProperties: color, tenBit: tenBit))
        precondition(SoftwareVideoEncoding.isSoftwareOnly(settings), "refusing to encode with settings that allow hardware")
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw ConversionError.engine("The software \(codec) encoder refused these settings (tenBit=\(tenBit)).")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let format = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ConversionError.engine("startWriting") }
        writer.startSession(atSourceTime: .zero)
        // Hold the session open so a 20 ms sampler (and the probe script's ioreg loop) can't miss an encoder that opens
        // AVE only for a moment.
        Thread.sleep(forTimeInterval: 0.5)

        let frames = Int(seconds * Double(fps))
        var frame = 0
        while frame < frames {
            guard writer.status == .writing else { break }
            guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else {
                Thread.sleep(forTimeInterval: 0.002)
                continue
            }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { throw ConversionError.engine("pixel buffer") }
            if tenBit { fill10(pb, frame: frame) } else if fastFill { fillBGRAFast(pb, frame: frame) } else { fillBGRA(pb, frame: frame) }
            guard adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))) else { break }
            frame += 1
        }
        Thread.sleep(forTimeInterval: 0.5)
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? ConversionError.engine("finishWriting") }
        return url
    }

    /// For long clips: one noisy row per frame, copied down the picture with a shift per row, so every frame still
    /// moves and carries noise for the encoder but costs one memcpy per row instead of per-pixel maths.
    private static func fillBGRAFast(_ pb: CVPixelBuffer, frame: Int) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), stride = CVPixelBufferGetBytesPerRow(pb)
        let rowBytes = w * 4
        var line = [UInt8](repeating: 255, count: rowBytes * 2)
        var seed = UInt32(truncatingIfNeeded: frame &* 2_654_435_761 &+ 1)
        for x in 0..<(w * 2) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let n = UInt8(truncatingIfNeeded: seed >> 26)
            line[x * 4 + 0] = UInt8(truncatingIfNeeded: x + frame * 3) &+ n
            line[x * 4 + 1] = UInt8(truncatingIfNeeded: x / 3 + frame) &+ n
            line[x * 4 + 2] = UInt8(truncatingIfNeeded: x / 2 + frame * 5)
        }
        line.withUnsafeBytes { src in
            for y in 0..<h {
                let shift = ((y * 7 + frame * 4) % w) * 4
                base.advanced(by: y * stride).copyMemory(from: src.baseAddress!.advanced(by: shift), byteCount: rowBytes)
            }
        }
    }

    /// A moving gradient plus cheap per-pixel noise, so the encoder has real work.
    private static func fillBGRA(_ pb: CVPixelBuffer, frame: Int) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), stride = CVPixelBufferGetBytesPerRow(pb)
        var seed = UInt32(truncatingIfNeeded: frame &* 2_654_435_761 &+ 1)
        for y in 0..<h {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let n = UInt8(truncatingIfNeeded: seed >> 27)
                row[x * 4 + 0] = UInt8(truncatingIfNeeded: x + frame * 3) &+ n
                row[x * 4 + 1] = UInt8(truncatingIfNeeded: y * 2 + frame) &+ n
                row[x * 4 + 2] = UInt8(truncatingIfNeeded: (x + y) / 2 + frame * 5)
                row[x * 4 + 3] = 255
            }
        }
    }

    /// 10-bit 4:2:0 biplanar video range: a moving luma ramp with neutral chroma.
    private static func fill10(_ pb: CVPixelBuffer, frame: Int) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(pb) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane) else { continue }
            let w = CVPixelBufferGetWidthOfPlane(pb, plane), h = CVPixelBufferGetHeightOfPlane(pb, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
            for y in 0..<h {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)
                if plane == 0 {
                    for x in 0..<w { row[x] = UInt16(64 + (x * 4 + y + frame * 7) % 876) << 6 }
                } else {
                    for x in 0..<(w * 2) { row[x] = 512 << 6 }
                }
            }
        }
    }
}
