import AppKit
import Combine
import SwiftUI
import os
import HaloCore
import HaloConverters
import HaloUI
import HaloDrag
import UniformTypeIdentifiers

/// All of Halo's wiring in one place:
///
///     DragTriggerMonitoring.onSummon(urls, point)            (via DragCoordinator)
///       -> ringContent(for:)  [InputFile] -> registry.actions(for:limit: settings.maxRingItems) -> [RingItem]
///       -> RingOverlayPresenting.present(...)                (empty list = no ring, see ringContent)
///       -> onDrop(actionID, urls) -> startJob(...)
///       -> ConversionBackend.run: the sandboxed XPC worker converts into its container, then the app places the
///          results next to the originals, or in Downloads when that's impossible (XPCConversionBackend, StagedPlacement)
///       -> per-job cards (progress with a plain-language stage and Cancel, then the result card or the failure),
///          recent conversions
///
/// Every job is a tracked Task, so Cancel, Quit and logout can stop it and wait for its cleanup.
/// Concrete types come from `Integration`; this class only holds protocols plus the coordinator.
@MainActor
final class AppController: NSObject, NSMenuDelegate {
    let settings: HaloSettings
    let registry: ActionRegistry
    let backend: any ConversionBackend
    let toasts: any JobToastPresenting
    let recents = RecentConversions()
    let usedFolders = UsedFolders()
    let launchAtLogin = LaunchAtLogin()
    let windows = WindowPresenter()
    /// The onboarding "Try it once" step's state, made the first time onboarding opens.
    private var onboardingTry: OnboardingTry?
    /// Bumped each time onboarding opens from closed, so it starts again at Welcome.
    private var onboardingOpens = 0
    /// The main window's state (drop zone, formats, recents).
    let home = HomeModel()
    private(set) var drag: DragCoordinator!

    private let log = Logger(subsystem: "com.snappycrew.frenzy", category: "app")
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []
    /// Last "no conversions" notice, so one long drag doesn't repeat it.
    private var lastNoMatch: (urls: Set<URL>, date: Date)?
    /// Clears the main window's notice a few seconds after it appears.
    private var noticeTimer: Task<Void, Never>?
    /// Outputs of jobs still showing their "Done" row. Recent hides them until that row goes, so a result never
    /// appears twice.
    private var outputsShowingDone: [String: Set<URL>] = [:]
    /// Failed jobs still listed in the window, by job key: what Try Again runs.
    private var failedJobs: [String: (action: ActionID, urls: [URL])] = [:]
    /// Running conversions. Kept so Cancel, Quit and logout can stop them and wait for cleanup.
    private var jobs: [UUID: Task<Void, Never>] = [:]
    /// Held while any job runs: keeps the Mac from idle-sleeping mid-conversion and tells macOS work is in flight.
    private var activity: (any NSObjectProtocol)?
    /// Where files from Photos, Mail and browsers wait while they convert.
    let inbox = PromiseInbox()
    /// Where outputs go when they can't or shouldn't go next to the original.
    private lazy var savePolicy = SavePolicy.standard(inbox: inbox.root)
    /// Times the Mac has woken from sleep since launch. A job that spans a change may have been broken by the sleep.
    private var wakeCount = 0
    private var wakeObserver: (any NSObjectProtocol)?
    /// "Finish, Then Quit" was chosen: quit once the last job ends.
    private var quitsWhenDone = false

    var activeJobs: Int { jobs.count }

    private(set) var isPaused: Bool {
        get { defaults.bool(forKey: "halo.paused") }
        set { defaults.set(newValue, forKey: "halo.paused") }
    }

    init(settings: HaloSettings = Integration.makeSettings(),
         registry: ActionRegistry = DefaultActions.registry(),
         backend: (any ConversionBackend)? = nil,
         monitor: any DragTriggerMonitoring = Integration.makeMonitor(),
         overlay: any RingOverlayPresenting = Integration.makeOverlay(),
         toasts: (any JobToastPresenting)? = nil) {
        self.settings = settings
        self.registry = registry
        self.backend = backend ?? Integration.makeBackend(registry: registry)
        self.toasts = toasts ?? Integration.makeToasts(settings: settings)
        super.init()
        drag = Integration.makeDragCoordinator(
            monitor: monitor, overlay: overlay,
            itemsFor: { [weak self] urls in self?.ringContent(for: urls) ?? ([], "") },
            onConvert: { [weak self] id, urls in self?.handleDrop(id, urls: urls) })
        drag.centerSymbolFor = { [weak self] in self?.centerSymbol(for: $0) }
        drag.promisedItemsFor = { [weak self] types in self?.promisedRingContent(for: types) ?? ([], "") }
        drag.promisedSymbolFor = { types in types.allSatisfy { UTType($0)?.conforms(to: .image) == true } ? "photo" : nil }
        drag.onLinkDrag = { [weak self] in
            self?.toasts.showNotice("This is a link, not a file",
                                    message: "Frenzy never downloads anything. Save it to your Mac first, then drag the file.")
        }
        if let ring = overlay as? RingOverlayController {
            ring.promiseDestination = inbox.root
            ring.onPromiseDelivery = { [weak self] event in self?.promiseDelivery(event) }
        }
        // A light tick as the pointer crosses into a new wedge. Felt only through a Force Touch trackpad.
        (overlay as? RingOverlayController)?.onHoverChange = { index in
            guard index != nil else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    // MARK: Lifecycle

    /// `showWindow` is false for a launch at login: Halo then starts quietly in the menu bar.
    func start(showWindow: Bool = true) {
        installStatusItem()
        MainMenu.install(controller: self)
        setUpHome()

        drag.trigger = settings.trigger
        if let monitor = drag.monitor as? DragTriggerMonitor {
            monitor.opensOnPause = settings.opensOnPause
            monitor.pauseBlocked = { [weak self] point in
                // Only when Frenzy's window is the one actually under the pointer. An open window covered by Finder or
                // another app must not block the ring there.
                guard let window = self?.windows.window(id: "home"), window.isVisible, window.frame.contains(point) else { return false }
                return NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == window.windowNumber
            }
            settings.$opensOnPause
                .sink { [weak self, weak monitor] on in
                    MainActor.assumeIsolated {
                        monitor?.opensOnPause = on
                        // @Published fires before the value is stored, so the tooltip reads it a turn later.
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateStatusButton() } }
                    }
                }
                .store(in: &cancellables)
        }
        if !isPaused { drag.start() }
        // Build the ring once now, off screen: the first ring after launch then opens in about 18 ms instead of 28 ms
        // (measured), so it doesn't hold up the drag while SwiftUI and the glass set themselves up.
        if let ring = drag.overlay as? RingOverlayController {
            let sample = RingItem.fitted(registry.all.prefix(settings.maxRingItems).map(RingItem.init), limit: settings.maxRingItems)
            DispatchQueue.main.async { MainActor.assumeIsolated { ring.prewarm(with: sample) } }
        }

        settings.$trigger
            .sink { [weak self] key in MainActor.assumeIsolated { self?.triggerChanged(key) } }
            .store(in: &cancellables)
        // "Show file previews" off: the ring's centre keeps Finder's icon (the window and cards read the setting).
        if let ring = (drag.overlay as? RingOverlayController)?.model {
            settings.$showPreviews
                .sink { shows in MainActor.assumeIsolated { ring.showsThumbnails = shows } }
                .store(in: &cancellables)
        }

        // Launch at login: the Settings toggle drives SMAppService, and the toggle always shows the real state.
        settings.syncLaunchAtLogin(launchAtLogin.isEnabled)
        settings.onLaunchAtLoginChange = { [weak self] wanted in
            guard let self else { return }
            let actual = self.launchAtLogin.setEnabled(wanted)
            // Defer so we don't write the @Published value from inside its own didSet.
            DispatchQueue.main.async { MainActor.assumeIsolated { self.settings.syncLaunchAtLogin(actual) } }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.wakeCount += 1
                self.log.notice("Mac woke with \(self.jobs.count) conversions running")
            }
        }
        sweepLeftovers()
        if !settings.hasCompletedOnboarding { showOnboarding() } else if showWindow { showHome() }
        log.notice("Frenzy started: \(self.registry.all.count) actions, backend: \(String(describing: type(of: self.backend)), privacy: .public), paused: \(self.isPaused)")
        // The button has no real frame until the menu bar lays it out (it logs {38, 0} right here), so measure later.
        checkStatusItemVisibility(after: .seconds(2), attemptsLeft: 4)
    }

    /// Logs where the menu-bar icon really is, and tells the user once per launch if macOS hid it (a full menu bar
    /// on a notched MacBook puts extra icons under the camera; System Settings can also hide it).
    private func checkStatusItemVisibility(after delay: Duration, attemptsLeft: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, let window = self.statusItem?.button?.window else { return }
            let screens = NSScreen.screens.map {
                MenuBarIconVisibility.Screen(frame: $0.frame, notchLeft: $0.auxiliaryTopLeftArea, notchRight: $0.auxiliaryTopRightArea)
            }
            let result = MenuBarIconVisibility.classify(iconFrame: window.frame, screens: screens,
                                                        occlusionVisible: window.occlusionState.contains(.visible),
                                                        menuBarShown: NSMenu.menuBarVisible())
            self.log.notice("Status icon: \(String(describing: result), privacy: .public), frame: \(NSStringFromRect(window.frame), privacy: .public)")
            if result == .notLaidOut, attemptsLeft > 1 {
                self.checkStatusItemVisibility(after: .seconds(3), attemptsLeft: attemptsLeft - 1)
            } else if result.isHidden {
                // No card asking the user to change settings: Frenzy has a Dock icon, and dragging works anyway.
                self.log.notice("Status icon hidden by macOS; the Dock icon still opens Frenzy")
            }
        }
    }

    func stop() {
        drag.stop()
        (backend as? XPCConversionBackend)?.shutdown()
        inbox.removeAll()
    }

    /// Removes scratch files (".halo-<uuid>…") older than an hour that a crash or force quit left behind, only in
    /// folders Halo recorded as used. The worker sweeps its own staging folder when it starts.
    private func sweepLeftovers() {
        // Not Desktop, Documents or Downloads: reading those at launch makes macOS ask for permission out of nowhere.
        // A leftover there is swept the next time the user converts something in that folder.
        let folders = usedFolders.all.filter { !PrivacyFolders.isProtected($0) }
        let log = self.log
        let inbox = self.inbox
        Task.detached(priority: .utility) {
            inbox.sweep()
            let removed = TempSweeper.sweep(folders: folders)
            if !removed.isEmpty { log.notice("Removed \(removed.count) leftover temp files") }
        }
    }

    private func triggerChanged(_ key: TriggerKey) {
        drag.trigger = key
        updateStatusButton(trigger: key)
    }

    // MARK: Summon and drop

    /// Selections larger than this resolve types from extensions only (no per-file disk access on the main thread).
    static let inspectLimit = 50
    /// Longest the ring may wait for the disk while the user is mid-drag. Past this, types come from names alone: a slow
    /// or vanished share can't freeze the drag. The job re-checks the real types off the main thread.
    static let summonBudget: TimeInterval = 0.08
    /// The inputs from the last summon, so the centre glyph needn't ask the disk again on the same turn.
    private var lastSummon: (urls: [URL], inputs: [InputFile])?

    /// What the ring shows for a drag of `urls`.
    ///
    /// When no action fits we return no items, so no ring appears. An empty ring would sit under the cursor and
    /// catch the drop, stealing it from the folder or app the user is really dragging to. Instead a short notice
    /// explains why nothing appeared, since the user deliberately held the trigger key.
    func ringContent(for urls: [URL]) -> (items: [RingItem], centerLabel: String) {
        guard !isPaused else { return ([], "") }
        let (inputs, complete) = InputFile.resolveWithinBudget(Self.summonBudget, urls, inspectLimit: Self.inspectLimit)
        lastSummon = (urls, inputs)
        // Every fitting action, so a ring too small for them ends in a "More" wedge instead of hiding some.
        let actions = inputs.isEmpty ? [] : registry.actions(for: inputs, limit: .max)
        log.notice("Summon: \(urls.count) dragged, \(inputs.count) recognised, \(actions.count) actions\(complete ? "" : " (disk slow, names only)", privacy: .public)")
        guard !actions.isEmpty else {
            // Holding the key is a question and deserves an answer. A pause is just a pause: stay out of the way.
            // The disk didn't answer in time and some items had no telling name (a folder, say): they may well convert,
            // so don't say they can't.
            if !summonedByPause { notifyNoMatch(urls: urls, inputs: inputs, complete: complete) }
            return ([], "")
        }
        return (RingItem.fitted(actions.map(RingItem.init), limit: settings.maxRingItems), Self.subject(for: inputs))
    }

    private var summonedByPause: Bool { (drag.monitor as? DragTriggerMonitor)?.summonedByPause ?? false }

    /// What the ring shows for files another app has only promised so far (Photos, Mail, a browser).
    func promisedRingContent(for types: [String]) -> (items: [RingItem], centerLabel: String) {
        guard !isPaused else { return ([], "") }
        let actions = PromisedChoices.actions(forTypes: types, registry: registry)
        log.notice("Summon: \(types.count) promised (\(Set(types).joined(separator: ","), privacy: .public)), \(actions.count) actions")
        guard !actions.isEmpty else {
            if !summonedByPause {
                toasts.showNotice("Frenzy can't tell what this is", message: "Save it to Finder first, then drag the file.")
            }
            return ([], "")
        }
        return (RingItem.fitted(actions.map(RingItem.init), limit: settings.maxRingItems), PromisedChoices.subject(forTypes: types))
    }

    /// The card while another app hands over a promised file. It can take a while (Photos may fetch an original from
    /// iCloud), and without this the drop would seem to have done nothing. Each drop has its own card and source name.
    private func promiseDelivery(_ event: PromiseDeliveryEvent) {
        switch event {
        case .began(let drop, let action, let count, let cancel):
            let key = Self.promiseKey(drop)
            let source = NSWorkspace.shared.frontmostApplication?.localizedName ?? "the other app"
            promiseSources[drop] = source
            let title = registry.action(action)?.title ?? "Convert"
            toasts.showProgress(job: key, title: "\(title): \(count == 1 ? "1 file" : "\(count) files")",
                                stage: "Getting \(count == 1 ? "it" : "them") from \(source)…", file: nil, fraction: 0,
                                onCancel: { MainActor.assumeIsolated { cancel() } })
        case .ended(let drop, let received, let expected, let cancelled):
            toasts.dismiss(job: Self.promiseKey(drop))
            let source = promiseSources.removeValue(forKey: drop) ?? "The other app"
            if cancelled { return }
            if received == 0 {
                toasts.showFailure("Couldn't get the file", message: "\(source) didn't hand it over. Save it to Finder first, then drag the file.")
            } else if received < expected {
                toasts.showNotice("Got \(received) of \(expected) files", message: "\(source) didn't hand over the rest. Frenzy is converting the ones it got.")
            }
        case .couldNotReceive(let drop, let expected):
            toasts.dismiss(job: Self.promiseKey(drop))
            promiseSources[drop] = nil
            log.error("Promised drop: no room in the inbox for \(expected) files")
            toasts.showFailure("Couldn't make room for \(expected == 1 ? "the file" : "the files")",
                               message: "Frenzy couldn't write to its temporary folder. Free up some disk space, then try again.")
        }
    }
    /// The app each promised drop comes from, by drop.
    private var promiseSources: [UUID: String] = [:]

    nonisolated static func promiseKey(_ drop: UUID) -> String { "promise-\(drop.uuidString)" }

    private func handleDrop(_ id: ActionID, urls: [URL]) {
        // "More": the window lists every choice for these files (the same path as a drop on it).
        if id == RingItem.moreID, !urls.isEmpty {
            showHome()
            homeDropped(urls)
            return
        }
        guard let action = registry.action(id), !urls.isEmpty else {
            inbox.remove(abandoned: urls, keeping: inboxFilesKept)
            toasts.showFailure("Couldn't convert", message: "Frenzy didn't receive the files. Try the drag again.")
            return
        }
        startJob(action, urls: urls)
    }

    /// Starts a tracked conversion job. Input types are resolved off the main thread, and where the results will go is
    /// worked out before any work: a job with nowhere to save stops now, not after converting.
    func startJob(_ action: ConversionAction, urls: [URL]) {
        let id = UUID()
        let policy = savePolicy
        let inbox = self.inbox
        let promised = urls.filter(inbox.contains)
        inboxFilesInJobs[id] = promised.isEmpty ? nil : promised
        if jobs.isEmpty {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                              reason: "Converting files")
        }
        jobs[id] = Task { [weak self] in
            let (allInputs, plan) = await Task.detached(priority: .userInitiated) { () -> ([InputFile], SavePolicy.Plan) in
                let inputs = urls.compactMap(InputFile.init(url:))
                return (inputs, policy.plan(forFolders: inputs.map { $0.url.deletingLastPathComponent() }))
            }.value
            defer {
                inbox.remove(dropsHolding: urls)
                self?.inboxFilesInJobs[id] = nil
            }
            guard let self else { return }
            // Files from another app can differ from what it promised: a Live Photo is a picture and a movie.
            let fromApp = urls.contains(where: inbox.contains)
            let fitted = fromApp ? PromisedChoices.fitting(action, inputs: allInputs) : (kept: allInputs, leftOut: 0)
            let inputs = fitted.kept
            if inputs.isEmpty || !action.accepts(inputs) {
                self.toasts.showFailure("Couldn't convert", message: allInputs.isEmpty
                    ? "Frenzy didn't receive the files. Try the drag again."
                    : "These files don't fit \(action.title).")
            } else if case .nowhere = plan {
                self.toasts.showFailure("Couldn't convert \(Self.subject(for: inputs))",
                                        message: FailureText.nowhereToSave(fallbackName: Self.displayName(SavePolicy.downloads)))
            } else {
                if fitted.leftOut > 0 {
                    self.toasts.showNotice("Skipped \(fitted.leftOut) of \(allInputs.count) files", message: "They don't fit \(action.title).")
                }
                await self.convert(action, inputs: inputs, job: id)
            }
            self.jobFinished(id)
        }
    }

    private func jobFinished(_ id: UUID) {
        jobs[id] = nil
        if jobs.isEmpty, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        // A beat to see the result before the app goes.
        if jobs.isEmpty, quitsWhenDone {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                if let self, self.jobs.isEmpty, self.quitsWhenDone { NSApp.terminate(nil) }
            }
        }
    }

    nonisolated private static func displayName(_ folder: URL) -> String {
        FileManager.default.displayName(atPath: folder.path)
    }

    /// Cancels one job (the toast's Cancel button).
    func cancelJob(_ id: UUID) { jobs[id]?.cancel() }

    /// Cancels every job and waits (up to `timeout`) for them to clean up. Used at quit and logout.
    func cancelAllAndWait(timeout: Duration = .seconds(10)) async {
        let running = Array(jobs.values)
        guard !running.isEmpty else { return }
        log.notice("Cancelling \(running.count) running conversions")
        running.forEach { $0.cancel() }
        let gate = OneShot()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            gate.set(c)
            Task { for task in running { await task.value }; gate.fire() }
            Task { try? await Task.sleep(for: timeout); gate.fire() }
        }
    }

    /// Runs one conversion and reports it. Progress flows through an AsyncStream consumed on the main actor, so
    /// updates arrive in order, never go backwards, and none can land after the result. Each update carries a
    /// plain-language stage (`JobStage`); a ticker re-checks it every second, so a job that stops moving (at 0 % or
    /// partway) says so instead of sitting on a frozen line.
    func convert(_ action: ConversionAction, inputs: [InputFile], job id: UUID) async {
        let key = id.uuidString
        let subject = Self.subject(for: inputs)
        let progressTitle = "\(action.title): \(subject)"
        let file = inputs.count == 1 ? inputs[0].url : nil
        let firstRun = registry.usage.count(for: action.id) == 0
        let started = Date()
        let onCancel: () -> Void = { [weak self] in self?.cancelJob(id) }
        // Remember the folders Halo writes into, so a crash's leftovers can be swept at next launch.
        let folders = Array(Set(inputs.map { $0.url.deletingLastPathComponent() })).filter { !inbox.contains($0) }
        usedFolders.record(folders)
        // The user just dropped from these, so macOS has already allowed them.
        Task.detached(priority: .utility) { _ = TempSweeper.sweep(folders: folders.filter { PrivacyFolders.isProtected($0) }) }
        let progress = ProgressBox()
        let stageLine: @MainActor (Double) -> String = { fraction in
            if let special = progress.specialStage { return special }
            let now = Date()
            return JobStage.line(for: action.id, fraction: fraction, elapsed: now.timeIntervalSince(started),
                                 sinceProgress: now.timeIntervalSince(progress.movedAt), firstRun: firstRun)
        }
        let report: @MainActor (Double) -> Void = { [weak self] fraction in
            // The line follows the newest fraction, even a move too small to redraw the bar.
            let stage = stageLine(max(fraction, progress.latest))
            progress.stage = stage
            self?.toasts.showProgress(job: key, title: progressTitle, stage: stage, file: file, fraction: fraction, onCancel: onCancel)
            self?.updateHomeJob(key, .working(fraction), stage: stage)
        }
        home.jobs.insert(HomeJob(id: key, title: action.title, subject: subject, state: .working(0),
                                 stage: JobStage.line(for: action.id, fraction: 0, elapsed: 0, firstRun: firstRun)), at: 0)
        report(0)

        let (stream, continuation) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
        let consumer = Task { @MainActor in
            for await fraction in stream {
                // Any forward move counts as moving, even one too small to redraw the bar.
                if fraction > progress.latest { progress.latest = fraction; progress.movedAt = Date() }
                guard fraction >= progress.shown + 0.01 || (fraction >= 1 && progress.shown < 1) else { continue }
                progress.shown = fraction
                report(fraction)
            }
        }
        // Progress stood still for a while: say so honestly. Only a changed line is shown, so this costs nothing
        // while the job moves. Cancelled before the result, so it can never land after it.
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled, stageLine(progress.latest) != progress.stage { report(progress.shown) }
            }
        }
        let tryIt = onboardingTry.flatMap { $0.isSample(inputs.map(\.url)) ? $0 : nil }
        tryIt?.began(action.title)
        // iCloud placeholders first, so the wait is named for what it is, and Cancel really can stop it.
        let cloud = await CloudDownloads.fetch(inputs.map(\.url)) { [weak progress] waiting, total in
            let line = inputs.count == 1
                ? "Downloading \(subject) \(CloudDownloads.isInICloudDrive(inputs[0].url) ? "from iCloud" : "first")…"
                : "Downloading from the cloud first: \(total - waiting) of \(total) ready…"
            Task { @MainActor in
                guard let progress, progress.specialStage != line else { return }
                progress.specialStage = line
                report(0)
            }
        }
        if case .ready = cloud, progress.specialStage != nil {
            progress.specialStage = nil
            progress.movedAt = Date()
            report(0)
        }
        let wakesAtStart = wakeCount
        var outcome: ConversionOutcome
        switch cloud {
        case .ready:
            outcome = await backend.run(action.id, on: inputs) { continuation.yield($0) }
            if WakeRetry.shouldRetry(outcome, cancelled: Task.isCancelled, sleptDuringJob: wakeCount != wakesAtStart) {
                log.notice("\(action.id.rawValue, privacy: .public) failed across a sleep; running it once more")
                progress.specialStage = "The Mac went to sleep. Starting again…"
                report(progress.shown)
                progress.specialStage = nil
                progress.movedAt = Date()
                outcome = await backend.run(action.id, on: inputs) { continuation.yield($0) }
            }
        case .failed(let url, let message):
            outcome = ConversionOutcome(actionID: action.id, outputs: [], failures: [.init(input: url, message: message)], duration: .zero)
        case .cancelled:
            outcome = .failed(action.id, ConversionError.cancelled.errorDescription ?? "Cancelled.")
        }
        continuation.finish()
        ticker.cancel()
        await consumer.value
        await finish(outcome, action: action, inputs: inputs, subject: subject, key: key, cancelled: Task.isCancelled)
        reportFallback(outcome, inputs: inputs)
        if let tryIt {
            let outputs = outcome.outputs.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            tryIt.finished(outputs: outputs, actionTitle: action.title, failure: outcome.failures.first?.message)
            log.notice("Onboarding try: \(outcome.outputs.count) outputs")
        }
    }

    private func finish(_ outcome: ConversionOutcome, action: ConversionAction, inputs: [InputFile], subject: String,
                        key: String, cancelled: Bool) async {
        let outputs = outcome.outputs.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        log.info("\(action.id.rawValue, privacy: .public): \(outputs.count) outputs, \(outcome.failures.count) failures, cancelled: \(cancelled)")

        if outputs.isEmpty && (cancelled || outcome.wasCancelled) {
            toasts.dismiss(job: key)
            home.jobs.removeAll { $0.id == key }
            return
        }
        if !outputs.isEmpty {
            // Count a use only when the conversion actually produced something.
            registry.usage.recordUse(of: action.id)
            recents.record(actionTitle: action.title, outputs: outputs)
            // A beat of "Done" on the job's row, then the result takes its place at the top of Recent.
            updateHomeJob(key, .done)
            outputsShowingDone[key] = Set(outputs)
            refreshHomeRecents()
            // Felt only if a finger rests on the trackpad; otherwise a no-op.
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.2))
                self?.home.jobs.removeAll { $0.id == key }
                self?.outputsShowingDone[key] = nil
                self?.refreshHomeRecents()
            }
            announce("Saved \(outputs.count == 1 ? outputs[0].lastPathComponent : "\(outputs.count) files")")
            // The files are saved: Cancel must go while the sizes are measured, or it would cancel finished work.
            toasts.showProgress(job: key, title: "\(action.title): \(subject)", stage: "Finishing…",
                                file: inputs.count == 1 ? inputs[0].url : nil, fraction: 1, onCancel: nil)
            // Sizes and folder names only (file-system metadata, never contents), off the main thread.
            let title = Self.successTitle(outputs: outputs, failures: outcome.failures.count)
            let inputURLs = inputs.map(\.url)
            let failures = outcome.failures.count
            let result = await Task.detached(priority: .userInitiated) {
                ConversionResult.measure(title: title, actionTitle: action.title, outputs: outputs, inputs: inputURLs,
                                         failures: failures)
            }.value
            toasts.showResult(job: key, result)
            // The card only counts failures. Say which and why, or the user has nothing to act on.
            if let partial = FailureText.partialFailure(outcome.failures.filter { !ConversionError.isAlreadySmall($0.message) }) {
                toasts.showNotice(partial.title, message: partial.message)
            }
        } else {
            if !outcome.failures.isEmpty, outcome.failures.allSatisfy({ ConversionError.isAlreadySmall($0.message) }) {
                log.notice("\(action.id.rawValue, privacy: .public): already small, nothing to do")
                toasts.dismiss(job: key)
                toasts.showNotice("Nothing to shrink", message: outcome.failures.count == 1
                                  ? outcome.failures[0].message : "These \(outcome.failures.count) files are already as small as Frenzy can make them.")
                removeHomeJob(key)
                return
            }
            var message = outcome.failures.first.map { FailureText.explain($0.message, input: $0.input) } ?? "Frenzy couldn't make a new file from this."
            if outcome.failures.count > 1 { message += " (\(outcome.failures.count) files failed)" }
            let safeMessage = inputs.reduce(message) { $0.replacingOccurrences(of: $1.url.lastPathComponent, with: "<file>") }
            log.notice("\(action.id.rawValue, privacy: .public) failed: \(safeMessage, privacy: .public)")
            toasts.showFailure(job: key, title: "Couldn't convert \(subject)", message: message)
            // The failed row stays a little longer than the card, so a glance at the window still explains it.
            // Files from another app are gone once this job ends, so there's nothing to retry with.
            let canRetry = !inputs.contains { inbox.contains($0.url) }
            if canRetry { failedJobs[key] = (action.id, inputs.map(\.url)) }
            updateHomeJob(key, .failed(message), canRetry: canRetry)
            announce("Couldn't convert \(subject). \(message)")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(12))
                self?.removeHomeJob(key)
            }
        }
    }

    /// Results that went to Downloads because the source folder couldn't take them: the card says Downloads, this says
    /// why. Files from another app or the Trash weren't blocked, just never meant to stay there: no explaining needed.
    private func reportFallback(_ outcome: ConversionOutcome, inputs: [InputFile]) {
        guard !outcome.redirected.isEmpty else { return }
        usedFolders.record(Array(Set(outcome.redirected.map { $0.deletingLastPathComponent() })))
        let policy = savePolicy
        let blocked = Set(inputs.map { $0.url.deletingLastPathComponent() }).filter { !policy.mustRedirect($0) }
        guard !blocked.isEmpty, let saved = outcome.redirected.first?.deletingLastPathComponent() else { return }
        let notice = FailureText.redirectNotice(fallbackName: Self.displayName(saved),
                                                blocked: blocked.map(\.lastPathComponent),
                                                inputCount: outcome.redirected.count)
        log.notice("Saved \(outcome.redirected.count) outputs in the fallback folder")
        toasts.showNotice(notice.title, message: notice.message)
    }

    private func removeHomeJob(_ key: String) {
        home.jobs.removeAll { $0.id == key }
        failedJobs[key] = nil
    }

    /// Try Again on a failed row: the same action on the same files, through the normal drop path (which re-checks
    /// the files and the action).
    private func retryHomeJob(_ key: String) {
        guard let failed = failedJobs[key] else { return }
        removeHomeJob(key)
        toasts.dismiss(job: key)
        log.notice("Retrying \(failed.action.rawValue, privacy: .public)")
        handleDrop(failed.action, urls: failed.urls)
    }

    private func updateHomeJob(_ key: String, _ state: HomeJob.State, stage: String? = nil, canRetry: Bool = false) {
        guard let index = home.jobs.firstIndex(where: { $0.id == key }) else { return }
        // One mutation, so the window redraws once.
        var job = home.jobs[index]
        job.state = state
        if let stage { job.stage = stage }
        job.canRetry = canRetry
        home.jobs[index] = job
    }

    /// "Saved photo.jpg", "Saved 12 files", "Saved 2, 1 couldn't be converted". A folder output is one item.
    static func successTitle(outputs: [URL], failures: Int) -> String {
        if failures > 0 { return "Saved \(outputs.count), \(failures) couldn't be converted" }
        return outputs.count == 1 ? "Saved \(outputs[0].lastPathComponent)" : "Saved \(outputs.count) files"
    }

    private func notifyNoMatch(urls: [URL], inputs: [InputFile], complete: Bool = true) {
        let key = Set(urls)
        if let last = lastNoMatch, last.urls == key, Date().timeIntervalSince(last.date) < 4 { return }
        lastNoMatch = (key, Date())
        log.notice("No conversions for: \(urls.map(\.pathExtension).joined(separator: ","), privacy: .public)")
        if Self.diskTooSlowToTell(urls: urls, inputs: inputs, complete: complete) {
            toasts.showNotice("Still reading", message: Self.slowDiskMessage)
        } else {
            toasts.showNotice("No conversions", message: Self.noMatchMessage(urls: urls, inputs: inputs))
        }
    }

    /// The types came from the names alone and some items had none to give: "can't convert" would be a guess.
    nonisolated static func diskTooSlowToTell(urls: [URL], inputs: [InputFile], complete: Bool) -> Bool {
        !complete && inputs.count < urls.count
    }

    static let slowDiskMessage = "The disk is slow to answer, so Frenzy can't tell what this is yet. Try again in a moment."

    /// Why nothing can be done with a drop, in one plain sentence.
    static func noMatchMessage(urls: [URL], inputs: [InputFile]) -> String {
        if inputs.isEmpty {
            return urls.count == 1 ? "Frenzy can't convert this kind of item yet." : "Frenzy can't convert these items yet."
        }
        if inputs.count > 1 { return "These files don't share a conversion. Try one kind at a time." }
        let ext = inputs[0].url.pathExtension.uppercased()
        return ext.isEmpty ? "Frenzy can't convert this file yet." : "Frenzy can't convert \(ext) files yet."
    }

    /// The ring's centre glyph when "doc" would mislead: a folder or a zip. Nil keeps the default. Uses the types just
    /// worked out for this summon, so it costs no second wait on a slow disk.
    func centerSymbol(for urls: [URL]) -> String? {
        guard urls.count == 1, let input = lastSummon?.urls == urls ? lastSummon?.inputs.first : InputFile(nameOf: urls[0]) else { return nil }
        if input.type.conforms(to: .folder) { return "folder" }
        if input.type.conforms(to: .zip) { return "archivebox.fill" }
        return nil
    }

    /// "photo.heic" for one file, "3 files" for many, "3 items" when folders are among them.
    static func subject(for inputs: [InputFile]) -> String {
        if inputs.count == 1 { return inputs[0].url.lastPathComponent }
        return inputs.contains { $0.type.conforms(to: .directory) } ? "\(inputs.count) items" : "\(inputs.count) files"
    }

    // MARK: Menu actions

    @objc func togglePause() {
        isPaused.toggle()
        onboardingTry?.isPaused = isPaused
        if isPaused { drag.stop() } else { drag.start() }
        updateStatusButton()
    }

    // MARK: Main window

    private func setUpHome() {
        home.appIcon = NSApp.applicationIconImage
        home.onDrop = { [weak self] urls in self?.homeDropped(urls) }
        home.onChoose = { [weak self] id, urls in self?.handleDrop(id, urls: urls) }
        home.onChooseFiles = { [weak self] in self?.chooseFilesForHome() }
        home.onOpenSettings = { [weak self] in self?.showSettings() }
        home.onClearRecents = { [weak self] in self?.clearRecent() }
        home.onDismissJob = { [weak self] key in self?.removeHomeJob(key) }
        home.onRetryJob = { [weak self] key in self?.retryHomeJob(key) }
        // Cancel in the window clears the choice itself, so the app watches the choice to drop promised copies.
        home.$choice
            .sink { [weak self] next in MainActor.assumeIsolated { self?.homeChoiceChanging(to: next) } }
            .store(in: &cancellables)
        // Also the baseline for arrivals: the first list is history, so keep this before any job can finish.
        refreshHomeRecents()
    }

    @objc func showHome() {
        refreshHomeRecents()
        windows.show(id: "home", title: "Frenzy", content: Integration.homeView(model: home, settings: settings),
                     chromeless: true, size: HomeMetrics.size, onClose: { [weak self] in self?.clearHomeChoice() })
        let frame = NSApp.windows.first { $0.identifier?.rawValue == "home" }.map { NSStringFromRect($0.frame) } ?? "none"
        log.notice("Home window shown, frame: \(frame, privacy: .public)")
    }

    /// The window closed with a choice still open: nothing will convert those files, so a promised copy can go
    /// (`homeChoiceChanging` removes it).
    private func clearHomeChoice() {
        home.choice = nil
    }

    /// Promised copies (Photos, Mail) that a running job is converting. Kept when a choice is cancelled or replaced.
    private var inboxFilesInJobs: [UUID: [URL]] = [:]

    /// Inbox files that must stay: running jobs' and the choice on screen.
    private var inboxFilesKept: [URL] { inboxFilesInJobs.values.flatMap { $0 } + (home.choice?.files ?? []) }

    /// The window's choice is about to change: Cancel (Esc), a new drop replacing it, the window closing, or a pick.
    /// Runs before the change lands, so it looks a turn later: by then a pick has started its job, whose files stay.
    /// Any other promised copy of the old choice will never be converted, so it goes.
    private func homeChoiceChanging(to next: HomeChoice?) {
        guard let old = home.choice?.files, !old.isEmpty, old.contains(where: inbox.contains) else { return }
        let incoming = next?.files ?? []
        DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in
            guard let self else { return }
            self.inbox.remove(abandoned: old, keeping: self.inboxFilesKept + incoming)
        } }
    }

    /// Files dropped on the main window: show every format that fits, or say why there is none. Works while paused,
    /// since a drop on the window is a deliberate request.
    func homeDropped(_ urls: [URL]) {
        let (inputs, complete) = InputFile.resolveWithinBudget(Self.summonBudget, urls, inspectLimit: Self.inspectLimit)
        let actions = inputs.isEmpty ? [] : registry.actions(for: inputs, limit: 12)
        log.notice("Home drop: \(urls.count) dropped, \(inputs.count) recognised, \(actions.count) actions")
        guard !actions.isEmpty else {
            home.choice = nil
            // Promised copies nothing fits: nothing will ever convert them.
            inbox.remove(abandoned: urls, keeping: inboxFilesKept)
            showHomeNotice(Self.diskTooSlowToTell(urls: urls, inputs: inputs, complete: complete)
                           ? Self.slowDiskMessage : Self.noMatchMessage(urls: urls, inputs: inputs))
            return
        }
        noticeTimer?.cancel()
        home.notice = nil
        // Only the files Halo recognised: the icon and the conversion then match what will really be converted.
        let files = inputs.map(\.url)
        home.choice = HomeChoice(files: files, subject: Self.subject(for: inputs), items: actions.map(RingItem.init))
        // Promised copies left out of the choice (not recognised) will never convert either.
        inbox.remove(abandoned: urls.filter { !files.contains($0) }, keeping: inboxFilesKept)
    }

    /// The newest result or failure the cards showed, until dismissed. The cards never take focus, so this is how the
    /// keyboard and VoiceOver reach it.
    private var latestResult: ToastContent? { (toasts as? ToastCenter)?.latest }

    static func latestTitle(_ content: ToastContent) -> String {
        switch content {
        case .success(let result): "Show \(result.title) in Finder"
        case .failure(let title, _): "Latest: \(title)…"
        case .notice(let title, _), .progress(let title, _, _, _): "Latest: \(title)…"
        }
    }

    /// "Show Latest Result" (⌘L): reveals the newest outputs in Finder, or reads out the newest failure in a dialog.
    @objc func showLatestResult() {
        guard let latest = latestResult else {
            announce("No recent results")
            return
        }
        switch latest {
        case .success(let result):
            let existing = result.outputs.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !existing.isEmpty else {
                announce("The new files were moved or deleted")
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting(Array(existing.prefix(ToastCenter.maxRevealed)))
        case .failure(let title, let message), .notice(let title, let message):
            guard !HaloRuntime.isUnderTest else { return }
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            NSApp.activate()
            alert.runModal()
        case .progress:
            showHome()
        }
    }

    /// "Convert Files…" in the menus (⌘O): the main window's file picker. The way to convert with no drag and no mouse.
    @objc func convertFiles() {
        showHome()
        chooseFilesForHome()
    }

    /// "Choose Files…" (⌘O): the same path as a drop, for people who'd rather not drag.
    private func chooseFilesForHome() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose files or folders to convert. The new files are saved next to the originals."
        panel.prompt = "Choose"
        let done: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard response == .OK, let urls = panel?.urls, !urls.isEmpty else { return }
            self?.homeDropped(urls)
        }
        // A sheet on the main window, so it can never open behind it.
        if let window = windows.window(id: "home"), window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: done)
        } else {
            NSApp.activate()
            panel.begin(completionHandler: done)
        }
    }

    private func showHomeNotice(_ message: String) {
        home.notice = message
        // VoiceOver users hear why nothing happened.
        announce(message)
        noticeTimer?.cancel()
        noticeTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.home.notice = nil
        }
    }

    /// Spoken by VoiceOver (when it is on); nothing happens otherwise.
    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func refreshHomeRecents() {
        let pending = outputsShowingDone.values.reduce(into: Set<URL>()) { $0.formUnion($1) }
        home.recents = recents.entries
            .filter { entry in !entry.outputs.contains(where: pending.contains) }
            .map { HomeRecent(outputs: $0.outputs, actionTitle: $0.actionTitle, date: $0.date, count: $0.count) }
    }

    /// Halo opened again (Finder, Spotlight, a second launch): the main window, or onboarding if that's unfinished.
    func reopen(from source: String = "app") {
        log.notice("Reopen asked by \(source, privacy: .public)")
        if settings.hasCompletedOnboarding { showHome() } else { showOnboarding() }
    }

    @objc func showSettings() {
        windows.show(id: "settings", title: "Frenzy Settings",
                     content: Integration.settingsView(settings: settings, version: Self.versionString))
    }

    @objc func showOnboarding() {
        let finish: () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                self?.settings.hasCompletedOnboarding = true
                self?.windows.close(id: "onboarding")
                self?.showHome()
            }
        }
        if onboardingTry == nil { onboardingTry = makeOnboardingTry() }
        onboardingTry?.isPaused = isPaused
        // The window is kept after closing. Opened again from closed, it starts over at Welcome with a fresh try;
        // already on screen, it only comes forward, keeping the step and a try that just finished or is running.
        if !windows.isVisible(id: "onboarding") {
            if case .working = onboardingTry?.phase {} else { onboardingTry?.reset() }
            onboardingOpens += 1
        }
        let content = AnyView(Integration.onboardingView(settings: settings, tryIt: onboardingTry, onFinish: finish)
            .id(onboardingOpens))
        if !windows.isVisible(id: "onboarding") { windows.replaceContent(id: "onboarding", with: content) }
        // Closing the window counts as "seen": it stays one click away under Show Onboarding.
        windows.show(id: "onboarding", title: "Welcome to Frenzy", content: content, chromeless: true,
                     size: OnboardingMetrics.windowSize,
                     onClose: { [weak self] in self?.settings.hasCompletedOnboarding = true })
    }

    /// Draws Halo's sample picture into Application Support. On failure the step is left out; onboarding still works.
    private func makeOnboardingTry() -> OnboardingTry? {
        guard let folder = OnboardingSample.defaultFolder else { return nil }
        do {
            let tryIt = OnboardingTry(sampleURL: try OnboardingSample.prepare(in: folder))
            // VoiceOver's "Convert to JPG" on the sample: the same job a drop on the ring would start.
            tryIt.convertSample = { [weak self, weak tryIt] in
                guard let self, let tryIt, let jpg = self.registry.action("image.to-jpg") else { return }
                self.startJob(jpg, urls: [tryIt.sampleURL])
            }
            tryIt.resume = { [weak self] in
                if self?.isPaused == true { self?.togglePause() }
            }
            return tryIt
        } catch {
            log.error("Onboarding sample not prepared: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    @objc func showAbout() {
        NSApp.activate()
        let credits = NSAttributedString(
            string: "Conversions run in a helper that macOS blocks from the network.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Frenzy", .credits: credits])
    }

    @objc func toggleLaunchAtLogin() {
        // Goes through the setting so the Settings toggle and the menu always agree.
        settings.launchAtLogin = !launchAtLogin.isEnabled
    }

    /// Quit from the menu or ⌘Q. With work running, ask first: quitting stops it (cleanly, nothing half-done is left).
    /// Logout and shutdown don't come through here: they cancel and clean up without a dialog in their way.
    @objc func quit() {
        guard activeJobs > 0, !HaloRuntime.isUnderTest else { NSApp.terminate(nil); return }
        let alert = NSAlert()
        alert.messageText = activeJobs == 1 ? "Frenzy is still converting" : "Frenzy is still running \(activeJobs) conversions"
        alert.informativeText = "If you quit now, unfinished conversions stop and nothing half-done is left behind. Your originals are safe."
        alert.addButton(withTitle: "Finish, Then Quit")
        alert.addButton(withTitle: "Quit Now")
        alert.addButton(withTitle: "Keep Frenzy Open")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // The job may have ended while the question was up.
            if jobs.isEmpty { NSApp.terminate(nil) } else { quitsWhenDone = true }
        case .alertSecondButtonReturn: NSApp.terminate(nil)
        default: quitsWhenDone = false
        }
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    // MARK: Status item and menu

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.behavior = .terminationOnRemoval
        // A stable name lets macOS remember where the user moved the icon (Command-drag) across launches.
        item.autosaveName = "HaloStatusItem"
        item.button?.setAccessibilityLabel("Frenzy")
        if let button = item.button {
            let drop = StatusDropView(frame: button.bounds)
            drop.onDrop = { [weak self] urls in self?.showDropMenu(for: urls) }
            drop.onEnter = { [weak self] in self?.log.notice("Icon drag entered") }
            button.addSubview(drop)
            // The button may not be laid out yet (zero bounds), so pin the layer to its edges.
            drop.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                drop.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                drop.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                drop.topAnchor.constraint(equalTo: button.topAnchor),
                drop.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusButton()
    }

    private func updateStatusButton(trigger: TriggerKey? = nil) {
        guard let button = statusItem?.button else { return }
        button.image = StatusIcon.image(paused: isPaused)
        button.toolTip = isPaused ? "Frenzy is paused" : settings.opensOnPause
            ? "Frenzy: pause for half a second while dragging a file"
            : "Frenzy: hold \(Self.symbol(for: trigger ?? settings.trigger)) while dragging a file"
    }

    // MARK: Drop on the menu-bar icon

    /// Files waiting for the user to pick a conversion from the drop menu.
    private var droppedFiles: [URL] = []

    /// Files dropped on the icon: a menu of the conversions that fit, right under the icon. Works even while
    /// paused, since dropping on the icon is a deliberate request.
    func showDropMenu(for urls: [URL]) {
        guard let button = statusItem?.button else { return }
        let inputs = InputFile.resolveWithin(Self.summonBudget, urls, inspectLimit: Self.inspectLimit)
        let actions = inputs.isEmpty ? [] : registry.actions(for: inputs, limit: 12)
        log.notice("Icon drop: \(urls.count) dropped, \(inputs.count) recognised, \(actions.count) actions")
        guard !actions.isEmpty else {
            notifyNoMatch(urls: urls, inputs: inputs)
            return
        }
        droppedFiles = urls
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "Convert \(Self.subject(for: inputs))", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for action in actions {
            let row = item(action.title, #selector(convertDropped(_:)))
            row.representedObject = action.id.rawValue
            row.toolTip = action.subtitle
            row.image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: nil)
            menu.addItem(row)
        }
        let y = button.isFlipped ? button.bounds.maxY + 6 : -6
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: button)
    }

    @objc private func convertDropped(_ sender: NSMenuItem) {
        let urls = droppedFiles
        droppedFiles = []
        guard let raw = sender.representedObject as? String else { return }
        handleDrop(ActionID(rawValue: raw), urls: urls)
    }

    static func symbol(for key: TriggerKey) -> String {
        switch key {
        case .option: "⌥"
        case .shift: "⇧"
        case .control: "⌃"
        case .function: "fn"
        }
    }

    /// Rebuilt every time the menu opens so recents, pause and login state are always current.
    /// Logged for the e2e test. Only real opening calls this; reading the menu's accessibility tree calls
    /// `menuNeedsUpdate` too, so that one can't prove a click worked.
    func menuWillOpen(_ menu: NSMenu) { log.notice("Menu opened") }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let statusLine = isPaused
            ? "Frenzy is paused"
            : (activeJobs > 0 ? (quitsWhenDone ? "Converting… Frenzy will quit when done" : "Converting…")
                : "Frenzy is ready. Start dragging a file and \(settings.gesture)")
        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        menu.addItem(item("Open Frenzy", #selector(showHome)))
        menu.addItem(item("Convert Files…", #selector(convertFiles), key: "o"))
        // The result cards can't take keyboard focus: the newest one is offered here too.
        if let latest = latestResult {
            let row = item(Self.latestTitle(latest), #selector(showLatestResult), key: "l")
            row.setAccessibilityHelp("Shows the newest conversion result")
            menu.addItem(row)
        }
        menu.addItem(item(isPaused ? "Resume Frenzy" : "Pause Frenzy", #selector(togglePause)))

        let recentItem = NSMenuItem(title: "Recent Conversions", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        let entries = recents.entries
        if entries.isEmpty {
            let none = NSMenuItem(title: "No conversions yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            recentMenu.addItem(none)
        } else {
            for (index, entry) in entries.prefix(10).enumerated() {
                let row = item(entry.label, #selector(revealRecent(_:)))
                row.tag = index
                row.toolTip = "\(entry.actionTitle)\n" + entry.outputs.prefix(10).map(\.path).joined(separator: "\n")
                    + (entry.count > 10 ? "\n…and \(entry.count - 10) more" : "")
                let icon = NSWorkspace.shared.icon(forFile: entry.outputs[0].path)
                icon.size = NSSize(width: 16, height: 16)
                row.image = icon
                recentMenu.addItem(row)
            }
            recentMenu.addItem(.separator())
            recentMenu.addItem(item("Clear Recent", #selector(clearRecent)))
        }
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)
        menu.addItem(.separator())

        let login = item("Open at Login", #selector(toggleLaunchAtLogin))
        login.state = launchAtLogin.isEnabled ? .on : (launchAtLogin.needsApproval ? .mixed : .off)
        login.isEnabled = launchAtLogin.isAvailable
        if !launchAtLogin.isAvailable { login.toolTip = "Available when Frenzy runs from Frenzy.app" }
        menu.addItem(login)
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(item("Show Onboarding…", #selector(showOnboarding)))
        menu.addItem(item("About Frenzy", #selector(showAbout)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Frenzy", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func revealRecent(_ sender: NSMenuItem) {
        let entries = recents.entries
        guard entries.indices.contains(sender.tag) else { return }
        let existing = entries[sender.tag].outputs.filter { FileManager.default.fileExists(atPath: $0.path) }
        NSWorkspace.shared.activateFileViewerSelecting(Array(existing.prefix(ToastCenter.maxRevealed)))
    }

    @objc private func clearRecent() {
        recents.clear()
        refreshHomeRecents()
    }
}

/// The newest progress shown for one job, shared by its stream consumer and its slow-wait ticker.
@MainActor
private final class ProgressBox {
    var shown = 0.0
    /// The newest fraction reported, shown or not.
    var latest = 0.0
    /// When `latest` last moved (the job's start until the first update).
    var movedAt = Date()
    /// The stage line on screen.
    var stage = ""
    /// A wait that isn't the conversion (a cloud download). While set, this is the line, whatever the fraction says.
    var specialStage: String?
}

/// Resumes a continuation once, whichever caller fires first.
final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func set(_ c: CheckedContinuation<Void, Never>) {
        let fireNow: Bool = lock.withLock { if fired { return true }; continuation = c; return false }
        if fireNow { c.resume() }
    }

    func fire() {
        let c: CheckedContinuation<Void, Never>? = lock.withLock {
            guard !fired else { return nil }
            fired = true
            defer { continuation = nil }
            return continuation
        }
        c?.resume()
    }
}
