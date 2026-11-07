import SwiftUI
import AppKit
import HaloCore

/// The ring: glass bubbles around a centre disc, drawn on a `RingMetrics.canvasSize` square canvas. They split out of
/// the centre like liquid as it opens. Hit-testing stays by angle, so each bubble owns a generous wedge around it.
/// Purely visual: HaloDrag hit-tests with `RingGeometry` and drives `RingModel`.
public struct RingView: View {
    @ObservedObject var model: RingModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // View-local state uses the `State` struct directly: in this SDK `@State` is a macro and the Command Line Tools
    // ship no SwiftUIMacros plugin to expand it.
    private let revealedState: State<Bool>
    private let dismissedState = State(initialValue: false)
    private let commitState: State<CommitStage>
    private let commitTaskState = State<Task<Void, Never>?>(initialValue: nil)

    /// Segments are on screen (drives the staggered bloom).
    private var revealed: Bool {
        get { revealedState.wrappedValue } nonmutating set { revealedState.wrappedValue = newValue }
    }
    /// `.dismissing` fade-out in progress.
    private var dismissed: Bool {
        get { dismissedState.wrappedValue } nonmutating set { dismissedState.wrappedValue = newValue }
    }
    private var commit: CommitStage {
        get { commitState.wrappedValue } nonmutating set { commitState.wrappedValue = newValue }
    }
    private var commitTask: Task<Void, Never>? {
        get { commitTaskState.wrappedValue } nonmutating set { commitTaskState.wrappedValue = newValue }
    }

    enum CommitStage: Equatable {
        case none
        case pulse(ActionID)
        case collapse(ActionID)

        var id: ActionID? {
            switch self {
            case .none: nil
            case .pulse(let id), .collapse(let id): id
            }
        }
    }

    /// Fixed ripple progress for offscreen renders (`init(model:landed:ripple:)`); nil plays it live.
    private let ripplePreview: Double?

    public init(model: RingModel) {
        self.model = model
        // A model that is already `.shown` (or later) renders settled; `.presenting` blooms in on appear.
        switch model.phase {
        case .shown, .committing: revealedState = State(initialValue: true)
        case .hidden, .presenting, .dismissing: revealedState = State(initialValue: false)
        }
        commitState = State(initialValue: .none)
        ripplePreview = nil
    }

    /// Renders the moment a drop on `id` lands in the centre, with the ripple frozen at `ripple` (0 to 1). For the
    /// design review's offscreen renders, which can't play the commit.
    init(model: RingModel, landed id: ActionID, ripple: Double) {
        self.model = model
        revealedState = State(initialValue: true)
        commitState = State(initialValue: .collapse(id))
        ripplePreview = ripple
    }

    public var body: some View {
        let items = model.items
        let layout = RingBubbleLayout(count: items.count)
        let hovered = model.hoveredIndex.flatMap { items.indices.contains($0) ? $0 : nil }
        let hint = centerHint(items: items, hovered: hovered)
        let landed: RingItem? = if case .collapse = commit { committedItem(items) } else { nil }

        ZStack {
            // The drop's one memorable beat: a ring of the chosen colour leaves the centre and fades past the wedges.
            if let landed, Self.showsRipple(commit, reduceMotion: reduceMotion) {
                DropRipple(color: landed.tint, frozenAt: ripplePreview)
                    // It plays its own animation from the centre; the commit's spring must not fade it in as well.
                    .transition(.identity)
            }

            RingGlassContainer {
                ZStack {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        RingBubbleView(item: item, layout: layout,
                                       isHovered: hovered == index && commit == .none || commit.id == item.id,
                                       flash: { if case .pulse(item.id) = commit { true } else { false } }())
                            .modifier(bubbleMotion(index: index, item: item, layout: layout, hovered: hovered))
                            // No zIndex flip on hover: reordering entries in the glass container makes it re-merge
                            // every shape, which made one hover animate for about 50% more frames (RingLagTests).
                            // Hovered and pushed-aside bubbles never overlap, so the order never showed.
                            .animation(reduceMotion ? RingMotion.crossfade : RingMotion.bubbleHover, value: hovered)
                            .animation(reduceMotion ? RingMotion.crossfade
                                                    : RingMotion.bubbleBloom.delay(Double(index) * RingMotion.bubbleStagger),
                                       value: revealed)
                    }

                    RingCenterView(label: model.centerLabel,
                                   symbolName: centerSymbol(items: items),
                                   preview: { if case .collapse = commit { nil } else { centerPreview } }(),
                                   detail: hint ?? model.centerDetail,
                                   isHint: hint != nil,
                                   tint: committedItem(items)?.tint,
                                   received: landed != nil)
                        .scaleEffect(reduceMotion || revealed ? 1 : 0.7)
                        .opacity(revealed ? 1 : 0)
                        .animation(reduceMotion ? RingMotion.crossfade : RingMotion.bubbleBloom, value: revealed)
                        // The Quick Look thumbnail fades in over Finder's icon when it arrives.
                        .animation(RingMotion.crossfade, value: model.centerThumbnail != nil)
                }
            }
        }
        .frame(width: RingMetrics.canvasSize, height: RingMetrics.canvasSize)
        .scaleEffect(dismissed && !reduceMotion ? 0.94 : 1)
        .opacity(dismissed ? 0 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.centerLabel.isEmpty ? "Conversions" : "Conversions for \(model.centerLabel)")
        // A frozen preview keeps the stage it was given; the live view follows the model.
        .onAppear { if ripplePreview == nil { sync(to: model.phase) } }
        .onChange(of: model.phase) { _, phase in if ripplePreview == nil { sync(to: phase) } }
        .onDisappear { commitTask?.cancel() }
    }

    /// The drop ripple plays only once the chosen wedge has landed in the centre, and never under Reduce Motion.
    static func showsRipple(_ commit: CommitStage, reduceMotion: Bool) -> Bool {
        if case .collapse = commit { !reduceMotion } else { false }
    }

    // MARK: Per-bubble motion

    private func bubbleMotion(index: Int, item: RingItem, layout: RingBubbleLayout, hovered: Int?) -> BubbleMotion {
        let home = layout.offset(index: index)
        var m = BubbleMotion(offset: home)
        if !revealed {
            m.opacity = 0
            if !reduceMotion { m.offset = .zero; m.scale = 0.4 }
            return m
        }
        guard !reduceMotion else {
            if commit != .none, commit.id != item.id { m.opacity = 0 }
            if case .collapse = commit { m.opacity = 0 }
            return m
        }
        switch commit {
        case .none:
            if let hovered {
                if hovered == index {
                    m.offset = layout.offset(index: index, extra: RingMotion.hoverPush)
                    m.scale = RingMotion.hoverScale
                } else if layout.isNeighbour(index, of: hovered) {
                    m.offset = layout.pushedAside(index: index, from: hovered, by: RingMotion.neighbourPush)
                    m.scale = RingMotion.neighbourScale
                } else {
                    m.scale = RingMotion.restingScale
                }
            }
        case .pulse(let id):
            if id == item.id {
                m.offset = layout.offset(index: index, extra: RingMotion.pulsePush)
                m.scale = RingMotion.pulseScale
            } else {
                m.offset = CGSize(width: home.width * 0.55, height: home.height * 0.55)
                m.scale = 0.6
                m.opacity = 0
            }
        case .collapse(let id):
            m.offset = .zero
            m.scale = id == item.id ? 0.35 : 0.5
            m.opacity = 0
        }
        return m
    }

    // MARK: Phase handling

    private func sync(to phase: RingModel.Phase) {
        switch phase {
        case .hidden:
            commitTask?.cancel()
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) {
                revealed = false
                dismissed = false
                commit = .none
            }
        case .presenting, .shown:
            if dismissed || commit != .none {
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) { dismissed = false; commit = .none }
            }
            if !revealed { revealed = true }
        case .committing(let id):
            if !revealed { revealed = true }
            runCommit(id)
            // VoiceOver hears what the drop started (the result card announces the outcome).
            if let item = model.items.first(where: { $0.id == id }) {
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                     userInfo: [.announcement: item.isMore ? "Opening Frenzy" : "Converting to \(item.title)"])
            }
        case .dismissing:
            commitTask?.cancel()
            withAnimation(reduceMotion ? RingMotion.crossfade : RingMotion.dismiss) { dismissed = true }
        }
    }

    private func runCommit(_ id: ActionID) {
        commitTask?.cancel()
        let reduce = reduceMotion
        withAnimation(reduce ? RingMotion.crossfade : RingMotion.pulse) { commit = .pulse(id) }
        commitTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(RingMotion.collapseDelay))
            guard !Task.isCancelled else { return }
            withAnimation(reduce ? RingMotion.crossfade : RingMotion.collapse) { commit = .collapse(id) }
        }
    }

    // MARK: Centre

    private func committedItem(_ items: [RingItem]) -> RingItem? {
        guard let id = commit.id else { return nil }
        return items.first { $0.id == id }
    }

    /// The dragged file's thumbnail, or its Finder icon until the thumbnail arrives; a fan of icons for several.
    /// Nil shows a symbol.
    private var centerPreview: RingCenterView.Preview? {
        if let thumbnail = model.centerThumbnail { return .thumbnail(thumbnail) }
        switch model.centerIcons.count {
        case 0: return nil
        case 1: return .icon(model.centerIcons[0])
        default: return .stack(model.centerIcons)
        }
    }

    /// Bubbles carry only a name, so the centre says what the hovered one does ("Smaller file").
    private func centerHint(items: [RingItem], hovered: Int?) -> String? {
        guard commit == .none, let hovered else { return nil }
        return items[hovered].subtitle
    }

    private func centerSymbol(items: [RingItem]) -> String {
        if case .collapse = commit, let item = committedItem(items) { return item.symbolName }
        if let custom = model.centerSymbolName { return custom }
        return model.centerLabel.hasSuffix(" files") ? "doc.on.doc" : "doc"
    }
}

/// Sizes inside the centre disc.
enum RingCenterMetrics {
    /// Side of the box the file's thumbnail or icon fits in.
    static let thumbnail: CGFloat = 46
    /// The one line of words under it.
    static let line: CGFloat = 16
}

/// The disc under the cursor: what is being dragged, as a preview and one line of words. On commit it takes on the
/// chosen action's symbol.
struct RingCenterView: View {
    enum Preview {
        case thumbnail(CGImage)
        case icon(NSImage)
        /// Up to three Finder icons, fanned out.
        case stack([NSImage])
    }

    let label: String
    let symbolName: String
    let preview: Preview?
    /// What the hovered wedge does (with `isHint`), which takes the name's line while it shows. Otherwise the file's size,
    /// for VoiceOver: the disc itself stays a preview and a name.
    let detail: String?
    var isHint = false
    /// The chosen action's colour once a drop is committed.
    let tint: Color?
    /// The chosen wedge has landed: the disc fills with its colour and everything on it turns white.
    let received: Bool
    var ground: LabelSurface.Ground = .anything

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var scale
    @Environment(\.self) private var environment

    private var diameter: CGFloat { (RingMetrics.innerRadius - 6) * 2 }

    /// The lit fill the disc takes on when the drop lands (the hovered wedge's colour, so white reads at 4.5:1).
    private var landedFill: RingPalette.RGB? {
        guard received, let tint else { return nil }
        return RingPalette.litFill(tint: RingPalette.RGB(tint.resolve(in: environment)))
    }

    /// The disc's one line of words.
    static func line(label: String, detail: String?, isHint: Bool) -> String {
        isHint ? detail ?? label : label
    }

    var body: some View {
        let disc = Circle()
        let fill = landedFill
        // Plain colours (not shape styles) so the text fades to white with the fill instead of flipping first.
        let ink = fill == nil ? environment.labelSurface(ground).ink.color : .white
        let line = Self.line(label: label, detail: detail, isHint: isHint)
        VStack(spacing: preview == nil ? 4 : 3) {
            artwork
                .frame(width: preview == nil ? 24 : RingCenterMetrics.thumbnail,
                       height: preview == nil ? 22 : RingCenterMetrics.thumbnail)
            if !line.isEmpty {
                Text(line)
                    .font(isHint ? .frenzy(.label) : .frenzy(.label, weight: .medium))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    // Cut a name in the middle, so its extension stays.
                    .truncationMode(isHint ? .tail : .middle)
                    .allowsTightening(true)
                    // The same height either way, so the preview never moves when the words change.
                    .frame(width: diameter - 22, height: RingCenterMetrics.line)
                    .id(line)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? RingMotion.crossfade : RingMotion.quick, value: line)
        .animation(reduceMotion ? RingMotion.crossfade : RingMotion.quick, value: fill != nil)
        .frame(width: diameter, height: diameter)
        .background {
            ZStack {
                LabelPlate(diameter: diameter, ground: ground)
                if let fill {
                    // Same lit treatment as a hovered wedge: solid colour with a light rim along the top.
                    disc.fill(LinearGradient(colors: [fill.color, fill.mixed(with: HeroPalette.black, 0.06).color],
                                             startPoint: .top, endPoint: .bottom))
                    disc.stroke(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0)], startPoint: .top, endPoint: .center),
                                lineWidth: 1.5)
                }
            }
            .animation(reduceMotion ? RingMotion.crossfade : RingMotion.quick, value: fill != nil)
        }
        .modifier(LiquidGlassBackground(shape: disc, fallback: .regularMaterial))
        .scaleEffect(received && !reduceMotion ? 1.12 : 1)
        .animation(reduceMotion ? RingMotion.crossfade : RingMotion.settle, value: received)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(detail ?? "")
    }

    @ViewBuilder private var artwork: some View {
        switch preview {
        case .thumbnail(let image):
            Image(decorative: image, scale: scale)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 1.5, y: 0.5)
                .transition(.opacity)
        case .icon(let icon):
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        case .stack(let icons):
            ZStack {
                // The first item sits in front, upright and a size larger; the others lean out behind it.
                ForEach(Array(icons.enumerated().reversed()), id: \.offset) { index, icon in
                    let lean: Double = index == 0 ? 0 : (index == 1 ? -1 : 1)
                    let side = RingCenterMetrics.thumbnail * (index == 0 ? 0.86 : 0.72)
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: side, height: side)
                        .shadow(color: .black.opacity(0.22), radius: 1.5, y: 0.5)
                        .rotationEffect(.degrees(lean * 13), anchor: .bottom)
                        .offset(x: CGFloat(lean) * 11)
                }
            }
        case nil:
            Image(systemName: symbolName)
                .font(.frenzyGlyph(17, weight: .medium))
                .symbolRenderingMode(landedFill == nil ? .hierarchical : .monochrome)
                .foregroundStyle(landedFill != nil ? AnyShapeStyle(Color.white)
                                                   : tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(environment.labelSurface(ground).ink.color))
                .contentTransition(.symbolEffect(.replace))
        }
    }
}

// MARK: Drop ripple

/// One ring of the chosen colour that leaves the centre disc and fades out past the wedges as a drop lands.
struct DropRipple: View {
    let color: Color
    /// A fixed progress (0 to 1) for offscreen renders; nil plays the ripple once when it appears.
    let frozenAt: Double?

    private let progressState = State(initialValue: 0.0)
    private var progress: Double {
        get { progressState.wrappedValue } nonmutating set { progressState.wrappedValue = newValue }
    }

    @Environment(\.self) private var environment

    var body: some View {
        let t = frozenAt ?? progress
        // The disc's own lit colour, so the ripple and the centre read as one colour leaving the other.
        let lit = RingPalette.litFill(tint: RingPalette.RGB(color.resolve(in: environment))).color
        RippleRing(progress: t)
            .fill(lit, style: FillStyle(eoFill: true))
            .shadow(color: lit.opacity(0.5), radius: 5)
            .opacity(1 - t)
            .frame(width: RingMetrics.canvasSize, height: RingMetrics.canvasSize)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                guard frozenAt == nil else { return }
                withAnimation(.easeOut(duration: RingMotion.rippleDuration)) { progress = 1 }
            }
    }
}

/// The ripple's band: from the centre disc's edge out past the wedges, thinning as it grows.
struct RippleRing: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress } set { progress = newValue }
    }

    static let startRadius = RingMetrics.innerRadius - 6
    static let endRadius = RingMetrics.outerRadius + 24

    /// Radius and width of the band at `progress`: 5 pt wide for the first half, so it still reads as a ring in
    /// flight, then thinning to 1.5 pt.
    static func band(at progress: Double) -> (radius: CGFloat, width: CGFloat) {
        let t = CGFloat(min(max(progress, 0), 1))
        return (startRadius + (endRadius - startRadius) * t, t < 0.5 ? 5 : 5 - 7 * (t - 0.5))
    }

    func path(in rect: CGRect) -> Path {
        let (radius, width) = Self.band(at: progress)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        for r in [radius + width / 2, radius - width / 2] {
            path.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        }
        return path
    }
}
