import SwiftUI
import HaloCore

/// Where the bubbles sit and how big they are, per ring size. Pure value so tests can check it.
struct RingBubbleLayout: Equatable {
    let count: Int
    /// Distance from the ring's centre to a bubble's centre.
    let orbit: CGFloat
    let diameter: CGFloat
    let iconSize: CGFloat
    let titleSize: FrenzyTextSize

    /// The width a name has, which the bubble's curve still clears at the name's height.
    var titleWidth: CGFloat { diameter - 8 }
    /// How far a long name may shrink to fit before it would cut.
    static let titleMinScale: CGFloat = 0.85
    /// The largest bubble in the window and onboarding, where the centre has to lead. The overlay keeps its larger ones:
    /// they are aimed at with a file in hand.
    static let windowDiameter: CGFloat = 76

    /// Far enough out that the hero disc's edge runs under a bubble's clear rim and stays off its words.
    static let windowOrbit: CGFloat = 124

    static func window(count: Int) -> RingBubbleLayout {
        RingBubbleLayout(count: count, maxDiameter: windowDiameter, minOrbit: windowOrbit)
    }

    init(count: Int, maxDiameter: CGFloat = 92, minOrbit: CGFloat = 0) {
        self.count = count
        // Ten or more sit a little further out, so each bubble keeps room for a 12 pt name (nothing is smaller).
        orbit = max(minOrbit, count <= 6 ? 116 : (count <= 8 ? 124 : (count <= 9 ? 134 : 142)))
        // Neighbours keep a clear gap at rest, so the glass only flows together while they move.
        let chord = 2 * orbit * CGFloat(sin(.pi / Double(max(count, 2))))
        diameter = min(maxDiameter, max(58, chord - 10))
        iconSize = diameter >= 84 ? 22 : (diameter >= 70 ? 18 : 15)
        titleSize = .label
    }

    private func angle(_ index: Int) -> Double {
        count == 1 ? 0 : RingGeometry.centerAngle(index: index, count: count)
    }

    /// A bubble's resting place relative to the ring's centre (y down), pushed `extra` points further out.
    func offset(index: Int, extra: CGFloat = 0) -> CGSize {
        let point = RingGeometry.point(angle: angle(index), radius: orbit + extra, center: .zero)
        return CGSize(width: point.x, height: point.y)
    }

    /// Moves `index` aside along the ring, away from the hovered neighbour `from`, so a hover makes room for itself.
    func pushedAside(index: Int, from hovered: Int, by distance: CGFloat) -> CGSize {
        let base = offset(index: index)
        let forward = (index - hovered + count) % count == 1
        let a = angle(index) + (forward ? .pi / 2 : -.pi / 2)
        let direction = RingGeometry.point(angle: a, radius: distance, center: .zero)
        return CGSize(width: base.width + direction.x, height: base.height + direction.y)
    }

    func isNeighbour(_ index: Int, of hovered: Int) -> Bool {
        guard count > 2 else { return false }
        let gap = (index - hovered + count) % count
        return gap == 1 || gap == count - 1
    }
}

/// The edge a bubble or card keeps under Reduce Transparency and Increase Contrast, where it sits on an opaque surface
/// instead of glass. Without it a bubble on the window, or over a page of the same grey, had no visible edge at all.
/// The rim is the ink colour, and the surface is the window's: one of the two is always 3:1 or better against whatever
/// is behind (the rim against light backdrops, the surface against dark ones), and the rim is far past 3:1 against the
/// surface, so the shape always holds. Pure value so tests can measure it.
struct GlassRim: Equatable {
    static let width: CGFloat = 1.5

    let reduceTransparency: Bool
    let increasedContrast: Bool
    let dark: Bool

    /// Opaque surface and drawn rim instead of glass.
    var isShown: Bool { reduceTransparency || increasedContrast }
    var tone: RingPalette.RGB { dark ? FrenzyInk.dark : FrenzyInk.light }
}

/// Puts the view on Liquid Glass on macOS 26 and later (it flows together with nearby glass in a `RingGlassContainer`),
/// on frosted material before that, and on an opaque surface with a solid rim under Reduce Transparency or Increase
/// Contrast (`GlassRim`). It has to be a modifier on the content: inside a glass container, glass drawn as a sibling
/// covers and blurs whatever sits on it.
struct LiquidGlassBackground<S: InsettableShape>: ViewModifier {
    let shape: S
    var fallback: Material = .thinMaterial
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let rim = GlassRim(reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased,
                           dark: colorScheme == .dark)
        if rim.isShown {
            content
                .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(shape.strokeBorder(rim.tone.color, lineWidth: GlassRim.width).allowsHitTesting(false))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(shape.fill(fallback))
        }
    }
}

/// Lets the bubbles and the centre merge like liquid while they are close: they split out of the centre as the ring
/// opens, and flow back in on a drop.
struct RingGlassContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { content }
        } else {
            content
        }
    }
}

/// What a label sits on, and so the ink and plate that make it read. Pure value so tests can measure it.
struct LabelSurface: Equatable {
    enum Ground {
        /// The overlay: any page or wallpaper can be behind it.
        case anything
        /// The window's ground, with only a bubble's clear rim over the disc.
        case window
        /// Right over the flat accent disc: a window's or onboarding's centre.
        case disc
    }

    let ground: Ground
    let dark: Bool
    let increasedContrast: Bool
    let reduceTransparency: Bool

    private var onDisc: Bool {
        ground == .disc && HeroDiscRule.isShown(reduceTransparency: reduceTransparency, contrast: increasedContrast ? .increased : .standard)
    }

    var ink: RingPalette.RGB {
        onDisc ? HeroPalette.white : (dark ? FrenzyInk.dark : FrenzyInk.light)
    }

    /// Black under white ink and white under dark ink, so it adds no colour. On the disc, the disc's own hue a step deeper,
    /// which disappears into it and only pulls back whatever the glass has lightened.
    var plateTone: RingPalette.RGB {
        onDisc ? FrenzyPalette.deep : (dark ? HeroPalette.black : HeroPalette.white)
    }

    /// As strong as `ink` needs for 4.5:1 on the worst thing behind it, with no help from the glass. Reduce Transparency
    /// already puts the words on an opaque surface, and the window's ground needs nothing.
    var plateOpacity: Double {
        if reduceTransparency { return 0 }
        switch ground {
        case .anything: return increasedContrast ? 0.8 : (dark ? 0.55 : 0.52)
        case .window: return 0
        case .disc: return onDisc ? 0.6 : 0
        }
    }
}

extension EnvironmentValues {
    func labelSurface(_ ground: LabelSurface.Ground) -> LabelSurface {
        LabelSurface(ground: ground, dark: colorScheme == .dark, increasedContrast: colorSchemeContrast == .increased,
                     reduceTransparency: accessibilityReduceTransparency)
    }
}

/// A soft disc inside a bubble's content, under its words, so they read whatever is behind the glass. It holds to about
/// the bubble's edge and then fades out, which leaves the rim clear for the glass to bend the light.
struct LabelPlate: View {
    let diameter: CGFloat
    let ground: LabelSurface.Ground

    @Environment(\.self) private var environment

    /// Where the fade starts, as a share of the radius.
    static let solidUntil: CGFloat = 0.84

    var body: some View {
        let surface = environment.labelSurface(ground)
        if surface.plateOpacity > 0 {
            let tone = surface.plateTone.color
            Circle()
                .fill(RadialGradient(stops: [.init(color: tone.opacity(surface.plateOpacity), location: 0),
                                             .init(color: tone.opacity(surface.plateOpacity), location: Self.solidUntil),
                                             .init(color: tone.opacity(0), location: 1)],
                                     center: .center, startRadius: 0, endRadius: diameter / 2))
                .frame(width: diameter, height: diameter)
                .allowsHitTesting(false)
        }
    }
}

/// One choice: a glass bubble with its icon and name. Colour is saved for the moment that matters: the hovered bubble
/// fills with its family's colour.
struct RingBubbleView: View {
    let item: RingItem
    let layout: RingBubbleLayout
    let isHovered: Bool
    let flash: Bool
    var ground: LabelSurface.Ground = .anything
    /// False hides the plate and words of a bubble gathered in the centre. Fading the bubble from outside doesn't reach
    /// what sits on its glass.
    var showsContent = true

    @Environment(\.self) private var environment

    var body: some View {
        let circle = Circle()
        let lit = RingPalette.litFill(tint: RingPalette.RGB(item.tint.resolve(in: environment)))

        ZStack {
            LabelPlate(diameter: layout.diameter, ground: ground)
                .opacity(showsContent ? 1 : 0)
            ZStack {
                circle.fill(LinearGradient(colors: [lit.color, lit.mixed(with: HeroPalette.black, 0.08).color],
                                           startPoint: .top, endPoint: .bottom))
                // A light rim along the top, so the colour reads as lit glass rather than flat paint.
                circle.strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0)],
                                                   startPoint: .top, endPoint: .center), lineWidth: 1)
            }
            .shadow(color: lit.color.opacity(0.45), radius: 12, y: 4)
            .opacity(isHovered ? 1 : 0)
            circle.fill(Color.white.opacity(flash ? 0.3 : 0))

            VStack(spacing: 3) {
                Image(systemName: item.symbolName)
                    .font(.frenzyGlyph(layout.iconSize, weight: .medium))
                    .symbolRenderingMode(.monochrome)
                    .frame(height: layout.iconSize + 3)
                Text(item.title)
                    .font(.frenzy(layout.titleSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(RingBubbleLayout.titleMinScale)
                    .allowsTightening(true)
            }
            .foregroundStyle(isHovered ? Color.white : environment.labelSurface(ground).ink.color)
            .frame(width: layout.titleWidth)
            .opacity(showsContent ? 1 : 0)
        }
        .frame(width: layout.diameter, height: layout.diameter)
        .modifier(LiquidGlassBackground(shape: circle))
        .contentShape(circle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(item.isMore ? "Opens the Frenzy window with every choice" : "")
        .accessibilityAddTraits(isHovered ? [.isButton, .isSelected] : .isButton)
    }
}

/// Where a bubble is right now, relative to its place in the ring's centre.
struct BubbleMotion: ViewModifier {
    var offset: CGSize = .zero
    var scale: CGFloat = 1
    var opacity: Double = 1

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .offset(offset)
            .opacity(opacity)
    }
}

// MARK: - Shared with the window and onboarding

enum HeroDiscRule {
    static let diameter: CGFloat = 184

    static func isShown(reduceTransparency: Bool, contrast: ColorSchemeContrast) -> Bool {
        !reduceTransparency && contrast != .increased
    }
}

/// The one disc of ember behind a screen's hero, lit from the top like the icon's back folds: flame at the top, the
/// accent below it, a step deeper from a third of the way down, where the words sit. No blur: its hard edge, running behind
/// the bubbles, is what gives the glass something to bend. It goes where the glass stops bending (Reduce Transparency)
/// or where it would compete with the words (Increase Contrast).
struct HeroDisc: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if HeroDiscRule.isShown(reduceTransparency: reduceTransparency, contrast: contrast) {
            Circle()
                .fill(FrenzyPalette.discGradient)
                .frame(width: HeroDiscRule.diameter, height: HeroDiscRule.diameter)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// Phoenix ember, sampled from the app icon's back folds (Resources/AppIcon-1024.png: ember red #AE1B12, #DA3D15,
/// flame #EF6823, #FA8B2C, gold #FDAB3E, the tile #F9E5D9). One brand colour: bubbles carry family colours only under
/// the pointer; everything else that asks for attention (the primary button, the drop highlight, focus) uses `accent`.
/// The warm gradient is kept for a few hero moments: the disc behind a hero, a running bar, the brand mark.
enum FrenzyPalette {
    /// Ember: #C4420F on a light window (white text 5.1:1, 5.1:1 on white as a focus ring), #CC4A12 on a dark one
    /// (white text 4.6:1, 3.6:1 on the dark window as a ring or bar).
    static let accent = dynamic("FrenzyAccent", light: 0xC4420F, dark: 0xCC4A12)
    /// Pressed and hovered: a step deeper, #A8320C (white 6.7:1) and #B93A0F (white 5.7:1).
    static let pressed = dynamic("FrenzyAccentPressed", light: 0xA8320C, dark: 0xB93A0F)
    /// A soft wash for backgrounds behind the accent: the icon's warm tile on light (#FCEBDF), banked embers on dark
    /// (#3A2016). Words on it stay in ink (16:1 and better); the accent on it is a mark, never text.
    static let tint = dynamic("FrenzyAccentTint", light: 0xFCEBDF, dark: 0x3A2016)
    /// The accent a step deeper, as RGB: the plate under white words on the disc.
    static let deep = HeroPalette.RGB(hex: 0xA8320C)
    /// The icon's lit fold and its tip: decoration only, never under words.
    static let flame = HeroPalette.RGB(hex: 0xEF6823)
    static let gold = HeroPalette.RGB(hex: 0xFDAB3E)
    static let emberRed = HeroPalette.RGB(hex: 0xAE1B12)

    /// The hero disc: a lip of flame along the top running into the accent, then deep ember from a third of the way down,
    /// which is exactly the plate's tone, so the plate under the centre's words melts into the disc instead of showing.
    static let discGradient = LinearGradient(stops: [.init(color: flame.color, location: 0),
                                                     .init(color: accent, location: 0.13),
                                                     .init(color: deep.color, location: 0.32),
                                                     .init(color: deep.color, location: 1)],
                                             startPoint: .top, endPoint: .bottom)

    /// A running bar: deep ember into flame along the part done, with the accent itself held across the middle so the bar
    /// still reads as the brand colour at a glance.
    static let progressGradient = LinearGradient(stops: [.init(color: deep.color, location: 0),
                                                         .init(color: accent, location: 0.44),
                                                         .init(color: accent, location: 0.56),
                                                         .init(color: flame.color, location: 1)],
                                                 startPoint: .leading, endPoint: .trailing)

    /// The brand mark's tile: ember red to flame to gold on the diagonal, as the icon's back folds run.
    static let heroGradient = LinearGradient(colors: [emberRed.color, flame.color, gold.color],
                                             startPoint: .bottomLeading, endPoint: .topTrailing)

    private static func dynamic(_ name: String, light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            let rgb = HeroPalette.RGB(hex: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
            return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
        })
    }
}

extension HeroPalette.RGB {
    init(hex: UInt32) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255)
    }
}

extension View {
    /// The one main action on a screen: tinted Liquid Glass, or a prominent button before macOS 26.
    @ViewBuilder func frenzyPrimaryButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent).tint(FrenzyPalette.accent).controlSize(.large)
        } else {
            buttonStyle(.borderedProminent).tint(FrenzyPalette.accent).controlSize(.large)
        }
    }

    /// Any other button: plain Liquid Glass, or a bordered button before macOS 26.
    @ViewBuilder func frenzySecondaryButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass).controlSize(.large)
        } else {
            buttonStyle(.bordered).controlSize(.large)
        }
    }
}

/// The ring's bubbles around any centre, outside the overlay: the same glass and hover motion as the real ring, smaller so
/// the centre leads, for the main window and onboarding. `spread` runs the bloom: false gathers them in the centre, true sends them out,
/// so a parent can replay it. `tap` makes each bubble a button (nil for an illustration).
struct BubbleCluster<Center: View>: View {
    let items: [RingItem]
    var hoveredIndex: Int?
    var spread = true
    var tap: ((RingItem) -> Void)?
    @ViewBuilder let center: Center

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func motion(_ index: Int, _ layout: RingBubbleLayout) -> BubbleMotion {
        let home = layout.offset(index: index)
        guard spread else {
            return reduceMotion ? BubbleMotion(offset: home, opacity: 0) : BubbleMotion(offset: .zero, scale: 0.4, opacity: 0)
        }
        guard !reduceMotion, let hoveredIndex else { return BubbleMotion(offset: home) }
        if hoveredIndex == index {
            return BubbleMotion(offset: layout.offset(index: index, extra: RingMotion.hoverPush), scale: RingMotion.hoverScale)
        }
        if layout.isNeighbour(index, of: hoveredIndex) {
            return BubbleMotion(offset: layout.pushedAside(index: index, from: hoveredIndex, by: RingMotion.neighbourPush),
                                scale: RingMotion.neighbourScale)
        }
        return BubbleMotion(offset: home, scale: RingMotion.restingScale)
    }

    var body: some View {
        let layout = RingBubbleLayout.window(count: items.count)
        RingGlassContainer {
            ZStack {
                ZStack {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        bubble(item, index: index, layout: layout)
                            .modifier(motion(index, layout))
                            // No zIndex flip on hover, as in RingView: it makes the glass container re-merge every shape.
                            .animation(reduceMotion ? RingMotion.crossfade : RingMotion.bubbleHover, value: hoveredIndex)
                            .animation(reduceMotion ? RingMotion.crossfade
                                                    : RingMotion.bubbleBloom.delay(Double(index) * RingMotion.bubbleStagger),
                                       value: spread)
                    }
                }
                // Gathered, they are out of sight as a group too, so no glass lingers around the centre.
                .opacity(spread ? 1 : 0)
                .animation(spread || reduceMotion ? RingMotion.crossfade : RingMotion.gatherFade, value: spread)
                center
            }
        }
        .frame(width: BubbleCluster.side(layout), height: BubbleCluster.side(layout))
    }

    @ViewBuilder private func bubble(_ item: RingItem, index: Int, layout: RingBubbleLayout) -> some View {
        let view = RingBubbleView(item: item, layout: layout, isHovered: hoveredIndex == index, flash: false, ground: .window,
                                  showsContent: spread)
        if let tap {
            Button { tap(item) } label: { view }.buttonStyle(.plain)
        } else {
            view
        }
    }

    /// Room for the bubbles at their largest.
    static func side(_ layout: RingBubbleLayout) -> CGFloat {
        (layout.orbit + RingMotion.hoverPush + layout.diameter * RingMotion.hoverScale / 2) * 2
    }
}
