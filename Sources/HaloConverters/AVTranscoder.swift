import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import HaloCore
import VideoToolbox // profile-level names only (HEVC Main10). Never sessions or compression keys: see `SafetyRule`.

/// Re-encodes a movie with `AVAssetReader` -> `AVAssetWriter`: one writer, one encode per job, average bitrate.
///
/// SafetyRule (7 Nov 2026): the founder's Mac kernel-panicked three times (DART fault on dart-ave0) during video
/// encoding. The build that panicked also drove VideoToolbox directly (its own compression sessions to sample a
/// clip's cost, constant-quality targets). This file never does: AVAssetWriter is the only thing that talks to the
/// encoder, the bitrate is decided up front from the source (see `BitRateTable`), decoded frames are always copied
/// before the encoder sees them, and the writer is always stopped before the reader. A non-video test fails if any
/// file in `Sources/` names a VideoToolbox compression session or compression key.
///
/// What a result keeps: picture size (Compress) or a 1080p cap (Smaller), frame rate and every frame timestamp, HDR
/// (HEVC Main10 with the source's tags and HDR10 metadata), every sound track (copied untouched where the container
/// can hold it), each track's language and on/off state, rotation, creation date, make and model. What it drops:
/// where the video was shot.
enum AVTranscoder {
    struct Plan: Sendable {
        /// The longest and shortest edge the output may have. `nil` keeps the source's size, always.
        var maxLongEdge: CGFloat?
        var maxShortEdge: CGFloat?
        /// The video bitrate, as a share of the source's own video bitrate (after allowing for a smaller picture),
        /// before the per-resolution floor and cap in `BitRateTable`. Older codecs (H.264, ProRes) have more to give
        /// than sources already in HEVC, AV1 or VP9.
        var fractionOfSource = 0.55
        var fractionOfEfficientSource = 0.65
        /// Never more than this share of the source's (scaled) video bitrate, floors included: a result never spends
        /// more than the original did.
        var maxFractionOfSource = 0.8
        var minVideoBitRate = 150_000.0
        var preferHEVC = true
        var audio = AudioPolicy.keep
        /// Size comes first, so an already lean source still gets squeezed instead of being left alone.
        var alwaysSqueezes = false

        /// "Compress": same picture size, frame rate, colour and sound tracks, a little over half the bitrate.
        static let compress = Plan()
        /// "Smaller": size first. Fits inside 1080p at a lower share of the source. Keeps frame rate, HDR and tracks.
        static let smaller = Plan(maxLongEdge: 1920, maxShortEdge: 1080, fractionOfSource: 0.45, fractionOfEfficientSource: 0.5,
                                  maxFractionOfSource: 0.6, audio: .economy, alwaysSqueezes: true)
    }

    // MARK: - Bitrate

    /// Floors and caps for the video bitrate, by the output's short edge. Values are HEVC, 8-bit, up to 30 fps, in
    /// bits per second; `multiplier` scales them for frame rate, 10-bit and the H.264 fallback.
    ///
    /// | Short edge up to | Floor    | Typical  | Cap      |
    /// |------------------|----------|----------|----------|
    /// | 480 (SD)         | 0.8 Mb/s | 1.5 Mb/s | 2.5 Mb/s |
    /// | 720              | 1.5      | 3        | 5        |
    /// | 1080             | 3        | 6        | 10       |
    /// | 1440             | 5        | 10       | 16       |
    /// | 2160 (4K)        | 10       | 20       | 32       |
    /// | above            | 20       | 40       | 60       |
    ///
    /// Multipliers: up to 31 fps x1, up to 61 fps x1.5, faster x2; 10-bit (HDR) x1.25; H.264 instead of HEVC x1.5.
    /// "Typical" is used only when the source's bitrate is unknown.
    enum BitRateTable {
        struct Row: Sendable, Equatable {
            var maxShortEdge: Int
            var floor: Double
            var typical: Double
            var cap: Double
        }

        static let rows: [Row] = [
            Row(maxShortEdge: 480, floor: 800_000, typical: 1_500_000, cap: 2_500_000),
            Row(maxShortEdge: 720, floor: 1_500_000, typical: 3_000_000, cap: 5_000_000),
            Row(maxShortEdge: 1080, floor: 3_000_000, typical: 6_000_000, cap: 10_000_000),
            Row(maxShortEdge: 1440, floor: 5_000_000, typical: 10_000_000, cap: 16_000_000),
            Row(maxShortEdge: 2160, floor: 10_000_000, typical: 20_000_000, cap: 32_000_000),
            Row(maxShortEdge: .max, floor: 20_000_000, typical: 40_000_000, cap: 60_000_000),
        ]

        static func row(width: Int, height: Int) -> Row {
            let short = min(width, height)
            return rows.first { short <= $0.maxShortEdge } ?? rows[rows.count - 1]
        }

        static func multiplier(fps: Double, tenBit: Bool, h264: Bool) -> Double {
            let motion = fps <= 31 ? 1.0 : fps <= 61 ? 1.5 : 2.0
            return motion * (tenBit ? 1.25 : 1) * (h264 ? 1.5 : 1)
        }
    }

    /// What the bitrate decision needs to know about a source and its output.
    struct RateFacts: Sendable, Equatable {
        /// The source's video bitrate in bits per second, 0 when unknown.
        var sourceRate: Double
        var sourceWidth: Double
        var sourceHeight: Double
        var width: Int
        var height: Int
        var fps: Double
        var sourceIsEfficient: Bool

        /// The source's rate as it would be at the output's size. Bitrate grows slower than pixel count, hence 0.75.
        var scaledSourceRate: Double {
            let srcPixels = sourceWidth * sourceHeight, outPixels = Double(width * height)
            guard sourceRate > 0, srcPixels > 0, outPixels > 0 else { return sourceRate }
            return sourceRate * pow(min(1, outPixels / srcPixels), 0.75)
        }
    }

    /// The average video bitrate for one encode: a share of the source's (scaled) rate, held between the table's floor
    /// and cap, and never above `maxFractionOfSource` of the source, so the floor can't make a file bigger.
    static func videoBitRate(_ facts: RateFacts, plan: Plan, tenBit: Bool, h264: Bool) -> Double {
        let row = BitRateTable.row(width: facts.width, height: facts.height)
        let k = BitRateTable.multiplier(fps: facts.fps, tenBit: tenBit, h264: h264)
        let source = facts.scaledSourceRate
        var rate: Double
        if source > 0 {
            let share = facts.sourceIsEfficient ? plan.fractionOfEfficientSource : plan.fractionOfSource
            rate = min(max(source * share, row.floor * k), row.cap * k)
            rate = min(rate, source * plan.maxFractionOfSource)
        } else {
            rate = row.typical * k
        }
        return max(rate.rounded(), plan.minVideoBitRate)
    }

    /// True when re-encoding can't save enough to be worth a second generation: the source is already in an
    /// efficient codec and its share would land under the table's floor. Compress then says so without encoding.
    /// Smaller always tries (its size guard still stops a result that isn't smaller).
    static func isAlreadyLean(_ facts: RateFacts, plan: Plan, tenBit: Bool) -> Bool {
        guard !plan.alwaysSqueezes, facts.sourceIsEfficient, facts.sourceRate > 0 else { return false }
        let row = BitRateTable.row(width: facts.width, height: facts.height)
        let floor = row.floor * BitRateTable.multiplier(fps: facts.fps, tenBit: tenBit, h264: false)
        return facts.scaledSourceRate * plan.fractionOfEfficientSource < floor
    }

    // MARK: - Audio

    /// What happens to audio that needs re-encoding (compressed tracks at a sensible rate are never touched).
    enum AudioPolicy: Sendable {
        /// Only tracks MP4 can't carry well (PCM and lossless) are re-encoded, to high-rate AAC.
        case keep
        /// Tracks above a modest rate are also re-encoded, to modest AAC.
        case economy

        func aacBitRate(channels: Int) -> Int {
            switch (self, channels) {
            case (.keep, 1): return 128_000
            case (.keep, 2): return 256_000
            case (.keep, _): return channels * 96_000
            case (.economy, 1): return 80_000
            case (.economy, 2): return 128_000
            case (.economy, _): return channels * 64_000
            }
        }
    }

    /// How one source audio track reaches the output.
    struct AudioRoute: @unchecked Sendable {
        let track: AVAssetTrack
        let format: CMFormatDescription
        let enabled: Bool
        /// `nil` copies the compressed samples untouched.
        let readerSettings: [String: Any]?
        let writerSettings: [String: Any]?
        /// What this track will cost in the output, bits per second.
        let bitRate: Double
        /// What the track costs in the source, bits per second.
        let sourceBitRate: Double

        var isPassthrough: Bool { writerSettings == nil }
    }

    /// Lossy or MP4-registered sound that an MP4 can hold as it is. Anything else (PCM, for one) means MOV.
    static let mp4SafeAudio: Set<FourCharCode> = [
        kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD,
        kAudioFormatAC3, kAudioFormatEnhancedAC3, kAudioFormatAppleLossless, kAudioFormatFLAC, kAudioFormatOpus, kAudioFormatMPEGLayer3,
    ]

    /// Uncompressed or lossless sound worth re-encoding: PCM is 10+ times the size of transparent AAC.
    private static let bulkyAudio: Set<FourCharCode> = [kAudioFormatLinearPCM, kAudioFormatAppleLossless, kAudioFormatFLAC]
    /// Worth re-encoding under `.economy` when above this rate per channel.
    private static let economyRatePerChannel = 96_000.0

    /// One route per track, in order. Nothing is mixed down. A track AAC can't represent (spatial APAC, an unusual
    /// layout) is copied as it is, which is lossless and only ever costs a MOV instead of an MP4.
    private static func audioRoutes(_ tracks: [AVAssetTrack], policy: AudioPolicy) async throws -> [AudioRoute] {
        var routes: [AudioRoute] = []
        // Only asked about audio settings, never started: no file, no encoder.
        let probe = try AVAssetWriter(outputURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-audio-probe-\(UUID().uuidString).mp4"), fileType: .mp4)
        for track in tracks {
            let (formats, enabled, rate) = try await track.load(.formatDescriptions, .isEnabled, .estimatedDataRate)
            guard let format = formats.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { continue }
            let codec = CMFormatDescriptionGetMediaSubType(format)
            let channels = Int(max(1, asbd.mChannelsPerFrame))
            var wantsAAC = bulkyAudio.contains(codec) || formats.count > 1
            if case .economy = policy, Double(rate) > economyRatePerChannel * Double(max(2, channels)), codec != kAudioFormatAPAC { wantsAAC = true }
            if !wantsAAC, !mp4SafeAudio.contains(codec), codec != kAudioFormatAPAC { wantsAAC = true }

            if wantsAAC, let settings = aacSettings(format: format, asbd: asbd, channels: channels, policy: policy),
               probe.canApply(outputSettings: settings, forMediaType: .audio) {
                let sampleRate = settings[AVSampleRateKey] as? Double ?? 48_000
                var reader: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false,
                    AVLinearPCMIsBigEndianKey: false,
                ]
                if let layout = settings[AVChannelLayoutKey] { reader[AVChannelLayoutKey] = layout }
                routes.append(AudioRoute(track: track, format: format, enabled: enabled, readerSettings: reader, writerSettings: settings,
                                         bitRate: Double(settings[AVEncoderBitRateKey] as? Int ?? 0), sourceBitRate: Double(rate)))
            } else {
                routes.append(AudioRoute(track: track, format: format, enabled: enabled, readerSettings: nil, writerSettings: nil,
                                         bitRate: Double(rate), sourceBitRate: Double(rate)))
            }
        }
        return routes
    }

    /// AAC settings keeping the track's channels and layout, or nil when AAC can't hold them.
    private static func aacSettings(format: CMFormatDescription, asbd: AudioStreamBasicDescription, channels: Int,
                                    policy: AudioPolicy) -> [String: Any]? {
        var layoutData: Data?
        if channels <= 2 {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
            layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        } else {
            var size = 0
            if let layout = CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &size), size > 0 {
                layoutData = Data(bytes: layout, count: size)
            }
        }
        guard let layoutData else { return nil }
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: min(48_000, max(8_000, asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000)),
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: policy.aacBitRate(channels: channels),
            AVChannelLayoutKey: layoutData,
        ]
    }

    // MARK: - Decisions made before anything is written

    /// Everything decided about one transcode, before an output is reserved (the container decides the extension).
    struct Prepared: @unchecked Sendable {
        let media: AVSupport.Media
        let plan: Plan
        let videoTrack: AVAssetTrack
        let transform: CGAffineTransform
        let timeScale: CMTimeScale
        let width: Int
        let height: Int
        let needsScaling: Bool
        let color: AVColorInfo
        let audio: [AudioRoute]
        let fileType: AVFileType
        let videoSeconds: Double
        let rate: RateFacts

        var fps: Double { rate.fps }
        var pathExtension: String { fileType == .mov ? "mov" : "mp4" }

        /// The bitrate the encode will use when the preferred codec is available.
        var plannedVideoBitRate: Double {
            AVTranscoder.videoBitRate(rate, plan: plan, tenBit: plan.preferHEVC && color.wantsTenBit, h264: !plan.preferHEVC)
        }

        var isAlreadyLean: Bool { AVTranscoder.isAlreadyLean(rate, plan: plan, tenBit: plan.preferHEVC && color.wantsTenBit) }

        private var audioBytes: Double { audio.reduce(0) { $0 + $1.bitRate } * media.seconds / 8 }

        /// The expected result: below this there is plainly no room, so the job doesn't even start.
        var likelyOutputBytes: Int64 { Int64(plannedVideoBitRate * media.seconds / 8 + audioBytes) + 16 << 20 }

        /// The most this can plausibly take (average-bitrate encoders overshoot a little). Fast start needs a second
        /// copy of it, so it is only asked for with room.
        var largestOutputBytes: Int64 { Int64(plannedVideoBitRate * 1.5 * media.seconds / 8 + audioBytes) + 16 << 20 }
    }

    static func prepare(_ media: AVSupport.Media, plan: Plan) async throws -> Prepared {
        // The first enabled video track is the picture people see.
        var chosen: AVAssetTrack?
        for track in media.videoTracks where try await track.load(.isEnabled) { chosen = track; break }
        guard let videoTrack = chosen ?? media.videoTracks.first else {
            throw ConversionError.unsupportedInput("It has no video track.")
        }
        let (naturalSize, transform, frameRate, dataRate, timeScale, range, formats) = try await videoTrack.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate, .naturalTimeScale, .timeRange, .formatDescriptions)

        let w = abs(naturalSize.width), h = abs(naturalSize.height)
        guard w >= 2, h >= 2 else { throw ConversionError.unsupportedInput("The video has no picture.") }
        let (outW, outH) = outputSize(width: w, height: h, plan: plan)
        // Encoded pixels can differ from the shown size (odd sizes, anamorphic): the decoder then scales to the output.
        var needsScaling = CGFloat(outW) != w || CGFloat(outH) != h
        if let first = formats.first {
            let encoded = CMVideoFormatDescriptionGetDimensions(first)
            if Int(encoded.width) != outW || Int(encoded.height) != outH { needsScaling = true }
        }

        let color = await AVColorInfo.of(videoTrack)
        // Frenzy never uses the video chip (it panicked the founder's Mac, 7 Nov 2026), so it encodes in software.
        // Software HEVC runs ~12 fps at 1080p; software H.264 is several times faster and plays everywhere. HDR keeps
        // HEVC Main10, the only way to stay HDR.
        var plan = plan
        if softwareFallbackInstalled, !color.isHDR { plan.preferHEVC = false }
        let routes = try await audioRoutes(media.audioTracks, policy: plan.audio)
        let wantsMOV = routes.contains { $0.isPassthrough && !mp4SafeAudio.contains(CMFormatDescriptionGetMediaSubType($0.format)) }

        // The video track's own rate. When the file doesn't say, the file's average less its sound.
        var sourceRate = Double(dataRate)
        if sourceRate <= 0, media.seconds > 0, let url = Optional(media.asset.url) {
            let whole = Double(AVSupport.fileSize(url)) * 8 / media.seconds
            sourceRate = max(0, whole - routes.reduce(0) { $0 + $1.sourceBitRate })
        }
        let fps = frameRate > 0 ? min(Double(frameRate), 960) : 30
        let facts = RateFacts(sourceRate: sourceRate, sourceWidth: Double(w), sourceHeight: Double(h), width: outW, height: outH,
                              fps: fps, sourceIsEfficient: efficientVideo.contains(color.codec))
        return Prepared(
            media: media, plan: plan, videoTrack: videoTrack, transform: transform, timeScale: timeScale,
            width: outW, height: outH, needsScaling: needsScaling, color: color, audio: routes,
            fileType: wantsMOV ? .mov : .mp4,
            videoSeconds: { let end = range.end.seconds; return end.isFinite && end > 0 ? end : media.seconds }(),
            rate: facts)
    }

    /// Fits inside the plan's cap, never upscales, even dimensions for 4:2:0. Without a cap the size only changes
    /// when the source is odd (down by one pixel, so nothing is ever invented).
    static func outputSize(width w: CGFloat, height h: CGFloat, plan: Plan) -> (Int, Int) {
        var scale: CGFloat = 1
        if let long = plan.maxLongEdge { scale = min(scale, long / max(w, h)) }
        if let short = plan.maxShortEdge { scale = min(scale, short / min(w, h)) }
        return (max(2, Int((w * scale / 2).rounded(.down)) * 2), max(2, Int((h * scale / 2).rounded(.down)) * 2))
    }

    static let efficientVideo: Set<FourCharCode> = [
        kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha, kCMVideoCodecType_DolbyVisionHEVC, kCMVideoCodecType_AV1,
        FourCharCode(0x6865_7631) /* hev1 */, FourCharCode(0x6476_6865) /* dvhe */, kCMVideoCodecType_VP9,
    ]

    // MARK: - Running

    /// What a transcode watches for while it runs.
    struct Guards: Sendable {
        /// Stop calmly once the output can't end up under this many bytes. The action decides what that means.
        var sizeLimit: Int64?
        var whenOverSizeLimit: (any Error)?
        var disk = DiskGuard.live
        /// Folders whose volumes must keep some room while writing.
        var watchedFolders: [URL] = []
        /// No sample moved for this long: fail rather than sit at the same percentage forever.
        var stallLimit: TimeInterval = 120
    }

    /// Stop writing once this little is left on a watched volume: macOS itself needs room to keep running.
    static let minimumFreeBytes: Int64 = 96 << 20

    /// Runs one encode. It waits its turn at `HardwareEncodeGate` (one hardware encode at a time in this process, see
    /// FB23045975), then waits while another app holds the hardware encoder, falling back to Apple's software encoder
    /// if it stays busy. The gate is released only once the writer has completely finished or completely cancelled.
    static func transcode(_ prepared: Prepared, to url: URL, guards: Guards = .init(), availability: EncoderAvailability = .live,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        // A disk that is already nearly full never gets an encoder started (and never waits in line for one).
        for folder in guards.watchedFolders {
            if let free = guards.disk.capacity(folder), free < minimumFreeBytes { throw DiskGuard.ranOutError }
        }
        try await HardwareEncodeGate.shared.withPermit {
            // Always Apple's software encoder when it is installed (every Mac on macOS 27): the video chip is never
            // touched. Only a Mac without it falls back to the chip, one encode at a time, after the busy check.
            let route: EncoderAvailability.Route = softwareFallbackInstalled
                ? .software : try await availability.chooseRoute(softwareAvailable: false)
            try await transcodeHoldingGate(prepared, to: url, guards: guards, route: route, progress: progress)
        }
    }

    /// Apple's software H.264 or HEVC encoder is on this Mac (read from its plug-in, nothing loaded).
    static let softwareFallbackInstalled = SoftwareVideoEncoding.softwareEncoderInstalled(.hevc)
        || SoftwareVideoEncoding.softwareEncoderInstalled(.h264)

    private static func transcodeHoldingGate(_ prepared: Prepared, to url: URL, guards: Guards, route: EncoderAvailability.Route,
                                             progress: @escaping @Sendable (Double) -> Void) async throws {
        let media = prepared.media, plan = prepared.plan
        let reader: AVAssetReader, writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: media.asset)
            writer = try AVAssetWriter(outputURL: url, fileType: prepared.fileType)
        } catch {
            throw AVSupport.mapped(error, url: url)
        }
        // Fast start rewrites the whole file at the end. Only ask for it when the disk has room for the second copy.
        let room = guards.disk.capacity(url.deletingLastPathComponent()) ?? .max
        writer.shouldOptimizeForNetworkUse = room / 3 > prepared.largestOutputBytes

        // Colour: HDR / 10-bit sources stay 10-bit HEVC Main10 with their own tags + HDR10 metadata; everything else is
        // 8-bit with explicit SDR tags (untagged sources are converted to BT.709 while decoding).
        let facts = prepared.rate
        let video = try videoSetup(color: prepared.color, plan: plan, width: prepared.width, height: prepared.height,
                                   scaled: prepared.needsScaling, fps: prepared.fps, writer: writer) { codec, tenBit in
            videoBitRate(facts, plan: plan, tenBit: tenBit, h264: codec == .h264)
        }
        var writerSettings = video.writerSettings
        if route == .software {
            // The hardware encoder stayed busy in another app: pin this encode to Apple's software encoder, or stop.
            guard let pinned = try? SoftwareVideoEncoding.forcingSoftware(writerSettings),
                  writer.canApply(outputSettings: pinned, forMediaType: .video) else { throw EncoderAvailability.busyError }
            writerSettings = pinned
        }
        let videoOut = AVAssetReaderTrackOutput(track: prepared.videoTrack, outputSettings: video.readerSettings)
        // Copies, always: never hand the hardware encoder the decoder's own buffers. Freeing them mid-encode panicked
        // the kernel on macOS 27 (DART fault on dart-ave0), three times on the founder's Mac, 7 Nov 2026. The writer's
        // back-pressure (`isReadyForMoreMediaData`) still keeps only a few frames in flight, even for 8K.
        videoOut.alwaysCopiesSampleData = true
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: writerSettings)
        videoIn.transform = prepared.transform
        videoIn.expectsMediaDataInRealTime = false
        // Keep the source's clock, so variable frame rate timestamps survive to the exact frame.
        if prepared.timeScale > 0 { videoIn.mediaTimeScale = prepared.timeScale }

        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = []
        guard reader.canAdd(videoOut), writer.canAdd(videoIn) else { throw ConversionError.engine("Couldn't set up the video encoder.") }
        reader.add(videoOut)
        writer.add(videoIn)
        pairs.append((videoOut, videoIn))

        // Audio: one output track per source track, in order, with its language and on/off state.
        var inputsByTrack: [CMPersistentTrackID: AVAssetWriterInput] = [:]
        for route in prepared.audio {
            let output = AVAssetReaderTrackOutput(track: route.track, outputSettings: route.readerSettings)
            output.alwaysCopiesSampleData = true
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: route.writerSettings,
                                           sourceFormatHint: route.isPassthrough ? route.format : nil)
            input.expectsMediaDataInRealTime = false
            input.marksOutputTrackAsEnabled = route.enabled
            if let language = try? await route.track.load(.languageCode), !language.isEmpty { input.languageCode = language }
            if let tag = try? await route.track.load(.extendedLanguageTag), !tag.isEmpty { input.extendedLanguageTag = tag }
            input.metadata = AVSupport.withoutLocation((try? await route.track.load(.metadata)) ?? [])
            guard reader.canAdd(output), writer.canAdd(input) else { continue }
            reader.add(output)
            writer.add(input)
            pairs.append((output, input))
            inputsByTrack[route.track.trackID] = input
        }
        // Alternates stay alternates (an iPhone's stereo and spatial tracks), or players would sound both at once.
        for group in (try? await media.asset.load(.trackGroups)) ?? [] {
            let ids = group.trackIDs.map { CMPersistentTrackID(truncating: $0) }
            let members = ids.compactMap { inputsByTrack[$0] }
            guard members.count > 1 else { continue }
            let defaultID = prepared.audio.first { ids.contains($0.track.trackID) && $0.enabled }?.track.trackID
            let inputGroup = AVAssetWriterInputGroup(inputs: members, defaultInput: defaultID.flatMap { inputsByTrack[$0] })
            if writer.canAdd(inputGroup) { writer.add(inputGroup) }
        }

        // Creation date, make, model and the like stay; where it was shot doesn't (no setting allows it today).
        writer.metadata = AVSupport.withoutLocation((try? await media.asset.load(.metadata)) ?? [])

        let pump = Pump(reader: reader, writer: writer, pairs: pairs, duration: prepared.videoSeconds, guards: guards, progress: progress)
        defer { AVSupport.removeWriterScratch(for: url) }
        try await pump.run()
    }

    /// Prepare and run in one go.
    static func transcode(_ media: AVSupport.Media, to url: URL, plan: Plan, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await transcode(try await prepare(media, plan: plan), to: url, progress: progress)
    }

    struct VideoSetup {
        var readerSettings: [String: Any]
        var writerSettings: [String: Any]
        var tenBit: Bool
    }

    /// Chooses decode format and encoder settings for `color`, with the average bitrate `bitRate` gives for the codec
    /// and bit depth chosen. Throws when an HDR source can't be kept HDR (no HEVC Main10 encoder), rather than
    /// silently writing washed-out 8-bit HDR.
    static func videoSetup(color: AVColorInfo, plan: Plan, width: Int, height: Int, scaled: Bool, fps: Double,
                           writer: AVAssetWriter,
                           bitRate: (_ codec: AVVideoCodecType, _ tenBit: Bool) -> Double) throws -> VideoSetup {
        func settings(_ codec: AVVideoCodecType, tenBit: Bool, colorProperties: [String: String]) -> [String: Any] {
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: Int(bitRate(codec, tenBit)),
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ]
            if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            if tenBit {
                compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
                compression.merge(color.hdrMetadataCompressionProperties) { $1 }
            }
            return [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
                AVVideoColorPropertiesKey: colorProperties,
                AVVideoCompressionPropertiesKey: compression,
            ]
        }
        func reader(tenBit: Bool, convertTo colorProperties: [String: String]?) -> [String: Any] {
            var s: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: tenBit
                    ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ]
            // Scale in the decoder so an 8K source never produces full-size frames we'd only shrink again.
            if scaled {
                s[kCVPixelBufferWidthKey as String] = width
                s[kCVPixelBufferHeightKey as String] = height
            }
            if let colorProperties { s[AVVideoColorPropertiesKey] = colorProperties }
            return s
        }

        if plan.preferHEVC, color.wantsTenBit {
            let hdr = settings(.hevc, tenBit: true, colorProperties: color.preservedProperties)
            if writer.canApply(outputSettings: hdr, forMediaType: .video) {
                // 10-bit SDR with incomplete tags gets converted to its (BT.709) output tags; HDR is passed as is.
                let convert = !color.isHDR && !color.hasCompleteSDRTags ? color.sdrProperties : nil
                return VideoSetup(readerSettings: reader(tenBit: true, convertTo: convert), writerSettings: hdr, tenBit: true)
            }
            if color.isHDR { throw ConversionError.engine("This Mac can't encode HDR video (HEVC 10-bit).") }
        }
        if color.isHDR, !plan.preferHEVC {
            throw ConversionError.engine("HDR video needs HEVC to stay HDR.")
        }
        let props = color.sdrProperties
        let convert = color.hasCompleteSDRTags ? nil : props
        var out = settings(plan.preferHEVC ? .hevc : .h264, tenBit: false, colorProperties: props)
        if !writer.canApply(outputSettings: out, forMediaType: .video) { out = settings(.h264, tenBit: false, colorProperties: props) }
        guard writer.canApply(outputSettings: out, forMediaType: .video) else {
            throw ConversionError.engine("This Mac can't encode video at that size.")
        }
        return VideoSetup(readerSettings: reader(tenBit: false, convertTo: convert), writerSettings: out, tenBit: false)
    }

    /// Output URLs of transcodes whose pump (and so reader, writer and buffers) is still alive. Lets tests prove a
    /// finished or cancelled transcode releases everything.
    static let live = LiveSet()

    final class LiveSet: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL: Int] = [:]
        func insert(_ url: URL) { lock.withLock { urls[url, default: 0] += 1 } }
        func remove(_ url: URL) { lock.withLock { urls[url] = (urls[url] ?? 1) > 1 ? urls[url]! - 1 : nil } }
        func contains(inDirectory dir: URL) -> Bool {
            let path = dir.standardizedFileURL.path
            return lock.withLock { urls.keys.contains { $0.deletingLastPathComponent().standardizedFileURL.path == path } }
        }
    }

    /// When a running transcode should give up on size: the output has already passed `limit`, or at half way or later
    /// it is clearly heading well past it. Early parts can be the busy ones, so an early projection alone never stops it.
    static func isHopeless(written: Int64, fraction: Double, limit: Int64) -> Bool {
        if written >= limit { return true }
        guard fraction >= 0.5, fraction < 1 else { return false }
        return Double(written) / fraction > Double(limit) * 1.25
    }

    /// Progress updates that reach the app: at most ten a second, or one per percent on a slow file, never backwards.
    struct ProgressThrottle: Sendable {
        /// Encoding fills up to here; the rest belongs to finishing the file.
        static let encodeEnd = 0.98
        private(set) var lastReported = 0.0
        private var lastAt: UInt64 = 0

        /// The value to send for a raw encode fraction at `now` (nanoseconds), or nil to stay quiet.
        mutating func next(_ raw: Double, now: UInt64) -> Double? {
            let fraction = raw.isFinite ? min(1, max(lastReported, raw)) : lastReported
            guard lastAt == 0 || now &- lastAt >= 100_000_000 || fraction - lastReported >= 0.01 else { return nil }
            lastAt = max(now, 1)
            lastReported = fraction
            return fraction * Self.encodeEnd
        }
    }

    /// Owns the reader/writer for one transcode.
    ///
    /// Everything (start, the per-input pull blocks, cancel, failure, finishing) runs on one serial `queue`, so the
    /// AVFoundation calls that raise Objective-C exceptions when misordered (`markAsFinished` / `finishWriting` after
    /// `cancelWriting`, `cancelWriting` before `startWriting`) are always guarded by a status check made on the same
    /// queue that changes it. The pull blocks capture the pump weakly (the writer input retains them), so there's no
    /// pump -> writer -> input -> block -> pump cycle; `transcode` keeps the pump alive while it awaits `run()`.
    ///
    /// A stop (Cancel, full disk, stall, hopeless size) is first recorded in `signal`, which the pull loop checks on
    /// every sample, so it never waits for a long pull block to end. A timer on its own queue does the watching.
    private final class Pump: @unchecked Sendable {
        private enum Phase { case idle, running, finishing, done }

        /// Lock-protected facts shared between the pump queue, the monitor and the cancel handler.
        private final class Signal: @unchecked Sendable {
            private let lock = NSLock()
            private var error: (any Error)?
            private var activity = DispatchTime.now()
            private var pumping = false
            private var fraction = 0.0
            var stop: (any Error)? { lock.withLock { error } }
            var stopRequested: Bool { lock.withLock { error != nil } }
            /// True for the first stop only: later ones keep the first reason.
            func request(_ reason: any Error) -> Bool {
                lock.withLock {
                    if error != nil { return false }
                    error = reason
                    return true
                }
            }
            func touch(fraction f: Double? = nil, pumping p: Bool = true) {
                lock.withLock {
                    activity = .now()
                    pumping = p
                    if let f { fraction = max(fraction, f) }
                }
            }
            var snapshot: (idleSeconds: Double, pumping: Bool, fraction: Double) {
                lock.withLock {
                    (Double(DispatchTime.now().uptimeNanoseconds &- activity.uptimeNanoseconds) / 1e9, pumping, fraction)
                }
            }
        }

        private let queue = DispatchQueue(label: "halo.transcode", qos: .userInitiated)
        private let monitorQueue = DispatchQueue(label: "halo.transcode.monitor", qos: .utility)
        private let signal = Signal()
        private let reader: AVAssetReader
        private let writer: AVAssetWriter
        private let pairs: [(AVAssetReaderOutput, AVAssetWriterInput)]
        private let duration: Double
        private let guards: Guards
        private let progress: @Sendable (Double) -> Void
        // State below is only touched on `queue`.
        private var phase = Phase.idle
        private var unfinished: Set<Int>
        private var continuation: CheckedContinuation<Void, any Error>?
        private var monitor: (any DispatchSourceTimer)?
        private var throttle = ProgressThrottle()

        init(reader: AVAssetReader, writer: AVAssetWriter, pairs: [(AVAssetReaderOutput, AVAssetWriterInput)],
             duration: Double, guards: Guards, progress: @escaping @Sendable (Double) -> Void) {
            self.reader = reader
            self.writer = writer
            self.pairs = pairs
            self.duration = duration
            self.guards = guards
            self.progress = progress
            self.unfinished = Set(pairs.indices)
            AVTranscoder.live.insert(writer.outputURL)
        }

        deinit {
            monitor?.cancel()
            AVTranscoder.live.remove(writer.outputURL)
        }

        func run() async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                    queue.async {
                        self.continuation = c
                        self.start()
                    }
                }
            } onCancel: {
                requestStop(CancellationError())
            }
        }

        private var outputURL: URL { writer.outputURL }

        private func start() {
            // A cancel that arrived first (even before the continuation existed) left the signal set.
            if let stop = signal.stop { return complete(stop) }
            guard writer.startWriting() else {
                return complete(AVSupport.mapped(writer.error ?? ConversionError.engine("Couldn't start writing."), url: outputURL))
            }
            guard reader.startReading() else {
                writer.cancelWriting() // status is .writing here
                return complete(AVSupport.mapped(reader.error ?? ConversionError.engine("Couldn't read the video."), url: outputURL))
            }
            writer.startSession(atSourceTime: .zero)
            phase = .running
            signal.touch()
            startMonitor()
            for index in pairs.indices {
                pairs[index].1.requestMediaDataWhenReady(on: queue) { [weak self] in self?.pull(index) }
            }
        }

        // MARK: Stopping

        private func requestStop(_ reason: any Error) {
            guard signal.request(reason) else { return }
            queue.async { self.applyStop() }
        }

        private func applyStop() {
            guard let stop = signal.stop else { return }
            switch phase {
            case .idle, .done: return               // `start` sees the signal / nothing left to do
            case .finishing: return                 // `finishedWriting` reports it; never cancel mid-finish
            case .running:
                stopEngines()
                complete(stop)
            }
        }

        private func startMonitor() {
            let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
            timer.setEventHandler { [weak self] in self?.check() }
            timer.resume()
            monitor = timer
        }

        /// Runs once a second on `monitorQueue`.
        private func check() {
            let state = signal.snapshot
            if state.pumping, state.idleSeconds > guards.stallLimit {
                // Only records the stop. The reader and writer are touched on the pump queue alone: calling
                // `cancelReading` from two queues at once crashed the test process on 7 Nov 2026, and a process dying
                // mid-encode preceded two of the panics. A reader that is truly stuck keeps the job (and the gate)
                // until it returns; that is slower, never unsafe.
                return requestStop(ConversionError.engine("The video stopped reading, so Frenzy stopped. Check the file or its disk, then try again."))
            }
            for folder in guards.watchedFolders {
                if let free = guards.disk.capacity(folder), free < AVTranscoder.minimumFreeBytes {
                    return requestStop(DiskGuard.ranOutError)
                }
            }
            if let limit = guards.sizeLimit, let reason = guards.whenOverSizeLimit,
               AVTranscoder.isHopeless(written: AVSupport.fileSize(outputURL), fraction: state.fraction, limit: limit) {
                requestStop(reason)
            }
        }

        // MARK: Pumping

        /// Called on `queue` whenever input `index` wants more samples.
        private func pull(_ index: Int) {
            guard phase == .running, unfinished.contains(index) else { return }
            let (output, input) = pairs[index]
            let reportsProgress = input.mediaType == .video && duration > 0
            while phase == .running, !signal.stopRequested, input.isReadyForMoreMediaData {
                // Drain autoreleased decoder objects per sample, not once per (possibly minutes-long) block.
                let more: Bool = autoreleasepool {
                    guard let sample = output.copyNextSampleBuffer() else {
                        if signal.stopRequested { return false }
                        if reader.status == .failed {
                            fail(AVSupport.mapped(reader.error ?? ConversionError.engine("Couldn't read the video."), url: outputURL))
                        } else {
                            inputFinished(index)
                        }
                        return false
                    }
                    if reportsProgress {
                        report(CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration)
                    } else {
                        signal.touch()
                    }
                    guard input.append(sample) else {
                        fail(AVSupport.mapped(writer.error ?? ConversionError.engine("Couldn't encode the video."), url: outputURL))
                        return false
                    }
                    return true
                }
                if !more { return }
            }
        }

        private func report(_ raw: Double) {
            signal.touch(fraction: raw.isFinite ? min(1, max(0, raw)) : nil)
            if let value = throttle.next(raw, now: DispatchTime.now().uptimeNanoseconds) { progress(value) }
        }

        private func inputFinished(_ index: Int) {
            guard unfinished.remove(index) != nil else { return }
            if writer.status == .writing { pairs[index].1.markAsFinished() }
            if unfinished.isEmpty { finishWriting() }
        }

        private func finishWriting() {
            guard phase == .running else { return }
            guard writer.status == .writing else {
                return fail(AVSupport.mapped(writer.error ?? ConversionError.engine("Couldn't finish the video."), url: outputURL))
            }
            phase = .finishing
            signal.touch(pumping: false)
            progress(ProgressThrottle.encodeEnd)
            writer.finishWriting { [self] in
                queue.async { self.finishedWriting() }
            }
        }

        private func finishedWriting() {
            if let stop = signal.stop { return complete(stop) }
            if writer.status == .completed {
                progress(1)
                return complete(nil)
            }
            complete(AVSupport.mapped(writer.error ?? ConversionError.engine("Couldn't finish the video."), url: outputURL))
        }

        private func fail(_ error: any Error) {
            guard phase == .running || phase == .idle else { return }
            stopEngines()
            complete(error)
        }

        /// The encoder stops first: it may still be working on frames the reader handed it. Tearing the reader down
        /// first is the pattern that panicked the kernel (see `transcode`).
        private func stopEngines() {
            phase = .done
            if writer.status == .writing { writer.cancelWriting() }
            if reader.status == .reading { reader.cancelReading() }
        }

        /// Resumes the continuation exactly once.
        private func complete(_ error: (any Error)?) {
            phase = .done
            monitor?.cancel()
            monitor = nil
            guard let c = continuation else { return }
            continuation = nil
            if let error { c.resume(throwing: error) } else { c.resume() }
        }
    }
}

/// Free space, as a single seam so tests can pretend the disk is full.
struct DiskGuard: Sendable {
    /// Bytes available on the volume holding a folder, nil when macOS won't say.
    var capacity: @Sendable (URL) -> Int64?

    static let live = DiskGuard { folder in
        // A fresh URL each time: URL caches resource values.
        let url = URL(fileURLWithPath: folder.path)
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    static let ranOutError = ConversionError.engine("The disk filled up, so Frenzy stopped and removed the unfinished file. Free up some space and try again.")

    /// Throws a clear message when any of `folders` plainly can't hold `bytes`.
    func requireRoom(_ bytes: Int64, in folders: [URL]) throws {
        for folder in folders {
            guard let free = capacity(folder), free < bytes else { continue }
            let f = ByteCountFormatter()
            f.countStyle = .file
            throw ConversionError.engine("There isn't enough free space. This needs about \(f.string(fromByteCount: bytes)) and the disk has \(f.string(fromByteCount: max(0, free))).")
        }
    }
}
