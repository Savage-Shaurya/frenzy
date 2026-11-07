import AVFoundation
import CoreMedia
import Foundation
import HaloCore
import IOKit
import VideoToolbox

/// Approach B of the safe video plan: encode H.264 and HEVC with Apple's **software** encoders, so the Apple Video
/// Encoder (AVE, `ave0` behind `dart-ave0`) is never opened. Driving AVE kernel-panicked the founder's Mac three times
/// on 7 Nov 2026. See `docs/VIDEO-SOFTWARE-PATH.md`.
///
/// What this file is: a settings builder and a validator. It never creates an encoder, never touches VideoToolbox at
/// run time (only its key constants) and never reads a movie. `AVTranscoder` can call `forcingSoftware(_:)` on the
/// writer settings it already builds, or build them here with `writerSettings(_:)`.
///
/// How the encoder is pinned (all three, in `AVVideoEncoderSpecificationKey`, which AVFoundation documents for
/// `AVAssetWriterInput` on macOS only):
/// - `kVTVideoEncoderSpecification_EncoderID` = the software encoder's own ID, read from its plug-in on macOS 27.0.1:
///   `com.apple.videotoolbox.videoencoder.h264` ("Apple H.264 (SW)", `AppleH264SW.bundle`) and
///   `com.apple.videotoolbox.videoencoder.hevc.vcp` ("Apple HEVC (SW)", `VCPHEVC.bundle`).
/// - `kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder` = false ("hardware encode will never be used").
/// - `kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder` = false.
///
/// Not proof on its own: run `scripts/video-safety-probe.sh` around the first real encode.
enum SoftwareVideoEncoding {
    enum Codec: String, Sendable, CaseIterable {
        case h264, hevc

        var avCodec: AVVideoCodecType { self == .h264 ? .h264 : .hevc }

        /// The VideoToolbox codec type the plug-ins register under.
        var fourCC: String { self == .h264 ? "avc1" : "hvc1" }

        /// Apple's software encoder for this codec. These two plug-ins link no IOKit (checked with `otool -L` and
        /// `nm -u` on macOS 27.0.1), so they have no way to open the AVE driver themselves.
        var softwareEncoderID: String {
            switch self {
            case .h264: "com.apple.videotoolbox.videoencoder.h264"
            case .hevc: "com.apple.videotoolbox.videoencoder.hevc.vcp"
            }
        }

        init?(_ codec: AVVideoCodecType) {
            switch codec {
            case .h264: self = .h264
            case .hevc: self = .hevc
            default: return nil
            }
        }
    }

    /// Every hardware H.264 / HEVC encoder ID found on macOS 27.0.1 (`/System/Library/Video/Plug-Ins`):
    /// AVE (Apple silicon) and GVA (Intel). A test checks the installed plug-ins against this list, so a new
    /// hardware ID in a later macOS fails a test instead of slipping through.
    static let hardwareEncoderIDs: Set<String> = [
        "com.apple.videotoolbox.videoencoder.ave.avc",
        "com.apple.videotoolbox.videoencoder.ave.hevc",
        "com.apple.videotoolbox.videoencoder.hevc.ave",
        "com.apple.videotoolbox.videoencoder.hevc.gva",
    ]

    /// The encoder specification that keeps `codec` in software.
    static func encoderSpecification(_ codec: Codec) -> [String: Any] {
        [
            kVTVideoEncoderSpecification_EncoderID as String: codec.softwareEncoderID,
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: false,
        ]
    }

    // MARK: - Settings

    struct Request {
        var codec: Codec
        var width: Int
        var height: Int
        var bitRate: Double
        var fps: Double
        var keyFrameIntervalSeconds = 2
        /// `AVVideoColorPropertiesKey` value; nil leaves colour untagged (test frames only).
        var colorProperties: [String: String]?
        /// HEVC Main10. Unproven on the software HEVC encoder: the first HDR test must confirm `canApply` and the output.
        var tenBit = false
        /// Extra `AVVideoCompressionPropertiesKey` entries (HDR metadata and so on). Win over the defaults.
        var extraCompression: [String: Any] = [:]
        /// Adds `AVVideoScalingModeResizeAspect` (the transcoder's frames may arrive at another size).
        var scales = false
    }

    /// Complete `AVAssetWriterInput` output settings for a software encode.
    static func writerSettings(_ request: Request) -> [String: Any] {
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(request.bitRate),
            AVVideoExpectedSourceFrameRateKey: Int(request.fps.rounded()),
            AVVideoMaxKeyFrameIntervalDurationKey: request.keyFrameIntervalSeconds,
        ]
        switch request.codec {
        case .h264: compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        case .hevc:
            compression[AVVideoProfileLevelKey] = request.tenBit
                ? kVTProfileLevel_HEVC_Main10_AutoLevel as String : kVTProfileLevel_HEVC_Main_AutoLevel as String
        }
        compression.merge(request.extraCompression) { $1 }
        var settings: [String: Any] = [
            AVVideoCodecKey: request.codec.avCodec,
            AVVideoWidthKey: request.width,
            AVVideoHeightKey: request.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoEncoderSpecificationKey: encoderSpecification(request.codec),
        ]
        if request.scales { settings[AVVideoScalingModeKey] = AVVideoScalingModeResizeAspect }
        if let color = request.colorProperties { settings[AVVideoColorPropertiesKey] = color }
        return settings
    }

    /// Takes writer settings built elsewhere (for example `AVTranscoder.videoSetup`) and pins them to the software
    /// encoder. Throws for anything that isn't H.264 or HEVC: ProRes and JPEG have hardware encoders too, and this path
    /// has not checked their software twins.
    static func forcingSoftware(_ settings: [String: Any]) throws -> [String: Any] {
        guard let codec = codec(in: settings) else {
            throw ConversionError.engine("Software encoding covers H.264 and HEVC only.")
        }
        var out = settings
        out[AVVideoEncoderSpecificationKey] = encoderSpecification(codec)
        return out
    }

    // MARK: - Validation

    enum Violation: Error, Equatable, Sendable {
        case unsupportedCodec(String)
        case noEncoderSpecification
        case hardwareNotDisabled
        case hardwareRequired
        case encoderNotPinned
        case notTheSoftwareEncoder(String)
        case gpuEncoderRequested
    }

    /// Everything that would let VideoToolbox pick a hardware encoder. Empty means the settings ask for software only.
    static func violations(in settings: [String: Any]) -> [Violation] {
        guard let codec = codec(in: settings) else {
            let raw = (settings[AVVideoCodecKey] as? AVVideoCodecType)?.rawValue ?? (settings[AVVideoCodecKey] as? String) ?? "none"
            return [.unsupportedCodec(raw)]
        }
        guard let spec = settings[AVVideoEncoderSpecificationKey] as? [String: Any] else { return [.noEncoderSpecification] }
        var found: [Violation] = []
        if spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String] as? Bool != false {
            found.append(.hardwareNotDisabled)
        }
        if spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String] as? Bool == true {
            found.append(.hardwareRequired)
        }
        switch spec[kVTVideoEncoderSpecification_EncoderID as String] as? String {
        case nil: found.append(.encoderNotPinned)
        case let id? where id != codec.softwareEncoderID: found.append(.notTheSoftwareEncoder(id))
        default: break
        }
        if spec[kVTVideoEncoderSpecification_RequiredEncoderGPURegistryID as String] != nil
            || spec[kVTVideoEncoderSpecification_PreferredEncoderGPURegistryID as String] != nil {
            found.append(.gpuEncoderRequested)
        }
        return found
    }

    static func isSoftwareOnly(_ settings: [String: Any]) -> Bool { violations(in: settings).isEmpty }

    private static func codec(in settings: [String: Any]) -> Codec? {
        if let c = settings[AVVideoCodecKey] as? AVVideoCodecType { return Codec(c) }
        if let s = settings[AVVideoCodecKey] as? String { return Codec(AVVideoCodecType(rawValue: s)) }
        return nil
    }

    // MARK: - Bitrate

    /// Bits per pixel per frame for the software encoders. Apple's software encoders at their default speed are
    /// expected to need a little more than AVE's 0.05 for HEVC to look the same (ESTIMATE, to be checked on real
    /// footage); H.264 needs roughly 1.5x HEVC.
    static func bitsPerPixel(_ codec: Codec) -> Double { codec == .hevc ? 0.055 : 0.085 }

    /// Same rule as `AVTranscoder`: never more than `maxFractionOfSource` of the source's own rate, never under the floor.
    static func bitRate(codec: Codec, width: Int, height: Int, fps: Double, sourceDataRate: Double,
                        maxFractionOfSource: Double = 0.6, floor: Double = 150_000) -> Double {
        var rate = Double(width * height) * fps * bitsPerPixel(codec)
        if sourceDataRate > 0 { rate = min(rate, sourceDataRate * maxFractionOfSource) }
        return max(rate, floor)
    }

    // MARK: - What macOS ships (read from disk, no code loaded)

    struct InstalledEncoder: Sendable, Equatable {
        var id: String
        var name: String
        var codecTypes: [String]
        var isHardware: Bool
        var bundle: String
    }

    static let pluginsFolder = URL(fileURLWithPath: "/System/Library/Video/Plug-Ins", isDirectory: true)

    /// Video encoders registered by the plug-in bundles in `folder`, read from their `Info.plist` files only. This
    /// never calls VideoToolbox and never loads a plug-in, so it is safe on a Mac where opening AVE is not.
    static func installedEncoders(in folder: URL = pluginsFolder) -> [InstalledEncoder] {
        let bundles = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var found: [InstalledEncoder] = []
        for bundle in bundles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where bundle.pathExtension == "bundle" {
            let plistURL = [bundle.appendingPathComponent("Contents/Info.plist"), bundle.appendingPathComponent("Info.plist")]
                .first { FileManager.default.fileExists(atPath: $0.path) }
            guard let plistURL, let data = try? Data(contentsOf: plistURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let classes = plist["CMClassImplementations"] as? [[String: Any]] else { continue }
            for entry in classes where entry["CMClassID"] as? String == "com.apple.videotoolbox.videoencoder" {
                guard let id = entry["CMClassImplementationID"] as? String else { continue }
                let matching = entry["CMMatchingInfo"] as? [String: Any] ?? [:]
                let types: [String]
                if let one = matching["VTCodecType"] as? String { types = [one] } else { types = matching["VTCodecType"] as? [String] ?? [] }
                found.append(InstalledEncoder(
                    id: id,
                    name: entry["VTEncoderName"] as? String ?? entry["CMClassImplementationName"] as? String ?? id,
                    codecTypes: types,
                    isHardware: matching["VTIsHardwareAccelerated"] as? Bool ?? false,
                    bundle: bundle.lastPathComponent))
            }
        }
        return found
    }

    /// Whether this Mac ships Apple's software encoder for `codec` (by its plug-in, not by asking VideoToolbox).
    static func softwareEncoderInstalled(_ codec: Codec, in folder: URL = pluginsFolder) -> Bool {
        installedEncoders(in: folder).contains { $0.id == codec.softwareEncoderID && !$0.isHardware }
    }

    // MARK: - Speed

    /// ESTIMATED frames per second for a 1080p encode on a recent Apple silicon Mac (not measured: the first gated
    /// throughput test replaces these). Scales with pixel count. Used only to size time limits and progress copy.
    static func estimatedFramesPerSecond(_ codec: Codec, width: Int, height: Int) -> Double {
        let base1080p = codec == .h264 ? 120.0 : 30.0
        let pixels = Double(max(1, width * height))
        return base1080p * (1920.0 * 1080.0) / pixels
    }
}

// MARK: - Choosing the encoder (approach A's fallback)

extension SoftwareVideoEncoding {
    enum Route: Equatable, Sendable {
        case hardware
        case software(Reason)

        enum Reason: Equatable, Sendable {
            /// Another session (any process: Chrome, FaceTime, a second Frenzy job) already holds AVE. Two sessions at
            /// once is the trigger of the dart-ave panic (Apple FB23045975, forums thread 831532).
            case encoderBusy(Int)
            /// The count couldn't be read (sandbox, unexpected registry layout). Unknown is treated as busy.
            case encoderStateUnknown
            /// The caller asked for software (a setting, or a test).
            case forced
        }

        var isSoftware: Bool { if case .software = self { true } else { false } }
    }

    /// The one decision approach A makes right before it creates its single AVAssetWriter: hardware only when nothing
    /// else holds AVE and this codec has no software fallback reason; software otherwise. `aveUserClients` is
    /// `AVEStatus.userClientCount()`, passed in so tests can drive it.
    ///
    /// The check is a snapshot: another app can open AVE a moment later. It narrows the window, it doesn't close it.
    /// Only the software route closes it.
    static func route(aveUserClients: Int?, forceSoftware: Bool = false) -> Route {
        if forceSoftware { return .software(.forced) }
        guard let n = aveUserClients else { return .software(.encoderStateUnknown) }
        return n == 0 ? .hardware : .software(.encoderBusy(n))
    }

    /// Writer settings for `route`: unchanged for hardware, pinned to the software encoder otherwise. Approach A builds
    /// its settings as it does today and passes them through this.
    static func settings(_ settings: [String: Any], for route: Route) throws -> [String: Any] {
        route.isSoftware ? try forcingSoftware(settings) : settings
    }
}

/// Read-only view of the Apple Video Encoder's driver in the IORegistry. Never opens the driver.
enum AVEStatus {
    /// IOKit class names of AVE user clients. One exists per open hardware encode session on this Mac.
    static let userClientClasses = ["AppleAVE2UserClient", "AppleAVEUserClient"]

    /// Live AVE user clients across every process, from the registry root's `IOKitDiagnostics` class counts (what
    /// `ioreg -l -w0 -d2 | grep AppleAVE2UserClient` prints). nil when that can't be read; callers treat nil as busy.
    static func userClientCount() -> Int? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let diag = IORegistryEntryCreateCFProperty(root, "IOKitDiagnostics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
              let classes = diag["Classes"] as? [String: Any] else { return nil }
        var total = 0, seen = false
        for name in userClientClasses {
            if let n = (classes[name] as? NSNumber)?.intValue { total += n; seen = true }
        }
        // No AVE class registered at all (Intel Mac, or the driver hasn't loaded yet): nothing can hold it.
        return seen ? total : 0
    }
}
