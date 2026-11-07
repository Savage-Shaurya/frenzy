import Testing
import SwiftUI
import AppKit
import HaloCore
@testable import HaloUI

/// The result card (B4): honest stage lines, measured sizes and folder, card behaviour, and renders of every card
/// state (light and dark) to loop/shots/<HALO_SHOTS or "latest">/card-*.png for the design review.
@MainActor
@Suite struct ResultCardTests {
    // MARK: Stage lines

    /// The real panel, not a render: the founder saw a result card's top and buttons cut off. `sizingOptions = []` made
    /// the hosting view's `fittingSize` 0, so the panel stayed at its 56 pt minimum for every card.
    @Test func theRealPanelFitsEveryKindOfCard() async throws {
        let suite = "halo.tests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = HaloSettings(defaults: try #require(UserDefaults(suiteName: suite)))
        settings.playSounds = false
        settings.revealAfterConvert = false
        let center = ToastCenter(settings: settings)
        defer { center.hide() }
        func settle() async { for _ in 0..<40 { try? await Task.sleep(for: .milliseconds(25)) } }
        let actions = ToastActions(open: { _, _ in }, reveal: { _, _ in }, copy: { _, _ in false }, cancel: { _ in }, close: { _ in })
        /// Height of the cards now showing, measured by a separate view that sizes itself normally.
        func needed() -> CGFloat {
            let cards = center.model.entries.map { NSHostingView(rootView: ToastCard(entry: $0, actions: actions)).fittingSize.height }
            return cards.reduce(0, +) + CGFloat(max(cards.count - 1, 0)) * 8
        }
        func check(_ kind: String, min: CGFloat) async throws {
            await settle()
            let panel = try #require(center.panel)
            let need = needed()
            #expect(need >= min, "\(kind): measured \(need), expected at least \(min)")
            #expect(abs(panel.frame.height - need) <= 1, "\(kind): panel \(panel.frame.height), cards \(need), measured \(center.contentHeight), visible \(panel.isVisible), alpha \(panel.alphaValue)")
            #expect(panel.frame.maxY <= (panel.screen?.visibleFrame.maxY ?? .infinity), "\(kind): under the menu bar")
        }

        center.showProgress(job: "j", title: "Converting to JPG", stage: "Converting…", file: nil, fraction: 0.5, onCancel: {})
        try await check("progress", min: 60)
        let output = URL(fileURLWithPath: "/tmp/photo.jpg")
        center.showResult(job: "j", ConversionResult(title: "Saved photo.jpg", outputs: [output], actionTitle: "JPG",
                                                     inputBytes: 169_000, outputBytes: 139_000, folderName: "halo-test"))
        try await check("result", min: 90)
        center.showFailure(job: "f", title: "Couldn't convert", message: "This file looks damaged, or macOS can't read this format.")
        try await check("result + failure", min: 150)
        center.hide()
        await settle()
        center.showNotice("Frenzy's icon is hidden", message: "Your menu bar is full, so macOS put Frenzy's icon under the camera.")
        try await check("notice", min: 56)
    }

    /// A test's fake cards must never appear on the screen of whoever runs it: they looked like real app errors to the
    /// founder for a whole day.
    @Test func testsNeverShowCardsOnScreen() async throws {
        #expect(HaloRuntime.isUnderTest)
        let center = ToastCenter()
        defer { center.hide() }
        center.showNotice("Test", message: "This must stay invisible.")
        for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(25)) }
        #expect(try #require(center.panel).alphaValue == 0)
    }

    /// Cards follow "Show file previews" at once, even one already on screen.
    @Test func cardsFollowThePreviewsSetting() throws {
        let suite = "halo.tests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = HaloSettings(defaults: try #require(UserDefaults(suiteName: suite)))
        let center = ToastCenter(settings: settings)
        #expect(center.model.showsPreviews)
        settings.showPreviews = false
        #expect(!center.model.showsPreviews)
        settings.showPreviews = true
        #expect(center.model.showsPreviews)
    }

    @Test func textRecognitionWarnsOnlyOnTheFirstRun() {
        let first = JobStage.line(for: "text.ocr-image", fraction: 0, elapsed: 0, firstRun: true)
        #expect(first.contains("first time"))
        #expect(JobStage.line(for: "text.ocr-image", fraction: 0, elapsed: 0, firstRun: false) == "Preparing text recognition…")
        #expect(JobStage.line(for: "text.ocr-image", fraction: 0.3, elapsed: 20, firstRun: true) == "Reading text…")
    }

    @Test func aStuckJobSaysSoAfterAWhile() {
        #expect(JobStage.line(for: "image.to-jpg", fraction: 0, elapsed: 1, firstRun: false) == "Converting…")
        let slow = JobStage.line(for: "image.to-jpg", fraction: 0, elapsed: JobStage.slowAfter, firstRun: false)
        #expect(slow.hasPrefix("Still working"))
        // Once progress moves, the line goes back to what is happening.
        #expect(JobStage.line(for: "video.to-mp4", fraction: 0.5, elapsed: 60, firstRun: false) == "Converting video…")
    }

    @Test func aJobStalledPartwaySaysSo() {
        // Moving: the line says what is happening, however long the whole job has run.
        #expect(JobStage.line(for: "video.to-mp4", fraction: 0.4, elapsed: 90, sinceProgress: 2, firstRun: false) == "Converting video…")
        // Stuck at 40 % for a while: it admits it, instead of "Converting video…" forever.
        let stalled = JobStage.line(for: "video.to-mp4", fraction: 0.4, elapsed: 90, sinceProgress: JobStage.slowAfter, firstRun: false)
        #expect(stalled == "Still working on this step…")
        // Text recognition sits at 20 % while it reads, which is the normal case for a dense page.
        #expect(JobStage.line(for: "text.ocr-image", fraction: 0.2, elapsed: 30, sinceProgress: 20, firstRun: false)
                == "Still reading the text…")
        // Never moved: sinceProgress defaults to elapsed.
        #expect(JobStage.line(for: "pdf.compress", fraction: 0, elapsed: 9, firstRun: false).hasPrefix("Still working"))
    }

    @Test func theFirstRecognitionNeverOverstaysItsPromise() {
        let early = JobStage.line(for: "text.ocr-image", fraction: 0, elapsed: 30, firstRun: true)
        #expect(early.contains("about a minute"))
        // Past the promised minute, the line stops promising one.
        let late = JobStage.line(for: "text.ocr-image", fraction: 0, elapsed: JobStage.firstRecognitionWait, firstRun: true)
        #expect(!late.contains("minute"))
        #expect(late == "Still preparing text recognition…")
        // Not the first run, but still nothing after a while: it says so too.
        #expect(JobStage.line(for: "text.ocr-image", fraction: 0, elapsed: 3, firstRun: false) == "Preparing text recognition…")
        #expect(JobStage.line(for: "text.ocr-image", fraction: 0, elapsed: 20, firstRun: false) == "Still preparing text recognition…")
    }

    @Test func stageLinesAreHouseStyle() {
        let ids: [ActionID] = ["text.ocr-image", "video.to-mp4", "audio.to-m4a", "pdf.compress", "document.to-pdf", "image.compress"]
        for id in ids {
            for (fraction, elapsed, quiet, first) in [(0.0, 0.0, 0.0, true), (0.0, 30.0, 30.0, false), (0.5, 5.0, 1.0, false),
                                                     (0.5, 60.0, 20.0, false), (0.0, 90.0, 90.0, true)] {
                let line = JobStage.line(for: id, fraction: fraction, elapsed: elapsed, sinceProgress: quiet, firstRun: first)
                #expect(!line.isEmpty)
                #expect(!line.contains("—"), "no em dashes: \(line)")
            }
        }
    }

    // MARK: Facts

    static func tempFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-card-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func measureReadsSizesAndTheFolder() throws {
        let dir = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("photo.png"), output = dir.appendingPathComponent("photo.jpg")
        try Data(count: 2_400_000).write(to: input)
        try Data(count: 380_000).write(to: output)

        let result = ConversionResult.measure(title: "Saved photo.jpg", actionTitle: "JPG", outputs: [output], inputs: [input])
        #expect(result.inputBytes == 2_400_000)
        #expect(result.outputBytes == 380_000)
        #expect(result.folderName == FileManager.default.displayName(atPath: dir.path))
        #expect(result.sizeLine == "\(ConversionResult.format(2_400_000)) → \(ConversionResult.format(380_000))")
        #expect(result.placeLine == "Saved in \(result.folderName!)")
        #expect(result.name == "photo.jpg")
    }

    @Test func unknownSizesStayUnknown() throws {
        let dir = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("report pages", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let missing = dir.appendingPathComponent("gone.pdf")

        // A folder output (pages of a split) and a missing input: no made-up numbers.
        let result = ConversionResult.measure(title: "Saved report pages", actionTitle: "Split", outputs: [folder], inputs: [missing])
        #expect(result.outputBytes == nil)
        #expect(result.inputBytes == nil)
        #expect(result.sizeLine == nil)
        // Outputs in two folders: no single folder to name.
        let other = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: other) }
        let split = ConversionResult.measure(title: "t", actionTitle: "", outputs: [folder, other.appendingPathComponent("x.jpg")],
                                             inputs: [], failures: 2)
        #expect(split.folderName == nil)
        #expect(split.placeLine == "Saved next to the originals. 2 couldn't be converted")
        #expect(split.name == "report pages and 1 more")
    }

    // MARK: Card behaviour

    @Test func copyPutsTheFilesOnThePasteboard() throws {
        let dir = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.jpg")
        try Data("x".utf8).write(to: file)
        let board = NSPasteboard(name: NSPasteboard.Name("halo.test.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }

        #expect(ToastCenter.copy([file, dir.appendingPathComponent("missing.jpg")], to: board))
        let urls = board.readObjects(forClasses: [NSURL.self]) as? [URL]
        #expect(urls?.map(\.standardizedFileURL) == [file.standardizedFileURL])
        #expect(!ToastCenter.copy([dir.appendingPathComponent("missing.jpg")], to: board))
    }

    @Test func dragCarriesEveryExistingOutputUpToTheCap() throws {
        let dir = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = (0..<25).map { dir.appendingPathComponent("page \($0).jpg") }
        for file in files { try Data("x".utf8).write(to: file) }
        let items = FileDragSourceView.draggingItems(for: files + [dir.appendingPathComponent("gone.jpg")], at: .zero)
        #expect(items.count == ToastCenter.maxRevealed)
        #expect(FileDragSourceView.draggingItems(for: [dir.appendingPathComponent("gone.jpg")], at: .zero).isEmpty)
    }

    @Test func resultReplacesProgressAndNoticesAreNotFailures() {
        let center = ToastCenter()
        defer { center.hide() }
        center.showProgress(job: "a", title: "JPG: photo.png", stage: "Converting…", file: nil, fraction: 0.5, onCancel: {})
        #expect(center.model.entries.count == 1)
        #expect(center.model.entries[0].cancellable)
        center.showResult(job: "a", ConversionResult(title: "Saved photo.jpg", outputs: [URL(fileURLWithPath: "/tmp/photo.jpg")]))
        #expect(center.model.entries.count == 1)
        if case .success(let result) = center.model.entries[0].content { #expect(result.title == "Saved photo.jpg") } else {
            Issue.record("expected a result card")
        }
        #expect(!center.model.entries[0].cancellable)

        center.showNotice("No conversions", message: "Frenzy can't convert this kind of item yet.")
        #expect(center.model.entries.count == 2)
        if case .notice = center.model.entries[0].content {} else { Issue.record("a notice must not use the failure style") }
    }

    @Test func aFullStackDropsFinishedCardsBeforeRunningOnes() {
        let center = ToastCenter()
        defer { center.hide() }
        center.showProgress(job: "run", title: "MP4: clip.mov", stage: "Converting video…", file: nil, fraction: 0.2, onCancel: nil)
        center.showResult(job: "done1", ConversionResult(title: "Saved a.jpg", outputs: []))
        center.showResult(job: "done2", ConversionResult(title: "Saved b.jpg", outputs: []))
        center.showFailure(job: "bad", title: "Couldn't convert c.mov", message: "This video has no picture track.")
        #expect(center.model.entries.count == ToastCenter.maxCards)
        #expect(center.model.entries.contains { $0.id == "run" })
        #expect(!center.model.entries.contains { $0.id == "done1" })
    }

    @Test func aResultNeverEvictsItselfAndEvictedJobsDontThrash() {
        let center = ToastCenter()
        defer { center.hide() }
        for job in ["a", "b", "c", "d"] {
            center.showProgress(job: job, title: job, stage: "Converting…", file: nil, fraction: 0.1, onCancel: {})
        }
        // A full stack of running jobs: the oldest ("a") made room for "d".
        #expect(center.model.entries.map(\.id) == ["d", "c", "b"])
        // a's progress stays off screen instead of pushing another running job out.
        center.showProgress(job: "a", title: "a", stage: "Converting…", file: nil, fraction: 0.5, onCancel: {})
        #expect(center.model.entries.map(\.id) == ["d", "c", "b"])
        // But its result shows, and is not the card that gets dropped.
        center.showResult(job: "a", ConversionResult(title: "Saved a.jpg", outputs: []))
        #expect(center.model.entries.first?.id == "a")
        #expect(center.model.entries.count == ToastCenter.maxCards)
    }

    @Test func hoverResetsWhenTheLastCardGoes() {
        let center = ToastCenter()
        defer { center.hide() }
        center.showNotice("No conversions", message: "Frenzy can't convert this kind of item yet.")
        center.model.isHovering = true
        // Clicking Dismiss under the pointer removes the card without an exit hover event.
        center.dismiss(job: ToastCenter.noticeJob)
        #expect(!center.model.isHovering)
    }

    @Test func partialFailuresDontClaimASaving() {
        let partial = ConversionResult(title: "Saved 11 files", outputs: [], inputBytes: 48_200_000, outputBytes: 9_100_000,
                                       failures: 1)
        #expect(partial.sizeLine == ConversionResult.format(9_100_000))
        let clean = ConversionResult(title: "Saved 12 files", outputs: [], inputBytes: 48_200_000, outputBytes: 9_100_000)
        #expect(clean.sizeLine == "\(ConversionResult.format(48_200_000)) → \(ConversionResult.format(9_100_000))")
    }

    // MARK: What the cards say

    @Test func aRunningCardSeparatesTheActionFromTheFile() {
        let pdf = URL(fileURLWithPath: "/tmp/Quarterly report.pdf")
        let compress = ProgressLabels(title: "Compress: Quarterly report.pdf", file: pdf)
        #expect(compress.headline == "Compressing")
        #expect(compress.fileName == "Quarterly report.pdf")
        // Several files: no URL, so the subject from the title is the second line.
        let batch = ProgressLabels(title: "JPG: 3 files", file: nil)
        #expect(batch.headline == "Converting to JPG")
        #expect(batch.fileName == "3 files")
        // A plain title stays whole, and only the real file's name is ever shown as one.
        let plain = ProgressLabels(title: "Converting to JPG", file: nil)
        #expect(plain.headline == "Converting to JPG")
        #expect(plain.fileName == nil)
        // A colon in the name belongs to the name, not to the action.
        #expect(ProgressLabels(title: "MP4: Cut: final.mov", file: nil).fileName == "Cut: final.mov")
        // An action nobody listed keeps its own words.
        #expect(ProgressLabels.headline(forAction: "Sharpen") == "Sharpen")
    }

    @Test func everyRealActionGetsAHeadlineInHouseStyle() {
        let titles = ["Unzip", "Zip", "Compress", "Merge", "Images", "To Text", "Split", "Rotate", "MP4", "GIF", "Audio", "HEVC",
                      "PDF", "Word", "TXT", "RTF", "M4A", "WAV", "AIFF", "One PDF", "Half Size", "Strip Info", "JPG", "PNG"]
        for title in titles {
            let headline = ProgressLabels.headline(forAction: title)
            #expect(headline != title, "\(title) has no phrase, so its card would just say \(headline)")
            #expect(!headline.contains("—"))
        }
    }

    @Test func aFailureSeparatesTheHeadlineFromTheFile() {
        let failure = MessageLabels(title: "Couldn't convert Quarterly report.pdf")
        #expect(failure.headline == "Couldn't convert")
        #expect(failure.fileName == "Quarterly report.pdf")
        #expect(MessageLabels(title: "Couldn't convert").headline == "Couldn't convert")
        #expect(MessageLabels(title: "Couldn't convert").fileName == nil)
        #expect(MessageLabels(title: "Nothing to shrink") == MessageLabels(title: "Nothing to shrink"))
        #expect(MessageLabels(title: "Nothing to shrink").headline == "Nothing to shrink")
        #expect(MessageLabels(title: "Nothing to shrink").fileName == nil)
    }

    @Test func theResultCardOffersOneClearNextStep() {
        let one = URL(fileURLWithPath: "/tmp/a.jpg"), two = URL(fileURLWithPath: "/tmp/b.jpg")
        #expect(ConversionResult(title: "t", outputs: [one]).primaryAction == .open(one))
        // Nothing single to open: the folder is the next step.
        #expect(ConversionResult(title: "t", outputs: [one, two]).primaryAction == .showInFinder)
    }

    @Test func theFactsSayTheSizesInWords() {
        let result = ConversionResult(title: "t", outputs: [], actionTitle: "Compress", inputBytes: 169_000, outputBytes: 139_000)
        #expect(result.factsLine == "\(ConversionResult.format(169_000)) to \(ConversionResult.format(139_000))")
        #expect(ConversionResult(title: "t", outputs: []).factsLine == nil)
        // Partial failures still don't claim a saving.
        #expect(ConversionResult(title: "t", outputs: [], inputBytes: 9, outputBytes: 5, failures: 1).factsLine == ConversionResult.format(5))
    }

    /// A long name must neither wrap nor push the layout about: it stays one line, whatever else the card holds.
    @Test func aLongFileNameStaysOnOneLine() {
        func height(_ content: ToastContent, cancellable: Bool = false) -> CGFloat {
            NSHostingView(rootView: ToastCard(entry: ToastEntry(id: "x", content: content, cancellable: cancellable),
                                              actions: ToastActions())).fittingSize.height
        }
        let long = String(repeating: "Quarterly report final ", count: 8) + ".pdf"
        let short = "a.pdf"
        func progress(_ name: String) -> ToastContent {
            .progress(title: "Compress: \(name)", stage: "Converting…", file: URL(fileURLWithPath: "/tmp/\(name)"), fraction: 0.5)
        }
        #expect(height(progress(long), cancellable: true) == height(progress(short), cancellable: true))
        func result(_ name: String) -> ToastContent {
            .success(ConversionResult(title: "Saved", outputs: [URL(fileURLWithPath: "/tmp/\(name)")], inputBytes: 2, outputBytes: 1, folderName: "Desktop"))
        }
        #expect(height(result(long)) == height(result(short)))
        func failure(_ name: String) -> ToastContent { .failure(title: "Couldn't convert \(name)", message: "This file looks damaged.") }
        #expect(height(failure(long)) == height(failure(short)))
    }

    /// A Mac with a red system accent would otherwise read a running job as an error. The bar's pixels are compared with
    /// a plain swatch of the brand colour drawn the same way, so colour-space handling can't hide a difference.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func theProgressBarIsTheBrandColour(scheme: NSAppearance.Name) throws {
        func centrePixel(of view: some View) throws -> NSColor {
            let appearance = try #require(NSAppearance(named: scheme))
            let host = NSHostingView(rootView: view.frame(width: 120, height: 5))
            host.appearance = appearance
            host.frame = NSRect(x: 0, y: 0, width: 120, height: 5)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = appearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
        }
        let bar = try centrePixel(of: ToastProgressBar(fraction: 1).tint(.red))
        let brand = try centrePixel(of: Rectangle().fill(FrenzyPalette.accent))
        for (a, b) in [(bar.redComponent, brand.redComponent), (bar.greenComponent, brand.greenComponent),
                       (bar.blueComponent, brand.blueComponent)] {
            #expect(abs(a - b) < 0.01, "bar \(bar), brand \(brand)")
        }
    }

    // MARK: Renders

    /// The cards as a still, over a stand-in wallpaper (glass needs something behind it to read). `cacheDisplay` drew
    /// these cards nearly blank offscreen, so ImageRenderer it is; it draws frosted material in place of Liquid Glass,
    /// and the still-render flag swaps the AppKit drag area and the thumbnail's arrival for their finished state.
    private func render(_ entries: [ToastEntry], name: String, scheme: NSAppearance.Name) throws {
        let dark = scheme == .darkAqua
        let still = ZStack {
            LinearGradient(colors: dark ? [Color(red: 0.12, green: 0.16, blue: 0.26), Color(red: 0.30, green: 0.20, blue: 0.24)]
                                        : [Color(red: 0.80, green: 0.86, blue: 0.95), Color(red: 0.97, green: 0.88, blue: 0.84)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: CardMetrics.stackGap) {
                ForEach(entries) { ToastCard(entry: $0, actions: ToastActions()) }
            }
            .padding(24)
        }
        .frame(width: ToastCenter.width + 48)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.toastStillRender, true)
        let renderer = ImageRenderer(content: still)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: HomeRenderTests.shotsDirectory, withIntermediateDirectories: true)
        try png.write(to: HomeRenderTests.shotsDirectory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        #expect(rep.pixelsHigh > 100)
    }

    /// The settings window's two panes and the brand mark, to loop/shots for the design review.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func settingsRender(scheme: NSAppearance.Name) throws {
        let suite = "halo.tests.render.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = HaloSettings(defaults: try #require(UserDefaults(suiteName: suite)))
        func shoot(_ view: some View, name: String) throws {
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: scheme)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = host.appearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(at: HomeRenderTests.shotsDirectory, withIntermediateDirectories: true)
            try png.write(to: HomeRenderTests.shotsDirectory.appendingPathComponent("\(name)-\(scheme == .darkAqua ? "dark" : "light").png"))
            #expect(rep.pixelsHigh > 100, "\(name) rendered \(rep.pixelsHigh) px high")
        }
        try shoot(GeneralSettingsPane(settings: settings).frame(width: 460), name: "settings-1-general")
        try shoot(AboutPane(version: "1.0").frame(width: 460), name: "settings-2-about")
        try shoot(HaloGlyph().frame(width: 128, height: 128).padding(16), name: "settings-3-glyph")
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func everyCardRenders(scheme: NSAppearance.Name) throws {
        let dir = try HomeRenderTests.fixtures()
        let png = dir.appendingPathComponent("Holiday photo.png"), jpg = dir.appendingPathComponent("Holiday photo.jpg")
        let pdf = dir.appendingPathComponent("Quarterly report.pdf")
        let photo = ConversionResult.measure(title: "Saved Holiday photo.jpg", actionTitle: "JPG", outputs: [jpg], inputs: [png])

        try render([ToastEntry(id: "1", content: .progress(title: "To Text: Holiday photo.png",
                                                           stage: JobStage.line(for: "text.ocr-image", fraction: 0, elapsed: 0, firstRun: true),
                                                           file: png, fraction: 0), cancellable: true)],
                   name: "card-1-first-ocr", scheme: scheme)
        try render([ToastEntry(id: "2", content: .progress(title: "Compress: Quarterly report.pdf",
                                                           stage: JobStage.line(for: "pdf.compress", fraction: 0.62, elapsed: 3, firstRun: false),
                                                           file: pdf, fraction: 0.62), cancellable: true)],
                   name: "card-2-progress", scheme: scheme)
        try render([ToastEntry(id: "3", content: .success(photo), cancellable: false)], name: "card-3-result", scheme: scheme)
        let batch = ConversionResult(title: "Saved 12 files", outputs: [jpg, png], actionTitle: "JPG",
                                     inputBytes: 48_200_000, outputBytes: 9_100_000, folderName: "Desktop", failures: 1)
        try render([ToastEntry(id: "4", content: .success(batch), cancellable: false)], name: "card-4-batch", scheme: scheme)
        try render([
            ToastEntry(id: "5", content: .failure(title: "Couldn't convert clip.mov",
                                                  message: "This video has no picture track, so there is nothing to convert to MP4."), cancellable: false),
            ToastEntry(id: "6", content: .notice(title: "No conversions", message: "Frenzy can't convert this kind of item yet."), cancellable: false),
        ], name: "card-5-failure-notice", scheme: scheme)
        try render([
            ToastEntry(id: "7", content: .progress(title: "MP4: clip.mov", stage: "Still working. Big files take a little longer.",
                                                   file: nil, fraction: 0), cancellable: true),
            ToastEntry(id: "8", content: .success(photo), cancellable: false),
        ], name: "card-6-stack", scheme: scheme)
        let long = "Quarterly report for the board meeting, final version 3 (signed).pdf"
        try render([
            ToastEntry(id: "10", content: .progress(title: "Compress: \(long)", stage: "Working through the pages…",
                                                    file: dir.appendingPathComponent(long), fraction: 0.35), cancellable: true),
            ToastEntry(id: "11", content: .success(ConversionResult(title: "Saved", outputs: [dir.appendingPathComponent(long)],
                                                                    actionTitle: "Compress", inputBytes: 169_000, outputBytes: 139_000,
                                                                    folderName: "Documents")), cancellable: false),
            ToastEntry(id: "12", content: .failure(title: "Couldn't convert \(long)",
                                                   message: "This file looks damaged, or macOS can't read this format."), cancellable: false),
        ], name: "card-8-long-names", scheme: scheme)
        try render([ToastEntry(id: "13", content: .notice(title: "Nothing to shrink",
                                                          message: "This file is already as small as Frenzy can make it."), cancellable: false)],
                   name: "card-9-nothing-to-shrink", scheme: scheme)
        try render([ToastEntry(id: "9", content: .progress(title: "MP4: Holiday trip.mov",
                                                           stage: JobStage.line(for: "video.to-mp4", fraction: 0.4, elapsed: 70,
                                                                                sinceProgress: 12, firstRun: false),
                                                           file: nil, fraction: 0.4), cancellable: true)],
                   name: "card-7-stalled", scheme: scheme)
        // The whole stack over a stand-in wallpaper, as the ring's renders do. ImageRenderer draws no Liquid Glass either,
        // but it does resolve text and buttons for the scheme, so dark mode can be read here.
        let wallpaper = ZStack {
            LinearGradient(colors: [Color(red: 0.36, green: 0.52, blue: 0.78), Color(red: 0.86, green: 0.62, blue: 0.56)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 8) {
                ForEach([
                    ToastEntry(id: "w1", content: .progress(title: "Compress: Quarterly report.pdf", stage: "Working through the pages…",
                                                            file: pdf, fraction: 0.62), cancellable: true),
                    ToastEntry(id: "w2", content: .success(photo), cancellable: false),
                    ToastEntry(id: "w3", content: .failure(title: "Couldn't convert clip.mov",
                                                           message: "This video has no picture track, so there is nothing to convert to MP4."), cancellable: false),
                    ToastEntry(id: "w4", content: .notice(title: "Nothing to shrink",
                                                          message: "This file is already as small as Frenzy can make it."), cancellable: false),
                ]) { ToastCard(entry: $0, actions: ToastActions()) }
            }
            .padding(24)
        }
        .frame(width: ToastCenter.width + 48)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.colorScheme, scheme == .darkAqua ? .dark : .light)
        .environment(\.toastStillRender, true)
        let renderer = ImageRenderer(content: wallpaper)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try #require(rep.representation(using: .png, properties: [:]))
            .write(to: HomeRenderTests.shotsDirectory.appendingPathComponent("card-10-wallpaper-\(scheme == .darkAqua ? "dark" : "light").png"))
    }
}
