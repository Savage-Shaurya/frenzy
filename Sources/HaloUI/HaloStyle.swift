import SwiftUI
import AppKit
import HaloCore

/// True inside a test bundle. Real panels stay invisible there: tests size and drive them for real, but their fake
/// cards ("Couldn't convert", "icon is hidden") must never appear on the screen of whoever is running them.
public enum HaloRuntime {
    public static let isUnderTest = ["swiftpm-testing-helper", "xctest"].contains(ProcessInfo.processInfo.processName)
}

/// Motion tokens shared by the ring, the toast and onboarding. HaloDrag can use the durations to time phase changes.
public enum RingMotion {
    /// Per-segment delay during the bloom.
    public static let stagger: Double = 0.015
    /// How long `.committing` takes to pulse, collapse into the centre and send out the drop ripple. Set
    /// `.dismissing` after this.
    public static let commitDuration: Double = 0.40
    /// How long `.dismissing` takes to fade out. Set `.hidden` (or close the panel) after this.
    public static let dismissDuration: Double = 0.16
    /// Time for the last segment of a 12-item ring to settle after `.presenting`.
    public static let presentDuration: Double = 0.36 + 11 * stagger

    /// A spring as plain numbers, so tests can hold the app to one overshoot.
    struct Spring: Equatable {
        let response: Double
        let damping: Double
        var animation: Animation { .spring(response: response, dampingFraction: damping) }
    }

    /// The bloom: the one visible overshoot in the app, and its one loud moment.
    static let bloomSpring = Spring(response: 0.42, damping: 0.68)
    /// Runs many times per drag, so it stays crisp.
    static let hoverSpring = Spring(response: 0.20, damping: 0.82)
    static let pulseSpring = Spring(response: 0.16, damping: 0.86)
    static let collapseSpring = Spring(response: 0.22, damping: 0.95)
    /// Content changing its place or state: a step, a list, a card, a thumbnail landing.
    static let settleSpring = Spring(response: 0.34, damping: 0.86)
    static let allSprings = [bloomSpring, hoverSpring, pulseSpring, collapseSpring, settleSpring]

    /// A bubble leaving the centre, and the centre appearing with it. Settled in under half a second.
    static let bubbleBloom = bloomSpring.animation
    /// Per-bubble delay during the bloom, so they leave one after another.
    static let bubbleStagger: Double = 0.02
    /// A bubble swelling under the pointer, and its neighbours making room.
    static let bubbleHover = hoverSpring.animation
    /// Commit pulse.
    static let pulse = pulseSpring.animation
    /// Commit collapse into the centre.
    static let collapse = collapseSpring.animation
    static let settle = settleSpring.animation
    /// Small state changes: a line of words, a row's hover, a fill arriving.
    static let quick = Animation.easeOut(duration: 0.12)
    /// A progress value moving.
    static let progress = Animation.easeOut(duration: 0.2)
    /// Bubbles flowing back into the centre: they fade as they arrive, not before.
    static let gatherFade = Animation.easeInOut(duration: 0.3)
    /// A new file's thumbnail thrown onto its card.
    static let arrival = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.5)

    /// The hovered bubble: how much it swells and how far it moves out.
    static let hoverScale: CGFloat = 1.12
    static let hoverPush: CGFloat = 8
    /// Its neighbours make room; everything else steps back a touch.
    static let neighbourPush: CGFloat = 7
    static let neighbourScale: CGFloat = 0.95
    static let restingScale: CGFloat = 0.98
    /// The chosen bubble on a drop, a little past its hover.
    static let pulseScale: CGFloat = 1.16
    static let pulsePush: CGFloat = 5

    /// When the wedge lands in the centre, after the pulse.
    static let collapseDelay: Double = 0.12
    /// The one ripple the centre sends out on a drop. It ends as the dismiss fade does.
    static let rippleDuration: Double = commitDuration + dismissDuration - collapseDelay
    static let dismiss = Animation.easeOut(duration: dismissDuration)
    /// Everything under Reduce Motion: opacity crossfades only.
    static let crossfade = Animation.easeInOut(duration: 0.15)
}

public extension ActionCategory {
    /// Calm tint per family. System colours adapt to dark mode and Increase Contrast on their own. Nothing in the old
    /// brand's hue: the app is ember now, and a bubble in that hue would read as the old brand. Video takes the icon's gold (it lights a deep amber) and
    /// documents a cobalt that sits clear of the "More" blue.
    var tint: Color {
        switch self {
        case .image: Color(nsColor: .systemTeal)
        case .pdf: Color(nsColor: .systemRed)
        case .video: Color(nsColor: .systemYellow)
        case .audio: Color(nsColor: .systemPink)
        case .document: FamilyTint.cobalt
        case .text: Color(nsColor: .systemOrange)
        // Green, not brown: brown darkened to carry white text turned to mud, and green is the one clear hue left.
        case .archive: Color(nsColor: .systemGreen)
        }
    }
}

/// The one family colour the system has no name for. Hue about 227°: blue, a clear 19° or more from system blue in
/// every appearance, so documents and "More" never light up alike.
enum FamilyTint {
    static let cobalt = Color(nsColor: NSColor(name: "FrenzyCobalt") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.36, green: 0.50, blue: 1, alpha: 1)
            : NSColor(srgbRed: 0.20, green: 0.36, blue: 0.95, alpha: 1)
    })
}

extension RingItem {
    /// The colour this wedge lights in: its family's, or system blue for "More", which no family uses (the accent
    /// colour could be red or pink and pass for PDF or audio, and a neutral grey is lost among dark-mode glass).
    var tint: Color { isMore ? RingPalette.more : category.tint }
}

/// The live ring's colours, from the tint the system resolves for the current appearance (dark mode and Increase
/// Contrast included). Resting wedges stay neutral; the hovered wedge fills with its category colour, deepened just
/// enough that its white label reads at 4.5:1 or better (WCAG AA).
enum RingPalette {
    typealias RGB = HeroPalette.RGB

    /// The "More" wedge's colour: system blue, a hue no category uses.
    static let more = Color(nsColor: .systemBlue)

    /// The hovered wedge: the tint, darkened until white text on it passes AA.
    static func litFill(tint: RGB) -> RGB {
        HeroPalette.nudged(tint, toward: HeroPalette.black, until: { HeroPalette.contrast(HeroPalette.white, $0) >= HeroPalette.target })
    }
}

/// The app's four text sizes. Text takes one of these and nothing else (`Font.frenzy`); a big gap between steps does the
/// work that weight and extra sizes would. Nothing is smaller than 12 pt: the 11 pt step was too small to read for many
/// people (accessibility audit, 2026-11-07).
enum FrenzyTextSize: CGFloat, CaseIterable {
    case display = 40
    case lead = 17
    case body = 13
    case label = 12

    /// The smallest size any words in the app may take.
    static let minimum: CGFloat = 12
}

extension Font {
    static func frenzy(_ size: FrenzyTextSize, weight: Font.Weight = .regular) -> Font {
        .system(size: size.rawValue, weight: weight)
    }

    /// SF Symbols only, never words: a glyph is sized to its shape, not to the type scale.
    static func frenzyGlyph(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

extension View {
    /// A screen's one headline: large and regular weight, set tight.
    func frenzyDisplayType() -> some View {
        font(.frenzy(.display)).kerning(-0.8)
    }

    /// The one line under a headline.
    func frenzyLeadType() -> some View {
        font(.frenzy(.lead)).kerning(-0.2)
    }
}

/// Words on glass, as fixed colours and not `.primary`: glass may adapt what it does with `.primary` to whatever is behind
/// it, and these are what `LabelSurface` is measured against.
enum FrenzyInk {
    static let light = RingPalette.RGB(r: 0x17 / 255, g: 0x17 / 255, b: 0x1A / 255)
    static let dark = HeroPalette.white
}

/// Quieter words on a window's opaque ground (the main window, settings, onboarding). `.secondary` measured about 3.9:1 on
/// the light window and a 0.62 share of `.primary` about 4.2:1, both under AA. Pure values so tests can measure them.
enum WindowInk {
    /// Share of `.primary` (which is itself black or white at 85%) for detail text: about 7:1 on the light window and 6:1
    /// on the dark one, so it still clears 4.5:1 on the lighter control background.
    static let detailOpacity: Double = 0.8

    static func detail(_ contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? .primary : .primary.opacity(detailOpacity)
    }
}

/// Frosted glass fill that falls back to an opaque surface under Reduce Transparency.
struct GlassFill<S: Shape>: View {
    let shape: S
    var material: Material = .thinMaterial
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            shape.fill(Color(nsColor: .windowBackgroundColor))
        } else {
            shape.fill(material)
        }
    }
}

/// Hairline edge that catches light from above, like Control Center tiles. Stronger under Increase Contrast.
struct GlassEdge<S: Shape>: View {
    let shape: S
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if contrast == .increased {
            shape.stroke(Color.primary.opacity(0.55), lineWidth: 1)
        } else {
            let top = colorScheme == .dark ? 0.24 : 0.65
            let bottom = colorScheme == .dark ? 0.06 : 0.18
            shape.stroke(
                LinearGradient(colors: [.white.opacity(top), .white.opacity(bottom)], startPoint: .top, endPoint: .bottom),
                lineWidth: 0.75
            )
        }
    }
}
