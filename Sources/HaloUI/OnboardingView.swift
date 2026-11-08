import SwiftUI
import HaloCore

/// Observable permission state for hosts that drive onboarding from AppKit.
@MainActor
public final class OnboardingPermissions: ObservableObject {
    @Published public var isGranted: Bool
    /// False hides the permissions step entirely.
    public let isRequired: Bool
    /// e.g. "Accessibility".
    public let name: String
    /// One sentence on why Halo needs it.
    public let explanation: String
    public let request: () -> Void

    /// Exact about what is read: the drag code checks only whether a modifier key is down (`DragEnvironment`), never which
    /// letters you type.
    public static let defaultExplanation = "Frenzy needs to see when you hold the trigger key during a drag. It checks only that key, not what you type."

    /// What stops working if the user goes on without the permission. Shown under the step and as the help for "Not now".
    public var withoutItNote: String {
        "Without \(name), holding the key won't open the bubbles. You can allow it later in System Settings."
    }

    public init(isRequired: Bool, isGranted: Bool = false, name: String = "Accessibility",
                explanation: String = OnboardingPermissions.defaultExplanation,
                request: @escaping () -> Void) {
        self.isRequired = isRequired
        self.isGranted = isGranted
        self.name = name
        self.explanation = explanation
        self.request = request
    }
}

/// Fixed sizes for the first-run window. It follows the view's size, so these are what set it. Pure values so tests can
/// check that every state fits.
public enum OnboardingMetrics {
    public static let windowSize = CGSize(width: 600, height: 572)
    static let horizontalPadding: CGFloat = 32
    static let contentWidth = windowSize.width - horizontalPadding * 2
    /// The same on every step, so the words below it never jump. Holds the largest `BubbleCluster`.
    static let heroHeight: CGFloat = 372
    /// With the room a cluster leaves in the hero, 32 from the bubbles to the headline.
    static let headlineGap: CGFloat = 8
    static let footerHeight: CGFloat = 64
    static let stepHeight = windowSize.height - footerHeight
}

/// First-run window: see the product (`WelcomeStep`), then do it once on a real sample picture (`tryIt`). The trigger key
/// and permission steps appear only when they apply.
public struct OnboardingView: View {
    @ObservedObject var settings: HaloSettings
    @ObservedObject var permissions: OnboardingPermissions
    /// Nil hides the try-it step (no sample could be prepared).
    private let tryIt: OnboardingTry?
    let onFinish: () -> Void
    /// Holds the welcome film on one beat instead of playing it (renders and tests).
    private let heldBeat: WelcomeDemoBeat?
    /// Set by the binding-based init; overrides `permissions.isGranted`.
    private var grantedBinding: Binding<Bool>?

    // `State` struct rather than the `@State` macro (no SwiftUIMacros plugin in the Command Line Tools).
    private let stepState: State<Step>
    private var step: Step {
        get { stepState.wrappedValue } nonmutating set { stepState.wrappedValue = newValue }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Step: Int, CaseIterable { case welcome, trigger, permissions, tryIt }

    public init(settings: HaloSettings, permissions: OnboardingPermissions, tryIt: OnboardingTry? = nil,
                onFinish: @escaping () -> Void) {
        self.init(settings: settings, permissions: permissions, tryIt: tryIt, startAt: .welcome, onFinish: onFinish)
    }

    /// `startAt` opens on a later step (renders and tests).
    init(settings: HaloSettings, permissions: OnboardingPermissions, tryIt: OnboardingTry?, startAt: Step,
         heldBeat: WelcomeDemoBeat? = nil, onFinish: @escaping () -> Void) {
        self.settings = settings
        self.permissions = permissions
        self.tryIt = tryIt
        self.onFinish = onFinish
        self.heldBeat = heldBeat
        stepState = State(initialValue: startAt)
    }

    static func steps(opensOnPause: Bool, permissionsRequired: Bool, hasTry: Bool) -> [Step] {
        Step.allCases.filter { step in
            switch step {
            case .permissions: permissionsRequired
            case .tryIt: hasTry
            case .trigger: !opensOnPause
            case .welcome: true
            }
        }
    }

    private var steps: [Step] {
        Self.steps(opensOnPause: settings.opensOnPause, permissionsRequired: permissions.isRequired, hasTry: tryIt != nil)
    }
    private var stepIndex: Int { steps.firstIndex(of: step) ?? 0 }
    private var isLast: Bool { stepIndex == steps.count - 1 }
    private var isGranted: Bool { grantedBinding?.wrappedValue ?? permissions.isGranted }

    public var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case .welcome: WelcomeStep(opensOnPause: settings.opensOnPause, heldBeat: heldBeat)
                case .trigger: TriggerStep(settings: settings)
                case .permissions: PermissionStep(permissions: permissions, isGranted: isGranted)
                case .tryIt: if let tryIt { TryItStep(model: tryIt, gesture: settings.gesture) }
                }
            }
            .id(step)
            .transition(reduceMotion ? .opacity
                        : .asymmetric(insertion: .opacity.combined(with: .offset(x: 18)),
                                      removal: .opacity.combined(with: .offset(x: -18))))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, OnboardingMetrics.horizontalPadding)

            OnboardingFooter(tryIt: step == .tryIt ? tryIt : nil, permissionName: permissions.name, stepIndex: stepIndex, stepCount: steps.count,
                             isLast: isLast, blockedByPermission: isLast && permissions.isRequired && !isGranted,
                             back: { go(to: stepIndex - 1) }, next: { go(to: stepIndex + 1) }, finish: finish)
                .padding(.horizontal, 20)
                .frame(height: OnboardingMetrics.footerHeight)
        }
        .frame(width: OnboardingMetrics.windowSize.width, height: OnboardingMetrics.windowSize.height)
        .background { FrenzyBackdrop() }
        // Runs under the transparent title bar, like the main window.
        .ignoresSafeArea()
    }

    private func go(to index: Int) {
        guard steps.indices.contains(index) else { return }
        withAnimation(reduceMotion ? RingMotion.crossfade : RingMotion.settle) {
            step = steps[index]
        }
    }

    private func finish() {
        settings.hasCompletedOnboarding = true
        onFinish()
    }
}

public extension OnboardingView {
    /// Binding-based variant: `permissionsGranted` should flip to true once the host sees the permission granted.
    init(settings: HaloSettings, permissionsRequired: Bool = true, permissionsGranted: Binding<Bool>,
         requestPermissions: @escaping () -> Void, onFinish: @escaping () -> Void) {
        self.init(settings: settings,
                  permissions: OnboardingPermissions(isRequired: permissionsRequired, request: requestPermissions),
                  onFinish: onFinish)
        grantedBinding = permissionsGranted
    }
}

/// The window's surface: a plain ground. What the glass catches is `HeroDisc`, which each hero centres on itself.
struct FrenzyBackdrop: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()
    }
}

// MARK: Footer

/// Which buttons a step's footer shows. The prominent one is always `primary`; everything else stays quiet.
struct OnboardingFooterPlan: Equatable {
    var showsBack: Bool
    var showsNotNow: Bool
    /// Never the default button: Return must not skip the lesson by accident.
    var skip: String?
    var primary: String?
    var primaryEnabled: Bool
    /// Why the primary button is disabled, as its help and VoiceOver hint. Nil while it is enabled.
    var disabledReason: String?
    /// What "Not now" gives up, as its help and VoiceOver hint.
    var notNowHelp: String?

    init(stepIndex: Int, isLast: Bool, isOnTry: Bool, tryIsDone: Bool, blockedByPermission: Bool,
         permissionName: String = "Accessibility") {
        showsBack = stepIndex > 0
        showsNotNow = blockedByPermission
        disabledReason = blockedByPermission ? "Allow \(permissionName) in System Settings first, or choose Not now." : nil
        notNowHelp = blockedByPermission
            ? "Finish without \(permissionName). Holding the key won't open the bubbles until you allow it." : nil
        // On the try-it step the way out is a quiet "Skip" until the sample has been converted.
        if isOnTry && !tryIsDone {
            skip = "Skip"
            primary = nil
        } else {
            skip = nil
            primary = isLast ? "Start using Frenzy" : "Continue"
        }
        primaryEnabled = !blockedByPermission
    }
}

/// Observes the try-it model (when on that step) so "Skip" turns into the primary button the moment it succeeds.
private struct OnboardingFooter: View {
    @ObservedObject private var tryIt: OnboardingTry
    private let hasTry: Bool
    let permissionName: String
    let stepIndex: Int
    let stepCount: Int
    let isLast: Bool
    let blockedByPermission: Bool
    let back: () -> Void
    let next: () -> Void
    let finish: () -> Void

    init(tryIt: OnboardingTry?, permissionName: String, stepIndex: Int, stepCount: Int, isLast: Bool,
         blockedByPermission: Bool, back: @escaping () -> Void, next: @escaping () -> Void, finish: @escaping () -> Void) {
        self.tryIt = tryIt ?? Self.placeholder
        hasTry = tryIt != nil
        self.permissionName = permissionName
        self.stepIndex = stepIndex
        self.stepCount = stepCount
        self.isLast = isLast
        self.blockedByPermission = blockedByPermission
        self.back = back
        self.next = next
        self.finish = finish
    }

    private static let placeholder = OnboardingTry(sampleURL: URL(fileURLWithPath: "/dev/null"))

    var body: some View {
        let plan = OnboardingFooterPlan(stepIndex: stepIndex, isLast: isLast, isOnTry: hasTry, tryIsDone: tryIt.isDone,
                                        blockedByPermission: blockedByPermission, permissionName: permissionName)
        ZStack {
            StepDots(index: stepIndex, count: stepCount)
            HStack(spacing: 8) {
                if plan.showsBack {
                    Button("Back", action: back)
                        .keyboardShortcut(.cancelAction)
                        .onboardingQuietButton()
                }
                Spacer()
                if plan.showsNotNow {
                    Button("Not now", action: finish)
                        .onboardingQuietButton()
                        .help(plan.notNowHelp ?? "")
                        .accessibilityHint(plan.notNowHelp ?? "")
                }
                if let skip = plan.skip {
                    Button(skip, action: isLast ? finish : next)
                        .onboardingQuietButton()
                }
                if let primary = plan.primary {
                    Button(primary, action: isLast ? finish : next)
                        .keyboardShortcut(.defaultAction)
                        .frenzyPrimaryButton()
                        .disabled(!plan.primaryEnabled)
                        .help(plan.disabledReason ?? "")
                        .accessibilityHint(plan.disabledReason ?? "")
                }
            }
        }
    }
}

private struct StepDots: View {
    let index: Int
    let count: Int

    var body: some View {
        if count > 1 {
            HStack(spacing: 8) {
                ForEach(0..<count, id: \.self) { dot in
                    Circle()
                        .fill(dot == index ? AnyShapeStyle(FrenzyPalette.accent) : AnyShapeStyle(.primary.opacity(0.22)))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(index + 1) of \(count)")
        }
    }
}

extension View {
    /// Back, Skip and other ways out: words only, readable but never competing with the primary button.
    func onboardingQuietButton() -> some View {
        buttonStyle(.borderless)
            .foregroundStyle(.primary.opacity(0.72))
            .controlSize(.large)
    }
}

// MARK: Steps

/// Every step's shape: the hero up top, then one headline and at most one line, always in the same place.
struct OnboardingStepLayout<Hero: View, Extra: View>: View {
    let title: String
    let message: String?
    @ViewBuilder let hero: Hero
    @ViewBuilder let extra: Extra

    var body: some View {
        VStack(spacing: 0) {
            hero
                .frame(maxWidth: .infinity)
                .frame(height: OnboardingMetrics.heroHeight)
            VStack(spacing: 6) {
                Text(title)
                    .frenzyDisplayType()
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message)
                        .frenzyLeadType()
                        .foregroundStyle(.primary.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 480)
                        .contentTransition(.opacity)
                }
            }
            .padding(.top, OnboardingMetrics.headlineGap)
            extra
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// One moment of the welcome film. Pure value so tests can check the story it tells.
struct WelcomeDemoBeat: Equatable {
    var spread: Bool
    var hovered: Int?
    var showsResult: Bool
    var holdMilliseconds: Int

    /// The file alone, the bubbles split out, one is chosen, the bubbles flow back and the disc says it is done. Then
    /// again, with enough rest that it never nags.
    static let film: [WelcomeDemoBeat] = [
        WelcomeDemoBeat(spread: false, hovered: nil, showsResult: false, holdMilliseconds: 700),
        WelcomeDemoBeat(spread: true, hovered: nil, showsResult: false, holdMilliseconds: 1500),
        WelcomeDemoBeat(spread: true, hovered: 0, showsResult: false, holdMilliseconds: 1200),
        WelcomeDemoBeat(spread: false, hovered: nil, showsResult: true, holdMilliseconds: 2200),
    ]
    /// Under Reduce Motion: open and still, so the picture still explains itself.
    static let still = WelcomeDemoBeat(spread: true, hovered: nil, showsResult: false, holdMilliseconds: 0)
}

/// The file the welcome film and the trigger step are about: one plain invoice, with the choices the real ring offers for
/// a PDF. Illustration only, so nothing here is pressable and no result is claimed beyond what the action does.
enum WelcomeDemo {
    static let fileName = "Invoice.pdf"
    /// The file after the film's drop. It stands in for "Invoice compressed.pdf", too long for the disc.
    static let doneLine = "Compressed"

    static let items: [RingItem] = [
        RingItem(id: "pdf.compress", title: "Compress", subtitle: "Smaller file", symbolName: "rectangle.compress.vertical", category: .pdf),
        RingItem(id: "pdf.to-images", title: "Images", subtitle: "PNG per page", symbolName: "photo.on.rectangle.angled", category: .pdf),
        RingItem(id: "pdf.to-text", title: "To Text", subtitle: "Plain text", symbolName: "doc.plaintext", category: .pdf),
        RingItem(id: "pdf.split", title: "Split", subtitle: "PDF per page", symbolName: "scissors", category: .pdf),
        RingItem(id: "pdf.rotate-right", title: "Rotate", subtitle: "90° clockwise", symbolName: "rotate.right", category: .pdf),
    ]

    static let pixelSize = CGSize(width: 138, height: 184)

    /// A page as Quick Look would show it at this size: a heading, a few line items with amounts, a total.
    static func makePage() -> CGImage? {
        let width = pixelSize.width, height = pixelSize.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        func bar(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat, gray: CGFloat) {
            ctx.setFillColor(CGColor(gray: gray, alpha: 1))
            ctx.fill(CGRect(x: x, y: height - top - h, width: w, height: h))
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: pixelSize))
        let margin: CGFloat = 14
        bar(margin, 16, 58, 10, gray: 0.14)
        bar(margin, 32, 36, 4, gray: 0.62)
        for row in 0..<6 {
            let top = 58 + CGFloat(row) * 14
            bar(margin, top, row % 3 == 2 ? 48 : 72, 4, gray: 0.72)
            bar(width - margin - 18, top, 18, 4, gray: 0.55)
        }
        bar(margin, 142, width - margin * 2, 1, gray: 0.8)
        bar(width - margin - 36, 150, 36, 8, gray: 0.14)
        return ctx.makeImage()
    }
}

/// Drawn once for the welcome film and the trigger step.
@MainActor
private enum OnboardingArt {
    static let page = WelcomeDemo.makePage()
}

/// The real centre disc, holding the demo file: what the live ring shows while you drag it.
private struct DemoFileHub: View {
    /// What the lit bubble does.
    var hint: String?
    var isDone = false

    var body: some View {
        RingCenterView(label: isDone ? WelcomeDemo.doneLine : WelcomeDemo.fileName,
                       symbolName: "doc",
                       preview: OnboardingArt.page.map { .thumbnail($0) },
                       detail: hint,
                       isHint: hint != nil,
                       tint: nil,
                       received: false,
                       ground: .disc)
            .overlay {
                if isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.frenzyGlyph(16, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        // A white disc: this sits on the accent disc, which would swallow an accent one.
                        .foregroundStyle(FrenzyPalette.accent, .white)
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                        // On the page's bottom corner.
                        .offset(x: 19, y: 6)
                        .transition(.opacity)
                }
            }
    }
}

private struct WelcomeStep: View {
    let opensOnPause: Bool
    let heldBeat: WelcomeDemoBeat?

    private let beatState: State<WelcomeDemoBeat>
    private var beat: WelcomeDemoBeat {
        get { beatState.wrappedValue } nonmutating set { beatState.wrappedValue = newValue }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(opensOnPause: Bool, heldBeat: WelcomeDemoBeat?) {
        self.opensOnPause = opensOnPause
        self.heldBeat = heldBeat
        beatState = State(initialValue: heldBeat ?? WelcomeDemoBeat.film[0])
    }

    var body: some View {
        OnboardingStepLayout(title: opensOnPause ? "Drag. Pause. Drop." : "Drag. Hold. Drop.",
                             message: "Convert files right where they are, in Finder or on the Desktop.") {
            ZStack {
                HeroDisc()
                // The centre sits in the cluster, as it does in the real ring, so the bubbles split out of its glass.
                BubbleCluster(items: WelcomeDemo.items, hoveredIndex: beat.hovered, spread: beat.spread) {
                    DemoFileHub(hint: beat.hovered.flatMap { WelcomeDemo.items[$0].subtitle }, isDone: beat.showsResult)
                        .animation(reduceMotion ? RingMotion.crossfade : RingMotion.quick, value: beat.showsResult)
                }
            }
            .accessibilityHidden(true)
        } extra: {
            EmptyView()
        }
        .task(id: reduceMotion) { await play() }
    }

    private func play() async {
        if heldBeat != nil { return }
        if reduceMotion {
            beat = .still
            return
        }
        while !Task.isCancelled {
            for next in WelcomeDemoBeat.film {
                beat = next
                try? await Task.sleep(for: .milliseconds(next.holdMilliseconds))
                if Task.isCancelled { return }
            }
        }
    }
}

extension TriggerKey {
    /// The key's name alone: on a bubble its glyph sits above it.
    var bubbleTitle: String { displayName.split(separator: " ").last.map(String.init) ?? displayName }

    var symbolName: String {
        switch self {
        case .option: "option"
        case .shift: "shift"
        case .control: "control"
        case .function: "fn"
        }
    }
}

private struct TriggerStep: View {
    @ObservedObject var settings: HaloSettings
    private let spreadState = State(initialValue: false)
    private var spread: Bool {
        get { spreadState.wrappedValue } nonmutating set { spreadState.wrappedValue = newValue }
    }

    /// PDF's red is the icon's ember red, so the chosen key reads as part of the fire (text's orange lit up brown on the
    /// disc), and only the chosen bubble shows it.
    private static let items = TriggerKey.allCases.map {
        RingItem(id: ActionID(rawValue: "trigger.\($0.rawValue)"), title: $0.bubbleTitle, subtitle: nil,
                 symbolName: $0.symbolName, category: .pdf)
    }

    var body: some View {
        let keys = TriggerKey.allCases
        OnboardingStepLayout(title: "Pick your key", message: "Hold it during a drag to open the bubbles.") {
            ZStack {
                HeroDisc()
                BubbleCluster(items: Self.items, hoveredIndex: keys.firstIndex(of: settings.trigger), spread: spread,
                              tap: { item in
                                  if let index = Self.items.firstIndex(of: item) { settings.trigger = keys[index] }
                              }) {
                    DemoFileHub()
                        .accessibilityHidden(true)
                }
            }
        } extra: {
            EmptyView()
        }
        .onAppear { spread = true }
    }
}

private struct PermissionStep: View {
    @ObservedObject var permissions: OnboardingPermissions
    let isGranted: Bool
    @Environment(\.self) private var environment
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        OnboardingStepLayout(title: "Allow \(permissions.name)", message: permissions.explanation) {
            ZStack {
                HeroDisc()
                RingGlassContainer {
                    Image(systemName: isGranted ? "checkmark.shield.fill" : "hand.raised.fill")
                        .font(.frenzyGlyph(44, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        // The ink, not the accent: this glass sits on the accent disc.
                        .foregroundStyle(environment.labelSurface(.disc).ink.color)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 128, height: 128)
                        .background { LabelPlate(diameter: 128, ground: .disc) }
                        .modifier(LiquidGlassBackground(shape: Circle()))
                }
            }
        } extra: {
            if isGranted {
                Label("Access granted", systemImage: "checkmark")
                    .font(.frenzy(.body, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.72))
            } else {
                VStack(spacing: 8) {
                    Button("Open System Settings…", action: permissions.request)
                        .frenzySecondaryButton()
                    // Says what "Not now" gives up, and why the main button waits, without needing its tooltip.
                    Text(permissions.withoutItNote)
                        .font(.frenzy(.label))
                        .foregroundStyle(WindowInk.detail(contrast))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420)
                }
            }
        }
    }
}
