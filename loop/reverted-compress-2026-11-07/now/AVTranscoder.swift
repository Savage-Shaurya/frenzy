import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import HaloCore
import VideoToolbox

/// Re-encodes a movie with `AVAssetReader` -> `AVAssetWriter`. Export presets choose their own settings, drop or mix
/// audio tracks and can't promise a smaller file; this keeps every track and picture property it can and only spends
/// the bits the picture needs.
///
/// Rate control: VideoToolbox constant quality (`kVTCompressionPropertyKey_Quality`), so the bitrate follows the
/// content (a talking head costs less than a crowd at the same look), capped by a fraction of the source's own rate.
/// Encoders without a constant-quality mode get an average bitrate from `fallbackBitsPerPixel` instead.
enum AVTranscoder {
    struct Plan: Sendable {
        /// The longest and shortest edge the output may have. `nil` keeps the source's size, always.
        var maxLongEdge: CGFloat?
        var maxShortEdge: CGFloat?
        /// VideoToolbox constant-quality targets (0...1), per pipeline: the same number looks much better at 10 bits
        /// than at 8. Calibrated with VMAF on real footage: see `loop/DECISIONS.md`.
        var quality8: Double = 0.6
        var quality10: Double = 0.45
        /// Never let the video spend more than this fraction of the source's own video bitrate.
        var maxFractionOfSource: Double = 0.8
        /// Used only when the encoder has no constant-quality mode. Encoded bits per pixel per frame.
        var fallbackBitsPerPixel: Double = 0.08
        var minVideoBitRate: Double = 150_000
        var preferHEVC = true
        var audio = AudioPolicy.keep
        /// Size comes first, so an efficient source still gets squeezed instead of being left alone.
        var alwaysSqueezes = false

        func quality(tenBit: Bool) -> Double { tenBit ? quality10 : quality8 }

        /// "Compress": the same picture to a normal viewer. Same size, frame rate, colour and sound tracks.
        static let compress = Plan()
        /// "Smaller": size first. Fits inside 1080p and gives up visible detail. Keeps frame rate, HDR and every track.
        static let smaller = Plan(maxLongEdge: 1920, maxShortEdge: 1080, quality8: 0.45, quality10: 0.33, maxFractionOfSource: 0.6,
                                  fallbackBitsPerPixel: 0.05, audio: .economy, alwaysSqueezes: true)
    }

    /// What happens to audio that needs re-encoding (compressed tracks at a sensible rate are never touched).
    enum AudioPolicy: Sendable {
        /// Only tracks MP4 can't carry (PCM and friends) are re-encoded, to high-rate AAC.
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

    // MARK: - Decisions made before anything is written

    /// How one source audio track reaches the output.
    struct AudioRoute: @unchecked Sendable {
        let track: AVAssetTrack
        let format: CMFormatDescription
        let enabled: Bool
        /// `nil` copies the compressed samples untouched.
        let readerSettings: [String: Any]?
        let writerSettings: [String: Any]?
        let bitRate: Double

        var isPassthrough: Bool { writerSettings == nil }
    }

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
        let fps: Double
        let sourceVideoRate: Double
        let color: AVColorInfo
        let keepsAlpha: Bool
        let audio: [AudioRoute]
        let fileType: AVFileType
        let videoSeconds: Double
        /// The source's codec is about as efficient as the one Frenzy writes.
        let sourceIsEfficient: Bool

        var pathExtension: String { fileType == .mov ? "mov" : "mp4" }

        /// The cap on the encoder's rate, in bits per second. Nil when the source tells us nothing useful.
        var videoRateCap: Double? {
            guard sourceVideoRate > 0, plan.maxFractionOfSource > 0 else { return nil }
            return max(plan.minVideoBitRate, sourceVideoRate * plan.maxFractionOfSource)
        }

        private var audioBytes: Double { audio.reduce(0) { $0 + $1.bitRate } * media.seconds / 8 }

        /// A typical result: below this there is plainly no room, so the job doesn't even start.
        var likelyOutputBytes: Int64 {
            let typical = Double(width * height) * fps * 0.02
            let rate = videoRateCap.map { min($0, typical) } ?? typical
            return Int64(rate * media.seconds / 8 + audioBytes) + 16 << 20
        }

        /// The most this can plausibly take. Fast start needs a second copy of it, so it is only asked for with room.
        var largestOutputBytes: Int64 {
            let busy = Double(width * height) * fps * 0.6
            let rate = videoRateCap.map { min($0, busy) } ?? busy
            return Int64(rate * media.seconds / 8 + audioBytes) + 16 << 20
        }
    }

    static func prepare(_ media: AVSupport.Media, plan: Plan) async throws -> Prepared {
        // Every video track in a normal file: the first enabled one is the picture people see.
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
        let probe = try AVAssetWriter(outputURL: scratchProbeURL(), fileType: .mov)
        let keepsAlpha = color.hasAlpha && !color.isHDR && plan.preferHEVC
            && probe.canApply(outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha, AVVideoWidthKey: outW, AVVideoHeightKey: outH,
            ], forMediaType: .video)

        let routes = try await audioRoutes(media.audioTracks, policy: plan.audio)
        let wantsMOV = keepsAlpha || routes.contains { $0.isPassthrough && !mp4SafeAudio.contains(CMFormatDescriptionGetMediaSubType($0.format)) }
        return Prepared(
            media: media, plan: plan, videoTrack: videoTrack, transform: transform, timeScale: timeScale,
            width: outW, height: outH, needsScaling: needsScaling,
            fps: frameRate > 0 ? min(Double(frameRate), 960) : 30, sourceVideoRate: Double(dataRate),
            color: color, keepsAlpha: keepsAlpha, audio: routes, fileType: wantsMOV ? .mov : .mp4,
            videoSeconds: { let end = range.end.seconds; return end.isFinite && end > 0 ? end : media.seconds }(),
            sourceIsEfficient: efficientVideo.contains(color.codec))
    }

    /// Fits inside the plan's cap, never upscales, even dimensions for 4:2:0. Without a cap the size only changes
    /// when the source is odd (down by one pixel, so nothing is ever invented).
    static func outputSize(width w: CGFloat, height h: CGFloat, plan: Plan) -> (Int, Int) {
        var scale: CGFloat = 1
        if let long = plan.maxLongEdge { scale = min(scale, long / max(w, h)) }
        if let short = plan.maxShortEdge { scale = min(scale, short / min(w, h)) }
        return (max(2, Int((w * scale / 2).rounded(.down)) * 2), max(2, Int((h * scale / 2).rounded(.down)) * 2))
    }

    private static let efficientVideo: Set<FourCharCode> = [
        kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha, kCMVideoCodecType_DolbyVisionHEVC, kCMVideoCodecType_AV1,
        FourCharCode(0x6865_7631) /* hev1 */, FourCharCode(0x6476_6865) /* dvhe */, kCMVideoCodecType_VP9,
    ]

    /// Lossy or MP4-registered sound that an MP4 can hold as it is. Anything else (PCM, for one) means MOV.
    static let mp4SafeAudio: Set<FourCharCode> = [
        kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD,
        kAudioFormatAC3, kAudioFormatEnhancedAC3, kAudioFormatAppleLossless, kAudioFormatFLAC, kAudioFormatOpus, kAudioFormatMPEGLayer3,
    ]

    /// Uncompressed or lossless sound worth re-encoding: PCM is 10+ times the size of transparent AAC.
    private static let bulkyAudio: Set<FourCharCode> = [kAudioFormatLinearPCM, kAudioFormatAppleLossless, kAudioFormatFLAC]
    /// Worth re-encoding under `.economy` when above this rate per channel.
    private static let economyRatePerChannel = 96_000.0

    private static func scratchProbeURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("halo-probe-\(UUID().uuidString).mov")
    }

    /// One route per track, in order. Nothing is mixed down. A track AAC can't represent (4-channel spatial APAC, an
    /// unusual layout) is copied as it is, which is lossless and only ever costs a MOV instead of an MP4.
    private static func audioRoutes(_ tracks: [AVAssetTrack], policy: AudioPolicy) async throws -> [AudioRoute] {
        var routes: [AudioRoute] = []
        let probe = try AVAssetWriter(outputURL: scratchProbeURL(), fileType: .mp4)
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
                                         bitRate: Double(settings[AVEncoderBitRateKey] as? Int ?? 0)))
            } else {
                routes.append(AudioRoute(track: track, format: format, enabled: enabled, readerSettings: nil, writerSettings: nil, bitRate: Double(rate)))
            }
        }
        return routes
    }

    /// AAC settings keeping the track's channels and layout, or nil when AAC can't hold them.
    private static func aacSettings(format: CMFormatDescription, asbd: AudioStreamBasicDescription, channels: Int, policy: AudioPolicy) -> [String: Any]? {
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

    static func transcode(_ prepared: Prepared, to url: URL, guards: Guards = .init(),
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
        let color = prepared.color
        func setup(_ rate: RateControl, bitRate: Double = 0) throws -> VideoSetup {
            try videoSetup(color: color, plan: plan, width: prepared.width, height: prepared.height,
                           scaled: prepared.needsScaling, bitRate: bitRate, fps: prepared.fps, writer: writer,
                           rate: rate, keepsAlpha: prepared.keepsAlpha)
        }
        var video: VideoSetup
        var encodeStart = 0.0
        if constantQualitySupported(prefersHEVC: plan.preferHEVC) {
            // Constant quality has no ceiling, and VideoToolbox's rate limits switch it off: with limits set, the rate
            // follows the limit whatever the quality (measured). So ask first: encode a few seconds and see what the
            // picture costs. It stays constant quality if that fits, and only a costly picture gets a capped average.
            video = try setup(.constantQuality)
            let sampled = try await sampledBitRate(prepared, setup: video, progress: progress)
            encodeStart = sampleShare
            switch rateDecision(sampled: sampled, sourceRate: prepared.sourceVideoRate, sourceIsEfficient: prepared.sourceIsEfficient, plan: plan) {
            case .constantQuality:
                break
            case .average(let bitRate):
                video = try setup(.average, bitRate: bitRate)
            case .leaveAlone:
                if let calm = guards.whenOverSizeLimit { throw calm }
            }
        } else {
            var bitRate = Double(prepared.width * prepared.height) * prepared.fps * plan.fallbackBitsPerPixel
            if let cap = prepared.videoRateCap { bitRate = min(bitRate, cap) }
            video = try setup(.average, bitRate: max(bitRate, plan.minVideoBitRate))
        }
        let videoOut = AVAssetReaderTrackOutput(track: prepared.videoTrack, outputSettings: video.readerSettings)
        // Copies, always. Without them the hardware encoder reads frames straight out of the decoder's pool, and a
        // Cancel that tears the reader down mid-encode frees memory the encoder chip is still reading: on macOS 27 that
        // is a kernel panic (DART fault on dart-ave0), seen twice on the founder's Mac, 7 Nov 2026. The writer's
        // back-pressure (`isReadyForMoreMediaData`) still keeps only a few frames in flight, even for 8K.
        videoOut.alwaysCopiesSampleData = true
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: video.writerSettings)
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

        let pump = Pump(reader: reader, writer: writer, pairs: pairs, duration: prepared.videoSeconds, guards: guards,
                        encodeStart: encodeStart, progress: progress)
        defer { AVSupport.removeWriterScratch(for: url) }
        try await pump.run()
    }

    /// Old call shape: prepare and run in one go.
    static func transcode(_ media: AVSupport.Media, to url: URL, plan: Plan, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await transcode(try await prepare(media, plan: plan), to: url, progress: progress)
    }

    /// True when this Mac's hardware encoder takes a constant-quality target. Software encoders are skipped: a
    /// software HEVC encode of a long 4K clip takes hours, so those Macs get the plain bitrate path.
    static func constantQualitySupported(prefersHEVC: Bool) -> Bool {
        prefersHEVC ? hevcQualityMode : h264QualityMode
    }
    private static let hevcQualityMode = probeQualityMode(kCMVideoCodecType_HEVC)
    private static let h264QualityMode = probeQualityMode(kCMVideoCodecType_H264)
    private static func probeQualityMode(_ codec: CMVideoCodecType) -> Bool {
        var session: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        guard VTCompressionSessionCreate(allocator: nil, width: 1920, height: 1080, codecType: codec, encoderSpecification: spec,
                                         imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                         compressionSessionOut: &session) == noErr, let session else { return false }
        defer { VTCompressionSessionInvalidate(session) }
        return VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: 0.6 as CFNumber) == noErr
    }

    enum RateControl: Sendable { case constantQuality, average }

    enum RateDecision: Equatable, Sendable {
        case constantQuality
        case average(Double)
        /// The picture would cost as much as the file already spends, in a codec just as good: nothing to gain.
        case leaveAlone
    }

    /// What to do once the sample says constant quality would cost `sampled` bits per second.
    static func rateDecision(sampled: Double?, sourceRate: Double, sourceIsEfficient: Bool, plan: Plan) -> RateDecision {
        guard let sampled, sourceRate > 0, plan.maxFractionOfSource > 0 else { return .constantQuality }
        let cap = max(plan.minVideoBitRate, sourceRate * plan.maxFractionOfSource)
        if sampled <= cap { return .constantQuality }
        if sourceIsEfficient, !plan.alwaysSqueezes, sampled >= sourceRate * 0.95 { return .leaveAlone }
        return .average(cap)
    }

    /// The part of the progress bar that sampling takes up.
    static let sampleShare = 0.02

    /// The stretches of a clip that get sampled: up to 3 x 2 s across it, never over about 15 % of a long clip, the
    /// whole clip when it's very short.
    static func sampleRanges(duration: Double) -> [ClosedRange<Double>] {
        guard duration > 0 else { return [] }
        let length = 2.0
        if duration <= length { return [0...duration] }
        let count = min(3, max(1, Int(duration * 0.15 / length)))
        return (0..<count).map { i in
            let centre = duration * (Double(i) + 0.5) / Double(count)
            let start = min(duration - length, max(0, centre - length / 2))
            return start...(start + length)
        }
    }

    /// Encodes the sample ranges with the real settings, keeping nothing but the byte count. Nil when it can't tell,
    /// which only means the size guards do the work later.
    private static func sampledBitRate(_ prepared: Prepared, setup: VideoSetup, progress: @escaping @Sendable (Double) -> Void) async throws -> Double? {
        let ranges = sampleRanges(duration: prepared.videoSeconds)
        let settings = VideoSetupBox(setup)
        let measured: Double? = try await AVSupport.runBlocking { cancel -> Double? in
            var bytes = 0, seconds = 0.0
            for (index, range) in ranges.enumerated() {
                guard let part = try sampleOne(range, asset: prepared.media.asset, track: prepared.videoTrack, setup: settings.setup,
                                                 width: prepared.width, height: prepared.height, cancel: cancel) else { return nil }
                bytes += part.bytes
                seconds += part.seconds
                progress(sampleShare * Double(index + 1) / Double(ranges.count))
            }
            return seconds > 0 ? Double(bytes) * 8 / seconds : nil
        }
        return measured
    }

    private struct VideoSetupBox: @unchecked Sendable {
        let setup: VideoSetup
        init(_ setup: VideoSetup) { self.setup = setup }
    }

    private static func sampleOne(_ range: ClosedRange<Double>, asset: AVAsset, track: AVAssetTrack, setup: VideoSetup,
                                  width: Int, height: Int, cancel: AVCancelFlag) throws -> (bytes: Int, seconds: Double)? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                                       end: CMTime(seconds: range.upperBound, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: setup.readerSettings)
        output.alwaysCopiesSampleData = true // see `transcode`: never hand the encoder the decoder's own buffers
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let codec: CMVideoCodecType
        switch setup.writerSettings[AVVideoCodecKey] as? AVVideoCodecType {
        case .some(.h264): codec = kCMVideoCodecType_H264
        case .some(.hevcWithAlpha): codec = kCMVideoCodecType_HEVCWithAlpha
        default: codec = kCMVideoCodecType_HEVC
        }
        var created: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: codec, encoderSpecification: nil,
                                         imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                         compressionSessionOut: &created) == noErr, let session = created else { return nil }
        defer { VTCompressionSessionInvalidate(session) }
        let compression = setup.writerSettings[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
        for (key, value) in compression { VTSessionSetProperty(session, key: key as CFString, value: value as CFTypeRef) }

        let tally = ByteTally()
        var first: CMTime?, last: CMTime?
        while let sample = autoreleasepool(invoking: { output.copyNextSampleBuffer() }) {
            try cancel.check()
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if first == nil { first = pts }
            last = pts
            let status = VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: pts, duration: CMSampleBufferGetDuration(sample),
                                                         frameProperties: nil, infoFlagsOut: nil) { _, _, encoded in
                if let encoded { tally.add(CMSampleBufferGetTotalSampleSize(encoded)) }
            }
            guard status == noErr else { return nil }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        try cancel.check()
        guard reader.status == .completed, let first, let last, tally.frames > 1 else { return nil }
        // One frame's worth on top of first-to-last, so a two-frame sample doesn't count as half its length.
        let seconds = (last - first).seconds * Double(tally.frames) / Double(tally.frames - 1)
        return seconds > 0 ? (tally.bytes, seconds) : nil
    }

    private final class ByteTally: @unchecked Sendable {
        private let lock = NSLock()
        private var total = 0, count = 0
        func add(_ size: Int) { lock.withLock { total += size; count += 1 } }
        var bytes: Int { lock.withLock { total } }
        var frames: Int { lock.withLock { count } }
    }

    struct VideoSetup {
        var readerSettings: [String: Any]
        var writerSettings: [String: Any]
        var tenBit: Bool
    }

    /// Chooses decode format and encoder settings for `color`. Throws when an HDR source can't be kept HDR (no HEVC
    /// Main10 encoder), rather than silently writing washed-out 8-bit HDR. `bitRate` only applies to `.average`.
    static func videoSetup(color: AVColorInfo, plan: Plan, width: Int, height: Int, scaled: Bool,
                           bitRate: Double, fps: Double, writer: AVAssetWriter,
                           rate: RateControl = .average, keepsAlpha: Bool = false) throws -> VideoSetup {
        func settings(_ codec: AVVideoCodecType, tenBit: Bool, colorProperties: [String: String]) -> [String: Any] {
            var compression: [String: Any] = [
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ]
            switch rate {
            case .constantQuality: compression[kVTCompressionPropertyKey_Quality as String] = plan.quality(tenBit: tenBit)
            case .average: compression[AVVideoAverageBitRateKey] = Int(bitRate)
            }
            if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            if codec == .hevcWithAlpha { compression[kVTCompressionPropertyKey_TargetQualityForAlpha as String] = 1.0 }
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
        func reader(pixelFormat: OSType, convertTo colorProperties: [String: String]?) -> [String: Any] {
            var s: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
            // Scale in the decoder so an 8K source never produces full-size frames we'd only shrink again.
            if scaled {
                s[kCVPixelBufferWidthKey as String] = width
                s[kCVPixelBufferHeightKey as String] = height
            }
            if let colorProperties { s[AVVideoColorPropertiesKey] = colorProperties }
            return s
        }
        let eightBit = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, tenBit = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

        if keepsAlpha {
            // HEVC with alpha takes BGRA. The transparency survives; the colour goes through 8-bit SDR.
            let props = color.sdrProperties
            let out = settings(.hevcWithAlpha, tenBit: false, colorProperties: props)
            if writer.canApply(outputSettings: out, forMediaType: .video) {
                return VideoSetup(readerSettings: reader(pixelFormat: kCVPixelFormatType_32BGRA, convertTo: color.hasCompleteSDRTags ? nil : props),
                                  writerSettings: out, tenBit: false)
            }
        }
        if plan.preferHEVC, color.wantsTenBit {
            let hdr = settings(.hevc, tenBit: true, colorProperties: color.preservedProperties)
            if writer.canApply(outputSettings: hdr, forMediaType: .video) {
                // 10-bit SDR with incomplete tags gets converted to its (BT.709) output tags; HDR is passed as is.
                let convert = !color.isHDR && !color.hasCompleteSDRTags ? color.sdrProperties : nil
                return VideoSetup(readerSettings: reader(pixelFormat: tenBit, convertTo: convert), writerSettings: hdr, tenBit: true)
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
        return VideoSetup(readerSettings: reader(pixelFormat: eightBit, convertTo: convert), writerSettings: out, tenBit: false)
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

        /// Encoding fills up to here; the rest belongs to finishing the file.
        private static let encodeEnd = 0.98
        /// Stop writing once this little is left on a watched volume: macOS itself needs room to keep running.
        private static let minimumFreeBytes: Int64 = 96 << 20

        private let queue = DispatchQueue(label: "halo.transcode", qos: .userInitiated)
        private let monitorQueue = DispatchQueue(label: "halo.transcode.monitor", qos: .utility)
        private let signal = Signal()
        private let reader: AVAssetReader
        private let writer: AVAssetWriter
        private let pairs: [(AVAssetReaderOutput, AVAssetWriterInput)]
        private let duration: Double
        private let guards: Guards
        private let encodeStart: Double
        private let progress: @Sendable (Double) -> Void
        // State below is only touched on `queue`.
        private var phase = Phase.idle
        private var unfinished: Set<Int>
        private var continuation: CheckedContinuation<Void, any Error>?
        private var monitor: (any DispatchSourceTimer)?
        private var lastReportedAt = DispatchTime.now()
        private var lastReported = 0.0

        init(reader: AVAssetReader, writer: AVAssetWriter, pairs: [(AVAssetReaderOutput, AVAssetWriterInput)],
             duration: Double, guards: Guards, encodeStart: Double, progress: @escaping @Sendable (Double) -> Void) {
            self.reader = reader
            self.writer = writer
            self.pairs = pairs
            self.duration = duration
            self.guards = guards
            self.encodeStart = encodeStart
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
                // The pump queue may be stuck inside the reader: cutting the reader is what frees it.
                requestStop(ConversionError.engine("The video stopped reading, so Frenzy stopped. Check the file or its disk, then try again."))
                if reader.status == .reading { reader.cancelReading() }
                return
            }
            for folder in guards.watchedFolders {
                if let free = guards.disk.capacity(folder), free < Self.minimumFreeBytes {
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

        /// At most ten updates a second reach the app (each is an XPC message), or one per percent on a slow file.
        private func report(_ raw: Double) {
            let fraction = raw.isFinite ? min(1, max(0, raw)) : lastReported
            signal.touch(fraction: fraction)
            let now = DispatchTime.now()
            guard Double(now.uptimeNanoseconds &- lastReportedAt.uptimeNanoseconds) >= 100_000_000 || fraction - lastReported >= 0.01 else { return }
            lastReportedAt = now
            lastReported = fraction
            progress(encodeStart + fraction * (Self.encodeEnd - encodeStart))
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
            progress(Self.encodeEnd)
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
        /// first is what panicked the kernel (see `transcode`).
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
