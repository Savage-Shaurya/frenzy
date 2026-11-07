import AppKit
import Testing
@testable import HaloDrag

@Suite struct MenuBarIconVisibilityTests {
    // A 14" MacBook Pro: 1512×982 points, menu bar 32 pt tall, notch side areas as AppKit reports them.
    let notched = MenuBarIconVisibility.Screen(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        notchLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32),
        notchRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32))
    let external = MenuBarIconVisibility.Screen(frame: CGRect(x: 1512, y: -300, width: 2560, height: 1440))

    @Test func iconRightOfTheNotchIsVisible() {
        let icon = CGRect(x: 1200, y: 950, width: 38, height: 32)
        #expect(MenuBarIconVisibility.classify(iconFrame: icon, screens: [notched], occlusionVisible: true) == .visible)
    }

    @Test func iconUnderTheNotchIsHidden() {
        let icon = CGRect(x: 740, y: 950, width: 38, height: 32)
        let result = MenuBarIconVisibility.classify(iconFrame: icon, screens: [notched], occlusionVisible: true)
        #expect(result == .behindNotch)
        #expect(result.isHidden)
    }

    @Test func zeroHeightFrameMeansNotLaidOutYetNotHidden() {
        // The exact frame Halo logged at launch on 1 Nov 2026: {{0, 0}, {38, 0}}.
        let result = MenuBarIconVisibility.classify(iconFrame: CGRect(x: 0, y: 0, width: 38, height: 0),
                                                    screens: [notched], occlusionVisible: false)
        #expect(result == .notLaidOut)
        #expect(!result.isHidden)
    }

    @Test func frameOffEveryScreen() {
        let icon = CGRect(x: -500, y: 2000, width: 38, height: 32)
        #expect(MenuBarIconVisibility.classify(iconFrame: icon, screens: [notched, external], occlusionVisible: true) == .offScreen)
    }

    @Test func occludedOnlyCountsWhileTheMenuBarIsShown() {
        let icon = CGRect(x: 1200, y: 950, width: 38, height: 32)
        #expect(MenuBarIconVisibility.classify(iconFrame: icon, screens: [notched], occlusionVisible: false) == .occluded)
        #expect(MenuBarIconVisibility.classify(iconFrame: icon, screens: [notched], occlusionVisible: false,
                                               menuBarShown: false) == .visible)
    }

    @Test func screenWithoutNotchNeverReportsNotch() {
        let icon = CGRect(x: 2000, y: 1108, width: 38, height: 32)
        #expect(MenuBarIconVisibility.classify(iconFrame: icon, screens: [notched, external], occlusionVisible: true) == .visible)
    }
}
