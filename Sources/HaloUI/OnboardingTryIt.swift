import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import HaloCore

/// The picture onboarding hands the user to try the gesture on. Halo draws it itself (no bundled asset, nothing parsed),
/// and keeps it in its own Application Support folder so the practice output lands there too, never in the user's files.
public enum OnboardingSample {
    public static let fileName = "Frenzy sample.png"
    public static let pixelSize = CGSize(width: 1200, height: 800)

    /// `~/Library/Application Support/Halo/Try Halo`.
    public static var defaultFolder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Frenzy/Try Frenzy", isDirectory: true)
    }

    /// Writes the sample into `folder` unless a readable one is already there, and returns its URL.
    public static func prepare(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(fileName)
        // Only Halo writes here. Anything that isn't a plain file (a link, a folder) is replaced, never written through.
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]),
           values.isSymbolicLink == true || values.isRegularFile == false {
            try FileManager.default.removeItem(at: url)
        }
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) == 1 { return url }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let image = makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// A calm dusk landscape: sky gradient, a low sun with a soft glow, two layers of hills.
    static func makeImage() -> CGImage? {
        let w = Int(pixelSize.width), h = Int(pixelSize.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: r, green: g, blue: b, alpha: a)
        }
        let width = CGFloat(w), height = CGFloat(h)
        let sky = CGGradient(colorsSpace: space,
                             colors: [color(0.99, 0.80, 0.58), color(0.93, 0.52, 0.52), color(0.36, 0.33, 0.64)] as CFArray,
                             locations: [0, 0.45, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: height * 0.3), end: CGPoint(x: 0, y: height),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        let sun = CGPoint(x: width * 0.62, y: height * 0.42)
        let glow = CGGradient(colorsSpace: space, colors: [color(1, 0.93, 0.74, 0.9), color(1, 0.85, 0.65, 0)] as CFArray,
                              locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: sun, startRadius: 0, endCenter: sun, endRadius: width * 0.28, options: [])
        ctx.setFillColor(color(1, 0.96, 0.84))
        ctx.fillEllipse(in: CGRect(x: sun.x - 70, y: sun.y - 70, width: 140, height: 140))
        func hill(base: CGFloat, amplitude: CGFloat, phase: CGFloat, fill: CGColor) {
            let path = CGMutablePath()
            path.move(to: .zero)
            for x in stride(from: CGFloat(0), through: width, by: 8) {
                path.addLine(to: CGPoint(x: x, y: base + amplitude * sin(x / width * .pi * 2 + phase)))
            }
            path.addLine(to: CGPoint(x: width, y: 0))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(fill)
            ctx.fillPath()
        }
        hill(base: height * 0.36, amplitude: height * 0.05, phase: 0.8, fill: color(0.45, 0.32, 0.55))
        hill(base: height * 0.22, amplitude: height * 0.06, phase: 2.6, fill: color(0.24, 0.20, 0.38))
        return ctx.makeImage()
    }
}

/// What the try-it step shows. `AppController` moves it along as the sample is converted.
@MainActor
public final class OnboardingTry: ObservableObject {
    public enum Phase: Equatable {
        case waiting
        case working(actionTitle: String)
        case done(output: URL, actionTitle: String)
        case failed(String)
    }

    @Published public var phase: Phase = .waiting
    /// The ring can't open while Halo is paused, so the step says so instead of letting the drag fail silently.
    @Published public var isPaused = false
    /// Converts the sample to JPG without a drag (VoiceOver's action on the sample). Set by the app.
    public var convertSample: (() -> Void)?
    /// Resumes Halo from the paused notice. Set by the app.
    public var resume: (() -> Void)?
    public let sampleURL: URL

    public init(sampleURL: URL) {
        self.sampleURL = sampleURL
    }

    public var isDone: Bool {
        if case .done = phase { return true }
        return false
    }

    /// True when a conversion's inputs are exactly the sample (a copy dragged elsewhere first doesn't count).
    public func isSample(_ inputs: [URL]) -> Bool {
        inputs.count == 1 && inputs[0].standardizedFileURL.resolvingSymlinksInPath()
            == sampleURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func began(_ actionTitle: String) {
        phase = .working(actionTitle: actionTitle)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Converting to \(actionTitle)"])
    }

    /// The first output wins. No outputs (cancelled or failed) puts the step back to waiting, with a reason if any.
    public func finished(outputs: [URL], actionTitle: String, failure: String?) {
        if let first = outputs.first {
            phase = .done(output: first, actionTitle: actionTitle)
        } else if let failure {
            phase = .failed(failure)
        } else {
            phase = .waiting
        }
    }

    /// A fresh try each time onboarding opens.
    public func reset() { phase = .waiting }
}

// MARK: - The step

/// The words under the picture for each phase. Pure value so tests can check them.
struct TryItCopy: Equatable {
    let title: String
    let message: String

    init(phase: OnboardingTry.Phase, isPaused: Bool, gesture: String) {
        switch phase {
        case .waiting where isPaused:
            title = "Frenzy is paused"
            message = "The bubbles can't open until you resume."
        case .waiting:
            title = "Your turn"
            message = "Drag this picture, \(gesture), then drop it on JPG."
        case .working(let actionTitle):
            title = "One moment"
            message = "Converting to \(actionTitle)…"
        case .done:
            title = "That's it."
            message = "Do the same with your files in Finder or on the Desktop."
        case .failed(let failure):
            title = "Let's try that again"
            message = failure
        }
    }
}

struct TryItStep: View {
    @ObservedObject var model: OnboardingTry
    let gesture: String
    var onShowInFinder: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let hoverState = State(initialValue: false)
    private var isHovering: Bool {
        get { hoverState.wrappedValue } nonmutating set { hoverState.wrappedValue = newValue }
    }

    /// Big enough that there is nothing else to look at while waiting; two side by side once the new file lands.
    static let waitingTileWidth: CGFloat = 384
    static let doneTileWidth: CGFloat = 252
    static let doneTileSpacing: CGFloat = 24

    /// Loaded once per step instance; the file is the one Halo drew, never a user file.
    private let sampleImage: NSImage?

    init(model: OnboardingTry, gesture: String) {
        self.model = model
        self.gesture = gesture
        sampleImage = NSImage(contentsOf: model.sampleURL)
    }

    var body: some View {
        let copy = TryItCopy(phase: model.phase, isPaused: model.isPaused, gesture: gesture)
        OnboardingStepLayout(title: copy.title, message: copy.message) {
            files
        } extra: {
            extra
        }
        .animation(reduceMotion ? RingMotion.crossfade : RingMotion.settle, value: model.phase)
        .animation(reduceMotion ? RingMotion.crossfade : RingMotion.settle, value: model.isPaused)
        .onChange(of: model.isDone) { _, done in
            guard done else { return }
            // Felt only with a finger on the trackpad.
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: "Done. The new file is next to the original."])
        }
    }

    private var files: some View {
        HStack(spacing: Self.doneTileSpacing) {
            sampleTile
            if case .done(let output, _) = model.phase {
                outputTile(output)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.6, anchor: .leading).combined(with: .opacity)
                        .animation(RingMotion.settle))
            }
        }
    }

    private var sampleTile: some View {
        FileTile(image: sampleImage, name: OnboardingSample.fileName, width: model.isDone ? Self.doneTileWidth : Self.waitingTileWidth,
                 lifted: !model.isDone)
            .scaleEffect(isHovering && !reduceMotion && !model.isDone ? 1.015 : 1)
            .animation(reduceMotion ? nil : RingMotion.bubbleHover, value: isHovering)
            .modifier(IdleFloat(active: model.phase == .waiting && !isHovering && !reduceMotion))
            .background { GrabCursorArea() }
            .overlay { FileDragArea(urls: [model.sampleURL]) }
            .onHover { isHovering = $0 }
            .help("Drag me, then \(gesture)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sample picture, \(OnboardingSample.fileName). Drag it and \(gesture) to open the bubbles.")
            .accessibilityAction(named: "Convert to JPG") { model.convertSample?() }
    }

    /// The picture for an image result; Finder's icon for anything else, so a PDF or text file doesn't pose as a photo.
    private func outputTile(_ output: URL) -> some View {
        let type = UTType(filenameExtension: output.pathExtension)
        let isImage = type?.conforms(to: .image) ?? false
        return FileTile(image: isImage ? sampleImage : NSWorkspace.shared.icon(for: type ?? .data), name: output.lastPathComponent,
                        width: Self.doneTileWidth, badge: true, isPicture: isImage)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(output.lastPathComponent), converted from \(OnboardingSample.fileName)")
    }

    @ViewBuilder private var extra: some View {
        switch model.phase {
        case .waiting where model.isPaused:
            if let resume = model.resume {
                Button("Resume Frenzy", action: resume)
                    .keyboardShortcut(.defaultAction)
                    .frenzyPrimaryButton()
            }
        case .working:
            ProgressView().controlSize(.small)
        case .done(let output, _):
            Button("Show in Finder") { onShowInFinder(output) }
                .onboardingQuietButton()
        case .waiting, .failed:
            if Self.offersConvertButton(phase: model.phase, isPaused: model.isPaused, canConvert: model.convertSample != nil),
               let convert = model.convertSample {
                // The way through without a drag: the keyboard, Switch Control, or a trackpad that makes dragging hard.
                Button("Convert to JPG", action: convert)
                    .keyboardShortcut(.defaultAction)
                    .onboardingQuietButton()
                    .help("Convert the sample to JPG without dragging (Return)")
            }
        }
    }

    /// A visible "Convert to JPG" whenever the step is waiting for the user and the app can convert without a drag.
    static func offersConvertButton(phase: OnboardingTry.Phase, isPaused: Bool, canConvert: Bool) -> Bool {
        guard canConvert, !isPaused else { return false }
        switch phase {
        case .waiting, .failed: return true
        case .working, .done: return false
        }
    }
}

/// A slow, small lift that says "pick me up". Only ever moves the picture, never the drag area over it.
private struct IdleFloat: ViewModifier {
    let active: Bool

    // The animator only exists while it floats: an idle phaseAnimator still re-renders the picture every 1.8 s, even
    // during a drag (the founder found the app laggy with this window open).
    @ViewBuilder func body(content: Content) -> some View {
        if active {
            content.phaseAnimator([false, true]) { view, up in
                view.offset(y: up ? -3 : 0)
            } animation: { _ in
                .easeInOut(duration: 1.8)
            }
        } else {
            content
        }
    }
}

/// Shows the open hand over the sample. A cursor rect, so a drag that swallows the mouse-up can't leave the cursor stuck.
private struct GrabCursorArea: NSViewRepresentable {
    final class Area: NSView {
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Area { Area() }
    func updateNSView(_ view: Area, context: Context) {}
}

/// A file as Finder shows it on the desktop: a framed thumbnail over its name. The frame is 3:2, like the sample.
struct FileTile: View {
    let image: NSImage?
    let name: String
    let width: CGFloat
    var badge = false
    var lifted = false
    /// False shows a file icon whole, without a photo's frame.
    var isPicture = true
    @Environment(\.colorScheme) private var colorScheme

    private var isSmall: Bool { width < 160 }

    var body: some View {
        let height = (width * 2 / 3).rounded()
        let radius: CGFloat = isSmall ? 7 : 12
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        VStack(spacing: isSmall ? 4 : 10) {
            ZStack(alignment: .bottomTrailing) {
                if let image, isPicture {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: height)
                        .clipShape(shape)
                        .overlay(shape.strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.25 : 0.85), lineWidth: isSmall ? 1.5 : 2.5))
                        // A hairline outside the white edge, so the frame holds on a light window too.
                        .overlay(RoundedRectangle(cornerRadius: radius + 0.5, style: .continuous)
                            .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.4 : 0.12), lineWidth: 0.5).padding(-0.5))
                        .shadow(color: .black.opacity(lifted ? 0.28 : 0.16), radius: lifted ? 18 : 6, y: lifted ? 8 : 2)
                } else if let image {
                    // Square, so the badge sits on the icon's corner rather than out in the empty frame.
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: height, height: height)
                } else {
                    shape.fill(Color.primary.opacity(0.12)).frame(width: width, height: height)
                }
                if badge {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.frenzyGlyph(isSmall ? 18 : 28))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, FrenzyPalette.accent)
                        .offset(x: isSmall ? 6 : 10, y: isSmall ? 6 : 10)
                }
            }
            Text(name)
                .font(.frenzy(isSmall ? .label : .body, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: width + (isSmall ? 16 : 0))
                .fixedSize(horizontal: isSmall, vertical: false)
        }
    }
}
