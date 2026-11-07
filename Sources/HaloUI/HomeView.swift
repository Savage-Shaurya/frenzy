import SwiftUI
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
import HaloCore

// The main Frenzy window: glass bubbles around a hub, like the live ring. Idle they invite a drop; after one they are
// the file's real choices. Below sit live jobs and recent results. HaloApp owns the window and fills `HomeModel`; this
// file only draws it.

/// One finished conversion, as the Recent list shows it.
public struct HomeRecent: Identifiable, Equatable, Sendable {
    /// Stable across refreshes (date + first output), so rows keep their identity when a new result is added.
    public let id: String
    /// The files it produced (at most a few dozen are kept).
    public let outputs: [URL]
    /// What it was, e.g. "JPG".
    public let actionTitle: String
    public let date: Date
    /// How many files it produced in total.
    public let count: Int

    public init(outputs: [URL], actionTitle: String, date: Date, count: Int) {
        self.id = "\(date.timeIntervalSinceReferenceDate)|\(outputs.first?.path ?? actionTitle)"
        self.outputs = outputs; self.actionTitle = actionTitle; self.date = date; self.count = count
    }

    /// "photo.jpg", or "photo.jpg + 3 more" for a batch.
    public var name: String {
        guard let first = outputs.first else { return actionTitle }
        return count > 1 ? "\(first.lastPathComponent) + \(count - 1) more" : first.lastPathComponent
    }

    /// "Desktop": the folder the results were saved in.
    public var folderName: String {
        outputs.first.map { FileManager.default.displayName(atPath: $0.deletingLastPathComponent().path) } ?? ""
    }
}

/// A conversion in flight (or one that just failed), shown at the top of the Recent list.
public struct HomeJob: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// 0...1; 0 shows an indeterminate spinner.
        case working(Double)
        /// Finished; shown for a moment before the result takes its place in Recent.
        case done
        case failed(String)
    }
    public let id: String
    /// The action, e.g. "JPG".
    public let title: String
    /// "photo.heic" or "3 files".
    public let subject: String
    public var state: State
    /// What the job is doing right now while `.working`, e.g. "Preparing text recognition. The first time can take
    /// about a minute." Nil shows "Converting…".
    public var stage: String?
    /// A failed job the host can run again with the same files: the row offers Try Again.
    public var canRetry: Bool

    public init(id: String, title: String, subject: String, state: State, stage: String? = nil, canRetry: Bool = false) {
        self.id = id; self.title = title; self.subject = subject; self.state = state; self.stage = stage
        self.canRetry = canRetry
    }
}

/// Files dropped on the window, waiting for the user to pick a format.
public struct HomeChoice: Equatable, Sendable {
    public let files: [URL]
    /// "photo.heic" or "3 files".
    public let subject: String
    public let items: [RingItem]

    public init(files: [URL], subject: String, items: [RingItem]) {
        self.files = files; self.subject = subject; self.items = items
    }
}

/// Live state of the main window. The host sets the callbacks; every callback runs on the main actor.
@MainActor
public final class HomeModel: ObservableObject {
    @Published public var recents: [HomeRecent] = [] {
        didSet { noteArrivals(replacing: oldValue) }
    }
    /// Results that just arrived while Halo was running (window open or not): their rows come in with a short
    /// highlight. The first list the host hands over is history, never an arrival, and neither is a result older than
    /// `HomeArrival.window`. An id leaves the set when its row first shows it (`settleArrival`), or after
    /// `arrivalLifetime` if no row ever does.
    @Published public private(set) var arrivals: Set<String> = []
    @Published public var jobs: [HomeJob] = []
    @Published public var choice: HomeChoice?
    /// A short line in the drop zone, e.g. "Frenzy can't convert this kind of item yet."
    @Published public var notice: String?
    /// The app's icon (the host passes `NSApp.applicationIconImage`). The window no longer draws a header with it.
    @Published public var appIcon: NSImage?

    /// Files arrived on the drop zone. The host answers by setting `choice` or `notice`.
    public var onDrop: ([URL]) -> Void = { _ in }
    /// The user picked a format for `choice`.
    public var onChoose: (ActionID, [URL]) -> Void = { _, _ in }
    /// "Choose Files…": the host shows an open panel and calls `onDrop` with the result.
    public var onChooseFiles: () -> Void = {}
    public var onOpenSettings: () -> Void = {}
    public var onClearRecents: () -> Void = {}
    /// The user dismissed a failed job's row.
    public var onDismissJob: (String) -> Void = { _ in }
    /// The user asked to run a failed job again (only offered when `canRetry`).
    public var onRetryJob: (String) -> Void = { _ in }

    public init() {}

    /// The clock arrivals are judged by.
    var now: () -> Date = Date.init
    /// How long an arrival waits for a row to show it (tests shorten it).
    var arrivalLifetime: Duration = HomeArrival.lifetime
    private var hasRecentsBaseline = false

    /// A row has shown this arrival: it is spent, so a re-created row (window closed and reopened) stays calm.
    func settleArrival(_ id: String) {
        arrivals.remove(id)
    }

    private func noteArrivals(replacing old: [HomeRecent]) {
        defer { hasRecentsBaseline = true }
        guard hasRecentsBaseline else { return }
        let known = Set(old.map(\.id))
        let current = now()
        let fresh = recents.filter { recent in
            !known.contains(recent.id) && abs(current.timeIntervalSince(recent.date)) < HomeArrival.window
        }
        for recent in fresh where !arrivals.contains(recent.id) {
            arrivals.insert(recent.id)
            let lifetime = arrivalLifetime
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: lifetime)
                self?.arrivals.remove(recent.id)
            }
        }
    }

    /// Jobs or results are listed. Without any, the list takes no space at all and the hero has the window.
    var hasContent: Bool { !jobs.isEmpty || !recents.isEmpty }

    public func choose(_ id: ActionID) {
        guard let files = choice?.files else { return }
        choice = nil
        onChoose(id, files)
    }
}

public enum HomeMetrics {
    public static let size = CGSize(width: 520, height: 640)
    /// The hero's stage starts here. Only a swollen bubble's edge reaches into the title bar, which runs over the content:
    /// bubbles at rest, and so their buttons, stay below it.
    static let top: CGFloat = 24
    /// The title bar's height, measured on this macOS. It takes clicks for itself, so controls stay below it.
    static let titleBar: CGFloat = 32
    static let footer: CGFloat = 28
}

/// How a just-finished result arrives in Recent: it takes the slot its "Done" row leaves with a soft green wash and the
/// same green check on its thumbnail, held for a beat, then both fade, so the eye goes from the job to its file.
enum HomeArrival {
    /// A result dated further from now than this is history (loaded, or moved back in by a refresh), not an arrival.
    static let window: TimeInterval = 10
    /// How long a result stays new if no row shows it. A row that does settles it at once (`settleArrival`).
    static let lifetime: Duration = .seconds(3)
    /// The wash and check stay full for this long, so they read, then fade.
    static let hold: Double = 0.7
    static let fade = Animation.easeOut(duration: 1.3).delay(hold)
    /// The thumbnail settling into place.
    static let land = RingMotion.settle
    static let landScale: CGFloat = 0.9
    static let washOpacity: (light: Double, dark: Double) = (0.10, 0.12)
}

/// The spring the window uses for its content changes, or a crossfade under Reduce Motion.
private func homeAnimation(_ reduceMotion: Bool) -> Animation {
    reduceMotion ? RingMotion.crossfade : RingMotion.settle
}

public struct HomeView: View {
    @ObservedObject var model: HomeModel
    @ObservedObject var settings: HaloSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    public init(model: HomeModel, settings: HaloSettings) {
        self.model = model
        self.settings = settings
    }

    public var body: some View {
        VStack(spacing: 0) {
            DropZone(model: model, trigger: settings.trigger, opensOnPause: settings.opensOnPause)
            if model.hasContent {
                // Takes the room the hero leaves, up to what its rows need; any left over goes around the hero.
                RecentsList(model: model)
                    .layoutPriority(1)
                    .transition(.opacity)
            }
            footer
        }
        .overlay(alignment: .topTrailing) { settingsButton }
        .frame(width: HomeMetrics.size.width, height: HomeMetrics.size.height)
        .background { FrenzyBackdrop() }
        // The content runs under the transparent title bar. Without this the fixed frame is centred in the safe area
        // below it, pushing the bottom of the window out of sight.
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : homeAnimation(false), value: model.hasContent)
        .animation(homeAnimation(reduceMotion), value: model.choice)
        .animation(homeAnimation(reduceMotion), value: model.jobs)
        .animation(homeAnimation(reduceMotion), value: model.recents)
        .environment(\.haloShowsPreviews, settings.showPreviews)
        // A container of its own, or this identifier replaces the ones on the views inside (the drop zone lost its).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("halo.home")
    }

    /// Just the glyph in the corner, below the title bar (which takes clicks for itself) and clear of the largest hero.
    private var settingsButton: some View {
        Button(action: model.onOpenSettings) {
            Image(systemName: "gearshape")
                .font(.frenzyGlyph(14))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(WindowInk.detail(contrast))
        .padding(.top, HomeMetrics.titleBar + 2)
        .padding(.trailing, 12)
        .help("Settings (⌘,)")
        .accessibilityLabel("Settings")
    }

    private var footer: some View {
        Label(HomeCopy.footer, systemImage: "lock.fill")
            .labelStyle(TightLabelStyle())
            .font(.frenzy(.label))
            .foregroundStyle(WindowInk.detail(contrast))
            .frame(height: HomeMetrics.footer)
    }
}

/// The window's fixed words, so tests can hold them to what the app does.
enum HomeCopy {
    /// Exact, not absolute: files are read and converted in the sandboxed worker, which has no network entitlement.
    static let footer = "Converted in a helper macOS blocks from the network"
    /// The idle bubbles are examples, and clicking them opens the file picker.
    static let examplesHelp = "Examples of what Frenzy can make. Click to choose a file."
}

/// Icon and title 6 pt apart, icon slightly smaller than the text.
private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

// MARK: Drop zone

/// The hero's stage: everything above the Recent list. A drop anywhere on it counts, and a drag over it makes the bubbles
/// swell and the hub's edge light up.
struct DropZone: View {
    @ObservedObject var model: HomeModel
    let trigger: TriggerKey
    var opensOnPause = true
    private let targetedState = State(initialValue: false)
    @Environment(\.haloHoldsDropTarget) private var holdsTarget
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isTargeted: Bool { targetedState.wrappedValue || holdsTarget }

    var body: some View {
        ZStack {
            if let choice = model.choice {
                // A new file is a new hero: its own thumbnail and a fresh bloom.
                ChoiceHero(model: model, choice: choice, isTargeted: isTargeted)
                    .id(choice.files)
                    .transition(.opacity)
            } else {
                IdleHero(model: model, trigger: trigger, opensOnPause: opensOnPause, isTargeted: isTargeted)
                    .transition(.opacity)
            }
        }
        .padding(.top, HomeMetrics.top)
        .padding(.bottom, 8)
        // Never squeezed below its content by the Recent list: it once was, and "Choose Files…" spilled over the edge.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            model.onDrop(files)
            return true
        } isTargeted: { targeted in
            withAnimation(reduceMotion ? RingMotion.crossfade : RingMotion.bubbleHover) {
                targetedState.wrappedValue = targeted
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("halo.home.dropzone")
        .accessibilityLabel("Drop files to convert")
    }
}

/// The room a cluster of `count` bubbles can reach, so the window can sit it tightly and nothing it does ever clips or
/// lands on the text below. Pure value so tests can check it.
struct BubbleStage: Equatable {
    /// The centre disc's diameter, the same as the live ring's.
    static let hub: CGFloat = (RingMetrics.innerRadius - 6) * 2
    /// How far the whole cluster swells while a file is over the window.
    static let dropScale: CGFloat = 1.08

    let count: Int
    var layout: RingBubbleLayout { .window(count: count) }

    /// Relative to the cluster's centre (y down): the flat disc behind the hub, and every bubble at its largest, hovered
    /// or carried out by a drag. A lone bubble sits at 12 o'clock and two sit side by side, so this is not always centred
    /// on the hub.
    var bounds: CGRect {
        let layout = layout
        func circle(_ center: CGSize, _ diameter: CGFloat) -> CGRect {
            CGRect(x: center.width - diameter / 2, y: center.height - diameter / 2, width: diameter, height: diameter)
        }
        var rect = circle(.zero, HeroDiscRule.diameter * Self.dropScale)
        for index in 0..<count {
            rect = rect.union(circle(layout.offset(index: index, extra: RingMotion.hoverPush), layout.diameter * RingMotion.hoverScale))
            let home = layout.offset(index: index)
            rect = rect.union(circle(CGSize(width: home.width * Self.dropScale, height: home.height * Self.dropScale),
                                     layout.diameter * Self.dropScale))
        }
        return rect
    }
}

/// Sits a cluster on its stage, over the flat accent disc, and swells it while a file is over the window (the hub's edge
/// alone under Reduce Motion).
private struct HeroStage<Content: View>: View {
    let count: Int
    let isTargeted: Bool
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let bounds = BubbleStage(count: count).bounds
        ZStack {
            HeroDisc()
            content
        }
        .scaleEffect(isTargeted && !reduceMotion ? BubbleStage.dropScale : 1)
        .offset(y: -bounds.midY)
        .frame(width: bounds.width, height: bounds.height)
    }
}

/// The ring on the hub's edge while a file is over the window: the accent, or white where the accent disc would swallow it.
private struct HubEdge: View {
    let isTargeted: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Circle()
            .strokeBorder(HeroDiscRule.isShown(reduceTransparency: reduceTransparency, contrast: contrast) ? Color.white : FrenzyPalette.accent,
                          lineWidth: 2.5)
            .opacity(isTargeted ? 1 : 0)
            .allowsHitTesting(false)
    }
}

// MARK: Idle

/// What the idle bubbles show: examples of the kind of thing Frenzy offers, not choices for a file. They used to look
/// pressable and do nothing; now a click on any of them opens the file picker, as "Choose Files…" does, and the tooltip
/// says they are examples.
enum HomeHero {
    static func examplesAction(_ model: HomeModel) -> (RingItem) -> Void {
        // Called from a button's action, on the main thread.
        { [weak model] _ in MainActor.assumeIsolated { model?.onChooseFiles() } }
    }

    static let items: [RingItem] = [
        RingItem(id: "illustration.jpg", title: "JPG", subtitle: nil, symbolName: "photo", category: .image),
        RingItem(id: "illustration.pdf", title: "PDF", subtitle: nil, symbolName: "doc.richtext", category: .pdf),
        RingItem(id: "illustration.compress", title: "Compress", subtitle: nil,
                 symbolName: "arrow.down.right.and.arrow.up.left", category: .image),
        RingItem(id: "illustration.mp4", title: "MP4", subtitle: nil, symbolName: "film", category: .video),
        RingItem(id: "illustration.m4a", title: "M4A", subtitle: nil, symbolName: "waveform", category: .audio),
        RingItem(id: "illustration.text", title: "To Text", subtitle: nil, symbolName: "text.viewfinder", category: .text),
    ]
}

private struct IdleHero: View {
    @ObservedObject var model: HomeModel
    let trigger: TriggerKey
    let opensOnPause: Bool
    let isTargeted: Bool
    private let spreadState = State(initialValue: false)

    var body: some View {
        VStack(spacing: 0) {
            HeroStage(count: HomeHero.items.count, isTargeted: isTargeted) {
                BubbleCluster(items: HomeHero.items, spread: spreadState.wrappedValue, tap: HomeHero.examplesAction(model)) {
                    DropHub(isTargeted: isTargeted)
                        .allowsHitTesting(false)
                }
                .help(HomeCopy.examplesHelp)
                // VoiceOver and the keyboard have "Choose Files…" right below, which does the same thing.
                .accessibilityHidden(true)
            }
            Group {
                if let notice = model.notice {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(Color(nsColor: .systemOrange))
                        Text(notice)
                    }
                    .foregroundStyle(.primary)
                } else {
                    TriggerHint(trigger: trigger, opensOnPause: opensOnPause)
                }
            }
            .font(.frenzy(.body))
            .multilineTextAlignment(.center)
            // Room for a two-line notice, so a long one wraps instead of being cut and the button never jumps.
            .lineLimit(2)
            .frame(minHeight: HeroLine.height)
            .padding(.horizontal, 48)
            Button("Choose Files…", action: model.onChooseFiles)
                .frenzySecondaryButton()
                .keyboardShortcut("o", modifiers: .command)
                .accessibilityIdentifier("halo.home.choose")
        }
        .onAppear { spreadState.wrappedValue = true }
    }
}

private enum HeroLine {
    /// Two lines of 13 pt, with one line centred in it.
    static let height: CGFloat = 36
}

/// The hub of the idle hero. The window's headline lives here.
private struct DropHub: View {
    let isTargeted: Bool
    @Environment(\.self) private var environment

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: isTargeted ? "arrow.down" : "doc")
                .font(.frenzyGlyph(22, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(height: 28)
            Text(isTargeted ? "Release" : "Drop a file")
                .frenzyLeadType()
                .contentTransition(.opacity)
        }
        .foregroundStyle(environment.labelSurface(.disc).ink.color)
        .frame(width: BubbleStage.hub, height: BubbleStage.hub)
        .background { LabelPlate(diameter: BubbleStage.hub, ground: .disc) }
        .modifier(LiquidGlassBackground(shape: Circle(), fallback: .regularMaterial))
        .overlay { HubEdge(isTargeted: isTargeted) }
    }
}

/// "Or drag from Finder and pause for half a second"
private struct TriggerHint: View {
    let trigger: TriggerKey
    let opensOnPause: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 6) {
            if opensOnPause {
                Text("Or drag from Finder and \(HaloSettings.pauseGesture)")
            } else {
                Text("Or drag from Finder and hold")
                KeyCap(text: trigger.displayName)
            }
        }
        .foregroundStyle(WindowInk.detail(contrast))
        .accessibilityElement(children: .combine)
    }
}

private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.frenzy(.label, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
    }
}

/// Colour maths shared by the ring, the toast and the window. Worked out from the tint the system resolves for the
/// current appearance, so dark mode and Increase Contrast are covered.
enum HeroPalette {
    struct RGB: Equatable {
        var r: Double, g: Double, b: Double

        init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
        init(_ resolved: Color.Resolved) {
            r = Double(resolved.red); g = Double(resolved.green); b = Double(resolved.blue)
        }

        var color: Color { Color(.sRGB, red: r, green: g, blue: b) }

        /// WCAG relative luminance.
        var luminance: Double {
            func linear(_ c: Double) -> Double {
                let c = min(max(c, 0), 1)
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }

        /// `amount` of the way to `other`.
        func mixed(with other: RGB, _ amount: Double) -> RGB {
            RGB(r: r + (other.r - r) * amount, g: g + (other.g - g) * amount, b: b + (other.b - b) * amount)
        }
    }

    static let white = RGB(r: 1, g: 1, b: 1)
    static let black = RGB(r: 0, g: 0, b: 0)
    /// A hair over 4.5, so rounding in the renderer never drops a label below AA.
    static let target = 4.6

    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (la, lb) = (a.luminance, b.luminance)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The least step from `color` toward `end` that passes `good`.
    static func nudged(_ color: RGB, toward end: RGB, until good: (RGB) -> Bool) -> RGB {
        for step in 0...100 {
            let candidate = color.mixed(with: end, Double(step) / 100)
            if good(candidate) { return candidate }
        }
        return end
    }
}

// MARK: Choosing a format

/// The file's real choices around its thumbnail and name. `BubbleCluster` draws the bubbles and an invisible button sits
/// on each one's resting place: a cluster's own tap buttons can't carry the identifier, the key or the tooltip each
/// choice needs. So the hit area stays put while the bubble swells away from it, and the pointer can't make it flicker.
struct ChoiceHero: View {
    @ObservedObject var model: HomeModel
    let choice: HomeChoice
    let isTargeted: Bool
    /// Loads the hub's icon, thumbnail and size the way the live ring does.
    @StateObject private var files = RingModel()
    private let spreadState = State(initialValue: false)
    private let hoverState = State<Int?>(initialValue: nil)
    /// The bubble the arrow keys have moved to. Works without Full Keyboard Access, and reaches bubbles past the ninth.
    private let selectedState = State<Int?>(initialValue: nil)
    @FocusState private var focused: Int?
    @FocusState private var stageFocused: Bool
    @Environment(\.haloShowsPreviews) private var showsPreviews
    @Environment(\.haloHoldsHover) private var heldHover
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var items: [RingItem] { choice.items }

    /// The bubble that lights up: under the pointer or the keyboard's focus. A lone choice is lit from the start, as a
    /// default button stands out, since Return picks it.
    private var lit: Int? {
        heldHover ?? hoverState.wrappedValue ?? focused ?? selectedState.wrappedValue ?? (items.count == 1 ? 0 : nil)
    }

    var body: some View {
        let layout = RingBubbleLayout.window(count: items.count)
        VStack(spacing: 0) {
            HeroStage(count: items.count, isTargeted: isTargeted) {
                ZStack {
                    BubbleCluster(items: items, hoveredIndex: lit, spread: spreadState.wrappedValue) { hub }
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                    Color.clear
                        .frame(width: BubbleStage.hub, height: BubbleStage.hub)
                        .accessibilityElement()
                        .accessibilityLabel(hubDescription)
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        hitButton(item, index: index, layout: layout)
                    }
                }
            }
            Text(ChoiceHint.text(count: items.count))
                .font(.frenzy(.body))
                .foregroundStyle(WindowInk.detail(contrast))
                .lineLimit(1)
                .frame(height: HeroLine.height)
            Button("Cancel") { model.choice = nil }
                .frenzySecondaryButton()
                .keyboardShortcut(.cancelAction)
                .help("Cancel (Esc)")
                .accessibilityIdentifier("halo.home.cancel")
        }
        // Always in the Tab loop (not only with Full Keyboard Access), so the arrow keys reach it.
        .focusable(interactions: .edit)
        .focused($stageFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            guard let direction = BubbleKeyboard.direction(for: press.key) else { return .ignored }
            selectedState.wrappedValue = BubbleKeyboard.step(from: lit, direction, count: items.count)
            return .handled
        }
        .onKeyPress(keys: [.return]) { _ in
            // A lone choice has Return as its own shortcut.
            guard items.count > 1, let index = selectedState.wrappedValue, items.indices.contains(index) else { return .ignored }
            model.choose(items[index].id)
            return .handled
        }
        .onAppear {
            files.showsThumbnails = showsPreviews
            files.showFiles(choice.files)
            spreadState.wrappedValue = true
            stageFocused = true
        }
        .onDisappear { files.clearFiles() }
    }

    private func hitButton(_ item: RingItem, index: Int, layout: RingBubbleLayout) -> some View {
        let shortcut = BubbleShortcut(index: index, of: items.count)
        let home = layout.offset(index: index)
        let swollen = layout.offset(index: index, extra: RingMotion.hoverPush)
        return Button { model.choose(item.id) } label: {
            Color.clear.frame(width: layout.diameter, height: layout.diameter)
        }
        .buttonStyle(BubblePressStyle(lift: reduceMotion ? .zero : CGSize(width: swollen.width - home.width,
                                                                          height: swollen.height - home.height),
                                      scale: reduceMotion ? 1 : RingMotion.hoverScale))
        .modifier(BubbleKey(shortcut: shortcut))
        .focused($focused, equals: index)
        .onHover { hovering in
            if hovering { hoverState.wrappedValue = index } else if hoverState.wrappedValue == index { hoverState.wrappedValue = nil }
        }
        .help(ChoiceHint.tooltip(item: item, shortcut: shortcut))
        .accessibilityLabel(item.title)
        .accessibilityHint(item.subtitle ?? "")
        .accessibilityIdentifier("halo.home.action.\(item.id.rawValue)")
        .offset(home)
    }

    /// The same disc the live ring has: the thumbnail and the name, or what the lit bubble does.
    private var hub: some View {
        let hint = lit.flatMap { items.indices.contains($0) ? items[$0].subtitle : nil }
        return RingCenterView(label: choice.subject,
                              symbolName: choice.files.count > 1 ? "doc.on.doc" : "doc",
                              preview: preview,
                              detail: hint ?? files.centerDetail,
                              isHint: hint != nil,
                              tint: nil,
                              received: false,
                              ground: .disc)
            .animation(RingMotion.crossfade, value: files.centerThumbnail != nil)
            .overlay { HubEdge(isTargeted: isTargeted) }
    }

    private var preview: RingCenterView.Preview? {
        if let thumbnail = files.centerThumbnail { return .thumbnail(thumbnail) }
        switch files.centerIcons.count {
        case 0: return nil
        case 1: return .icon(files.centerIcons[0])
        default: return .stack(files.centerIcons)
        }
    }

    private var hubDescription: String {
        [choice.subject, files.centerDetail].compactMap { $0 }.joined(separator: ", ")
    }
}

/// A bubble's feedback while pressed. It is drawn where the swollen bubble is, not on the button's resting place.
private struct BubblePressStyle: ButtonStyle {
    let lift: CGSize
    let scale: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Circle()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.28 : 0))
                    .scaleEffect(scale)
                    .offset(lift)
            }
            .contentShape(Circle())
    }
}

/// The quiet line under the choices, and each bubble's tooltip.
enum ChoiceHint {
    static func text(count: Int) -> String {
        switch count {
        case ...1: "Click it, or press Return"
        case 2: "Choose what to make, or press 1 or 2"
        case 3...9: "Choose what to make, or press 1 to \(count)"
        // Past the ninth there are no number keys, so say how to get there.
        default: "Press 1 to 9, or use the arrow keys and Return"
        }
    }

    /// "Smaller file (press 1)", or for a bubble past the ninth, how to reach it.
    static func tooltip(item: RingItem, shortcut: BubbleShortcut?) -> String {
        let what = item.subtitle ?? item.title
        return shortcut.map { "\(what) (press \($0.label))" } ?? "\(what) (arrow keys, then Return)"
    }
}

/// Arrow keys move the lit bubble around the cluster: right and down go clockwise, left and up go back. Pure value so
/// tests can check it.
enum BubbleKeyboard {
    enum Direction: Equatable { case forward, backward }

    static func direction(for key: KeyEquivalent) -> Direction? {
        switch key {
        case .rightArrow, .downArrow: .forward
        case .leftArrow, .upArrow: .backward
        default: nil
        }
    }

    /// The next bubble from `current`, wrapping around. With nothing lit, forward starts at the first and back at the last.
    static func step(from current: Int?, _ direction: Direction, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current, (0..<count).contains(current) else { return direction == .forward ? 0 : count - 1 }
        return (current + (direction == .forward ? 1 : count - 1)) % count
    }
}

/// The key that picks a bubble without the mouse (and without Full Keyboard Access): Return for the only choice,
/// else 1 to 9 in order. Bubbles past the ninth have none.
enum BubbleShortcut: Equatable {
    case returnKey
    case digit(Int)

    init?(index: Int, of count: Int) {
        if count == 1 { self = .returnKey; return }
        guard index < 9 else { return nil }
        self = .digit(index + 1)
    }

    var key: KeyEquivalent {
        switch self {
        case .returnKey: .return
        case .digit(let n): KeyEquivalent(Character(String(n)))
        }
    }

    var label: String {
        switch self {
        case .returnKey: "Return"
        case .digit(let n): String(n)
        }
    }
}

/// The bubble's key, with no modifier (the window has no text field to type into).
private struct BubbleKey: ViewModifier {
    let shortcut: BubbleShortcut?

    func body(content: Content) -> some View {
        content.keyboardShortcut(shortcut.map { KeyboardShortcut($0.key, modifiers: []) })
    }
}

// MARK: Recent

private struct RecentsList: View {
    @ObservedObject var model: HomeModel
    @Environment(\.colorSchemeContrast) private var contrast

    private var rows: Int { model.jobs.count + model.recents.count }

    var body: some View {
        VStack(alignment: .leading, spacing: RecentsMetrics.headerGap) {
            HStack(spacing: 6) {
                Text("Recent")
                    .font(.frenzy(.label, weight: .semibold))
                // How many results are kept, so a list that scrolls says how much is below.
                if !model.recents.isEmpty {
                    Text("\(model.recents.count)")
                        .font(.frenzy(.label).monospacedDigit())
                        .help(model.recents.count == 1 ? "1 conversion kept" : "\(model.recents.count) conversions kept")
                        .accessibilityLabel(model.recents.count == 1 ? "1 conversion" : "\(model.recents.count) conversions")
                }
                Spacer()
                if !model.recents.isEmpty {
                    Button("Clear", action: model.onClearRecents)
                        .buttonStyle(.borderless)
                        .font(.frenzy(.label))
                        .help("Forget this list. The files stay where they are.")
                }
            }
            .foregroundStyle(WindowInk.detail(contrast))
            .frame(height: RecentsMetrics.header)
            .padding(.horizontal, 24)
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.jobs) { job in
                            JobRow(job: job, retry: { model.onRetryJob(job.id) }, dismiss: { model.onDismissJob(job.id) })
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        ForEach(Array(model.recents.enumerated()), id: \.element.id) { index, recent in
                            RecentRow(recent: recent, index: index, arrived: model.arrivals.contains(recent.id),
                                      settle: { model.settleArrival(recent.id) })
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 16)
                    // As tall as the fade, so the last row clears it once scrolled to the end. None when all fit.
                    .padding(.bottom, RecentsMetrics.overflows(available: proxy.size.height, rows: rows)
                             ? RecentsMetrics.fade : 0)
                }
                .frame(height: RecentsMetrics.viewport(available: proxy.size.height, rows: rows))
                // When rows overflow, the peek fades out above the footer, icon and text together, instead of
                // being cut by a hard edge. Rows that all fit are never dimmed.
                .mask(VStack(spacing: 0) {
                    Color.black
                    HStack(spacing: 0) {
                        // The bright thumbnail fades faster than the title, so the two read at one weight.
                        RecentsMetrics.ghost(halfAt: RecentsMetrics.iconHalf, clearAt: RecentsMetrics.iconClear)
                            .frame(width: RecentsMetrics.iconWidth)
                        RecentsMetrics.ghost(clearAt: RecentsMetrics.fadeClear)
                        // The Open / Show buttons are gone before their glyphs start, so no cut shapes show.
                        RecentsMetrics.ghost(clearAt: RecentsMetrics.buttonsClear)
                            .frame(width: RecentsMetrics.buttonsWidth)
                    }
                    .frame(height: RecentsMetrics.overflows(available: proxy.size.height, rows: rows)
                           ? RecentsMetrics.fade : 0)
                })
            }
        }
        .frame(maxHeight: RecentsMetrics.natural(rows: rows))
    }
}

/// The Recent list's resting height. When rows overflow, it ends on whole rows plus a peek of the next one under the
/// fade, so the list never rests on a half-cut row and still shows there is more below.
enum RecentsMetrics {
    /// How a row takes keyboard focus: always reachable with Tab, then Return opens and Command-Return shows in Finder.
    static let rowFocus: FocusInteractions = .edit
    /// Every job and result row is exactly this tall (one line each for title and detail).
    static let row: CGFloat = 44
    static let leading: CGFloat = 28
    static let header: CGFloat = 20
    static let headerGap: CGFloat = 4
    /// The peek shows the next row's whole title line (its text ends about 22 pt down), and the fade covers all of
    /// it, so the next row reads as one soft ghost, never as cut glyph tops.
    static let peek: CGFloat = 24
    static let fade: CGFloat = peek
    /// Fully clear this far into the fade: just past the title line, so the detail line's tops never show.
    static let fadeClear: CGFloat = 22
    /// Half strength where the icon starts (8 pt in).
    static let iconStart: CGFloat = 8
    /// The leading column holding the thumbnail (list and row insets included). A thumbnail is much brighter than text,
    /// so at the title's ramp it read as a solid slab in dark mode: its fade is half by 10 pt and clear by 20 pt.
    static let iconWidth: CGFloat = 56
    static let iconHalf: CGFloat = 10
    static let iconClear: CGFloat = 20
    /// The trailing column holding the row buttons (list and row insets included), and where it is clear: before
    /// the button glyphs begin (about 15 pt in).
    static let buttonsWidth: CGFloat = 88
    static let buttonsClear: CGFloat = 14

    /// All the list wants: its header and every row. Whatever it doesn't take stays with the hero.
    static func natural(rows: Int) -> CGFloat {
        header + headerGap + CGFloat(rows) * row
    }

    /// The peek's fade, top to bottom: full, half by `halfAt`, clear by `clearAt` (all within `fade`). Continuous,
    /// so rows scrolling through it never cross a step.
    static func ghost(halfAt: CGFloat = iconStart, clearAt: CGFloat) -> LinearGradient {
        let half = min(halfAt, clearAt / 2)
        return LinearGradient(stops: [.init(color: .black, location: 0),
                                      .init(color: .black.opacity(0.5), location: half / fade),
                                      .init(color: .clear, location: clearAt / fade)],
                              startPoint: .top, endPoint: .bottom)
    }

    static func overflows(available: CGFloat, rows: Int) -> Bool {
        available > 0 && CGFloat(rows) * row > available
    }

    static func viewport(available: CGFloat, rows: Int) -> CGFloat {
        // Rows that fit keep all the space.
        guard overflows(available: available, rows: rows) else { return max(available, 0) }
        let whole = max(1, ((available - peek) / row).rounded(.down))
        return min(available, whole * row + peek)
    }
}

private struct RowLayout<Leading: View, Trailing: View>: View {
    let title: String
    let detail: Text
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 12) {
            leading.frame(width: RecentsMetrics.leading, height: RecentsMetrics.leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.frenzy(.body, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail
                    .font(.frenzy(.label))
                    // `.secondary` is about 3.6:1 on the light window; this is 4.5:1 or better.
                    .foregroundStyle(WindowInk.detail(contrast))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 8)
        .frame(height: RecentsMetrics.row)
    }
}

private struct JobRow: View {
    let job: HomeJob
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        RowLayout(title: title, detail: Text(detail)) {
            switch job.state {
            case .working(let fraction):
                JobProgress(fraction: fraction)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.frenzyGlyph(18))
                    .foregroundStyle(Color(nsColor: .systemGreen))
                    .transition(.scale.combined(with: .opacity))
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.frenzyGlyph(16))
                    .foregroundStyle(Color(nsColor: .systemOrange))
            }
        } trailing: {
            if case .failed = job.state {
                HStack(spacing: 2) {
                    if job.canRetry {
                        RowButton(symbol: "arrow.clockwise", label: "Try Again", action: retry)
                    }
                    RowButton(symbol: "xmark", label: "Dismiss", action: dismiss)
                }
            }
        }
        // A long stage or error can run past the row.
        .help(detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityActions {
            if case .failed = job.state {
                if job.canRetry { Button("Try Again", action: retry) }
                Button("Dismiss", action: dismiss)
            }
        }
        .accessibilityIdentifier("halo.home.job")
    }

    private var title: String {
        if case .failed = job.state { return "Couldn't convert \(job.subject) to \(job.title)" }
        return "\(job.title): \(job.subject)"
    }

    /// "Preparing text recognition. The first time can take about a minute. · 40%"
    private var detail: String {
        switch job.state {
        case .working(let fraction):
            (job.stage ?? "Converting…") + (fraction > 0 ? " · \(Int(fraction * 100))%" : "")
        case .done: "Done"
        case .failed(let message): message
        }
    }

    private var accessibilityText: String {
        switch job.state {
        case .working(let fraction):
            [
                "Converting \(job.subject) to \(job.title)",
                job.stage.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".… ")) },
                fraction > 0 ? "\(Int(fraction * 100)) percent" : nil,
            ].compactMap { $0 }.joined(separator: ". ")
        case .done: "Converted \(job.subject) to \(job.title)"
        case .failed(let message): "Failed. Couldn't convert \(job.subject) to \(job.title). \(message)"
        }
    }
}

/// A job's progress as a ring: a quiet track with a primary-coloured arc, crisp in light and dark (the small system
/// spinner nearly vanished on the dark window). At 0 % an arc turns until the first progress arrives.
struct JobProgress: View {
    let fraction: Double
    private let spinState = State(initialValue: false)
    private var isSpinning: Bool {
        get { spinState.wrappedValue } nonmutating set { spinState.wrappedValue = newValue }
    }
    static let side: CGFloat = 20
    static let line: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.16), lineWidth: Self.line)
            if fraction > 0 {
                Circle()
                    .trim(from: 0, to: min(max(fraction, 0.02), 1))
                    .stroke(Color.primary.opacity(0.85), style: StrokeStyle(lineWidth: Self.line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(RingMotion.progress, value: fraction)
            } else {
                // A progress indicator, not decoration, so it keeps turning under Reduce Motion (like the system's).
                // One repeating animation scoped to the rotation: no per-frame body updates, no layout animated.
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(Color.primary.opacity(0.85), style: StrokeStyle(lineWidth: Self.line, lineCap: .round))
                    .rotationEffect(.degrees(isSpinning ? 360 : 0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isSpinning)
                    .onAppear { isSpinning = true }
            }
        }
        .frame(width: Self.side, height: Self.side)
    }
}

private struct RecentRow: View {
    let recent: HomeRecent
    /// Position in the list (0 = newest), for the accessibility identifier.
    let index: Int
    /// It just finished: the row comes in with the green wash and check (`HomeArrival`).
    let arrived: Bool
    /// Tells the model the arrival has been shown.
    let settle: () -> Void
    /// 1 while the arrival wash and check show, easing to 0.
    private let glowState: State<Double>
    private var glow: Double {
        get { glowState.wrappedValue } nonmutating set { glowState.wrappedValue = newValue }
    }
    /// False until an arriving thumbnail has settled into place.
    private let landedState: State<Bool>
    private var landed: Bool {
        get { landedState.wrappedValue } nonmutating set { landedState.wrappedValue = newValue }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.haloHoldsArrival) private var holdsArrival
    private let hoverState = State(initialValue: false)
    private var isHovered: Bool {
        get { hoverState.wrappedValue } nonmutating set { hoverState.wrappedValue = newValue }
    }
    @FocusState private var isFocused: Bool
    /// Hovered with the pointer or focused with the keyboard: the row shows its buttons.
    private var isActive: Bool { isHovered || isFocused }

    private var first: URL? { recent.outputs.first }
    private var washOpacity: Double { scheme == .dark ? HomeArrival.washOpacity.dark : HomeArrival.washOpacity.light }

    init(recent: HomeRecent, index: Int, arrived: Bool, settle: @escaping () -> Void) {
        self.recent = recent; self.index = index; self.arrived = arrived; self.settle = settle
        glowState = State(initialValue: arrived ? 1 : 0)
        landedState = State(initialValue: !arrived)
    }

    var body: some View {
        RowLayout(title: recent.name,
                  detail: Text("\(recent.actionTitle) · \(Self.relative(recent.date)) · in \(recent.folderName)")) {
            if let first {
                FileIcon(url: first, side: RecentsMetrics.leading)
                    .scaleEffect(landed ? 1 : HomeArrival.landScale)
                    .overlay(alignment: .bottomTrailing) {
                        // The check the "Done" row just showed, carried onto the file it made.
                        if glow > 0 {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.frenzyGlyph(13))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color(nsColor: .systemGreen))
                                // Cut out of the row in its own washed colour, fading with it.
                                .background(Circle().fill(Color(nsColor: .windowBackgroundColor))
                                    .overlay(Circle().fill(Color(nsColor: .systemGreen).opacity(washOpacity)))
                                    .padding(-1.5))
                                // Overhangs the corner, clear of the icon's type caption.
                                .offset(x: 5, y: 5)
                                .opacity(glow)
                                .accessibilityHidden(true)
                        }
                    }
            }
        } trailing: {
            HStack(spacing: 2) {
                RowButton(symbol: "arrow.up.forward.square", label: "Open", action: open)
                RowButton(symbol: "folder", label: "Show in Finder", shortcut: "⌘Return", action: reveal)
            }
            .foregroundStyle(isActive ? .primary : .secondary)
            .accessibilityHidden(true)
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isActive ? Color.primary.opacity(0.05) : .clear))
        // Inset 2 pt so two arrivals side by side read as two rows, not one slab.
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .systemGreen).opacity(glow * washOpacity))
            .padding(.vertical, 2))
        .onAppear(perform: arrive)
        .contentShape(Rectangle())
        // `.edit` puts the row in the Tab loop even without Full Keyboard Access; plain `.focusable()` didn't.
        .focusable(interactions: RecentsMetrics.rowFocus)
        .focused($isFocused)
        .focusEffectDisabled()
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(FrenzyPalette.accent.opacity(isFocused ? 0.8 : 0), lineWidth: 2))
        // Return opens, Command-Return shows in Finder (as in Finder's own lists).
        .onKeyPress(keys: [.return]) { press in
            if press.modifiers.contains(.command) { reveal() } else { open() }
            return .handled
        }
        .onHover { hovering in withAnimation(RingMotion.quick) { isHovered = hovering } }
        .onTapGesture(count: 2, perform: open)
        .onDrag { first.map { NSItemProvider(object: $0 as NSURL) } ?? NSItemProvider() }
        .contextMenu {
            Button("Open", action: open)
            // Shown as the menu item's key equivalent; the row's own key handler does the work.
            Button("Show in Finder", action: reveal).keyboardShortcut(.return, modifiers: .command)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(recent.outputs.map { $0 as NSURL })
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(recent.name), \(recent.actionTitle), in \(recent.folderName)")
        .accessibilityAction(named: "Open", open)
        .accessibilityAction(named: "Show in Finder", reveal)
        .accessibilityIdentifier("halo.home.recent.\(index)")
    }

    /// Settles an arriving row: the thumbnail springs to full size (at once under Reduce Motion), then the wash and
    /// check fade after a beat. Opacity only, so the fade stays under Reduce Motion too.
    private func arrive() {
        guard arrived else { return }
        guard !holdsArrival else { landed = true; return }
        settle()
        if reduceMotion { landed = true } else { withAnimation(HomeArrival.land) { landed = true } }
        withAnimation(HomeArrival.fade) { glow = 0 }
    }

    private func open() {
        guard let first else { return }
        NSWorkspace.shared.open(first)
    }

    private func reveal() {
        let existing = recent.outputs.filter { FileManager.default.fileExists(atPath: $0.path) }
        NSWorkspace.shared.activateFileViewerSelecting(Array(existing.prefix(ToastCenter.maxRevealed)))
    }

    static func relative(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct RowButton: View {
    let symbol: String
    let label: String
    /// Shown in the tooltip, e.g. "⌘Return".
    var shortcut: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.frenzyGlyph(13, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(shortcut.map { "\(label) (\($0))" } ?? label)
        .accessibilityLabel(label)
    }
}

// MARK: File icons

private struct ShowsPreviewsKey: EnvironmentKey {
    static let defaultValue = true
}

/// Renders only: an arriving row stays at its first frame (wash and check full, thumbnail landed).
private struct HoldsArrivalKey: EnvironmentKey {
    static let defaultValue = false
}

/// Renders only: draws the window as it looks with a file over it.
private struct HoldsDropTargetKey: EnvironmentKey {
    static let defaultValue = false
}

/// Renders only: lights this bubble as if the pointer were on it.
private struct HoldsHoverKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

extension EnvironmentValues {
    var haloHoldsDropTarget: Bool {
        get { self[HoldsDropTargetKey.self] }
        set { self[HoldsDropTargetKey.self] = newValue }
    }

    var haloHoldsHover: Int? {
        get { self[HoldsHoverKey.self] }
        set { self[HoldsHoverKey.self] = newValue }
    }

    var haloHoldsArrival: Bool {
        get { self[HoldsArrivalKey.self] }
        set { self[HoldsArrivalKey.self] = newValue }
    }

    /// False when the user turned off file previews (`HaloSettings.showPreviews`): `FileIcon` then shows Finder's icon only.
    var haloShowsPreviews: Bool {
        get { self[ShowsPreviewsKey.self] }
        set { self[ShowsPreviewsKey.self] = newValue }
    }
}

/// A Quick Look thumbnail of `url` (the system draws it out of process), with Finder's icon until it arrives, when
/// there is none, or when previews are off.
struct FileIcon: View {
    let url: URL
    let side: CGFloat
    private let thumbnailState = State<CGImage?>(initialValue: nil)
    private var thumbnail: CGImage? {
        get { thumbnailState.wrappedValue } nonmutating set { thumbnailState.wrappedValue = newValue }
    }
    @Environment(\.displayScale) private var scale
    @Environment(\.haloShowsPreviews) private var showsPreviews

    var body: some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail, scale: scale)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
        .task(id: PreviewRequest(url: url, enabled: showsPreviews)) {
            thumbnail = nil
            guard showsPreviews else { return }
            let image = await Self.thumbnail(for: url, side: side, scale: scale)
            // A request overtaken by a new file or by previews being turned off never lands.
            guard !Task.isCancelled else { return }
            thumbnail = image
        }
    }

    private struct PreviewRequest: Equatable {
        let url: URL
        let enabled: Bool
    }

    /// The request is cancelled with the task (the request is immutable once made; cancel may come from any thread).
    static func thumbnail(for url: URL, side: CGFloat, scale: CGFloat) async -> CGImage? {
        nonisolated(unsafe) let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                                       scale: scale, representationTypes: .thumbnail)
        return await withTaskCancellationHandler {
            try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
        } onCancel: {
            QLThumbnailGenerator.shared.cancel(request)
        }
    }
}
