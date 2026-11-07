import AVFoundation
import CoreMedia
import Foundation
import HaloCore
@testable import HaloConverters
import Testing
import UniformTypeIdentifiers
import VideoToolbox // constant names only: these tests never create an encoder

/// NON-VIDEO. The decisions behind Compress and Smaller, checked without encoding or decoding a single frame: bitrate
/// table, sizes, metadata filters, disk and progress rules, the one-encode-at-a-time gate and the busy-encoder check.
/// Safe to run on the founder's Mac at any time (no `HardwareVideoTests.allowed` needed).
@Suite("Video plan (no encoding)")
struct VideoPlanTests {
    private typealias T = AVTranscoder

    private func facts(_ rate: Double, _ w: Int, _ h: Int, out: (Int, Int)? = nil, fps: Double = 30, efficient: Bool = false) -> T.RateFacts {
        T.RateFacts(sourceRate: rate, sourceWidth: Double(w), sourceHeight: Double(h), width: out?.0 ?? w, height: out?.1 ?? h,
                    fps: fps, sourceIsEfficient: efficient)
    }

    // MARK: Bitrate table

    @Test func tableRowsClimbWithResolution() {
        let rows = T.BitRateTable.rows
        for (a, b) in zip(rows, rows.dropFirst()) {
            #expect(a.maxShortEdge < b.maxShortEdge && a.floor < b.floor && a.typical < b.typical && a.cap < b.cap)
        }
        for row in rows { #expect(row.floor < row.typical && row.typical < row.cap) }
        #expect(T.BitRateTable.row(width: 640, height: 360).maxShortEdge == 480)
        #expect(T.BitRateTable.row(width: 1080, height: 1920).maxShortEdge == 1080, "portrait uses its short edge")
        #expect(T.BitRateTable.row(width: 3840, height: 2160).maxShortEdge == 2160)
        #expect(T.BitRateTable.row(width: 7680, height: 4320).floor == 20_000_000)
    }

    @Test func multipliers() {
        #expect(T.BitRateTable.multiplier(fps: 29.97, tenBit: false, h264: false) == 1)
        #expect(T.BitRateTable.multiplier(fps: 60, tenBit: false, h264: false) == 1.5)
        #expect(T.BitRateTable.multiplier(fps: 120, tenBit: false, h264: false) == 2)
        #expect(T.BitRateTable.multiplier(fps: 30, tenBit: true, h264: false) == 1.25)
        #expect(T.BitRateTable.multiplier(fps: 30, tenBit: false, h264: true) == 1.5)
    }

    @Test func compressTakesAShareOfTheSource() {
        let compress = T.Plan.compress
        // 1080p30 H.264 at 8 Mb/s: 55 %.
        #expect(T.videoBitRate(facts(8e6, 1920, 1080), plan: compress, tenBit: false, h264: false) == 4_400_000)
        // Already HEVC: 65 %.
        #expect(T.videoBitRate(facts(8e6, 1920, 1080, efficient: true), plan: compress, tenBit: false, h264: false) == 5_200_000)
        // A heavy source (ProRes-like) stops at the 1080p cap.
        #expect(T.videoBitRate(facts(147e6, 1920, 1080), plan: compress, tenBit: false, h264: false) == 10_000_000)
        // 1080p60 cap is 1.5x.
        #expect(T.videoBitRate(facts(40e6, 1920, 1080, fps: 60), plan: compress, tenBit: false, h264: false) == 15_000_000)
        // HDR 10-bit cap is 1.25x.
        #expect(T.videoBitRate(facts(20e6, 1920, 1080, efficient: true), plan: compress, tenBit: true, h264: false) == 12_500_000)
        // The H.264 fallback gets 1.5x room.
        #expect(T.videoBitRate(facts(40e6, 1920, 1080), plan: compress, tenBit: false, h264: true) == 15_000_000)
    }

    @Test func theFloorNeverMakesAFileBigger() {
        // 1080p H.264 at 2 Mb/s: the floor (3 Mb/s) would be more than the source, so 80 % of the source wins.
        #expect(T.videoBitRate(facts(2e6, 1920, 1080), plan: .compress, tenBit: false, h264: false) == 1_600_000)
        for plan in [T.Plan.compress, .smaller] {
            for rate in stride(from: 500_000.0, through: 200e6, by: 750_000) {
                for (w, h) in [(640, 360), (1280, 720), (1920, 1080), (3840, 2160)] {
                    let (ow, oh) = T.outputSize(width: CGFloat(w), height: CGFloat(h), plan: plan)
                    let f = facts(rate, w, h, out: (ow, oh))
                    let chosen = T.videoBitRate(f, plan: plan, tenBit: false, h264: false)
                    #expect(chosen <= max(f.scaledSourceRate * plan.maxFractionOfSource, plan.minVideoBitRate) + 1)
                }
            }
        }
    }

    @Test func unknownSourceRateUsesTheTypicalColumn() {
        #expect(T.videoBitRate(facts(0, 1920, 1080), plan: .compress, tenBit: false, h264: false) == 6_000_000)
        #expect(T.videoBitRate(facts(0, 3840, 2160), plan: .compress, tenBit: true, h264: false) == 25_000_000)
    }

    @Test func tinySourcesStillGetTheMinimum() {
        #expect(T.videoBitRate(facts(100_000, 640, 360), plan: .compress, tenBit: false, h264: false) == 150_000)
    }

    @Test func smallerScalesTheSourceRateWithThePicture() {
        // 4K H.264 at 40 Mb/s into 1080p: 40 x (1/4)^0.75 = 14.14 Mb/s, x 0.45.
        let (w, h) = T.outputSize(width: 3840, height: 2160, plan: .smaller)
        let f = facts(40e6, 3840, 2160, out: (w, h))
        #expect(abs(f.scaledSourceRate - 14_142_136) < 2)
        #expect(T.videoBitRate(f, plan: .smaller, tenBit: false, h264: false) == (f.scaledSourceRate * 0.45).rounded())
        // Same source with Compress keeps 4K and lands on the 4K row's 55 %.
        #expect(T.videoBitRate(facts(40e6, 3840, 2160), plan: .compress, tenBit: false, h264: false) == 22_000_000)
    }

    @Test func leanEfficientFilesAreLeftAloneByCompressOnly() {
        let lean = facts(120_000, 640, 360, efficient: true)
        #expect(T.isAlreadyLean(lean, plan: .compress, tenBit: false))
        #expect(!T.isAlreadyLean(lean, plan: .smaller, tenBit: false), "Smaller always tries")
        #expect(!T.isAlreadyLean(facts(120_000, 640, 360), plan: .compress, tenBit: false), "H.264 always has room")
        #expect(!T.isAlreadyLean(facts(8e6, 1920, 1080, efficient: true), plan: .compress, tenBit: false))
        #expect(!T.isAlreadyLean(facts(0, 1920, 1080, efficient: true), plan: .compress, tenBit: false), "unknown rate: try")
    }

    // MARK: Sizes and ring wording

    @Test func compressNeverCapsTheSize() {
        #expect(T.Plan.compress.maxLongEdge == nil && T.Plan.compress.maxShortEdge == nil)
        let (w, h) = T.outputSize(width: 7680, height: 4320, plan: .compress)
        #expect(w == 7680 && h == 4320)
    }

    @Test func smallerFitsInside1080pEitherWayRound() {
        #expect(T.outputSize(width: 3840, height: 2160, plan: .smaller) == (1920, 1080))
        #expect(T.outputSize(width: 2160, height: 3840, plan: .smaller) == (1080, 1920))
        #expect(T.outputSize(width: 1280, height: 720, plan: .smaller) == (1280, 720), "never upscales")
    }

    @Test func oddSizesLoseOnePixelAtMost() {
        #expect(T.outputSize(width: 1081, height: 1921, plan: .compress) == (1080, 1920))
    }

    @Test func ringWordsStateTheDifference() throws {
        let actions = Dictionary(uniqueKeysWithValues: VideoActions.all.map { ($0.id.rawValue, $0) })
        let compress = try #require(actions["video.compress"]), smaller = try #require(actions["video.smaller"])
        #expect(compress.title == "Compress" && compress.subtitle == "Same size")
        #expect(smaller.title == "Smaller")
        #expect(smaller.subtitle?.contains("1080p") == true, "the downscale is stated on the bubble")
        #expect(compress.defaultRank < smaller.defaultRank)
        for action in VideoActions.all {
            #expect(!(action.title + (action.subtitle ?? "")).contains("\u{2014}"), "no em dashes in copy")
        }
    }

    @Test func movAndMP4BothGetCompressAndSmaller() {
        let mp4 = InputFile(url: URL(fileURLWithPath: "/x/a.mp4"), type: .mpeg4Movie)
        let mov = InputFile(url: URL(fileURLWithPath: "/x/a.mov"), type: .quickTimeMovie)
        let registry = ActionRegistry(actions: VideoActions.all, usage: MemoryUsageStore())
        for file in [mp4, mov] {
            let ids = Set(registry.actions(for: [file], limit: 99).map(\.id.rawValue))
            #expect(ids.isSuperset(of: ["video.compress", "video.smaller"]))
        }
    }

    // MARK: Guards and progress

    @Test func sizeGuardOnlyGivesUpWhenItIsSure() {
        #expect(T.isHopeless(written: 100, fraction: 0.1, limit: 100))
        #expect(!T.isHopeless(written: 50, fraction: 0.1, limit: 100), "an early busy part proves nothing")
        #expect(!T.isHopeless(written: 60, fraction: 0.5, limit: 100))
        #expect(T.isHopeless(written: 90, fraction: 0.5, limit: 100))
    }

    @Test func progressIsThrottledNeverGoesBackAndLeavesRoomToFinish() {
        var throttle = T.ProgressThrottle()
        var sent: [Double] = []
        var now: UInt64 = 1_000
        // 3000 frames 1 ms apart: one per percent at most.
        for i in 0..<3000 {
            now += 1_000_000
            if let v = throttle.next(Double(i) / 3000, now: now) { sent.append(v) }
        }
        #expect(sent.count <= 102, "\(sent.count)")
        #expect(zip(sent, sent.dropFirst()).allSatisfy { $0 <= $1 })
        #expect((sent.last ?? 1) <= T.ProgressThrottle.encodeEnd)
        // A timestamp from before the last one (B-frames, a second track) never moves it back.
        let before = throttle.lastReported
        now += 200_000_000
        if let v = throttle.next(0.1, now: now) { #expect(v >= before * T.ProgressThrottle.encodeEnd) }
        // A slow file still updates ten times a second.
        var slow = T.ProgressThrottle()
        var count = 0
        for i in 0..<50 where slow.next(Double(i) * 0.0001, now: UInt64(i + 1) * 100_000_000) != nil { count += 1 }
        #expect(count == 50)
    }

    @Test func diskGuardGivesAClearMessage() throws {
        let tight = DiskGuard { _ in 300 << 20 }
        #expect(throws: Never.self) { try tight.requireRoom(100 << 20, in: [URL(fileURLWithPath: "/tmp")]) }
        do {
            try tight.requireRoom(2 << 30, in: [URL(fileURLWithPath: "/tmp")])
            Issue.record("should have refused")
        } catch {
            let text = error.localizedDescription
            let f = ByteCountFormatter()
            f.countStyle = .file
            #expect(text.contains("free space") && text.contains(f.string(fromByteCount: 2 << 30))
                    && text.contains(f.string(fromByteCount: 300 << 20)), "\(text)")
            #expect(!text.contains("\u{2014}"), "no em dashes in copy")
        }
        let unknown = DiskGuard { _ in nil }
        #expect(throws: Never.self) { try unknown.requireRoom(1 << 40, in: [URL(fileURLWithPath: "/tmp")]) }
        #expect(!DiskGuard.ranOutError.localizedDescription.contains("\u{2014}"))
    }

    // MARK: Metadata

    @Test func everyLocationKeySpaceIsRecognised() {
        for id: AVMetadataIdentifier in [.quickTimeMetadataLocationISO6709, .quickTimeUserDataLocationISO6709, .commonIdentifierLocation,
                                         .quickTimeMetadataLocationName, .identifier3GPUserDataLocation] {
            let item = AVMutableMetadataItem()
            item.identifier = id
            #expect(AVSupport.isLocation(item), "\(id.rawValue)")
        }
        let date = AVMutableMetadataItem()
        date.identifier = .quickTimeMetadataCreationDate
        let model = AVMutableMetadataItem()
        model.identifier = .quickTimeMetadataModel
        #expect(!AVSupport.isLocation(date) && !AVSupport.isLocation(model))
        let place = AVMutableMetadataItem()
        place.identifier = .quickTimeMetadataLocationISO6709
        #expect(AVSupport.withoutLocation([date, place, model]).map(\.identifier) == [date.identifier, model.identifier])
    }

    // MARK: HDR metadata keys

    @Test func hdrKeysMatchTheSDKAndOnlyTravelWithHDR() {
        #expect(AVColorInfo.masteringDisplayKey == kVTCompressionPropertyKey_MasteringDisplayColorVolume as String)
        #expect(AVColorInfo.contentLightLevelKey == kVTCompressionPropertyKey_ContentLightLevelInfo as String)
        #expect(AVColorInfo.ambientViewingKey == kCMFormatDescriptionExtension_AmbientViewingEnvironment as String)
        let blob = Data([1, 2, 3, 4])
        let hdr = AVColorInfo(codec: kCMVideoCodecType_HEVC, primaries: AVVideoColorPrimaries_ITU_R_2020,
                              transfer: AVColorInfo.hlg, matrix: AVVideoYCbCrMatrix_ITU_R_2020, bitsPerComponent: 10,
                              masteringDisplay: blob, contentLightLevel: blob, ambientViewing: blob)
        #expect(hdr.hdrMetadataCompressionProperties.count == 3)
        var sdr = hdr
        sdr.transfer = AVVideoTransferFunction_ITU_R_709_2
        #expect(sdr.hdrMetadataCompressionProperties.isEmpty)
    }

    // MARK: One encode at a time

    @Test func gateRunsOneEncodeAtATime() async throws {
        let gate = HardwareEncodeGate()
        let log = VideoPlanLog()
        try await gate.acquire()
        #expect(gate.isEncoding)
        let second = Task {
            try await gate.acquire()
            log.add("second")
            gate.release()
        }
        try await Task.sleep(for: .milliseconds(60))
        log.add("first done")
        gate.release()
        try await second.value
        #expect(log.all == ["first done", "second"])
        #expect(!gate.isEncoding)
    }

    @Test func gateHandsOverInArrivalOrder() async throws {
        let gate = HardwareEncodeGate()
        let log = VideoPlanLog()
        try await gate.acquire()
        var tasks: [Task<Void, any Error>] = []
        for i in 0..<4 {
            tasks.append(Task { try await gate.withPermit { log.add("\(i)") } })
            try await Task.sleep(for: .milliseconds(20))
        }
        gate.release()
        for t in tasks { try await t.value }
        #expect(log.all == ["0", "1", "2", "3"])
        #expect(!gate.isEncoding)
    }

    @Test func cancellingAWaiterGivesUpItsPlace() async throws {
        let gate = HardwareEncodeGate()
        try await gate.acquire()
        let waiter = Task { try await gate.acquire() }
        try await Task.sleep(for: .milliseconds(30))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        gate.release()
        #expect(!gate.isEncoding, "a cancelled waiter must not end up holding the gate")
    }

    @Test func blockingCallersWaitForAsyncHolders() async throws {
        let gate = HardwareEncodeGate()
        let log = VideoPlanLog()
        try await gate.acquire()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            gate.withPermitBlocking { log.add("blocking") }
            done.signal()
        }
        try await Task.sleep(for: .milliseconds(50))
        log.add("async done")
        gate.release()
        await withCheckedContinuation { c in DispatchQueue.global().async { done.wait(); c.resume() } }
        #expect(log.all == ["async done", "blocking"])
        #expect(!gate.isEncoding)
    }

    // MARK: Is the hardware encoder busy elsewhere?

    private func availability(_ counts: [Int?], patience: Duration = .milliseconds(150)) -> EncoderAvailability {
        let feed = Feed(counts)
        return EncoderAvailability(openHardwareSessions: { feed.next() }, patience: patience, pollEvery: .milliseconds(10))
    }

    @Test func freeEncoderIsUsed() async throws {
        #expect(try await availability([0]).chooseRoute(softwareAvailable: true) == .hardware)
    }

    @Test func unknownEncoderStateCountsAsBusy() async throws {
        #expect(try await availability([nil]).chooseRoute(softwareAvailable: true) == .software, "fail safe")
        await #expect(throws: ConversionError.self) { try await availability([nil]).chooseRoute(softwareAvailable: false) }
        #expect(throws: ConversionError.self) { try availability([nil]).chooseRouteBlocking(softwareAvailable: false) }
    }

    @Test func blockingCheckWaitsToo() throws {
        #expect(try availability([2, 1, 0]).chooseRouteBlocking(softwareAvailable: false) == .hardware)
        #expect(throws: ConversionError.self) { try availability([1]).chooseRouteBlocking(softwareAvailable: false) }
    }

    @Test func onlyHEICAndAVIFStillsTakeTheGate() throws {
        #expect(HardwareImageEncode.needsGate(.heic) && HardwareImageEncode.needsGate(.avif))
        for format in [ImageFormat.jpeg, .png, .tiff, .gif, .bmp] { #expect(!HardwareImageEncode.needsGate(format)) }
        // A JPEG never waits, even with the encoder busy; a HEIC with the encoder busy stops before encoding.
        #expect(try HardwareImageEncode.run(.jpeg, availability: availability([1])) { 7 } == 7)
        var ran = false
        #expect(throws: ConversionError.self) { try HardwareImageEncode.run(.heic, availability: availability([1])) { ran = true } }
        #expect(!ran)
        #expect(try HardwareImageEncode.run(.heic, availability: availability([0])) { 8 } == 8)
        #expect(!HardwareEncodeGate.shared.isEncoding)
    }

    @Test func busyEncoderIsWaitedFor() async throws {
        #expect(try await availability([1, 1, 2, 0]).chooseRoute(softwareAvailable: false) == .hardware)
    }

    @Test func stillBusyFallsBackToSoftwareOrSaysSoPlainly() async throws {
        #expect(try await availability([1]).chooseRoute(softwareAvailable: true) == .software)
        do {
            _ = try await availability([1]).chooseRoute(softwareAvailable: false)
            Issue.record("should have refused")
        } catch {
            #expect(error.localizedDescription == EncoderAvailability.busyMessage)
            #expect(!EncoderAvailability.busyMessage.contains("\u{2014}"), "no em dashes in copy")
        }
    }

    @Test func waitingCanBeCancelled() async throws {
        let wait = availability([1], patience: .seconds(30))
        let task = Task { try await wait.chooseRoute(softwareAvailable: true) }
        try await Task.sleep(for: .milliseconds(40))
        let cancelledAt = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(cancelledAt) < 1)
    }

    /// Reads the IORegistry only (what `ioreg` prints); opens nothing.
    @Test func thisMacReportsItsEncoderClients() {
        let count = AVEStatus.userClientCount()
        #expect(count != nil, "the registry's class counts should be readable outside the sandbox")
        #expect((count ?? 0) >= 0)
    }
}

final class VideoPlanLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
}

/// Hands out counts in order, then repeats the last.
private final class Feed: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int?]
    init(_ values: [Int?]) { self.values = values }
    func next() -> Int? {
        lock.withLock { values.count > 1 ? values.removeFirst() : values.first ?? nil }
    }
}
