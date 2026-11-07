import Foundation
import HaloCore
import os

/// One hardware encode at a time, across the whole process.
///
/// Why: the founder's Mac kernel-panicked three times on 7 Nov 2026 (DART fault on dart-ave0). It matches a known Apple
/// driver bug (Apple Developer Forums thread 831532, FB23045975): the Apple Video Encoder faults when more than one
/// hardware encode session is open at the same time. See `docs/VIDEO-SAFETY.md`.
///
/// Every video encode (`AVTranscoder`, export-session re-encodes in `VideoActions`) and every ImageIO encode that can
/// reach the hardware HEVC encoder (HEIC, AVIF) must run inside this gate, batches included. The gate is held until the
/// writer has completely finished or completely cancelled, never released while frames may still be in flight.
final class HardwareEncodeGate: @unchecked Sendable {
    static let shared = HardwareEncodeGate()

    private let condition = NSCondition()
    private var held = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    /// True while an encode holds the gate. The worker can check this before exiting on its own (memory watchdog,
    /// an abandoned connection), so it never quits mid-encode.
    var isEncoding: Bool { condition.withLock { held } }

    /// Waits (first come, first served) for the gate. Cancelling the waiting task gives up its place and throws.
    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                condition.lock()
                if Task.isCancelled {
                    condition.unlock()
                    return c.resume(throwing: CancellationError())
                }
                if !held {
                    held = true
                    condition.unlock()
                    return c.resume()
                }
                waiters.append((id, c))
                condition.unlock()
            }
        } onCancel: {
            condition.lock()
            let index = waiters.firstIndex { $0.id == id }
            let waiter = index.map { waiters.remove(at: $0) }
            condition.unlock()
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// For synchronous encoders (ImageIO, test fixtures on their own queue). Blocks the calling thread: never call it
    /// from Swift's cooperative pool.
    func acquireBlocking() {
        condition.lock()
        while held { condition.wait() }
        held = true
        condition.unlock()
    }

    /// Hands the gate to the next async waiter, or frees it for a blocking one.
    func release() {
        condition.lock()
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            condition.unlock()
            next.continuation.resume() // `held` stays true: handed over
            return
        }
        held = false
        condition.broadcast()
        condition.unlock()
    }

    func withPermit<T>(_ body: () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await body()
    }

    func withPermitBlocking<T>(_ body: () throws -> T) rethrows -> T {
        acquireBlocking()
        defer { release() }
        return try body()
    }
}

/// Is any other process (a browser on a video call, a screen recorder) already using the hardware video encoder?
///
/// The count comes from `AVEStatus.userClientCount()` (SoftwareVideoEncoding.swift), the app's one reader of the
/// IORegistry: what `ioreg -l -w0 -d2 | grep AppleAVE2UserClient` prints. Reading it opens nothing and encodes nothing.
///
/// Fail safe: a count that can't be read counts as busy. Video then goes to Apple's software encoder; encodes that have
/// no software route (export sessions, HEIC and AVIF images) stop with a plain message instead.
struct EncoderAvailability: Sendable {
    /// Open hardware encoder clients on the whole Mac, nil when macOS won't say.
    var openHardwareSessions: @Sendable () -> Int?
    /// How long to wait for the encoder to come free before falling back or giving up.
    var patience: Duration = .seconds(15)
    var pollEvery: Duration = .milliseconds(500)

    static let live = EncoderAvailability(openHardwareSessions: { AVEStatus.userClientCount() })

    enum Route: Equatable, Sendable {
        /// The hardware encoder was free: use it, inside the gate.
        case hardware
        /// It stayed busy, or its state couldn't be read: Apple's software encoder. Slower, never touches the chip.
        case software
    }

    static let busyMessage = "Another app is using your Mac's video encoder right now, for example a browser on a video call. Frenzy waited so your Mac stays stable. Close that app's video, then try again."
    static var busyError: ConversionError { .engine(busyMessage) }

    private static let log = Logger(subsystem: "com.snappycrew.halo", category: "video-encoder")

    private enum Look { case free, busy, unknown }

    private func look() -> Look {
        guard let open = openHardwareSessions() else { return .unknown }
        return open == 0 ? .free : .busy
    }

    private func giveUp(_ look: Look, softwareAvailable: Bool) throws -> Route {
        if softwareAvailable {
            Self.log.notice("Hardware video encoder \(look == .unknown ? "state unknown" : "stayed busy", privacy: .public); using the software encoder")
            return .software
        }
        throw Self.busyError
    }

    /// Waits while the hardware encoder is busy elsewhere. Call it while holding `HardwareEncodeGate`, so the only
    /// sessions it can see belong to other apps (or our own last one, still closing).
    func chooseRoute(softwareAvailable: Bool) async throws -> Route {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: patience)
        while true {
            try Task.checkCancellation()
            let state = look()
            switch state {
            case .free: return .hardware
            case .unknown: return try giveUp(state, softwareAvailable: softwareAvailable)
            case .busy: if clock.now >= deadline { return try giveUp(state, softwareAvailable: softwareAvailable) }
            }
            try await Task.sleep(for: pollEvery)
        }
    }

    /// The same, for synchronous encoders (ImageIO). Blocks the calling thread while it waits.
    func chooseRouteBlocking(softwareAvailable: Bool) throws -> Route {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: patience)
        let step = Double(pollEvery.components.seconds) + Double(pollEvery.components.attoseconds) / 1e18
        while true {
            try Task.checkCancellation()
            let state = look()
            switch state {
            case .free: return .hardware
            case .unknown: return try giveUp(state, softwareAvailable: softwareAvailable)
            case .busy: if clock.now >= deadline { return try giveUp(state, softwareAvailable: softwareAvailable) }
            }
            Thread.sleep(forTimeInterval: step)
        }
    }
}

/// HEIC and AVIF stills go through the hardware HEVC/AV1 path on Apple silicon, so they share the video gate and the
/// busy check. ImageIO can't be pinned to software: a busy or unknown encoder ends in the plain busy message.
enum HardwareImageEncode {
    /// Test runs never open the hardware encoder unless asked for (FRENZY_HEIC_TESTS=1): a HEIC/AVIF write inside a test
    /// process stops with this message, so a test that would touch the chip shows up instead of slipping through.
    static let testBlockMessage = "HEIC/AVIF writing is off in test runs (it uses the hardware video encoder): FRENZY_HEIC_TESTS=1"
    static let blockedInTests: Bool = {
        let name = ProcessInfo.processInfo.processName
        let testing = name == "swiftpm-testing-helper" || name == "xctest" || name.hasSuffix("PackageTests")
        return testing && ProcessInfo.processInfo.environment["FRENZY_HEIC_TESTS"] != "1"
    }()

    static func needsGate(_ format: ImageFormat) -> Bool { format == .heic || format == .avif }

    /// Runs `body` (one ImageIO encode) holding the gate when `format` can reach the hardware encoder.
    ///
    /// Blocks the calling thread while waiting. That is safe from the image converters even though they run on Swift's
    /// cooperative pool: `ConcurrencyLimiter.shared` lets at most half the cores' worth of jobs run at once, so a
    /// gate holder always has pool threads left to finish on.
    static func run<T>(_ format: ImageFormat, availability: EncoderAvailability = .live, _ body: () throws -> T) throws -> T {
        guard needsGate(format) else { return try body() }
        return try HardwareEncodeGate.shared.withPermitBlocking {
            _ = try availability.chooseRouteBlocking(softwareAvailable: false)
            return try body()
        }
    }
}
