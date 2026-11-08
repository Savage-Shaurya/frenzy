import Testing
import SwiftUI
import AppKit
import HaloCore
import HaloConverters
@testable import HaloUI

/// The numbers the design direction commits to (docs/DESIGN-DIRECTION.md, "Lusion and taste benchmark"). Offscreen renders
/// can't draw Liquid Glass, so the contrast here is worked out without any help from the glass.
@MainActor
@Suite struct DesignPolishTests {
    // MARK: Type

    private static var sources: [(name: String, text: String)] {
        get throws {
            let dir = HomeRenderTests.repoRoot.appendingPathComponent("Sources/HaloUI", isDirectory: true)
            return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
                .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
        }
    }

    /// Nothing under 12 pt (accessibility audit, 2026-11-07): the old 11 pt step is gone.
    @Test func thereAreFourTextSizesAndNoneUnder12() {
        #expect(FrenzyTextSize.allCases.map(\.rawValue) == [40, 17, 13, 12])
        #expect(FrenzyTextSize.allCases.allSatisfy { $0.rawValue >= FrenzyTextSize.minimum })
        #expect(FrenzyTextSize.minimum >= 12)
    }

    /// Words only reach a size through `Font.frenzy`, and system text styles would bring sizes of their own.
    @Test func nothingSetsASizeOutsideTheTokens() throws {
        let styles = ["largeTitle", "title", "title2", "title3", "headline", "subheadline", "body", "callout", "footnote", "caption", "caption2"]
        for (name, text) in try Self.sources {
            for style in styles { #expect(!text.contains(".font(.\(style))"), "\(name) uses .\(style)") }
            if name != "HaloStyle.swift" { #expect(!text.contains(".system(size:"), "\(name) sets a size of its own") }
        }
    }

    @Test func bubbleLabelsKeepToTheScale() {
        for count in 1...12 {
            for layout in [RingBubbleLayout(count: count), .window(count: count)] {
                #expect(layout.titleSize == .label, "\(count)")
            }
        }
    }

    // MARK: Labels on glass

    /// `ink` on the plate, over `backdrop`.
    private func contrast(_ surface: LabelSurface, over backdrop: RingPalette.RGB) -> Double {
        HeroPalette.contrast(surface.ink, backdrop.mixed(with: surface.plateTone, surface.plateOpacity))
    }

    private func accent(_ scheme: NSAppearance.Name) throws -> RingPalette.RGB {
        var rgb: RingPalette.RGB?
        try #require(NSAppearance(named: scheme)).performAsCurrentDrawingAppearance {
            if let c = NSColor(FrenzyPalette.accent).usingColorSpace(.sRGB) {
                rgb = RingPalette.RGB(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
            }
        }
        return try #require(rgb)
    }

    /// The overlay's words reach 4.5:1 over anything a page or wallpaper can put behind them.
    @Test func wordsOnTheOverlayReadOnAnyBackground() {
        let backdrops: [(String, RingPalette.RGB)] = [
            ("white", HeroPalette.white), ("black", HeroPalette.black),
            ("mid grey", RingPalette.RGB(r: 0.5, g: 0.5, b: 0.5)), ("red", RingPalette.RGB(r: 1, g: 0, b: 0)),
            ("yellow", RingPalette.RGB(r: 1, g: 1, b: 0)), ("blue", RingPalette.RGB(r: 0, g: 0, b: 1)),
        ]
        for dark in [false, true] {
            for increased in [false, true] {
                let surface = LabelSurface(ground: .anything, dark: dark, increasedContrast: increased, reduceTransparency: false)
                for (name, backdrop) in backdrops {
                    #expect(contrast(surface, over: backdrop) >= 4.5, "\(name), dark: \(dark), increased: \(increased)")
                }
            }
        }
    }

    /// Bubbles in the window sit on its plain ground: no plate, and the ink alone clears 4.5:1.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func wordsInTheWindowRead(scheme: NSAppearance.Name) throws {
        var ground: RingPalette.RGB?
        try #require(NSAppearance(named: scheme)).performAsCurrentDrawingAppearance {
            if let c = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) {
                ground = RingPalette.RGB(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
            }
        }
        let surface = LabelSurface(ground: .window, dark: scheme == .darkAqua, increasedContrast: false, reduceTransparency: false)
        #expect(surface.plateOpacity == 0)
        #expect(contrast(surface, over: try #require(ground)) >= 4.5)
    }

    /// A centre on the disc: white on the accent, even if the glass lightens what it shows. These amounts are a pessimistic
    /// guess at the glass, which offscreen renders can't draw: check them live.
    @Test(arguments: [(NSAppearance.Name.aqua, 0.4), (NSAppearance.Name.darkAqua, 0.15)])
    func wordsOnTheDiscRead(scheme: NSAppearance.Name, glassLightens: Double) throws {
        let dark = scheme == .darkAqua
        let surface = LabelSurface(ground: .disc, dark: dark, increasedContrast: false, reduceTransparency: false)
        #expect(surface.ink == HeroPalette.white)
        // The disc runs flame into the accent into deep ember; the words sit where it is the accent or deeper.
        for tone in [try accent(scheme), FrenzyPalette.deep] {
            #expect(contrast(surface, over: tone) >= 4.5)
            #expect(contrast(surface, over: tone.mixed(with: HeroPalette.white, glassLightens)) >= 4.5)
        }
    }

    /// With the disc gone, a centre goes back to the ordinary ink and no plate.
    @Test func withoutTheDiscTheCentreIsOrdinary() {
        for dark in [false, true] {
            for (increased, reduced) in [(true, false), (false, true)] {
                let surface = LabelSurface(ground: .disc, dark: dark, increasedContrast: increased, reduceTransparency: reduced)
                #expect(surface.ink == (dark ? FrenzyInk.dark : FrenzyInk.light))
                #expect(surface.plateOpacity == 0)
            }
        }
        #expect(LabelSurface(ground: .anything, dark: true, increasedContrast: false, reduceTransparency: true).plateOpacity == 0)
    }

    /// The rim stays clear, or the glass has nothing left to bend.
    @Test func thePlateLeavesTheRimClear() {
        #expect(LabelPlate.solidUntil < 1)
        #expect(RingBubbleLayout(count: 12).diameter / 2 * (1 - LabelPlate.solidUntil) >= 4)
    }

    /// One line: the name, or what the hovered bubble does in its place. The size never takes a line.
    @Test func theCentreSaysOneThing() {
        #expect(RingCenterView.line(label: "a.png", detail: "2 MB", isHint: false) == "a.png")
        #expect(RingCenterView.line(label: "a.png", detail: "Smaller file", isHint: true) == "Smaller file")
        #expect(RingCenterView.line(label: "a.png", detail: nil, isHint: true) == "a.png")
    }

    // MARK: The disc

    /// Its hard edge runs behind the bubbles, where the glass can bend it, and stays off the words under the hero.
    @Test func theDiscGivesTheGlassAnEdge() {
        #expect(HeroDiscRule.diameter == 184)
        #expect(HeroDiscRule.diameter > BubbleStage.hub)
        for count in 1...8 {
            let layout = RingBubbleLayout.window(count: count)
            let inRim = HeroDiscRule.diameter / 2 - (layout.orbit - layout.diameter / 2)
            #expect(inRim > 0, "\(count): the edge misses the bubbles")
            // Inside the part the plate leaves clear would be ideal; the words start well past this.
            #expect(inRim <= layout.diameter / 2 * (1 - 0.68), "\(count): the edge runs into the words")
        }
        for count in 1...12 {
            let bounds = BubbleStage(count: count).bounds
            let disc = HeroDiscRule.diameter * BubbleStage.dropScale
            #expect(bounds.contains(CGRect(x: -disc / 2, y: -disc / 2, width: disc, height: disc)), "\(count)")
        }
    }

    @Test func theDiscGoesWhenItWouldGetInTheWay() {
        #expect(HeroDiscRule.isShown(reduceTransparency: false, contrast: .standard))
        #expect(!HeroDiscRule.isShown(reduceTransparency: true, contrast: .standard))
        #expect(!HeroDiscRule.isShown(reduceTransparency: false, contrast: .increased))
    }

    // MARK: Hierarchy

    /// In the window the centre clearly leads. The overlay keeps its own sizes.
    @Test func theCentreLeadsInTheWindow() {
        for count in 1...12 {
            let window = RingBubbleLayout.window(count: count), ring = RingBubbleLayout(count: count)
            #expect(window.diameter <= RingBubbleLayout.windowDiameter)
            #expect(BubbleStage.hub / window.diameter >= 1.4, "\(count)")
            #expect(window.orbit >= ring.orbit)
            #expect(window.diameter <= ring.diameter)
            #expect(window.diameter >= 44, "\(count): a bubble is a button here")
        }
        #expect(RingBubbleLayout(count: 6).diameter == 92)
    }

    // MARK: Motion

    @Test func hoverIsCrispAndOnlyTheBloomOvershoots() {
        #expect(RingMotion.hoverSpring == .init(response: 0.20, damping: 0.82))
        #expect(RingMotion.hoverScale == 1.12)
        #expect(RingMotion.hoverPush == 8)
        #expect(RingMotion.bloomSpring == .init(response: 0.42, damping: 0.68))
        for spring in RingMotion.allSprings where spring != RingMotion.bloomSpring {
            #expect(spring.damping >= 0.8, "\(spring) overshoots")
        }
    }

    /// Every spring in the app comes from the tokens above.
    @Test func noSpringsOutsideTheTokens() throws {
        for (name, text) in try Self.sources where name != "HaloStyle.swift" {
            #expect(!text.contains(".spring("), "\(name) has a spring of its own")
            #expect(!text.contains(".symbolEffect(.bounce"), "\(name) bounces")
        }
    }

    /// From beside the tile to exactly its place, bowed upward and staying near the card.
    @Test func theThumbnailArrivesOnASmallArc() {
        #expect(ArcArrival.offset(at: 0) == ArcArrival.start)
        #expect(ArcArrival.offset(at: 1) == .zero)
        let middle = ArcArrival.offset(at: 0.5)
        #expect(middle.height < ArcArrival.start.height / 2, "it bows upward")
        #expect(ArcArrival.lift <= 140)
        #expect(ArcArrival.start.width >= 0, "it comes from inside the card, never past the panel's left edge")
        for step in 0...20 {
            let at = ArcArrival.offset(at: CGFloat(step) / 20)
            #expect(at.height >= -CardMetrics.padding - 8, "it stays near the card: \(at)")
        }
    }

    // MARK: Welcome

    /// The film promises what the ring really offers for a PDF: same names, same words, same order.
    @Test func theWelcomeFilmShowsARealRing() throws {
        let pdf = try HomeRenderTests.fixtures().appendingPathComponent("Quarterly report.pdf")
        let real = try HomeRenderTests.realItems(for: pdf)
        for item in WelcomeDemo.items {
            let match = try #require(real.first { $0.id == item.id }, "\(item.id) isn't offered for a PDF")
            #expect(match == item)
        }
        let order = WelcomeDemo.items.compactMap { item in real.firstIndex { $0.id == item.id } }
        #expect(order == order.sorted())
        #expect(WelcomeDemo.makePage() != nil)
    }
}
