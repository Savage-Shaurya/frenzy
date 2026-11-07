import SwiftUI
import AppKit
import Combine

/// What a card is showing.
public enum ToastContent: Equatable, Sendable {
    /// A running conversion. `stage` is the plain-language line ("Preparing text recognition…"); `file` is the input
    /// whose thumbnail leads the card.
    case progress(title: String, stage: String, file: URL?, fraction: Double)
    /// A finished conversion: thumbnail, name, sizes, where it went, and what you can do with it.
    case success(ConversionResult)
    case failure(title: String, message: String)
    /// Neutral information (the menu-bar icon is hidden, nothing fits a drop). Not an error.
    case notice(title: String, message: String)
}

/// Per-job cards: each conversion owns its own card, so one job's progress never replaces another job's result.
/// `ToastCenter` implements it; the plain `ToastPresenting` calls use a shared "notice" card.
@MainActor
public protocol JobToastPresenting: ToastPresenting {
    /// Shows or updates `job`'s progress card. With `onCancel`, the card has a Cancel button.
    func showProgress(job: String, title: String, stage: String, file: URL?, fraction: Double, onCancel: (() -> Void)?)
    /// Turns `job`'s card into its result card (or adds one).
    func showResult(job: String, _ result: ConversionResult)
    func showFailure(job: String, title: String, message: String)
    /// A neutral information card, styled apart from failures.
    func showNotice(_ title: String, message: String)
    /// Removes `job`'s card right away (e.g. after the user cancelled it).
    func dismiss(job: String)
}

/// One card in the stack.
struct ToastEntry: Identifiable, Equatable {
    let id: String
    var content: ToastContent
    var cancellable: Bool
}

@MainActor
final class ToastModel: ObservableObject {
    @Published var entries: [ToastEntry] = []
    @Published var isHovering = false
    /// Mirrors `HaloSettings.showPreviews`.
    @Published var showsPreviews = true
    /// The cards' real height, reported by SwiftUI once they are laid out. The panel sizes itself from this:
    /// `sizingOptions = []` makes the hosting view's `fittingSize` 0, so it can't be asked.
    var onContentHeight: (@MainActor (CGFloat) -> Void)?

    /// First card's content (kept for single-card callers and tests).
    var content: ToastContent? { entries.first?.content }
}

/// Result cards in the top-right corner of the screen under the cursor, stacked newest first (at most `maxCards`).
/// The panel can never become key or main and is shown with `orderFrontRegardless`, so it never takes focus from the
/// app you are working in. Cards wait while the pointer rests on them.
///
/// With `settings`: progress and result cards respect `showToasts` (failures and notices always show), `playSounds`
/// plays a quiet system sound, and `revealAfterConvert` selects outputs in Finder on success.
///
/// The panel never takes focus, so nothing in it is reachable from the keyboard. Every result and failure is therefore
/// announced to VoiceOver, failures stay until dismissed, and `latest` (with `onLatestChange`) lets the app offer the
/// newest result somewhere the keyboard does reach, such as the main window or the menu.
@MainActor
public final class ToastCenter: JobToastPresenting {
    public static let width: CGFloat = 344
    public static let successDuration: Duration = .seconds(8)
    public static let noticeDuration: Duration = .seconds(8)
    /// The longest the pointer can hold a card on screen. A pointer that never sends an exit event (the panel shrank
    /// under it, or it left while the Mac was busy) must not keep cards forever.
    public static let maxHoverHold: Duration = .seconds(60)
    public static let maxCards = 3
    /// Reveal selects at most this many files; a big batch is better shown by its folder.
    public static let maxRevealed = 20
    static let noticeJob = "halo.notice"

    private let settings: HaloSettings?
    let model = ToastModel()
    private(set) var panel: ToastPanel?
    private(set) var hosting: FirstMouseHostingView<ToastView>?
    private var hideTasks: [String: Task<Void, Never>] = [:]
    private var cancelHandlers: [String: () -> Void] = [:]
    /// Running jobs pushed out of a full stack. Their progress stays off screen (no thrashing between running jobs);
    /// their result or failure still shows.
    private var evicted: Set<String> = []
    private var isVisible = false
    private(set) var contentHeight: CGFloat = 0
    private var isSettlingIn = false
    private var previewsSubscription: AnyCancellable?

    /// The newest finished conversion or failure, until it is dismissed or replaced. The panel can't be reached without
    /// a mouse, so the app shows this where the keyboard and VoiceOver can (the main window, the menu).
    public private(set) var latest: ToastContent? {
        didSet { if latest != oldValue { onLatestChange?(latest) } }
    }
    /// The job `latest` belongs to.
    private var latestJob: String?
    /// Called on the main actor whenever `latest` changes (nil once it is dismissed).
    public var onLatestChange: ((ToastContent?) -> Void)?

    /// Speaks a line with VoiceOver (does nothing when it is off). Tests replace it to hear what was said.
    var announce: (String) -> Void = { message in
        // A test's fake cards are never spoken, like they are never shown.
        guard !HaloRuntime.isUnderTest, let app = NSApp else { return }
        NSAccessibility.post(element: app, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
    /// Where the pointer is, in screen coordinates. Tests move it.
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    /// How long a result or notice stays, and how often a held card checks the pointer. Tests shorten them.
    var successDelay: Duration = ToastCenter.successDuration
    var noticeDelay: Duration = ToastCenter.noticeDuration
    var hoverPoll: Duration = .milliseconds(400)
    var hoverCap: Duration = ToastCenter.maxHoverHold

    public init(settings: HaloSettings? = nil) {
        self.settings = settings
        // Cards on screen follow "Show file previews" at once.
        previewsSubscription = settings?.$showPreviews.sink { [model] shows in
            MainActor.assumeIsolated { model.showsPreviews = shows }
        }
    }

    // MARK: ToastPresenting (shared notice card)

    public func showProgress(_ title: String, fraction: Double) {
        showProgress(job: Self.noticeJob, title: title, stage: "Converting…", file: nil, fraction: fraction, onCancel: nil)
    }

    public func showSuccess(_ title: String, outputs: [URL]) {
        showResult(job: Self.noticeJob, ConversionResult(title: title, outputs: outputs))
    }

    public func showFailure(_ title: String, message: String) {
        showFailure(job: Self.noticeJob, title: title, message: message)
    }

    // MARK: JobToastPresenting

    public func showProgress(job: String, title: String, stage: String, file: URL?, fraction: Double, onCancel: (() -> Void)?) {
        guard settings?.showToasts ?? true, !evicted.contains(job) else { return }
        hideTasks.removeValue(forKey: job)?.cancel()
        cancelHandlers[job] = onCancel
        let content = ToastContent.progress(title: title, stage: stage, file: file, fraction: min(max(fraction, 0), 1))
        upsert(ToastEntry(id: job, content: content, cancellable: onCancel != nil))
    }

    public func showResult(job: String, _ result: ConversionResult) {
        cancelHandlers[job] = nil
        evicted.remove(job)
        if settings?.playSounds == true { NSSound(named: "Glass")?.play() }
        if settings?.revealAfterConvert == true, !result.outputs.isEmpty {
            Self.reveal(result.outputs)
        }
        latestJob = job
        latest = .success(result)
        announce(Self.announcement(for: .success(result)))
        guard settings?.showToasts ?? true else { dismissCard(job); return }
        upsert(ToastEntry(id: job, content: .success(result), cancellable: false))
        scheduleHide(job, after: successDelay)
    }

    /// A failure stays until it is dismissed: it says what to do next, and a timer would take that away mid-read.
    public func showFailure(job: String, title: String, message: String) {
        cancelHandlers[job] = nil
        evicted.remove(job)
        if settings?.playSounds == true { NSSound(named: "Basso")?.play() }
        let content = ToastContent.failure(title: title, message: message)
        latestJob = job
        latest = content
        announce(Self.announcement(for: content))
        hideTasks.removeValue(forKey: job)?.cancel()
        upsert(ToastEntry(id: job, content: content, cancellable: false))
    }

    public func showNotice(_ title: String, message: String) {
        cancelHandlers[Self.noticeJob] = nil
        let content = ToastContent.notice(title: title, message: message)
        announce(Self.announcement(for: content))
        upsert(ToastEntry(id: Self.noticeJob, content: content, cancellable: false))
        scheduleHide(Self.noticeJob, after: noticeDelay)
    }

    /// What VoiceOver says when a card arrives. Progress is not announced: it changes too often.
    static func announcement(for content: ToastContent) -> String {
        switch content {
        case .success(let result):
            return [result.title, result.failureLine].compactMap { $0 }.joined(separator: ". ")
        case .failure(let title, let message), .notice(let title, let message):
            return "\(title). \(message)"
        case .progress(let title, _, _, _):
            return title
        }
    }

    /// Removes `job`'s card. Dismissing the latest result also clears `latest`.
    public func dismiss(job: String) {
        if latestJob == job {
            latestJob = nil
            latest = nil
        }
        dismissCard(job)
    }

    /// Removes the card only; `latest` stays (a result shown with cards turned off is still the latest).
    private func dismissCard(_ job: String) {
        hideTasks.removeValue(forKey: job)?.cancel()
        cancelHandlers[job] = nil
        evicted.remove(job)
        guard model.entries.contains(where: { $0.id == job }) else { return }
        model.entries.removeAll { $0.id == job }
        layout()
    }

    /// Fades every card out.
    public func hide() {
        hideTasks.values.forEach { $0.cancel() }
        hideTasks.removeAll()
        cancelHandlers.removeAll()
        evicted.removeAll()
        model.entries.removeAll()
        layout()
    }

    /// Selects at most `maxRevealed` of `urls` in Finder (only ones that still exist).
    static func reveal(_ urls: [URL]) {
        // Lazy: a 2,000-file batch costs at most a few dozen checks on the main thread.
        let existing = urls.lazy.filter { FileManager.default.fileExists(atPath: $0.path) }.prefix(maxRevealed)
        guard !existing.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(Array(existing))
    }

    /// Puts the files themselves on `pasteboard`, ready to paste into Finder, Mail or Slack. Only ones that exist.
    @discardableResult
    static func copy(_ urls: [URL], to pasteboard: NSPasteboard = .general) -> Bool {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(existing as [NSURL])
    }

    // MARK: Private

    private func upsert(_ entry: ToastEntry) {
        if let i = model.entries.firstIndex(where: { $0.id == entry.id }) {
            guard model.entries[i] != entry else { return }
            model.entries[i] = entry
        } else {
            model.entries.insert(entry, at: 0)
            // Keep the stack small: drop the oldest finished card first, else the oldest card. Never the card just
            // inserted at index 0, or a new result could evict itself.
            while model.entries.count > Self.maxCards {
                let victim = model.entries.indices.dropFirst().last { if case .progress = model.entries[$0].content { false } else { true } }
                    ?? model.entries.count - 1
                let removed = model.entries.remove(at: victim)
                hideTasks.removeValue(forKey: removed.id)?.cancel()
                cancelHandlers[removed.id] = nil
                if case .progress = removed.content { evicted.insert(removed.id) }
            }
        }
        layout()
    }

    private func layout() {
        if model.entries.isEmpty {
            // The card under the pointer may vanish (Open, Dismiss) without an exit hover event; a stale true would
            // hold every later card on screen forever.
            model.isHovering = false
            fadeOut()
            return
        }
        let panel = panel ?? makePanel()
        guard hosting != nil else { return }
        let size = NSSize(width: Self.width, height: max(56, contentHeight))

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let target = NSRect(x: visible.maxX - size.width - 14, y: visible.maxY - size.height - 14,
                            width: size.width, height: size.height)

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if isVisible {
            // Keep the top edge pinned while the height changes, in step with the cards' spring.
            if reduceMotion || isSettlingIn || panel.frame.size == target.size {
                isSettlingIn = false
                panel.setFrame(target, display: true, animate: false)
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                    panel.animator().setFrame(target, display: true)
                }
            }
            panel.invalidateShadow()
            return
        }
        isVisible = true
        isSettlingIn = true
        // A fade only: the first real height arrives a moment later, and a frame animation running then would land on
        // the old size and leave the card cut off.
        panel.setFrame(target, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().alphaValue = HaloRuntime.isUnderTest ? 0 : 1
        }
    }

    private func fadeOut() {
        guard let panel, isVisible else { return }
        isVisible = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isVisible else { return }
                self.panel?.orderOut(nil)
            }
        })
    }

    /// True while the pointer really is over the panel. SwiftUI's hover can miss the exit when the panel shrinks out
    /// from under a still pointer, so the flag alone is not trusted.
    var pointerIsOverCards: Bool {
        guard model.isHovering else { return false }
        guard let panel, isVisible || HaloRuntime.isUnderTest else { return false }
        return NSMouseInRect(pointerLocation(), panel.frame, false)
    }

    private func scheduleHide(_ job: String, after delay: Duration) {
        hideTasks.removeValue(forKey: job)?.cancel()
        hideTasks[job] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            // Hold while the pointer rests on the cards, but never past the cap.
            let clock = ContinuousClock()
            let holdUntil = clock.now.advanced(by: self?.hoverCap ?? Self.maxHoverHold)
            while let self, !Task.isCancelled, clock.now < holdUntil {
                guard self.pointerIsOverCards else {
                    // A stale flag would hold every later card too.
                    self.model.isHovering = false
                    break
                }
                try? await Task.sleep(for: self.hoverPoll)
            }
            guard !Task.isCancelled, let self else { return }
            self.hideTasks[job] = nil
            self.model.entries.removeAll { $0.id == job }
            self.layout()
        }
    }

    func applyContentHeight(_ height: CGFloat) {
        guard contentHeight != height else { return }
        contentHeight = height
        layout()
    }

    private func makePanel() -> ToastPanel {
        let panel = ToastPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 64),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true // computed from the cards' opaque pixels, so each card gets its own shadow
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = ToastView(model: model,
                             actions: ToastActions(
                                 open: { [weak self] id, url in
                                     NSWorkspace.shared.open(url)
                                     self?.dismiss(job: id)
                                 },
                                 reveal: { [weak self] id, urls in
                                     ToastCenter.reveal(urls)
                                     self?.dismiss(job: id)
                                 },
                                 copy: { _, urls in ToastCenter.copy(urls) },
                                 cancel: { [weak self] id in self?.cancelHandlers.removeValue(forKey: id)?() },
                                 close: { [weak self] id in self?.dismiss(job: id) }))
        model.onContentHeight = { [weak self] height in
            // Reported during a SwiftUI update: resizing the panel from inside it re-enters layout. Next turn instead.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.applyContentHeight(height) }
            }
        }
        let hosting = FirstMouseHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting
        return panel
    }
}

/// A panel that can never become key or main, so showing it never steals focus from the user's app.
final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on a card's button work even though the panel is never key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// What the card buttons do, keyed by the card's job id.
struct ToastActions {
    var open: (String, URL) -> Void = { _, _ in }
    var reveal: (String, [URL]) -> Void = { _, _ in }
    var copy: (String, [URL]) -> Bool = { _, _ in false }
    var cancel: (String) -> Void = { _ in }
    var close: (String) -> Void = { _ in }
}

struct ToastView: View {
    @ObservedObject var model: ToastModel
    let actions: ToastActions

    var body: some View {
        VStack(alignment: .trailing, spacing: CardMetrics.stackGap) {
            ForEach(model.entries) { entry in
                ToastCard(entry: entry, actions: actions)
                    .transition(reduceMotion ? .opacity : Self.cardTransition)
            }
        }
        .frame(width: ToastCenter.width)
        // Always the stack's own height, whatever the panel offers, and pinned to the top while the panel catches up.
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { proxy in Color.clear.preference(key: ToastHeightKey.self, value: proxy.size.height) }
        }
        .onPreferenceChange(ToastHeightKey.self) { height in
            MainActor.assumeIsolated { model.onContentHeight?(height) }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? RingMotion.crossfade : RingMotion.settle, value: model.entries)
        .onHover { model.isHovering = $0 }
        .environment(\.haloShowsPreviews, model.showsPreviews)
        // The panel never becomes key, so macOS would draw every button dimmed, as if disabled.
        .environment(\.controlActiveState, .key)
    }

    /// A card slides in a short way from the screen edge and settles; it leaves by shrinking a touch as it fades, so the
    /// cards under it close the gap without a jump. Reduce Motion: a dissolve.
    static let cardTransition = AnyTransition.asymmetric(
        insertion: .offset(x: 24).combined(with: .scale(scale: 0.96, anchor: .topTrailing)).combined(with: .opacity),
        removal: .scale(scale: 0.96, anchor: .top).combined(with: .opacity))

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
}

private struct ToastHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// True in a still render (design review). A still can't run the thumbnail's arrival or host the AppKit drag area, so
/// cards draw their finished state instead.
private struct ToastStillRenderKey: EnvironmentKey {
    static let defaultValue = false
}

/// True while the pointer is over this card, so its close button can show.
private struct ToastCardHoverKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var toastStillRender: Bool {
        get { self[ToastStillRenderKey.self] } set { self[ToastStillRenderKey.self] = newValue }
    }

    var toastCardHovered: Bool {
        get { self[ToastCardHoverKey.self] } set { self[ToastCardHoverKey.self] = newValue }
    }
}

// MARK: Cards

/// One grid for every card: a 40 pt lead (thumbnail or status mark) and a text column that starts at the same x on every
/// card, so a stack of different cards still reads as one list.
enum CardMetrics {
    static let thumbnail: CGFloat = 40
    static let padding: CGFloat = 14
    /// Nested corners: the card's corner is the tile's plus the padding (design direction rule 11).
    static let tileCorner: CGFloat = 8
    static let corner: CGFloat = tileCorner + padding
    /// Between the lead and the text column.
    static let leadGap: CGFloat = 12
    /// Where the text column starts, from the card's content edge.
    static let textInset: CGFloat = thumbnail + leadGap
    static let stackGap: CGFloat = 8
    /// The close button's side. It sits in the top-right corner over the first line only.
    static let closeSide: CGFloat = 20

    /// Secondary text on the card's glass. The glass can sit over anything (a white page, a bright photo), so no fixed
    /// share of `.primary` is safe there: `.secondary` measured about 3:1 and 0.62 of `.primary` fell under 4.5:1 on light
    /// backdrops. Details take the full ink; size and weight carry the hierarchy instead.
    static let detailOpacity: Double = 1

    static func detail(_ contrast: ColorSchemeContrast) -> Color {
        .primary.opacity(detailOpacity)
    }

    /// Something went wrong, calmly: an amber deep enough for 4.5:1 as text, where the system's orange reaches about 2:1
    /// on a light card.
    static let attention = Color(nsColor: NSColor(name: "FrenzyAttention") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0.70, blue: 0.25, alpha: 1)
            : NSColor(srgbRed: 0.66, green: 0.33, blue: 0, alpha: 1)
    })
}

struct ToastCard: View {
    let entry: ToastEntry
    let actions: ToastActions
    private let hoverState = State<Bool>(initialValue: false)
    private var hovering: Bool {
        get { hoverState.wrappedValue } nonmutating set { hoverState.wrappedValue = newValue }
    }

    var body: some View {
        let card = RoundedRectangle(cornerRadius: CardMetrics.corner, style: .continuous)
        Group {
            switch entry.content {
            case .progress(let title, let stage, let file, let fraction):
                ProgressCard(title: title, stage: stage, file: file, fraction: fraction,
                             cancel: entry.cancellable ? { actions.cancel(entry.id) } : nil)
            case .success(let result):
                ResultCard(result: result,
                           open: { actions.open(entry.id, $0) },
                           reveal: { actions.reveal(entry.id, result.outputs) },
                           copy: { actions.copy(entry.id, result.outputs) },
                           close: { actions.close(entry.id) })
            case .failure(let title, let message):
                MessageCard(style: .failure, title: title, message: message, close: { actions.close(entry.id) })
            case .notice(let title, let message):
                MessageCard(style: .notice, title: title, message: message, close: { actions.close(entry.id) })
            }
        }
        .padding(CardMetrics.padding)
        .frame(width: ToastCenter.width, alignment: .leading)
        .modifier(CardSurface(shape: card))
        .modifier(CardHover(shape: card, hovering: hoverState.projectedValue))
    }
}

/// Tracks the pointer over the whole card, so its close button can show. A still render draws nothing at all under a
/// hover tracker, so it skips it.
private struct CardHover<S: Shape>: ViewModifier {
    let shape: S
    @Binding var hovering: Bool
    @Environment(\.toastStillRender) private var stillRender

    func body(content: Content) -> some View {
        if stillRender {
            content
        } else {
            content
                .contentShape(shape)
                .onHover { hovering = $0 }
                .environment(\.toastCardHovered, hovering)
        }
    }
}

/// The card's glass. A still render (design review) can't draw Liquid Glass at all, so it gets the frosted material
/// the card wears before macOS 26.
private struct CardSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.toastStillRender) private var stillRender

    func body(content: Content) -> some View {
        if stillRender {
            content.background(shape.fill(.regularMaterial)).overlay(GlassEdge(shape: shape).allowsHitTesting(false))
        } else {
            content
                .modifier(LiquidGlassBackground(shape: shape, fallback: .regularMaterial))
                .overlay { CardEdge(shape: shape).allowsHitTesting(false) }
        }
    }
}

/// Liquid Glass brings its own edge, so a drawn one would double it, and under Reduce Transparency or Increase Contrast
/// `LiquidGlassBackground` draws a solid rim (`GlassRim`). Only frosted material on older macOS needs this soft line.
private struct CardEdge<S: Shape>: View {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if reduceTransparency || contrast == .increased {
            EmptyView()
        } else if #available(macOS 26.0, *) {
            EmptyView()
        } else {
            GlassEdge(shape: shape)
        }
    }
}

/// A low-emphasis action: text that only gains a soft capsule under the pointer, so it never competes with the one
/// primary button.
struct QuietCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietCardButton(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct QuietCardButton<Label: View>: View {
    let label: Label
    let isPressed: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled
    private let hoverState = State<Bool>(initialValue: false)
    private var hovering: Bool {
        get { hoverState.wrappedValue } nonmutating set { hoverState.wrappedValue = newValue }
    }

    var body: some View {
        label
            .font(.frenzy(.label, weight: .medium))
            .foregroundStyle(hovering && isEnabled ? Color.primary : CardMetrics.detail(contrast))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Capsule().fill(Color.primary.opacity(isPressed ? 0.14 : (hovering && isEnabled ? 0.08 : 0))))
            .contentShape(Capsule())
            .scaleEffect(isPressed ? 0.97 : 1)
            .animation(RingMotion.quick, value: isPressed)
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { hovering = $0 }
    }
}

/// What a running card says, split out of "Compress: Quarterly report.pdf" (the form the app sends): the action as a
/// headline, and the file on its own line so the name gets the full width and truncates only as a name.
struct ProgressLabels: Equatable {
    let headline: String
    let fileName: String?

    init(title: String, file: URL?) {
        if let split = title.range(of: ": ") {
            headline = Self.headline(forAction: String(title[..<split.lowerBound]))
            fileName = file?.lastPathComponent ?? String(title[split.upperBound...])
        } else {
            headline = title
            fileName = file?.lastPathComponent
        }
    }

    /// "Compress" reads as a command and "JPG" as a label; while it runs, say what is happening. An action this table
    /// doesn't know keeps its own title, which is still true.
    static func headline(forAction action: String) -> String {
        let phrases = ["Compress": "Compressing", "Merge": "Merging", "Split": "Splitting", "Rotate": "Rotating",
                       "Zip": "Zipping", "Unzip": "Unzipping", "To Text": "Converting to text",
                       "Images": "Converting to images", "Word": "Converting to Word", "Audio": "Extracting the audio",
                       "One PDF": "Making one PDF", "Half Size": "Resizing to half size", "Strip Info": "Removing file info"]
        if let phrase = phrases[action] { return phrase }
        // A format name: JPG, MP4, HEVC, M4A.
        return !action.isEmpty && action == action.uppercased() ? "Converting to \(action)" : action
    }
}

/// Converting: the input's thumbnail, what is happening and to which file, the share done as a number you can read at
/// a glance, a thin bar, and the plain-language stage with Cancel beside it.
struct ProgressCard: View {
    let title: String
    let stage: String
    let file: URL?
    let fraction: Double
    let cancel: (() -> Void)?
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let labels = ProgressLabels(title: title, file: file)
        HStack(alignment: .top, spacing: CardMetrics.leadGap) {
            CardThumbnail(url: file, fallbackSymbol: "arrow.triangle.2.circlepath")
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(labels.headline)
                        .font(.frenzy(.body, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // The width is held before progress starts, so the headline never jumps.
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.frenzy(.label, weight: .medium).monospacedDigit())
                        .foregroundStyle(CardMetrics.detail(contrast))
                        .contentTransition(.numericText(value: fraction))
                        .frame(minWidth: 34, alignment: .trailing)
                        .opacity(fraction > 0 ? 1 : 0)
                        .accessibilityHidden(true)
                }
                if let fileName = labels.fileName {
                    // Middle truncation keeps the extension.
                    Text(fileName)
                        .font(.frenzy(.label))
                        .foregroundStyle(CardMetrics.detail(contrast))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.top, 1)
                }
                ToastProgressBar(fraction: fraction)
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Progress")
                    .accessibilityValue(fraction > 0 ? Text(fraction, format: .percent.precision(.fractionLength(0))) : Text("Starting"))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // Three lines: the first-run text recognition warning must never be cut off.
                    Text(stage)
                        .font(.frenzy(.label))
                        .foregroundStyle(CardMetrics.detail(contrast))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let cancel {
                        Button("Cancel", action: cancel)
                            .buttonStyle(QuietCardButtonStyle())
                            .help("Stop this conversion")
                            // The word lines up with the bar's end, not its invisible capsule.
                            .padding(.trailing, -8)
                    }
                }
                .padding(.top, -4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }
}

/// The one thing a result card asks you to do next.
enum ResultPrimaryAction: Equatable {
    /// One file: open it.
    case open(URL)
    /// Several: there is nothing single to open, so the folder is the next step.
    case showInFinder
}

extension ConversionResult {
    var primaryAction: ResultPrimaryAction {
        outputs.count == 1 ? .open(outputs[0]) : .showInFinder
    }

    /// "169 KB to 139 KB", or nil when the sizes are unknown.
    var factsLine: String? {
        sizeLine?.replacingOccurrences(of: " → ", with: " to ")
    }
}

/// Done: what was made, how big it is and where it went in one line, one clear next step, and the rest kept quiet. Drag
/// the thumbnail and name into Mail, Slack or Finder.
struct ResultCard: View {
    let result: ConversionResult
    let open: (URL) -> Void
    let reveal: () -> Void
    let copy: () -> Bool
    let close: () -> Void

    private let copiedState = State<Bool>(initialValue: false)
    private var copied: Bool {
        get { copiedState.wrappedValue } nonmutating set { copiedState.wrappedValue = newValue }
    }
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.toastStillRender) private var stillRender

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: CardMetrics.leadGap) {
                CardThumbnail(url: result.outputs.first, fallbackSymbol: "doc", badge: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.name)
                        .font(.frenzy(.body, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // Long names stop short of the close button.
                        .padding(.trailing, CardMetrics.closeSide)
                    details
                    // A partial failure is news, not a footnote.
                    if let failureLine = result.failureLine {
                        Text(failureLine)
                            .font(.frenzy(.label, weight: .medium))
                            .foregroundStyle(CardMetrics.attention)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The whole summary is a drag handle for every output.
            .overlay {
                if !stillRender {
                    FileDragArea(urls: result.outputs,
                                 onDoubleClick: result.outputs.count == 1 ? { open(result.outputs[0]) } : nil)
                }
            }
            .help("Drag into Mail, Slack or Finder")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)

            actionRow
        }
        .overlay(alignment: .topTrailing) {
            CloseButton(action: close)
                .offset(x: 4, y: -4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Dismiss", close)
    }

    /// Sizes and place on one line when they fit ("169 KB to 139 KB · Desktop"), else on two.
    @ViewBuilder private var details: some View {
        let detail = Text(result.savedLine)
        if let facts = result.factsLine {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    Text(facts).monospacedDigit()
                    Text("·").accessibilityHidden(true)
                    detail
                }
                .lineLimit(1)
                .fixedSize()
                VStack(alignment: .leading, spacing: 2) {
                    Text(facts).monospacedDigit().lineLimit(1)
                    detail.lineLimit(1).truncationMode(.middle)
                }
            }
            .font(.frenzy(.label))
            .foregroundStyle(CardMetrics.detail(contrast))
        } else {
            detail
                .font(.frenzy(.label))
                .foregroundStyle(CardMetrics.detail(contrast))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var revealHelp: String {
        result.outputs.count > ToastCenter.maxRevealed ? "Show the first \(ToastCenter.maxRevealed) in Finder" : "Show in Finder"
    }

    private var actionRow: some View {
        HStack(spacing: 2) {
            switch result.primaryAction {
            case .open: Button("Show in Finder", action: reveal).buttonStyle(QuietCardButtonStyle()).help(revealHelp)
            case .showInFinder: EmptyView()
            }
            Button {
                copied = copy()
                guard copied else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.6))
                    copied = false
                }
            } label: {
                // Both words hold the width, so the row doesn't shift when it changes.
                ZStack(alignment: .leading) {
                    Text("Copied").opacity(copied ? 1 : 0)
                    Text("Copy").opacity(copied ? 0 : 1)
                }
            }
            .buttonStyle(QuietCardButtonStyle())
            .help("Copy the file, then paste it into Finder, Mail or Slack")
            .accessibilityLabel(copied ? "Copied" : "Copy file")
            Spacer(minLength: 8)
            switch result.primaryAction {
            case .open(let url): Button("Open") { open(url) }.cardPrimaryButton()
            case .showInFinder: Button("Show in Finder", action: reveal).cardPrimaryButton().help(revealHelp)
            }
        }
        // The row starts under the words, not under the thumbnail, and the quiet buttons' words line up with them
        // rather than with their invisible capsules.
        .padding(.leading, CardMetrics.textInset - 8)
        .disabled(result.outputs.isEmpty)
    }

    private var accessibilitySummary: String {
        var parts = ["Saved \(result.name)"]
        if let facts = result.factsLine { parts.append(facts) }
        parts.append(result.placeLine)
        return parts.joined(separator: ". ")
    }
}

extension View {
    /// The card's one main action: the brand's tinted glass at the regular size. The large size the windows use is too
    /// heavy for a card that sits over someone else's work.
    func cardPrimaryButton() -> some View {
        modifier(CardPrimaryButton())
    }
}

private struct CardPrimaryButton: ViewModifier {
    @Environment(\.toastStillRender) private var stillRender

    func body(content: Content) -> some View {
        // A still render can't draw glass, so it shows the button as it is before macOS 26.
        if #available(macOS 26.0, *), !stillRender {
            content.buttonStyle(.glassProminent).tint(FrenzyPalette.accent).controlSize(.regular)
        } else {
            content.buttonStyle(.borderedProminent).tint(FrenzyPalette.accent).controlSize(.regular)
        }
    }
}

/// What a message card says. "Couldn't convert Quarterly report.pdf" splits like a running card, so a long name
/// truncates as a name and the headline stays whole.
struct MessageLabels: Equatable {
    static let failurePrefix = "Couldn't convert "
    let headline: String
    let fileName: String?

    init(title: String) {
        if title.hasPrefix(Self.failurePrefix), title.count > Self.failurePrefix.count {
            headline = String(Self.failurePrefix.dropLast())
            fileName = String(title.dropFirst(Self.failurePrefix.count))
        } else {
            headline = title
            fileName = nil
        }
    }
}

/// A failure (amber, says what happened and what to do) or a neutral notice (no alarm colour at all).
struct MessageCard: View {
    enum Style { case failure, notice }
    let style: Style
    let title: String
    let message: String
    let close: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let labels = MessageLabels(title: title)
        let failure = style == .failure
        HStack(alignment: .top, spacing: CardMetrics.leadGap) {
            // The mark sits where a thumbnail would, so the words line up with every other card. A soft bubble rather
            // than a warning triangle: it says "look here" without raising an alarm.
            Image(systemName: failure ? "exclamationmark" : "info")
                .font(.frenzyGlyph(15, weight: .bold))
                .foregroundStyle(failure ? CardMetrics.attention : CardMetrics.detail(contrast))
                .frame(width: CardMetrics.thumbnail, height: CardMetrics.thumbnail)
                .background(Circle().fill(failure ? CardMetrics.attention.opacity(colorScheme == .dark ? 0.2 : 0.14)
                                                  : Color.primary.opacity(colorScheme == .dark ? 0.1 : 0.06)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(labels.headline)
                    .font(.frenzy(.body, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // Stops short of the close button, which sits over this line only.
                    .padding(.trailing, CardMetrics.closeSide)
                if let fileName = labels.fileName {
                    Text(fileName)
                        .font(.frenzy(.label))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(message)
                    .font(.frenzy(.label))
                    .foregroundStyle(CardMetrics.detail(contrast))
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, labels.fileName == nil ? 0 : 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // A short message still centres on the mark instead of hanging above it.
            .frame(minHeight: CardMetrics.thumbnail)
        }
        .overlay(alignment: .topTrailing) {
            CloseButton(action: close)
                .offset(x: 4, y: -4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Dismiss", close)
    }
}

/// Shows while the pointer is on its card, as macOS notifications do, so a resting card is only its words. Under
/// Increase Contrast it always shows. VoiceOver reaches it (and the card's Dismiss action) either way.
struct CloseButton: View {
    let action: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.toastCardHovered) private var cardHovered
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let hoverState = State<Bool>(initialValue: false)
    private var hovering: Bool {
        get { hoverState.wrappedValue } nonmutating set { hoverState.wrappedValue = newValue }
    }

    var body: some View {
        let shown = cardHovered || hovering || contrast == .increased
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.frenzyGlyph(9, weight: .bold))
                .foregroundStyle(hovering ? Color.primary : CardMetrics.detail(contrast))
                .frame(width: CardMetrics.closeSide, height: CardMetrics.closeSide)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.14 : 0.07)))
                .contentShape(Circle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown || reduceMotion ? 1 : 0.8)
        .animation(reduceMotion ? RingMotion.crossfade : RingMotion.quick, value: shown)
        .onHover { hovering = $0 }
        .help("Dismiss")
        .accessibilityLabel("Dismiss")
    }
}

/// The file's Quick Look thumbnail in a soft tile with a hairline edge; a symbol when there is no file. With `badge`, a
/// soft check in the brand colour.
struct CardThumbnail: View {
    let url: URL?
    let fallbackSymbol: String
    var badge = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.toastStillRender) private var stillRender
    private let landedState = State<Bool>(initialValue: false)
    private var landed: Bool {
        get { landedState.wrappedValue } nonmutating set { landedState.wrappedValue = newValue }
    }

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: CardMetrics.tileCorner, style: .continuous)
        let arrives = badge && !reduceMotion && !stillRender
        let isLanded = landed || stillRender
        ZStack {
            tile.fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05))
            if let url {
                FileIcon(url: url, side: CardMetrics.thumbnail - 6)
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.frenzyGlyph(16, weight: .medium))
                    .foregroundStyle(CardMetrics.detail(contrast))
            }
        }
        .frame(width: CardMetrics.thumbnail, height: CardMetrics.thumbnail)
        .clipShape(tile)
        // Design direction rule 11: a 1 pt inset outline, white 10% on dark, black 10% on light.
        .overlay(tile.strokeBorder(colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.1), lineWidth: 1))
        .overlay(alignment: .bottomTrailing) {
            if badge {
                Image(systemName: "checkmark.circle.fill")
                    .font(.frenzyGlyph(15, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, FrenzyPalette.accent)
                    .background(Circle().fill(.white).padding(2))
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                    .offset(x: 5, y: 5)
            }
        }
        // A new file arrives: thrown onto its card on a small arc, or (Reduce Motion) fading in where it will stay.
        .modifier(ArcArrival(progress: arrives && !isLanded ? 0 : 1))
        .opacity(badge && !isLanded ? 0 : 1)
        .onAppear {
            guard badge, !stillRender else { return }
            withAnimation(reduceMotion ? RingMotion.crossfade : RingMotion.arrival) { landed = true }
        }
        .accessibilityHidden(true)
    }
}

/// The small arc a result's thumbnail takes onto its card: from over the words beside it, up and across to its place.
/// It stays inside the card, so it can't be clipped by the panel. Purely visual: nothing is laid out differently.
struct ArcArrival: GeometryEffect {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress } set { progress = newValue }
    }

    static let start = CGSize(width: 56, height: 16)
    /// As the study has it: the height of the throw follows its length.
    static var lift: CGFloat { min(140, hypot(start.width, start.height) * 0.3) }

    /// Where the thumbnail is at `progress` (0 to 1), relative to its place: a curve from `start`, bowed upward, to zero.
    static func offset(at progress: CGFloat) -> CGSize {
        let t = min(max(progress, 0), 1), rest = 1 - t
        // The curve's control point sits above the midpoint, which is where the bow comes from.
        let control = CGSize(width: start.width / 2, height: start.height / 2 - lift * 2)
        return CGSize(width: rest * rest * start.width + 2 * rest * t * control.width,
                      height: rest * rest * start.height + 2 * rest * t * control.height)
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let offset = Self.offset(at: progress)
        return ProjectionTransform(CGAffineTransform(translationX: offset.width, y: offset.height))
    }
}

/// Always the brand colour, never `Color.accentColor`: a Mac with a red system accent would read this as an error.
/// Thin, so it informs without shouting; the number above it carries the exact share.
struct ToastProgressBar: View {
    let fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    private let phaseState = State<Bool>(initialValue: false)
    private var phase: Bool {
        get { phaseState.wrappedValue } nonmutating set { phaseState.wrappedValue = newValue }
    }

    static let height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(contrast == .increased ? 0.3 : 0.1))
                if fraction > 0 {
                    Capsule()
                        .fill(FrenzyPalette.accent)
                        .frame(width: max(Self.height, proxy.size.width * fraction))
                } else if reduceMotion {
                    // Not started, Reduce Motion: no sliding, the whole track breathes so the card never looks stuck.
                    Capsule()
                        .fill(FrenzyPalette.accent.opacity(phase ? 0.45 : 0.15))
                        .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: phase)
                        .onAppear { phase = true }
                } else {
                    // Not started yet: a short segment glides back and forth so the card never looks frozen.
                    let segment = proxy.size.width * 0.28
                    Capsule()
                        .fill(FrenzyPalette.accent.opacity(0.7))
                        .frame(width: segment)
                        .offset(x: phase ? proxy.size.width - segment : 0)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: phase)
                        .onAppear { phase = true }
                }
            }
        }
        .frame(height: Self.height)
        .animation(RingMotion.progress, value: fraction)
    }
}

/// An AppKit drag source over the card's summary: drags every output (Finder, Mail and Slack take file URLs), and
/// opens a single output on double-click. Works in the never-key panel because it accepts the first mouse.
struct FileDragArea: NSViewRepresentable {
    let urls: [URL]
    var onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> FileDragSourceView { FileDragSourceView() }

    func updateNSView(_ view: FileDragSourceView, context: Context) {
        view.urls = urls
        view.onDoubleClick = onDoubleClick
    }
}

final class FileDragSourceView: NSView, NSDraggingSource {
    var urls: [URL] = []
    var onDoubleClick: (() -> Void)?
    private var mouseDownEvent: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        if event.clickCount == 2 { onDoubleClick?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x, dy = event.locationInWindow.y - down.locationInWindow.y
        guard dx * dx + dy * dy > 9 else { return }
        mouseDownEvent = nil
        let items = Self.draggingItems(for: urls, at: convert(down.locationInWindow, from: nil))
        guard !items.isEmpty else { return }
        beginDraggingSession(with: items, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) { mouseDownEvent = nil }

    /// One item per existing output (at most `ToastCenter.maxRevealed`), Finder icons fanned out under the pointer.
    static func draggingItems(for urls: [URL], at point: NSPoint) -> [NSDraggingItem] {
        let existing = urls.lazy.filter { FileManager.default.fileExists(atPath: $0.path) }.prefix(ToastCenter.maxRevealed)
        return existing.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let offset = CGFloat(index) * 4
            item.setDraggingFrame(NSRect(x: point.x - 24 + offset, y: point.y - 24 - offset, width: 48, height: 48),
                                  contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
