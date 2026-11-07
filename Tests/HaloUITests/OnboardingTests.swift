import Testing
import SwiftUI
import AppKit
import ImageIO
import HaloCore
@testable import HaloUI

/// First-run onboarding: the sample photo Halo draws, the state the app drives, which steps and buttons appear, that
/// every state fits the window, and renders of every step for the design review
/// (loop/shots/<HALO_SHOTS or "latest">/onboarding-*.png). Offline renders don't draw Liquid Glass: they check layout,
/// clipping and contrast, not the glass itself.
@MainActor
@Suite struct OnboardingTests {
    static func tempFolder(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-onboarding-\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        return dir
    }

    @Test func theSampleIsARealPhotoHaloCanConvert() throws {
        let dir = try Self.tempFolder("sample")
        let url = try OnboardingSample.prepare(in: dir)
        #expect(url.lastPathComponent == "Frenzy sample.png")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 1200)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == 800)
        let input = try #require(InputFile(url: url))
        #expect(input.type.conforms(to: .image))
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func preparingAgainKeepsTheSameFileAndRepairsABrokenOne() throws {
        let dir = try Self.tempFolder("again")
        let url = try OnboardingSample.prepare(in: dir)
        let made = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(try OnboardingSample.prepare(in: dir) == url)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == made)
        // Someone emptied it: it is drawn again rather than handing the user a broken file.
        try Data().write(to: url)
        _ = try OnboardingSample.prepare(in: dir)
        #expect(CGImageSourceCreateWithURL(url as CFURL, nil).map(CGImageSourceGetCount) == 1)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func aLinkInTheSamplesPlaceIsReplacedNotWrittenThrough() throws {
        let dir = try Self.tempFolder("link")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let elsewhere = dir.appendingPathComponent("elsewhere.png")
        let link = dir.appendingPathComponent(OnboardingSample.fileName)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        _ = try OnboardingSample.prepare(in: dir)
        #expect(!FileManager.default.fileExists(atPath: elsewhere.path))
        let values = try link.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        #expect(values.isSymbolicLink == false && values.isRegularFile == true)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func onlyTheSampleItselfMovesTheStep() {
        let sample = URL(fileURLWithPath: "/tmp/halo-x/Try Frenzy/Frenzy sample.png")
        let model = OnboardingTry(sampleURL: sample)
        #expect(model.isSample([URL(fileURLWithPath: "/tmp/halo-x/Try Frenzy/../Try Frenzy/Frenzy sample.png")]))
        #expect(!model.isSample([URL(fileURLWithPath: "/Users/someone/Desktop/Frenzy sample.png")]))
        #expect(!model.isSample([sample, URL(fileURLWithPath: "/tmp/other.png")]))
        #expect(!model.isSample([]))
    }

    @Test func phasesFollowTheConversion() {
        let model = OnboardingTry(sampleURL: URL(fileURLWithPath: "/tmp/Frenzy sample.png"))
        #expect(model.phase == .waiting && !model.isDone)
        model.began("JPG")
        #expect(model.phase == .working(actionTitle: "JPG"))
        // Cancelled: back to waiting, no blame.
        model.finished(outputs: [], actionTitle: "JPG", failure: nil)
        #expect(model.phase == .waiting)
        model.finished(outputs: [], actionTitle: "JPG", failure: "Frenzy couldn't convert the sample.")
        #expect(model.phase == .failed("Frenzy couldn't convert the sample."))
        let out = URL(fileURLWithPath: "/tmp/Frenzy sample.jpg")
        model.finished(outputs: [out], actionTitle: "JPG", failure: nil)
        #expect(model.phase == .done(output: out, actionTitle: "JPG"))
        #expect(model.isDone)
        model.reset()
        #expect(model.phase == .waiting)
    }

    // MARK: Which steps and buttons appear

    @Test func optionalStepsOnlyAppearWhenTheyApply() {
        typealias Step = OnboardingView.Step
        #expect(OnboardingView.steps(opensOnPause: true, permissionsRequired: false, hasTry: true) == [Step.welcome, .tryIt])
        #expect(OnboardingView.steps(opensOnPause: false, permissionsRequired: false, hasTry: true) == [Step.welcome, .trigger, .tryIt])
        #expect(OnboardingView.steps(opensOnPause: true, permissionsRequired: true, hasTry: true) == [Step.welcome, .permissions, .tryIt])
        // No sample could be prepared: onboarding still works, without the try.
        #expect(OnboardingView.steps(opensOnPause: true, permissionsRequired: false, hasTry: false) == [Step.welcome])
    }

    @Test func skipIsQuietUntilTheSampleConverts() {
        let waiting = OnboardingFooterPlan(stepIndex: 1, isLast: true, isOnTry: true, tryIsDone: false, blockedByPermission: false)
        #expect(waiting.skip == "Skip")
        // Return must not skip the lesson: there is no primary (default) button while waiting.
        #expect(waiting.primary == nil)
        #expect(waiting.showsBack)

        let done = OnboardingFooterPlan(stepIndex: 1, isLast: true, isOnTry: true, tryIsDone: true, blockedByPermission: false)
        #expect(done.skip == nil)
        #expect(done.primary == "Start using Frenzy")
        #expect(done.primaryEnabled)
    }

    @Test func otherStepsHaveOnePrimaryButton() {
        let first = OnboardingFooterPlan(stepIndex: 0, isLast: false, isOnTry: false, tryIsDone: false, blockedByPermission: false)
        #expect(first.primary == "Continue" && first.skip == nil && !first.showsBack && !first.showsNotNow)

        // Waiting on a permission: the way forward is disabled, with a quiet way out.
        let blocked = OnboardingFooterPlan(stepIndex: 1, isLast: true, isOnTry: false, tryIsDone: false, blockedByPermission: true)
        #expect(blocked.primary == "Start using Frenzy" && !blocked.primaryEnabled && blocked.showsNotNow)
    }

    @Test func theWelcomeFilmTellsTheWholeStoryAndRests() {
        let film = WelcomeDemoBeat.film
        #expect(!film[0].spread && !film[0].showsResult)
        #expect(film[1].spread && film[1].hovered == nil)
        #expect(film[2].spread && film[2].hovered != nil)
        #expect(!film[3].spread && film[3].showsResult && film[3].hovered == nil)
        #expect(film.allSatisfy { $0.holdMilliseconds > 0 })
        // Reduce Motion: open and still.
        #expect(WelcomeDemoBeat.still.spread && WelcomeDemoBeat.still.hovered == nil && !WelcomeDemoBeat.still.showsResult)
    }

    @Test func tryItWordsFollowThePhase() {
        let out = URL(fileURLWithPath: "/tmp/Frenzy sample.jpg")
        let gesture = "pause for a moment"
        #expect(TryItCopy(phase: .waiting, isPaused: false, gesture: gesture).message.contains(gesture))
        #expect(TryItCopy(phase: .waiting, isPaused: false, gesture: "hold ⌥ Option").message.contains("hold ⌥ Option"))
        #expect(TryItCopy(phase: .waiting, isPaused: true, gesture: gesture).title == "Frenzy is paused")
        #expect(TryItCopy(phase: .working(actionTitle: "PDF"), isPaused: false, gesture: gesture).message.contains("PDF"))
        let done = TryItCopy(phase: .done(output: out, actionTitle: "JPG"), isPaused: false, gesture: gesture)
        #expect(done.title == "That's it.")
        // Honest: the only places drags are known to work from.
        #expect(done.message.contains("Finder") && done.message.contains("Desktop"))
        #expect(TryItCopy(phase: .failed("It broke."), isPaused: false, gesture: gesture).message == "It broke.")
    }

    @Test func triggerBubblesNameEveryKeyPlainly() {
        #expect(TriggerKey.allCases.map(\.bubbleTitle) == ["Option", "Shift", "Control", "Function"])
    }

    // MARK: Fit

    @Test func theHeroHoldsTheLargestCluster() {
        for count in [TriggerKey.allCases.count, 6] {
            #expect(BubbleCluster<EmptyView>.side(.window(count: count)) <= OnboardingMetrics.heroHeight)
            #expect(BubbleCluster<EmptyView>.side(.window(count: count)) <= OnboardingMetrics.contentWidth)
        }
        let row = TryItStep.doneTileWidth * 2 + TryItStep.doneTileSpacing
        #expect(row <= OnboardingMetrics.contentWidth)
        #expect(TryItStep.waitingTileWidth <= OnboardingMetrics.contentWidth)
    }

    /// Asks each state how tall it wants to be: anything over the step's height would be clipped by the window.
    @Test func everyTryItStateFitsTheWindow() throws {
        let dir = try Self.tempFolder("fit")
        let sample = try OnboardingSample.prepare(in: dir)
        let longFailure = String(repeating: "Frenzy couldn't convert the sample because of a long reason. ", count: 8)
        let phases: [OnboardingTry.Phase] = [
            .waiting, .working(actionTitle: "JPG"), .failed(longFailure),
            .done(output: dir.appendingPathComponent("A very long output file name that keeps going and going.jpg"), actionTitle: "JPG"),
            .done(output: dir.appendingPathComponent("Frenzy sample.pdf"), actionTitle: "PDF"),
        ]
        for phase in phases {
            for paused in [false, true] {
                let model = OnboardingTry(sampleURL: sample)
                model.phase = phase
                model.isPaused = paused
                model.resume = {}
                let host = NSHostingView(rootView: TryItStep(model: model, gesture: "hold ⌃ Control")
                    .frame(width: OnboardingMetrics.contentWidth))
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.height <= OnboardingMetrics.stepHeight, "\(phase), paused: \(paused)")
            }
        }
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Renders

    private func render(_ view: some View, name: String, scheme: NSAppearance.Name) throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: OnboardingMetrics.windowSize)
        host.appearance = NSAppearance(named: scheme)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.9))
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let dir = HomeRenderTests.shotsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("\(name)-\(scheme == .darkAqua ? "dark" : "light").png"))
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func everyStepRenders(scheme: NSAppearance.Name) throws {
        let dir = try Self.tempFolder("render-\(scheme.rawValue)")
        let sample = try OnboardingSample.prepare(in: dir)
        let settings = HaloSettings(defaults: UserDefaults(suiteName: "halo.onboarding.render")!)
        settings.trigger = .option
        let permissions = OnboardingPermissions(isRequired: false, request: {})
        func view(_ step: OnboardingView.Step, _ model: OnboardingTry, beat: WelcomeDemoBeat = .still) -> OnboardingView {
            OnboardingView(settings: settings, permissions: permissions, tryIt: model, startAt: step, heldBeat: beat, onFinish: {})
        }

        let waiting = OnboardingTry(sampleURL: sample)
        try render(view(.welcome, waiting), name: "onboarding-1-welcome", scheme: scheme)
        try render(view(.welcome, waiting, beat: WelcomeDemoBeat.film[2]), name: "onboarding-1b-welcome-choosing", scheme: scheme)
        try render(view(.welcome, waiting, beat: WelcomeDemoBeat.film[3]), name: "onboarding-1c-welcome-result", scheme: scheme)
        try render(view(.trigger, waiting), name: "onboarding-2-trigger", scheme: scheme)
        try render(OnboardingView(settings: settings,
                                  permissions: OnboardingPermissions(isRequired: true, request: {}),
                                  tryIt: waiting, startAt: .permissions, onFinish: {}),
                   name: "onboarding-2b-permission", scheme: scheme)
        try render(view(.tryIt, waiting), name: "onboarding-3-try", scheme: scheme)

        let working = OnboardingTry(sampleURL: sample)
        working.began("JPG")
        try render(view(.tryIt, working), name: "onboarding-4-working", scheme: scheme)

        let done = OnboardingTry(sampleURL: sample)
        done.finished(outputs: [dir.appendingPathComponent("Frenzy sample.jpg")], actionTitle: "JPG", failure: nil)
        try render(view(.tryIt, done), name: "onboarding-5-done", scheme: scheme)

        let doneOther = OnboardingTry(sampleURL: sample)
        doneOther.finished(outputs: [dir.appendingPathComponent("Frenzy sample.pdf")], actionTitle: "PDF", failure: nil)
        try render(view(.tryIt, doneOther), name: "onboarding-5b-done-pdf", scheme: scheme)

        let paused = OnboardingTry(sampleURL: sample)
        paused.isPaused = true
        paused.resume = {}
        try render(view(.tryIt, paused), name: "onboarding-6-paused", scheme: scheme)

        let failed = OnboardingTry(sampleURL: sample)
        failed.finished(outputs: [], actionTitle: "JPG",
                        failure: String(repeating: "Frenzy couldn't convert the sample because of a long reason. ", count: 8))
        try render(view(.tryIt, failed), name: "onboarding-7-failed", scheme: scheme)
        try? FileManager.default.removeItem(at: dir)
    }
}
