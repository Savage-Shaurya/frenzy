import Testing
import SwiftUI
import AppKit
import HaloCore
@testable import HaloUI

/// Regressions for the accessibility audit and correctness review of 2026-11-07. No windows are shown: the toast panel
/// stays at alpha 0 under test (`HaloRuntime.isUnderTest`) and nothing is spoken.
@MainActor
@Suite struct AccessibilityFixTests {
    private func quietCenter() throws -> (ToastCenter, String) {
        let suite = "halo.tests.\(UUID().uuidString)"
        let settings = HaloSettings(defaults: try #require(UserDefaults(suiteName: suite)))
        settings.playSounds = false
        settings.revealAfterConvert = false
        return (ToastCenter(settings: settings), suite)
    }

    private func wait(_ milliseconds: Int) async {
        for _ in 0..<(milliseconds / 20) { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private static let result = ConversionResult(title: "Saved photo.jpg", outputs: [URL(fileURLWithPath: "/tmp/photo.jpg")],
                                                 actionTitle: "JPG", inputBytes: 169_000, outputBytes: 139_000,
                                                 folderName: "halo-test")

    // MARK: Toasts (audit 1, review 2 and 3)

    @Test func resultsFailuresAndNoticesAreAnnounced() throws {
        let (center, suite) = try quietCenter()
        defer { center.hide(); UserDefaults.standard.removePersistentDomain(forName: suite) }
        var said: [String] = []
        center.announce = { said.append($0) }
        center.showResult(job: "a", Self.result)
        center.showFailure(job: "b", title: "Couldn't convert notes.pages", message: "Pages files need Pages to open.")
        center.showNotice("Frenzy's icon is hidden", message: "Your menu bar is full.")
        #expect(said.count == 3)
        #expect(said[0].contains("Saved photo.jpg"))
        #expect(said[1].contains("Couldn't convert notes.pages") && said[1].contains("Pages files need Pages"))
        #expect(said[2].contains("icon is hidden"))
        // Progress changes many times a second: never announced.
        center.showProgress(job: "c", title: "JPG: x.heic", stage: "Converting…", file: nil, fraction: 0.3, onCancel: nil)
        #expect(said.count == 3)
    }

    @Test func failuresStayUntilDismissedButResultsGo() async throws {
        let (center, suite) = try quietCenter()
        defer { center.hide(); UserDefaults.standard.removePersistentDomain(forName: suite) }
        center.successDelay = .milliseconds(40)
        center.hoverPoll = .milliseconds(20)
        center.showFailure(job: "f", title: "Couldn't convert a.mov", message: "The file is damaged.")
        center.showResult(job: "r", Self.result)
        await wait(400)
        #expect(center.model.entries.map(\.id) == ["f"], "the result timed out, the failure did not")
        center.dismiss(job: "f")
        #expect(center.model.entries.isEmpty)
    }

    @Test func theLatestResultIsReachableWithoutTheMouse() throws {
        let (center, suite) = try quietCenter()
        defer { center.hide(); UserDefaults.standard.removePersistentDomain(forName: suite) }
        var changes: [ToastContent?] = []
        center.onLatestChange = { changes.append($0) }
        #expect(center.latest == nil)
        center.showResult(job: "a", Self.result)
        #expect(center.latest == .success(Self.result))
        center.showFailure(job: "b", title: "Couldn't convert b.pdf", message: "It is locked.")
        #expect(center.latest == .failure(title: "Couldn't convert b.pdf", message: "It is locked."))
        // Dismissing an older card leaves the latest alone; dismissing the latest clears it.
        center.dismiss(job: "a")
        #expect(center.latest != nil)
        center.dismiss(job: "b")
        #expect(center.latest == nil)
        #expect(changes.count == 3)
    }

    @Test func theLatestResultIsKeptWhenCardsAreOff() throws {
        let (center, suite) = try quietCenter()
        defer { center.hide(); UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = HaloSettings(defaults: try #require(UserDefaults(suiteName: suite)))
        settings.showToasts = false
        let off = ToastCenter(settings: settings)
        defer { off.hide() }
        off.showResult(job: "a", Self.result)
        #expect(off.model.entries.isEmpty)
        #expect(off.latest == .success(Self.result))
    }

    /// The height arrives during a SwiftUI update; resizing the panel there re-entered layout. It now waits a turn.
    @Test func theHeightIsAppliedOnTheNextTurnNotDuringTheUpdate() async throws {
        let (center, suite) = try quietCenter()
        defer { center.hide(); UserDefaults.standard.removePersistentDomain(forName: suite) }
        center.showNotice("Test", message: "Height.")
        await wait(400)
        let before = center.contentHeight
        let panel = try #require(center.panel)
        let frameBefore = panel.frame
        center.model.onContentHeight?(before + 120)
        #expect(center.contentHeight == before, "applied synchronously, inside the update")
        #expect(panel.frame == frameBefore)
        // The panel then springs to the new height (0.25 s).
        await wait(600)
        #expect(center.contentHeight == before + 120)
        #expect(abs(panel.frame.height - (before + 120)) <= 1)
    }

    /// A panel that shrinks under a still pointer never sends an exit event; the stale flag held cards forever.
    @Test func aStaleHoverDoesNotHoldCards() async throws {
        let (center, suite) = try quietCenter()
        defer { center.hide(); UserDefaults.standard.removePersistentDomain(forName: suite) }
        center.successDelay = .milliseconds(40)
        center.hoverPoll = .milliseconds(20)
        center.showResult(job: "r", Self.result)
        let panel = try #require(center.panel)
        // Really over the cards: they wait.
        center.pointerLocation = { NSPoint(x: panel.frame.midX, y: panel.frame.midY) }
        center.model.isHovering = true
        await wait(300)
        #expect(center.model.entries.count == 1)
        // The pointer has left without an exit event: the flag is ignored and the card goes.
        center.pointerLocation = { NSPoint(x: -100_000, y: -100_000) }
        await wait(300)
        #expect(center.model.entries.isEmpty)
        #expect(!center.model.isHovering)
    }

    @Test func aHoverCanHoldACardOnlySoLong() async throws {
        let (center, suite) = try quietCenter()
        defer { center.hide(); UserDefaults.standard.removePersistentDomain(forName: suite) }
        #expect(ToastCenter.maxHoverHold <= .seconds(120))
        center.successDelay = .milliseconds(40)
        center.hoverPoll = .milliseconds(20)
        center.hoverCap = .milliseconds(150)
        center.showResult(job: "r", Self.result)
        let panel = try #require(center.panel)
        center.pointerLocation = { NSPoint(x: panel.frame.midX, y: panel.frame.midY) }
        center.model.isHovering = true
        await wait(600)
        #expect(center.model.entries.isEmpty)
    }

    // MARK: Contrast (audit 2, 4, 5)

    private func resolved(_ color: NSColor, _ scheme: NSAppearance.Name) throws -> (rgb: RingPalette.RGB, alpha: Double) {
        var out: (RingPalette.RGB, Double)?
        try #require(NSAppearance(named: scheme)).performAsCurrentDrawingAppearance {
            if let c = color.usingColorSpace(.sRGB) {
                out = (RingPalette.RGB(r: c.redComponent, g: c.greenComponent, b: c.blueComponent), Double(c.alphaComponent))
            }
        }
        return try #require(out)
    }

    /// `color` at `opacity` (times its own alpha) over `ground`.
    private func ink(_ color: NSColor, _ opacity: Double, over ground: RingPalette.RGB, _ scheme: NSAppearance.Name) throws -> Double {
        let (rgb, alpha) = try resolved(color, scheme)
        return HeroPalette.contrast(ground.mixed(with: rgb, alpha * opacity), ground)
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func detailTextOnTheWindowReadsAtAA(scheme: NSAppearance.Name) throws {
        for groundColor in [NSColor.windowBackgroundColor, .controlBackgroundColor] {
            let ground = try resolved(groundColor, scheme).rgb
            let ratio = try ink(.labelColor, WindowInk.detailOpacity, over: ground, scheme)
            #expect(ratio >= 4.5, "\(scheme.rawValue) \(groundColor): \(ratio)")
        }
    }

    /// The old 0.62 share failed over a light glass; details on cards now take the full ink.
    @Test(arguments: [(NSAppearance.Name.aqua, 0.75), (NSAppearance.Name.darkAqua, 0.3)])
    func detailTextOnCardsReadsOverAPaleOrDarkGlass(scheme: NSAppearance.Name, glass: Double) throws {
        let ground = RingPalette.RGB(r: glass, g: glass, b: glass)
        #expect(CardMetrics.detailOpacity == 1)
        #expect(try ink(.labelColor, CardMetrics.detailOpacity, over: ground, scheme) >= 4.5)
        #expect(try ink(.labelColor, 0.62, over: ground, scheme) < 4.5, "the pale glass is a real worst case")
    }

    @Test func theRimShowsOnlyWithoutGlass() {
        #expect(!GlassRim(reduceTransparency: false, increasedContrast: false, dark: false).isShown)
        #expect(GlassRim(reduceTransparency: true, increasedContrast: false, dark: false).isShown)
        #expect(GlassRim(reduceTransparency: false, increasedContrast: true, dark: true).isShown)
    }

    /// Under Reduce Transparency or Increase Contrast a bubble or card is an opaque surface with an ink rim. The rim holds
    /// the shape against the surface, and against any backdrop the rim or the surface reaches 3:1.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func theRimMeets3To1AgainstAnyBackdrop(scheme: NSAppearance.Name) throws {
        let surface = try resolved(.windowBackgroundColor, scheme).rgb
        let rim = GlassRim(reduceTransparency: true, increasedContrast: false, dark: scheme == .darkAqua)
        #expect(HeroPalette.contrast(rim.tone, surface) >= 3)
        var backdrops = stride(from: 0.0, through: 1.0, by: 0.02).map { RingPalette.RGB(r: $0, g: $0, b: $0) }
        backdrops += [RingPalette.RGB(r: 1, g: 0, b: 0), RingPalette.RGB(r: 0, g: 0, b: 1), RingPalette.RGB(r: 1, g: 1, b: 0),
                      RingPalette.RGB(r: 0, g: 0.6, b: 0.3), surface]
        for backdrop in backdrops {
            let best = max(HeroPalette.contrast(rim.tone, backdrop), HeroPalette.contrast(surface, backdrop))
            #expect(best >= 3, "\(scheme.rawValue) over \(backdrop): \(best)")
        }
        #expect(GlassRim.width >= 1)
    }

    // MARK: Keyboard (audit 7)

    @Test func arrowKeysWalkTheBubblesAndWrap() {
        #expect(BubbleKeyboard.direction(for: .rightArrow) == .forward)
        #expect(BubbleKeyboard.direction(for: .downArrow) == .forward)
        #expect(BubbleKeyboard.direction(for: .leftArrow) == .backward)
        #expect(BubbleKeyboard.direction(for: .upArrow) == .backward)
        #expect(BubbleKeyboard.direction(for: .return) == nil)
        #expect(BubbleKeyboard.step(from: nil, .forward, count: 12) == 0)
        #expect(BubbleKeyboard.step(from: nil, .backward, count: 12) == 11)
        #expect(BubbleKeyboard.step(from: 11, .forward, count: 12) == 0)
        #expect(BubbleKeyboard.step(from: 0, .backward, count: 12) == 11)
        #expect(BubbleKeyboard.step(from: 8, .forward, count: 12) == 9, "the tenth bubble, which has no number key")
        #expect(BubbleKeyboard.step(from: 3, .forward, count: 0) == nil)
        // Every bubble is reachable from nothing lit.
        var seen = Set<Int>(), at: Int? = nil
        for _ in 0..<12 { at = BubbleKeyboard.step(from: at, .forward, count: 12); seen.insert(at!) }
        #expect(seen == Set(0..<12))
    }

    @Test func recentRowsAreInTheTabLoopWithoutFullKeyboardAccess() {
        #expect(RecentsMetrics.rowFocus == .edit)
    }

    // MARK: Idle examples (audit 10)

    @Test func theExampleBubblesOpenTheFilePicker() {
        let model = HomeModel()
        var opened = 0
        model.onChooseFiles = { opened += 1 }
        HomeHero.examplesAction(model)(HomeHero.items[0])
        #expect(opened == 1)
        #expect(HomeCopy.examplesHelp.contains("Example"))
    }

    // MARK: Onboarding (audit 8, 9)

    @Test func notNowAndTheDisabledButtonSayWhy() {
        let blocked = OnboardingFooterPlan(stepIndex: 1, isLast: true, isOnTry: false, tryIsDone: false,
                                           blockedByPermission: true, permissionName: "Accessibility")
        #expect(!blocked.primaryEnabled)
        #expect(blocked.disabledReason?.contains("Allow Accessibility") == true)
        #expect(blocked.notNowHelp?.contains("won't open the bubbles") == true)
        let open = OnboardingFooterPlan(stepIndex: 1, isLast: true, isOnTry: false, tryIsDone: false, blockedByPermission: false)
        #expect(open.disabledReason == nil && open.notNowHelp == nil)
        let permissions = OnboardingPermissions(isRequired: true, request: {})
        #expect(permissions.withoutItNote.contains("won't open the bubbles"))
    }

    @Test func tryItHasAKeyboardPath() {
        #expect(TryItStep.offersConvertButton(phase: .waiting, isPaused: false, canConvert: true))
        #expect(TryItStep.offersConvertButton(phase: .failed("No."), isPaused: false, canConvert: true))
        #expect(!TryItStep.offersConvertButton(phase: .waiting, isPaused: true, canConvert: true))
        #expect(!TryItStep.offersConvertButton(phase: .waiting, isPaused: false, canConvert: false))
        #expect(!TryItStep.offersConvertButton(phase: .working(actionTitle: "JPG"), isPaused: false, canConvert: true))
        #expect(!TryItStep.offersConvertButton(phase: .done(output: URL(fileURLWithPath: "/tmp/a.jpg"), actionTitle: "JPG"),
                                               isPaused: false, canConvert: true))
    }

    // MARK: Copy (audit 11, 12)

    @Test func claimsAreExactNotAbsolute() throws {
        let dir = HomeRenderTests.repoRoot.appendingPathComponent("Sources/HaloUI", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for claim in ["100% offline", "Nothing is ever uploaded", "never reads what you type", "never leave this Mac"] {
                #expect(!text.contains(claim), "\(file.lastPathComponent) still says \"\(claim)\"")
            }
        }
        #expect(SettingsCopy.privacyHeadline == "Conversions run in a helper macOS blocks from the network.")
        #expect(!OnboardingPermissions.defaultExplanation.contains("never"))
    }

    @Test func pauseAndRevealSayWhatHappens() {
        #expect(HaloSettings.pauseGesture.contains("half a second"))
        #expect(SettingsCopy.pauseToggle.contains("half a second"))
        #expect(SettingsCopy.ringFooter(gesture: HaloSettings.pauseGesture).contains("half a second"))
        #expect(SettingsCopy.resultsFooter.contains("brings Finder to the front"))
    }

    @Test func newCopyHasNoEmDashes() {
        let copy = [SettingsCopy.pauseToggle, SettingsCopy.ringFooter(gesture: HaloSettings.pauseGesture), SettingsCopy.revealToggle,
                    SettingsCopy.resultsFooter, SettingsCopy.previewsFooter, SettingsCopy.privacyHeadline, SettingsCopy.privacyDetail,
                    HomeCopy.footer, HomeCopy.examplesHelp, OnboardingPermissions.defaultExplanation,
                    OnboardingPermissions(isRequired: true, request: {}).withoutItNote, ChoiceHint.text(count: 12)]
        for line in copy { #expect(!line.contains("\u{2014}") && !line.contains("\u{2013}"), "\(line)") }
    }
}
