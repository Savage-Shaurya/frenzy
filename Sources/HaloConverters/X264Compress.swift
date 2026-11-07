import AVFoundation
import Foundation
import HaloCore

/// Every video Frenzy makes goes through x264 (H.264) or x265 (HEVC, including 10-bit HDR) inside the sandboxed media
/// engine (`MediaEngine`). CPU only: nothing here can reach the hardware video encoder that kernel-panicked the
/// founder's Mac (dart-ave0, 7 Nov 2026).
///
/// Why: on a real 1080p clip at the same file size and speed, x264 (slow, two passes) scored VMAF 94.0 against 77.8 for
/// Apple's software H.264, and its worst frames stayed above 80 where Apple's fell to 25. In constant-quality mode
/// (CRF 20, no cap) it scored 97, worst frame 92. Apple's software HEVC was far too slow (a 5 minute clip did not finish
/// in 24 minutes). Measured 7 Nov 2026, see docs/VIDEO-SOFTWARE-PATH.md.
///
/// Compress and Smaller keep Frenzy's own analysis (`AVTranscoder.prepare`: size, frame rate, HDR, what "already small"
/// means); only the encoding happens here. The MP4 and HEVC buttons use `formatSettings`.
enum X264Compress {
    enum Codec: Equatable { case h264, hevc }

    /// Constant quality: the look stays the same, the size follows the picture. No bitrate cap: a cap starved hard
    /// scenes (worst frame VMAF 54 on a real clip). When Compress isn't clearly smaller, the original stays.
    static let compressCRF = 20
    static let smallerCRF = 22
    /// x265's scale runs about 2 points above x264's for the same look.
    static let hevcCompressCRF = 22
    static let hevcSmallerCRF = 24
    /// The MP4 and HEVC buttons change the format, not the size: quality first.
    static let mp4CRF = 18
    static let hevcCRF = 20
    static let preset = "slow"
    static let hevcPreset = "medium"
    /// Sound kept exactly as it is. Only what macOS itself sees inside an MP4: MP3 in MP4, for one, is invisible to
    /// QuickTime (a real clip came out silent on the Mac), so everything else becomes AAC.
    static let mp4SafeAudio: Set<String> = ["aac", "alac"]

    struct Settings: Equatable {
        var crf: Int
        var width: Int
        var height: Int
        var scale: Bool
        /// The source has no complete colour tags: label the result BT.709 (the tags only, the pixels are not changed).
        var tagBT709: Bool
        var economyAudio: Bool
        var codec: Codec = .h264
        /// HEVC Main10 (HDR, or 10-bit SDR kept 10-bit). The source's colour tags pass through.
        var tenBit: Bool = false
        /// PQ (HDR10): x265 writes the HDR10 headers and repeats them, so players see HDR from any point.
        var pq: Bool = false
    }

    static func canHandle(_ prepared: AVTranscoder.Prepared) -> Bool { MediaEngine.isAvailable }

    /// Compress and Smaller. HDR stays HDR through x265 Main10; everything else is x264.
    static func settings(_ p: AVTranscoder.Prepared) -> Settings {
        let squeeze = p.plan.alwaysSqueezes, hdr = p.color.isHDR
        return Settings(crf: hdr ? (squeeze ? hevcSmallerCRF : hevcCompressCRF) : (squeeze ? smallerCRF : compressCRF),
                        width: p.width, height: p.height, scale: p.needsScaling,
                        tagBT709: !hdr && !p.color.hasCompleteSDRTags, economyAudio: squeeze,
                        codec: hdr ? .hevc : .h264, tenBit: hdr, pq: hdr && p.color.transfer == AVColorInfo.pq)
    }

    /// The MP4 (H.264, 8-bit SDR) and HEVC (keeps HDR and 10-bit) buttons: same size, quality first.
    static func formatSettings(_ color: AVColorInfo, codec: Codec) -> Settings {
        let ten = codec == .hevc && (color.isHDR || color.wantsTenBit)
        return Settings(crf: codec == .hevc ? hevcCRF : mp4CRF, width: 0, height: 0, scale: false,
                        tagBT709: !color.isHDR && !color.hasCompleteSDRTags, economyAudio: false,
                        codec: codec, tenBit: ten, pq: ten && color.transfer == AVColorInfo.pq)
    }

    /// Everything after the input. A fixed list built from numbers only: nothing from the file or its name goes in.
    /// `soundFrom`: the input the sound and tags come from (1 when the picture arrives through a pipe as input 0).
    static func arguments(_ s: Settings, audio: [MediaProbe.Audio], soundFrom: Int = 0) -> [String] {
        var args = ["-map", "0:V:0", "-map", "\(soundFrom):a?", "-sn", "-dn", "-map_chapters", "-1",
                    // The file's own tags (date, camera model, title), never where it was shot, nor FFmpeg's container
                    // notes. `QuickTimeTags.relocate` then puts them where macOS reads them.
                    "-map_metadata", "\(soundFrom)", "-metadata", "location=", "-metadata", "location-eng=",
                    "-metadata", "com.apple.quicktime.location.ISO6709=", "-metadata", "major_brand=",
                    "-metadata", "minor_version=", "-metadata", "compatible_brands=",
                    // Every frame keeps its own timestamp (variable frame rate phones stay in sync).
                    "-fps_mode", "passthrough"]
        // FFmpeg takes colour labels from the frames: setparams labels untagged SDR as BT.709 (tags only, no pixel change).
        var filters: [String] = []
        // 4:2:0 needs even sizes: an odd source (1081 rows) is trimmed by one line instead of failing.
        filters.append(s.scale ? "scale=\(s.width):\(s.height):flags=lanczos" : "scale=trunc(iw/2)*2:trunc(ih/2)*2")
        if s.tagBT709 { filters.append("setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709") }
        if !filters.isEmpty { args += ["-vf", filters.joined(separator: ",")] }
        switch s.codec {
        case .h264:
            args += ["-c:v", "libx264", "-preset", preset, "-crf", String(s.crf),
                     "-profile:v", "high", "-pix_fmt", "yuv420p", "-tag:v", "avc1"]
        case .hevc:
            // hvc1: the tag QuickTime and iPhones need to play HEVC from an MP4.
            args += ["-c:v", "libx265", "-preset", hevcPreset, "-crf", String(s.crf),
                     "-pix_fmt", s.tenBit ? "yuv420p10le" : "yuv420p", "-profile:v", s.tenBit ? "main10" : "main",
                     "-tag:v", "hvc1", "-x265-params", s.pq ? "log-level=error:repeat-headers=1:hdr10-opt=1:hdr10=1"
                                                            : "log-level=error:repeat-headers=1"]
        }
        if s.tagBT709 { args += ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"] }

        let copyAll = !s.economyAudio && audio.allSatisfy { mp4SafeAudio.contains($0.codec) }
        if copyAll {
            if !audio.isEmpty { args += ["-c:a", "copy"] }
        } else {
            for (i, track) in audio.enumerated() {
                if !s.economyAudio, mp4SafeAudio.contains(track.codec) { args += ["-c:a:\(i)", "copy"]; continue }
                args += ["-c:a:\(i)", "aac_at"]
                switch track.channels {
                case 0...2: args += ["-b:a:\(i)", s.economyAudio ? "128k" : "192k"]
                case 6: args += ["-b:a:\(i)", s.economyAudio ? "256k" : "384k"]
                default: args += ["-ac:a:\(i)", "2", "-b:a:\(i)", s.economyAudio ? "128k" : "192k"]
                }
            }
        }
        // use_metadata_tags: Apple's own keys. negative_cts_offsets: B-frame delay goes into the frame offsets instead of
        // an edit list Apple's readers skipped (every frame came out 50 ms late on a variable-frame-rate clip). No fast
        // start: the movie box stays last, so moving the tags never shifts the media data.
        // write_colr: the colour box macOS reads (primaries, transfer, matrix); without it HDR and BT.709 labels go missing.
        return args + ["-movflags", "+use_metadata_tags+negative_cts_offsets+write_colr", "-f", "mp4"]
    }

    /// Encodes `input` to `output` with `settings`. The engine keeps the coded picture and its rotation tag
    /// (`-noautorotate`), the same as the AVFoundation path. Returns the probe, for the sound track count.
    static func encode(input: URL, output: URL, settings: Settings, fallbackSeconds: Double,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> MediaProbe {
        let probe = try await MediaEngine.probe(input)
        try await MediaEngine.convert(input: input, output: output, inputOptions: probe.demuxerOptions + ["-noautorotate"],
                                      outputArguments: arguments(settings, audio: probe.audio),
                                      expectedSeconds: probe.seconds > 0 ? probe.seconds : fallbackSeconds,
                                      checkLength: true, progress: progress)
        try QuickTimeTags.relocate(output)
        return probe
    }

    /// Compress and Smaller.
    static func run(_ prepared: AVTranscoder.Prepared, input: URL, output: URL,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> MediaProbe {
        try await encode(input: input, output: output, settings: settings(prepared), fallbackSeconds: prepared.media.seconds,
                         progress: progress)
    }
}
