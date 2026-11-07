import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// Colour facts about a video track and the colour tags Halo writes on outputs.
///
/// Rules:
/// - HDR (HLG, PQ/HDR10, Dolby Vision) is preserved only by HEVC outputs (`video.compress`, `video.to-hevc`): 10-bit
///   decode, HEVC Main10, the source's primaries/transfer/matrix, plus mastering-display and content-light metadata
///   when the source has them.
/// - 8-bit outputs (H.264 MP4, GIF) are tone-mapped to SDR BT.709 and tagged BT.709.
/// - Every re-encoded output carries explicit colour tags; untagged sources are converted to BT.709 on decode.
struct AVColorInfo: Sendable, Equatable {
    var codec: FourCharCode
    var primaries: String?
    var transfer: String?
    var matrix: String?
    /// Bits per component the source was encoded with (8 when unknown).
    var bitsPerComponent: Int
    /// SMPTE ST 2086 mastering display colour volume (HDR10), as stored in the format description.
    var masteringDisplay: Data?
    /// CTA-861.3 MaxCLL/MaxFALL, as stored in the format description.
    var contentLightLevel: Data?
    /// The viewing conditions HDR was graded for (iPhone HLG carries this), as stored in the format description.
    var ambientViewing: Data?
    /// The picture has an alpha channel (ProRes 4444, HEVC with alpha).
    var hasAlpha = false

    static let hlg = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
    static let pq = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String

    static let dolbyVisionCodecs: Set<FourCharCode> = [kCMVideoCodecType_DolbyVisionHEVC, FourCharCode(0x6476_6865) /* dvhe */]
    private static let proRes10Bit: Set<FourCharCode> = [
        kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422LT,
        kCMVideoCodecType_AppleProRes422Proxy, kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ,
    ]

    init(codec: FourCharCode, primaries: String? = nil, transfer: String? = nil, matrix: String? = nil,
         bitsPerComponent: Int = 8, masteringDisplay: Data? = nil, contentLightLevel: Data? = nil,
         ambientViewing: Data? = nil, hasAlpha: Bool = false) {
        self.codec = codec
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
        self.bitsPerComponent = bitsPerComponent
        self.masteringDisplay = masteringDisplay
        self.contentLightLevel = contentLightLevel
        self.ambientViewing = ambientViewing
        self.hasAlpha = hasAlpha
    }

    init(_ description: CMFormatDescription) {
        let ext = (CMFormatDescriptionGetExtensions(description) as? [String: Any]) ?? [:]
        func string(_ key: CFString) -> String? { ext[key as String] as? String }
        codec = CMFormatDescriptionGetMediaSubType(description)
        primaries = string(kCMFormatDescriptionExtension_ColorPrimaries)
        transfer = string(kCMFormatDescriptionExtension_TransferFunction)
        matrix = string(kCMFormatDescriptionExtension_YCbCrMatrix)
        masteringDisplay = ext[kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String] as? Data
        contentLightLevel = ext[kCMFormatDescriptionExtension_ContentLightLevelInfo as String] as? Data
        ambientViewing = ext[kCMFormatDescriptionExtension_AmbientViewingEnvironment as String] as? Data
        // QuickTime's "Depth" of 32 means colour plus alpha.
        hasAlpha = (ext[kCMFormatDescriptionExtension_Depth as String] as? NSNumber)?.intValue == 32
        var bits = (ext[kCMFormatDescriptionExtension_BitsPerComponent as String] as? NSNumber)?.intValue ?? 8
        if Self.proRes10Bit.contains(codec) || Self.dolbyVisionCodecs.contains(codec) { bits = max(bits, 10) }
        bitsPerComponent = bits
    }

    /// Reads the first format description of `track`. Unknown/odd tracks come back as plain 8-bit SDR.
    static func of(_ track: AVAssetTrack) async -> AVColorInfo {
        let descriptions = (try? await track.load(.formatDescriptions)) ?? []
        var info = descriptions.first.map { AVColorInfo($0) } ?? AVColorInfo(codec: 0)
        // AVFoundation's own verdict covers HDR signalled in ways the extensions above don't show.
        let characteristics = (try? await track.load(.mediaCharacteristics)) ?? []
        if !info.isHDR, characteristics.contains(.containsHDRVideo) {
            info.transfer = info.transfer ?? hlg
            info.bitsPerComponent = max(info.bitsPerComponent, 10)
        }
        if characteristics.contains(.containsAlphaChannel) { info.hasAlpha = true }
        return info
    }

    var isDolbyVision: Bool { Self.dolbyVisionCodecs.contains(codec) }
    var isHDR: Bool { transfer == Self.hlg || transfer == Self.pq || isDolbyVision }
    /// HDR or more than 8 bits: worth a 10-bit (HEVC Main10) pipeline when the output is HEVC.
    var wantsTenBit: Bool { isHDR || bitsPerComponent > 8 }

    // MARK: - Output tags

    /// The tags for an output that keeps the source's colour (HDR or 10-bit SDR into HEVC Main10).
    var preservedProperties: [String: String] {
        guard isHDR else { return sdrProperties }
        return [
            AVVideoColorPrimariesKey: primaries.flatMap(Self.writablePrimaries) ?? AVVideoColorPrimaries_ITU_R_2020,
            // Dolby Vision without an explicit transfer: iPhone's profile 8.4 base layer is HLG.
            AVVideoTransferFunctionKey: transfer == Self.pq ? AVVideoTransferFunction_SMPTE_ST_2084_PQ : AVVideoTransferFunction_ITU_R_2100_HLG,
            AVVideoYCbCrMatrixKey: matrix.flatMap(Self.writableMatrix) ?? AVVideoYCbCrMatrix_ITU_R_2020,
        ]
    }

    /// True when the source already carries a complete, SDR-valid set of tags we can copy without converting pixels.
    var hasCompleteSDRTags: Bool {
        guard !isHDR, let p = primaries, let t = transfer, let m = matrix else { return false }
        return Self.sdrPrimaries.contains(p) && t == AVVideoTransferFunction_ITU_R_709_2 && Self.sdrMatrices.contains(m)
    }

    /// Tags for an SDR output: the source's own SDR tags when complete, otherwise BT.709 (decode then converts to it).
    var sdrProperties: [String: String] {
        guard hasCompleteSDRTags, let p = primaries, let t = transfer, let m = matrix else { return Self.bt709 }
        return [AVVideoColorPrimariesKey: p, AVVideoTransferFunctionKey: t, AVVideoYCbCrMatrixKey: m]
    }

    /// HEVC compression properties that carry HDR10 static metadata through to the output, when present.
    var hdrMetadataCompressionProperties: [String: Any] {
        guard isHDR else { return [:] }
        var props: [String: Any] = [:]
        if let masteringDisplay { props[kVTCompressionPropertyKey_MasteringDisplayColorVolume as String] = masteringDisplay }
        if let contentLightLevel { props[kVTCompressionPropertyKey_ContentLightLevelInfo as String] = contentLightLevel }
        // VideoToolbox lists this key at run time but the SDK has no constant for it.
        if let ambientViewing { props["AmbientViewingEnvironment"] = ambientViewing }
        return props
    }

    static let bt709: [String: String] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]

    private static let sdrPrimaries: Set<String> = [
        AVVideoColorPrimaries_ITU_R_709_2, AVVideoColorPrimaries_P3_D65, AVVideoColorPrimaries_SMPTE_C, AVVideoColorPrimaries_EBU_3213,
    ]
    private static let sdrMatrices: Set<String> = [AVVideoYCbCrMatrix_ITU_R_709_2, AVVideoYCbCrMatrix_ITU_R_601_4]

    private static func writablePrimaries(_ p: String) -> String? {
        [AVVideoColorPrimaries_ITU_R_2020, AVVideoColorPrimaries_P3_D65, AVVideoColorPrimaries_ITU_R_709_2].contains(p) ? p : nil
    }

    private static func writableMatrix(_ m: String) -> String? {
        [AVVideoYCbCrMatrix_ITU_R_2020, AVVideoYCbCrMatrix_ITU_R_709_2].contains(m) ? m : nil
    }

    // MARK: - Compositions

    /// A video composition that renders `asset` as SDR BT.709. AVFoundation tone-maps HDR frames when the composition's
    /// colour properties are SDR, so this is the HDR -> SDR path for H.264 and GIF outputs. Frame timing follows the
    /// source track (variable frame rate stays variable).
    static func sdrComposition(for asset: AVAsset, track: AVAssetTrack, properties: [String: String] = bt709) async throws -> AVVideoComposition {
        let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        composition.colorPrimaries = properties[AVVideoColorPrimariesKey]
        composition.colorTransferFunction = properties[AVVideoTransferFunctionKey]
        composition.colorYCbCrMatrix = properties[AVVideoYCbCrMatrixKey]
        composition.sourceTrackIDForFrameTiming = track.trackID
        return composition
    }
}
