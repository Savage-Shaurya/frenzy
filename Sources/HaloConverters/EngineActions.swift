import AVFoundation
import Foundation
import HaloCore
import UniformTypeIdentifiers

/// Conversions macOS can't do itself, run by the bundled media engine (`MediaEngine`): video in WebM, MKV, AVI, FLV, WMV
/// and friends, audio in OGG, Opus, WMA and friends, and MP3 and FLAC out. Formats macOS reads keep their Apple paths in
/// `VideoActions` and `AudioActions`; these actions only add what is missing.
///
/// The engine is CPU only: AAC goes through AudioToolbox, video through x264 and x265, never VideoToolbox (the hardware
/// encoder kernel-panicked the founder's Mac on 7 Nov 2026).
enum EngineActions {
    /// A type by its identifier and by what macOS says each extension is here. Both: a Mac with VLC or IINA installed can
    /// map `.mkv` to their own type, and Macs without either give a `dyn.` type, the same one every time.
    private static func types(_ identifiers: [String], extensions: [String]) -> [UTType] {
        var seen = Set<String>(), result: [UTType] = []
        for type in identifiers.compactMap({ UTType($0) }) + extensions.compactMap({ UTType(filenameExtension: $0) }) where seen.insert(type.identifier).inserted {
            result.append(type)
        }
        return result
    }

    /// Video containers AVFoundation can't open, or that `VideoActions` doesn't list.
    /// Not ASF itself: WMA audio conforms to it, so listing it would offer a GIF for a song. WMV has its own type.
    /// Not RealMedia: the engine has no demuxer for it.
    static let foreignVideo = types(
        ["org.webmproject.webm", "org.matroska.mkv", "public.avi", "com.adobe.flash.video", "com.microsoft.windows-media-wmv",
         "org.xiph.ogv", "public.mpeg", "public.mpeg-2-transport-stream", "public.avchd-mpeg-2-transport-stream"],
        extensions: ["webm", "mkv", "avi", "divx", "flv", "wmv", "ogv", "mpg", "mpeg", "ts", "mts", "m2ts", "vob"])

    /// Audio formats AVFoundation can't decode, or that `AudioActions` didn't list before the engine.
    static let foreignAudio = types(
        ["org.xiph.ogg-audio", "org.xiph.opus", "com.microsoft.windows-media-wma", "org.3gpp.adaptive-multi-rate-audio",
         "public.ac3-audio", "public.aac-audio"],
        extensions: ["ogg", "oga", "opus", "wma", "amr", "ac3", "ec3", "dts", "aac", "mka", "ape", "wv", "mp2"])

    static func isForeignAudio(_ input: InputFile) -> Bool { foreignAudio.contains { input.type.conforms(to: $0) } }

    /// What the engine offers. Registered by `DefaultActions` only when the engine is in the app (`MediaEngine.isAvailable`).
    static var all: [ConversionAction] {
        videoOut + [
            ConversionAction(
                id: "video.foreign-to-gif", title: "GIF", subtitle: "Looping", symbolName: "photo.stack",
                category: .video, inputTypes: foreignVideo, defaultRank: 30, converter: ClosureConverter(toGIF)),
            ConversionAction(
                id: "video.foreign-extract-audio", title: "Audio", subtitle: "M4A sound", symbolName: "waveform",
                category: .video, inputTypes: foreignVideo, defaultRank: 40, converter: ClosureConverter(extractM4A)),
            // Every video, not just these: MP3 is what people want from an MP4 as well, and macOS has no MP3 encoder.
            ConversionAction(
                id: "video.to-mp3", title: "MP3", subtitle: "Sound only", symbolName: "music.note",
                category: .video, inputTypes: AVSupport.videoInputs + foreignVideo, defaultRank: 45, converter: ClosureConverter(extractMP3)),
        ]
    }

    /// MP4 (x264) and HEVC (x265) out of foreign video: the safe video plan, CPU only. Part of `all`.
    static var videoOut: [ConversionAction] {
        [
            // Not `video.to-mp4`: that action belongs to `VideoActions`, for formats macOS reads itself.
            ConversionAction(
                id: "video.foreign-to-mp4", title: "MP4", subtitle: "H.264", symbolName: "film",
                category: .video, inputTypes: foreignVideo, defaultRank: 10, converter: ClosureConverter { try await toMP4($0, target: .h264) }),
            ConversionAction(
                id: "video.foreign-to-hevc", title: "HEVC", subtitle: "H.265", symbolName: "film.stack",
                category: .video, inputTypes: foreignVideo, defaultRank: 50, converter: ClosureConverter { try await toMP4($0, target: .hevc) }),
        ]
    }

    // MARK: - Video

    enum VideoTarget { case h264, hevc }

    /// Plan for one MP4: which streams can be rewrapped and how the rest gets encoded.
    struct MP4Plan: Equatable {
        var copyVideo: Bool
        var copyAudio: Bool
        var usesHEVC: Bool
        var isHDR: Bool
    }

    static func plan(_ probe: MediaProbe, video: MediaProbe.Video, target: VideoTarget) -> MP4Plan {
        // H.264 here is 8-bit. An HDR source would lose its colour with no tone-mapper in the engine, so it stays HEVC Main 10
        // with its tags, and the output's name says HEVC.
        let hevc = target == .hevc || video.isHDR
        let copy = hevc ? video.codec == "hevc" : (video.codec == "h264" && video.is8Bit420)
        return MP4Plan(copyVideo: copy, copyAudio: probe.audio.first?.codec == "aac", usesHEVC: hevc, isHDR: video.isHDR)
    }

    /// Keeps the aspect ratio and sidesteps rotated files by working on the long and short sides. Even sizes, which
    /// VideoToolbox needs; never scales up.
    private static func fitFilter(longSide: Int, shortSide: Int) -> String {
        let scale = "min(1,min(\(longSide)/max(iw,ih),\(shortSide)/min(iw,ih)))"
        return "scale=w='trunc(\(scale)*iw/2)*2':h='trunc(\(scale)*ih/2)*2'"
    }

    /// Everything after the input for an MP4. A fixed list; nothing from the file or its name goes in, only the plan.
    static func mp4Arguments(_ plan: MP4Plan, audio: MediaProbe.Audio?) -> [String] {
        // The first sound track only (foreign files often carry commentary or many languages). Tags as in X264Compress:
        // the file's own, never the location, nor FFmpeg's container notes.
        var args = ["-map", "0:V:0", "-map", "0:a:0?", "-sn", "-dn", "-map_chapters", "-1",
                    "-map_metadata", "0", "-metadata", "location=", "-metadata", "location-eng=",
                    "-metadata", "com.apple.quicktime.location.ISO6709=", "-metadata", "major_brand=",
                    "-metadata", "minor_version=", "-metadata", "compatible_brands="]
        if plan.copyVideo {
            args += ["-c:v", "copy", "-tag:v", plan.usesHEVC ? "hvc1" : "avc1"]
        } else if plan.usesHEVC {
            // x265 (CPU). HDR stays Main10 with its tags (the probe can't tell PQ from HLG, so no PQ-only tuning).
            args += ["-vf", fitFilter(longSide: 7680, shortSide: 4320), "-c:v", "libx265", "-preset", X264Compress.hevcPreset,
                     "-crf", String(X264Compress.hevcCRF), "-tag:v", "hvc1",
                     "-x265-params", "log-level=error:repeat-headers=1"]
            args += plan.isHDR ? ["-pix_fmt", "yuv420p10le", "-profile:v", "main10"] : ["-pix_fmt", "yuv420p", "-profile:v", "main"]
        } else {
            // x264 (CPU): 8-bit 4:2:0, the H.264 every phone and browser plays.
            args += ["-vf", fitFilter(longSide: 3840, shortSide: 2160), "-c:v", "libx264", "-preset", X264Compress.preset,
                     "-crf", String(X264Compress.mp4CRF), "-profile:v", "high", "-pix_fmt", "yuv420p"]
        }
        if let audio {
            args += plan.copyAudio ? ["-c:a", "copy"] : aacArguments(audio)
        }
        // Same timing as X264Compress: B-frame delay in the frame offsets (exact frame times in Apple's readers).
        // No fast start: the movie box stays last, so QuickTimeTags can move the tags without shifting media.
        return args + ["-movflags", plan.copyVideo ? "+use_metadata_tags+write_colr" : "+use_metadata_tags+negative_cts_offsets+write_colr",
                       "-avoid_negative_ts", plan.copyVideo ? "make_zero" : "auto", "-f", "mp4"]
    }

    /// AudioToolbox's AAC. Stereo and 5.1 keep their layout; anything else folds to stereo, which every player handles.
    static func aacArguments(_ audio: MediaProbe.Audio) -> [String] {
        var args = ["-c:a", "aac_at"]
        switch audio.channels {
        case 0...2: args += ["-b:a", "192k"]
        case 6: args += ["-ac", "6", "-b:a", "384k"]
        default: args += ["-ac", "2", "-b:a", "192k"]
        }
        return args
    }

    private static func toMP4(_ job: ConversionJob, target: VideoTarget) async throws -> [URL] {
        try await VideoActions.eachInput(job) { input, progress in
            let probe = try await MediaEngine.probe(input.url)
            guard let video = probe.mainVideo else { throw ConversionError.unsupportedInput("It has no video track.") }
            let plan = plan(probe, video: video, target: target)
            let out = try job.makeOutput(for: input, pathExtension: "mp4", suffix: plan.usesHEVC ? "HEVC" : nil)
            do {
                try await MediaEngine.convert(input: input.url, output: out.temporaryURL, inputOptions: probe.demuxerOptions,
                                              outputArguments: mp4Arguments(plan, audio: probe.audio.first),
                                              expectedSeconds: probe.seconds, checkLength: true, progress: progress)
                try QuickTimeTags.relocate(out.temporaryURL)
                try await verifyVideo(out.temporaryURL)
            } catch where (plan.copyVideo || plan.copyAudio) && !(error is CancellationError) {
                // A stream that wouldn't rewrap cleanly can still be encoded. Damage fails again below, with the same message.
                try? FileManager.default.removeItem(at: out.temporaryURL)
                var encode = plan
                encode.copyVideo = false
                encode.copyAudio = false
                try await MediaEngine.convert(input: input.url, output: out.temporaryURL, inputOptions: probe.demuxerOptions,
                                              outputArguments: mp4Arguments(encode, audio: probe.audio.first),
                                              expectedSeconds: probe.seconds, checkLength: true, progress: progress)
                try await verifyVideo(out.temporaryURL)
            }
            return try out.commit()
        }
    }

    /// Never hand over a file macOS itself can't open: the point of the conversion is that it plays here.
    private static func verifyVideo(_ url: URL) async throws {
        do { _ = try await AVSupport.open(url, requireVideo: true) } catch { throw MediaEngine.damaged }
    }

    /// Up to the first 15 s at 12 fps, fitted to 480 x 480, looping forever: the same result as `VideoActions.toGIF`.
    private static func toGIF(_ job: ConversionJob) async throws -> [URL] {
        try await VideoActions.eachInput(job) { input, progress in
            let probe = try await MediaEngine.probe(input.url)
            guard probe.mainVideo != nil else { throw ConversionError.unsupportedInput("It has no video track.") }
            let edge = Int(VideoActions.gifMaxEdge), fps = Int(VideoActions.gifFPS)
            let seconds = probe.seconds > 0 ? min(probe.seconds, VideoActions.gifMaxSeconds) : VideoActions.gifMaxSeconds
            let filter = "fps=\(fps),scale=w='min(\(edge),iw)':h='min(\(edge),ih)':force_original_aspect_ratio=decrease:flags=lanczos,"
                + "split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3"
            let out = try job.makeOutput(for: input, pathExtension: "gif")
            try await MediaEngine.convert(input: input.url, output: out.temporaryURL, inputOptions: probe.demuxerOptions,
                                          outputArguments: ["-t", String(Int(VideoActions.gifMaxSeconds)), "-map", "0:V:0", "-an", "-sn", "-dn",
                                                            "-vf", filter, "-loop", "0", "-f", "gif"],
                                          expectedSeconds: seconds, checkLength: true, progress: progress)
            let file: ImageFile
            do { file = try ImageFile(url: out.temporaryURL) } catch { throw MediaEngine.damaged }
            guard file.frameCount > 0 else { throw MediaEngine.damaged }
            return try out.commit()
        }
    }

    private static func extractM4A(_ job: ConversionJob) async throws -> [URL] {
        try await VideoActions.eachInput(job) { input, progress in
            try await audio(input, job: job, format: .m4a, progress: progress)
        }
    }

    private static func extractMP3(_ job: ConversionJob) async throws -> [URL] {
        try await VideoActions.eachInput(job) { input, progress in
            try await audio(input, job: job, format: .mp3, progress: progress)
        }
    }

    // MARK: - Audio

    enum AudioFormat: String, Sendable {
        case mp3, flac, m4a, wav, aiff
    }

    /// Everything after the input for an audio file: first audio track only, cover art and video left behind.
    static func audioArguments(_ format: AudioFormat, audio: MediaProbe.Audio) -> [String] {
        var args = ["-vn", "-sn", "-dn", "-map", "0:a:0"]
        switch format {
        case .mp3:
            // V2: transparent for most people at about 190 kb/s. MP3 is stereo at most, 48 kHz at most.
            args += ["-c:a", "libmp3lame", "-q:a", "2"]
            if audio.channels > 2 { args += ["-ac", "2"] }
            if audio.sampleRate > 48_000 { args += ["-ar", "48000"] }
            args += ["-id3v2_version", "3", "-f", "mp3"]
        case .flac:
            // A fixed block size: an MP3 source starts with a short frame, and macOS can't read a FLAC whose blocks vary.
            args += ["-c:a", "flac", "-compression_level", "5", "-frame_size", "4608", "-sample_fmt", audio.bitDepth > 16 ? "s32" : "s16", "-f", "flac"]
        case .m4a:
            args += audio.codec == "aac" ? ["-c:a", "copy"] : aacArguments(audio)
            args += ["-movflags", "+faststart", "-f", "ipod"]
        case .wav:
            args += ["-c:a", audio.bitDepth > 16 ? "pcm_s24le" : "pcm_s16le", "-f", "wav"]
        case .aiff:
            args += ["-c:a", audio.bitDepth > 16 ? "pcm_s24be" : "pcm_s16be", "-f", "aiff"]
        }
        return args
    }

    /// One audio file through the engine, opened afterwards with Apple's decoder as a check that it's real.
    static func audio(_ input: InputFile, job: ConversionJob, format: AudioFormat,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let probe = try await MediaEngine.probe(input.url)
        guard let audio = probe.audio.first else { throw ConversionError.unsupportedInput("It has no sound.") }
        let out = try job.makeOutput(for: input, pathExtension: format.rawValue)
        try await MediaEngine.convert(input: input.url, output: out.temporaryURL, inputOptions: probe.demuxerOptions, outputArguments: audioArguments(format, audio: audio),
                                      // A file's sound can be shorter than its picture, so length is only checked on pure audio.
                                      expectedSeconds: probe.seconds, checkLength: probe.mainVideo == nil, progress: progress)
        do {
            let check = try AVAudioFile(forReading: out.temporaryURL)
            guard check.length > 0 else { throw MediaEngine.damaged }
        } catch {
            throw MediaEngine.damaged
        }
        return try out.commit()
    }

    // MARK: - WebP

    /// macOS reads WebP but can't write it. ImageIO decodes the source (HEIC, RAW, PSD and the rest) and applies its
    /// orientation; the engine only ever sees a PNG Frenzy wrote, converted to sRGB first because the result carries no
    /// colour profile. EXIF and other metadata aren't copied into the WebP.
    static func imageToWebP(_ job: ConversionJob) async throws -> [URL] {
        try await VideoActions.eachInput(job) { input, progress in
            let scratch = try ConverterScratch.folder("webp", job: job)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let png = scratch.appendingPathComponent("image.png")

            let file = try ImageFile(url: input.url)
            let size = file.uprightSize
            guard max(size.width, size.height) <= webPMaxEdge else {
                throw ConversionError.unsupportedInput("WebP can't hold an image over \(webPMaxEdge.formatted()) pixels on a side.")
            }
            let image = try file.uprightImage(for: .webp)
            guard let srgb = VideoActions.sRGB(image) else { throw ConversionError.unreadable(input.url) }
            try ImageWriter.write(srgb, as: .png, to: png)
            progress(0.3)
            try Task.checkCancellation()

            let out = try job.makeOutput(for: input, pathExtension: "webp")
            try await MediaEngine.convert(input: png, output: out.temporaryURL,
                                          inputOptions: ["-f", "png_pipe"], maxPixels: ImageLimits.maxPixels,
                                          outputArguments: ["-frames:v", "1", "-c:v", "libwebp", "-quality", "90", "-compression_level", "4",
                                                            "-pix_fmt", file.hasAlpha ? "yuva420p" : "yuv420p", "-f", "webp"],
                                          expectedSeconds: 0, checkLength: false) { _ in }
            guard let written = try? ImageFile(url: out.temporaryURL), written.pixelWidth == size.width, written.pixelHeight == size.height else {
                throw MediaEngine.damaged
            }
            return try out.commit()
        }
    }

    static let webPMaxEdge = 16_383
}
