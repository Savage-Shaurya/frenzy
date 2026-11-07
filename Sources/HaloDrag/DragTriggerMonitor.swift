import AppKit
import os
import HaloCore

/// Why the monitor asked for the ring to go away.
public enum DragDismissReason: Sendable, Equatable {
    /// The trigger key stayed released for longer than the grace period.
    case triggerReleased
    /// The mouse button came up (the drop landed somewhere, possibly on the ring) or the drag was cancelled.
    case dragEnded
    /// `stop()` was called while the ring was up.
    case stopped
    /// The pointer travelled well away from a ring that opened on a pause: the user is dragging somewhere else.
    case pointerLeft
    /// A new window opened under a still pointer while a pause ring was up: a folder spring-loaded, so the user was
    /// waiting for that, not for the ring.
    case underlyingChanged
}

/// Detects "a file drag is in progress AND the trigger key is held" anywhere on the system, with no permissions.
///
/// Idle cost is zero timers: only a global mouse monitor is installed. A left mouse-down arms a short-lived poll
/// (`pollInterval`, 60 Hz by default) that runs only while the button stays down. Each tick reads
/// `NSEvent.pressedMouseButtons`, `NSEvent.modifierFlags` and the drag pasteboard's `changeCount`. A drag is live
/// when the change count moved since mouse-down while the button is still down; its pasteboard is read once per change.
/// See docs/DRAG-DETECTION.md.
@MainActor
public final class DragTriggerMonitor: DragTriggerMonitoring {
    public var trigger: TriggerKey
    public var onSummon: (([URL], NSPoint) -> Void)?
    public var onDismiss: (() -> Void)?

    /// Like `onSummon`, but with the full payload (file promises included). Fired just before `onSummon`.
    public var onSummonPayload: ((DragPayload, NSPoint) -> Void)?
    /// When true, drags that carry only file promises (Mail, Photos, browsers) summon too, with an empty URL list. So do
    /// raw image bytes, with the key only: rich-text and in-app drags carry those too, so a pause would misfire.
    /// Off by default: the app needs `onSummonPayload` to choose actions for promised types.
    public var summonsForFilePromises = false
    /// The trigger key went down during a drag of a bare web link, which can't be converted. Once per drag.
    public var onLinkDrag: (() -> Void)?
    /// True while the ring must stay up though the key is released: the pointer is on a wedge, so a drop there is what
    /// the user is about to do. Letting the key go a moment before the mouse must not drop the file on what's underneath.
    public var holdsOpen: (() -> Bool)?
    /// How long the trigger may be released before the ring is dismissed (a quick flick keeps it up).
    public var releaseGracePeriod: TimeInterval
    public let pollInterval: TimeInterval
    /// Open the ring when a file drag holds still for `pauseDuration`, with no key at all. The trigger key still
    /// opens it at once.
    public var opensOnPause = false
    public var pauseDuration: TimeInterval = 0.4
    /// How long a pause must last over ANOTHER app's window. Pausing over a browser's drop zone or a chat box usually
    /// means "about to drop here"; pausing there this long means they want the ring.
    public var otherAppPauseDuration: TimeInterval = 1.2
    /// After the ring closes, the key must come up, this much later, before it can open the ring again. Without this a
    /// finger relaxing for a moment, or one bad read of the key, blooms the ring a second time at a new spot.
    public var reopenCooldown: TimeInterval = 0.6
    /// Movement under this many points still counts as holding still (a hand is never perfectly steady).
    public var pauseTolerance: CGFloat = 6
    /// A ring opened on a pause closes when the pointer gets this far from where it opened.
    public var pauseLeaveDistance: CGFloat = 230
    /// True where a pause must not open the ring (over Halo's own window, which takes the drop itself).
    public var pauseBlocked: ((NSPoint) -> Bool)?
    /// The pointer on every tick while a ring opened on a pause is up.
    public var onPausePointer: ((NSPoint) -> Void)?
    /// Where the ring's centre is. Near a screen edge the ring is pushed away from the pointer, so "too far from where it
    /// opened" alone would close it on the way to a far wedge.
    public var pauseLeaveCenter: (() -> NSPoint?)?
    /// True while the ring is up because of a pause, not the key.
    public private(set) var summonedByPause = false

    /// Reason for the most recent `onDismiss`, set just before it fires.
    public private(set) var lastDismissReason: DragDismissReason?
    /// True while the monitor considers the ring summoned for the current drag.
    public private(set) var isSummoned = false
    /// The payload of the live file drag, if any.
    public private(set) var currentPayload: DragPayload?
    public private(set) var isRunning = false

    /// How the modifier keys read right now, for the log: a bad read is what would explain a ring closing by itself.
    public var flagDiagnostics: String { env.flagDiagnostics }

    private let env: any DragSystemEnvironment
    private enum State: Equatable {
        case idle
        /// Button down. `baseline` is the drag pasteboard change count when the button went down.
        case armed(baseline: Int)
    }
    private var state: State = .idle
    private var readChangeCount: Int?
    private var releaseDeadline: TimeInterval?
    /// Change count when the last button press ended: the baseline when the mouse-down itself was missed.
    private var idleChangeCount = 0
    private var pauseAnchor: NSPoint?
    private var pauseStart: TimeInterval = 0
    private var summonPoint = NSPoint.zero
    /// One pause per drag: after the ring closes the user has said no, so later hesitation leaves them alone.
    private var pauseSpent = false
    /// What was under the pointer when the current still spell passed `pauseDuration`, and when the ring opened.
    private var pauseTarget: PointerTarget?
    private var summonTarget: PointerTarget?
    private var nextTargetCheck: TimeInterval = 0
    /// The process in front when the drag's contents were first read: its windows get the short pause.
    private var sourcePID: Int32?
    private var lastTick: TimeInterval?
    /// Set when the ring closes: it can't reopen until the key has been seen up, on or after `reopenAt`.
    private var needsKeyUp = false
    private var reopenAt: TimeInterval = 0
    private var linkNoticed = false
    /// The poll read the button as up once. A real mouse-up reads the same on the next tick, or sends an event.
    private var buttonUpSeen = false
    /// When a session with a ring up last ended, so a drag event right after it counts as the same drag.
    private var ringSessionEndedAt: TimeInterval?
    /// How soon a drag event must follow for it to be the same physical drag, not a new one.
    private let sameDragWindow: TimeInterval = 1.5
    /// Shortest gap between ticks run by `leftMouseDragged` events.
    let minDragTickGap: TimeInterval = 0.008
    /// A tick this late means the main thread was stalled, so a deadline that passed in between proves nothing.
    private let stallGap: TimeInterval = 0.25

    public init(trigger: TriggerKey = .option,
                releaseGracePeriod: TimeInterval = 0.3,
                pollInterval: TimeInterval = 1.0 / 60.0,
                environment: (any DragSystemEnvironment)? = nil) {
        self.trigger = trigger
        self.releaseGracePeriod = releaseGracePeriod
        self.pollInterval = pollInterval
        self.env = environment ?? LiveDragSystemEnvironment()
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        idleChangeCount = env.dragPasteboardChangeCount
        env.installEventMonitors { [weak self] event in self?.handle(event) }
        // Started mid-drag (e.g. at login while the user is already dragging): pick it up.
        if env.isLeftMouseDown { arm(baseline: idleChangeCount) }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        env.removeEventMonitors()
        endSession(reason: .stopped)
    }

    // MARK: - State machine (internal so tests can drive it)

    func handle(_ event: DragSystemEvent) {
        guard isRunning else { return }
        switch event {
        case .leftMouseDown:
            // A fresh press: anything already on the drag pasteboard is stale. Armed already = we missed a mouse-up.
            if state != .idle { endSession(reason: .dragEnded) }
            arm(baseline: env.dragPasteboardChangeCount)
        case .leftMouseDragged:
            // Mouse-down was missed (secure input, our own tracking loop…): fall back to the idle baseline.
            // Otherwise react straight away rather than waiting for the next poll.
            if state == .idle {
                arm(baseline: idleChangeCount)
                // The session ended with a ring up and the drag is still going: that's one drag, with a bad reading in
                // the middle. The ring it closed stays closed, or it would bloom a second time.
                if let ended = ringSessionEndedAt, env.now - ended < sameDragWindow {
                    needsKeyUp = true
                    reopenAt = env.now + reopenCooldown
                    pauseSpent = true
                }
            } else if readChangeCount != nil, let lastTick, env.now - lastTick < minDragTickGap {
                // A gaming mouse sends drag events at up to 1000 Hz. Once the drag's contents are read, one tick per
                // `minDragTickGap` is plenty (the 60 Hz poll runs regardless). Before that, react at once.
                return
            } else {
                tick()
            }
        case .leftMouseUp:
            buttonUpSeen = true
            tick()
        }
    }

    private func arm(baseline: Int) {
        state = .armed(baseline: baseline)
        readChangeCount = nil
        currentPayload = nil
        releaseDeadline = nil
        pauseAnchor = nil
        pauseSpent = false
        pauseTarget = nil
        summonTarget = nil
        sourcePID = nil
        lastTick = nil
        needsKeyUp = false
        linkNoticed = false
        buttonUpSeen = false
        env.startTicking(interval: pollInterval) { [weak self] in self?.tick() }
        tick()
    }

    func tick() {
        guard case .armed(let baseline) = state else { return }
        guard env.isLeftMouseDown else {
            // In a background app this can read wrong for a moment, and ending the session closes the ring. One reading
            // isn't enough; a real mouse-up also reads "up" on the next tick, 16 ms later.
            if buttonUpSeen { endSession(reason: .dragEnded) } else { buttonUpSeen = true }
            return
        }
        buttonUpSeen = false
        let now = env.now
        let tickGap = lastTick.map { now - $0 } ?? 0
        lastTick = now
        let count = env.dragPasteboardChangeCount
        if count != baseline, count != readChangeCount {
            // A drag wrote to the pasteboard after the button went down: read it once per change.
            readChangeCount = count
            let payload = env.readDragPayload()
            currentPayload = payload.isEmpty ? nil : payload
            sourcePID = env.frontmostProcessID
        }
        let held = env.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(trigger.flags)
        if needsKeyUp, !held, now >= reopenAt { needsKeyUp = false }

        if isSummoned, summonedByPause {
            let point = env.mouseLocation
            onPausePointer?(point)
            if isPastLeaveDistance(point) {
                dismiss(.pointerLeft)
            } else if underlyingWindowChanged(under: point, now: now) {
                dismiss(.underlyingChanged)
            }
        } else if isSummoned {
            if held || holdsOpen?() == true {
                releaseDeadline = nil
            } else if let deadline = releaseDeadline {
                if tickGap >= stallGap {
                    // We weren't looking. The next reading decides, with a full grace period.
                    releaseDeadline = now + releaseGracePeriod
                } else if now >= deadline {
                    dismiss(.triggerReleased)
                }
            } else {
                releaseDeadline = now + releaseGracePeriod
                if releaseGracePeriod <= 0 { dismiss(.triggerReleased) }
            }
        } else if let payload = currentPayload {
            if held, !needsKeyUp, opensOnKey(payload) {
                summon(payload, byPause: false)
            } else if held, payload.isLinkOnly, !linkNoticed {
                linkNoticed = true
                onLinkDrag?()
            } else if opensOnPause, !pauseSpent, opensOnPause(payload), hasPaused(payload) {
                summon(payload, byPause: true)
            }
        }
    }

    private func opensOnKey(_ payload: DragPayload) -> Bool {
        !payload.fileURLs.isEmpty || (summonsForFilePromises && (payload.hasFilePromises || payload.inlineImageType != nil))
    }

    private func opensOnPause(_ payload: DragPayload) -> Bool {
        !payload.fileURLs.isEmpty || (summonsForFilePromises && payload.hasFilePromises)
    }

    private func isPastLeaveDistance(_ point: NSPoint) -> Bool {
        func far(_ other: NSPoint) -> Bool { hypot(point.x - other.x, point.y - other.y) > pauseLeaveDistance }
        return far(summonPoint) && (pauseLeaveCenter?().map(far) ?? true)
    }

    /// A folder spring-loads under a still pointer: a new window appears beneath the pause ring. Only 4 times a second.
    private func underlyingWindowChanged(under point: NSPoint, now: TimeInterval) -> Bool {
        guard now >= nextTargetCheck, let summonTarget,
              hypot(point.x - summonPoint.x, point.y - summonPoint.y) <= pauseTolerance * 4 else { return false }
        nextTargetCheck = now + 0.25
        let current = env.pointerTarget(at: point)
        if case .window(_, let pid) = current, pid == env.ownProcessID { return false } // a result card just appeared
        return current != summonTarget
    }

    private func summon(_ payload: DragPayload, byPause: Bool) {
        isSummoned = true
        summonedByPause = byPause
        releaseDeadline = nil
        let point = env.mouseLocation
        summonPoint = point
        summonTarget = byPause ? (pauseTarget ?? env.pointerTarget(at: point)) : nil
        nextTargetCheck = env.now + 0.25
        onSummonPayload?(payload, point)
        onSummon?(payload.fileURLs, point)
    }

    /// True once the pointer has held still for long enough, somewhere a ring is welcome.
    private func hasPaused(_ payload: DragPayload) -> Bool {
        let point = env.mouseLocation
        guard let anchor = pauseAnchor, hypot(point.x - anchor.x, point.y - anchor.y) <= pauseTolerance else {
            pauseAnchor = point
            pauseStart = env.now
            pauseTarget = nil
            return false
        }
        let elapsed = env.now - pauseStart
        guard elapsed >= pauseDuration else { return false }
        // Frenzy's window takes real files itself. It can't take a promise, so a promise still gets the ring there.
        if !payload.fileURLs.isEmpty, pauseBlocked?(point) ?? false {
            if pauseTarget == nil {
                Logger(subsystem: "com.snappycrew.frenzy", category: "app").notice("Pause check: blocked by Frenzy's window")
            }
            return false
        }
        let target = pauseTarget ?? env.pointerTarget(at: point)
        if pauseTarget == nil {
            let own = env.ownProcessID
            let source = sourcePID ?? -1
            Logger(subsystem: "com.snappycrew.frenzy", category: "app")
                .notice("Pause check: target \(String(describing: target), privacy: .public), source \(source), own \(own)")
        }
        pauseTarget = target
        switch target {
        case .blocked: return false
        case .desktop: return true
        case .window(_, let pid):
            if pid == env.ownProcessID || sourcePID == nil || pid == sourcePID { return true }
            return elapsed >= otherAppPauseDuration
        }
    }

    private func dismiss(_ reason: DragDismissReason) {
        isSummoned = false
        summonedByPause = false
        pauseSpent = true
        releaseDeadline = nil
        needsKeyUp = true
        reopenAt = env.now + reopenCooldown
        lastDismissReason = reason
        onDismiss?()
    }

    private func endSession(reason: DragDismissReason) {
        let wasSummoned = isSummoned
        ringSessionEndedAt = wasSummoned ? env.now : nil
        state = .idle
        env.stopTicking()
        idleChangeCount = env.dragPasteboardChangeCount
        readChangeCount = nil
        currentPayload = nil
        if wasSummoned { dismiss(reason) }
    }
}
