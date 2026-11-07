import AVFoundation
import CoreMedia
import Foundation
import HaloCore
@testable import HaloConverters
import ImageIO
import Testing
import UniformTypeIdentifiers
import VideoToolbox

/// HDR / colour handling. Fixtures are real 10-bit BT.2020 files written with AVAssetWriter (HEVC Main10 or ProRes 422,
/// tagged HLG or PQ), so these run the whole decode -> encode path, not just the tagging logic.
@Suite("Video HDR", .enabled(if: HardwareVideoTests.allowed), .serialized)
struct VideoHDRTests {
    private let p2020 = AVVideoColorPrimaries_ITU_R_2020
    private let m2020 = AVVideoYCbCrMatrix_ITU_R_2020
    private let hlg = AVVideoTransferFunction_ITU_R_2100_HLG
    private let pq = AVVideoTransferFunction_SMPTE_ST_2084_PQ
    private let r709 = AVVideoColorPrimaries_ITU_R_709_2

    private func convert(_ id: ActionID, _ spec: AVFixtures.MovieSpec) async throws -> (URL, ConversionOutcome) {
        let dir = try AVFixtures.tempDir()
        let original = try AVFixtures.copy(try await AVFixtures.movie(spec), into: dir)
        let before = try AVFixtures.sha(original)
        let outcome = await AVFixtures.run(id, on: original)
        #expect(try AVFixtures.sha(original) == before, "original modified")
        #expect(AVFixtures.leftovers(in: dir).isEmpty, "temp files left behind")
        return (original, outcome)
    }

    private func expectTags(_ c: AVColorInfo, _ primaries: String, _ transfer: String, _ matrix: String,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(c.primaries == primaries, "primaries \(String(describing: c.primaries))", sourceLocation: sourceLocation)
        #expect(c.transfer == transfer, "transfer \(String(describing: c.transfer))", sourceLocation: sourceLocation)
        #expect(c.matrix == matrix, "matrix \(String(describing: c.matrix))", sourceLocation: sourceLocation)
    }

    // MARK: Fixtures are what they claim

    @Test(arguments: [AVFixtures.HDR.hlg, .pq])
    func fixturesAreTenBitHDR(_ kind: AVFixtures.HDR) async throws {
        let c = try await AVFixtures.color(of: try await AVFixtures.movie(.hdr(kind)))
        #expect(c.isHDR && c.bitsPerComponent == 10 && c.codec == kCMVideoCodecType_HEVC)
        expectTags(c, p2020, kind == .hlg ? hlg : pq, m2020)
        #expect((c.masteringDisplay != nil) == (kind == .pq))
    }

    // MARK: Compress keeps HDR

    @Test func compressKeepsHLG() async throws {
        var spec = AVFixtures.MovieSpec.hdr(.hlg, audio: true)
        spec.bitRate = 20_000_000
        let (original, outcome) = try await convert("video.compress", spec)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let out = try #require(outcome.outputs.first)
        let c = try await AVFixtures.color(of: out)
        #expect(c.codec == kCMVideoCodecType_HEVC && c.bitsPerComponent == 10 && c.isHDR)
        expectTags(c, p2020, hlg, m2020)
        #expect(AVSupport.fileSize(out) < AVSupport.fileSize(original))
        #expect(try await AVFixtures.decodedFrameCount(out) == 45)
        #expect(!(try await AVURLAsset(url: out).loadTracks(withMediaType: .audio)).isEmpty)
    }

    @Test func compressKeepsPQAndHDR10Metadata() async throws {
        var spec = AVFixtures.MovieSpec.hdr(.pq)
        spec.bitRate = 20_000_000
        let (_, outcome) = try await convert("video.compress", spec)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let out = try #require(outcome.outputs.first)
        let c = try await AVFixtures.color(of: out)
        #expect(c.bitsPerComponent == 10)
        expectTags(c, p2020, pq, m2020)
        #expect(c.masteringDisplay == AVFixtures.mdcv)
        #expect(c.contentLightLevel == AVFixtures.cll)
        #expect(try await AVFixtures.decodedFrameCount(out) == 45)
    }

    // MARK: HEVC keeps HDR

    @Test(arguments: [AVFixtures.HDR.hlg, .pq])
    func proResHDRToHEVCStaysHDR(_ kind: AVFixtures.HDR) async throws {
        let (_, outcome) = try await convert("video.to-hevc", .hdr(kind, codec: .proRes422, seconds: 1))
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let out = try #require(outcome.outputs.first)
        let c = try await AVFixtures.color(of: out)
        #expect(c.codec == kCMVideoCodecType_HEVC && c.bitsPerComponent == 10)
        expectTags(c, p2020, kind == .hlg ? hlg : pq, m2020)
        #expect(try await AVFixtures.decodedFrameCount(out) == 30)
    }

    // MARK: 8-bit outputs are tone-mapped SDR BT.709

    @Test(arguments: [AVVideoCodecType.hevc, .proRes422])
    func hdrToMP4IsTaggedSDR709(_ codec: AVVideoCodecType) async throws {
        let (_, outcome) = try await convert("video.to-mp4", .hdr(.hlg, codec: codec, seconds: 1))
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let out = try #require(outcome.outputs.first)
        let c = try await AVFixtures.color(of: out)
        #expect(c.codec == kCMVideoCodecType_H264 && !c.isHDR && c.bitsPerComponent == 8)
        expectTags(c, r709, AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrix_ITU_R_709_2)
        #expect(try await AVFixtures.decodedFrameCount(out) == 30)
    }

    @Test func hdrToGIF() async throws {
        let (_, outcome) = try await convert("video.to-gif", .hdr(.pq, seconds: 1))
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let out = try #require(outcome.outputs.first)
        let source = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 12)
        let frame = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(frame.width == 480 && frame.height == 270)
        // The fixture is a dark-to-mid luma ramp: tone-mapped SDR must not be blown out to white or crushed to black.
        let mean = try meanLuma(frame)
        #expect(mean > 0.03 && mean < 0.97, "mean luma \(mean)")
    }

    // MARK: SDR outputs always carry explicit tags

    @Test(arguments: ["video.compress", "video.to-hevc", "video.to-mp4"] as [ActionID])
    func sdrOutputsAreTagged(_ id: ActionID) async throws {
        var spec = AVFixtures.MovieSpec()
        spec.seconds = 1; spec.audio = false
        if id == "video.to-mp4" { spec.codec = .hevc } // force a re-encode, not a passthrough
        let (_, outcome) = try await convert(id, spec)
        #expect(outcome.failures.isEmpty, "\(outcome.failures.map(\.message))")
        let c = try await AVFixtures.color(of: try #require(outcome.outputs.first))
        #expect(!c.isHDR && c.bitsPerComponent == 8)
        #expect(c.primaries != nil && c.transfer == AVVideoTransferFunction_ITU_R_709_2 && c.matrix != nil,
                "\(String(describing: c.primaries)) \(String(describing: c.transfer)) \(String(describing: c.matrix))")
    }

    // MARK: Tagging logic in isolation

    private func info(codec: FourCharCode = kCMVideoCodecType_HEVC, _ ext: [CFString: Any]) throws -> AVColorInfo {
        var fd: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: nil, codecType: codec, width: 1920, height: 1080,
                                                    extensions: ext as CFDictionary, formatDescriptionOut: &fd)
        #expect(status == noErr)
        return AVColorInfo(try #require(fd))
    }

    @Test func detectsHLGAndPQ() throws {
        let h = try info([kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
                          kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG,
                          kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
                          kCMFormatDescriptionExtension_BitsPerComponent: 10])
        #expect(h.isHDR && h.wantsTenBit)
        #expect(h.preservedProperties == [AVVideoColorPrimariesKey: p2020, AVVideoTransferFunctionKey: hlg, AVVideoYCbCrMatrixKey: m2020])
        #expect(h.hdrMetadataCompressionProperties.isEmpty)

        let p = try info([kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
                          kCMFormatDescriptionExtension_MasteringDisplayColorVolume: AVFixtures.mdcv,
                          kCMFormatDescriptionExtension_ContentLightLevelInfo: AVFixtures.cll])
        #expect(p.isHDR)
        // Missing primaries/matrix on an HDR source default to BT.2020.
        #expect(p.preservedProperties == [AVVideoColorPrimariesKey: p2020, AVVideoTransferFunctionKey: pq, AVVideoYCbCrMatrixKey: m2020])
        #expect(p.hdrMetadataCompressionProperties[kVTCompressionPropertyKey_MasteringDisplayColorVolume as String] as? Data == AVFixtures.mdcv)
        #expect(p.hdrMetadataCompressionProperties[kVTCompressionPropertyKey_ContentLightLevelInfo as String] as? Data == AVFixtures.cll)
    }

    @Test func dolbyVisionCountsAsHDR() throws {
        let dv = try info(codec: kCMVideoCodecType_DolbyVisionHEVC, [:])
        #expect(dv.isHDR && dv.isDolbyVision && dv.bitsPerComponent >= 10)
        #expect(dv.preservedProperties[AVVideoTransferFunctionKey] == hlg)
    }

    @Test func sdrTags() throws {
        // Untagged 8-bit H.264: not HDR, converted to and tagged BT.709.
        let plain = try info(codec: kCMVideoCodecType_H264, [:])
        #expect(!plain.isHDR && !plain.wantsTenBit && !plain.hasCompleteSDRTags)
        #expect(plain.sdrProperties == AVColorInfo.bt709)
        #expect(plain.preservedProperties == AVColorInfo.bt709)
        // Complete SD tags are kept as they are (no pixel conversion needed).
        let sd = try info(codec: kCMVideoCodecType_H264, [
            kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_SMPTE_C,
            kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4])
        #expect(sd.hasCompleteSDRTags)
        #expect(sd.sdrProperties[AVVideoColorPrimariesKey] == AVVideoColorPrimaries_SMPTE_C)
        #expect(sd.sdrProperties[AVVideoYCbCrMatrixKey] == AVVideoYCbCrMatrix_ITU_R_601_4)
        // ProRes is 10-bit even without a BitsPerComponent extension.
        #expect(try info(codec: kCMVideoCodecType_AppleProRes422, [:]).wantsTenBit)
    }

    // (The two "transcoder settings" checks are gone: asking Apple's writer whether HDR settings work starts the
    // hardware encoder, measured 7 Nov 2026. That Apple encoder path is unreachable now; video goes to x264 / x265.)

    private func meanLuma(_ image: CGImage) throws -> Double {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h)
        let ctx = try #require(CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Double(pixels.reduce(0) { $0 + Int($1) }) / Double(w * h) / 255
    }
}
