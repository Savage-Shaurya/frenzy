import SwiftUI
import HaloCore

/// Native settings window content: General and About tabs.
public struct SettingsView: View {
    @ObservedObject var settings: HaloSettings
    let version: String

    public init(settings: HaloSettings, version: String) {
        self.settings = settings
        self.version = version
    }

    public var body: some View {
        TabView {
            GeneralSettingsPane(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            AboutPane(version: version)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460)
    }
}

/// What the settings say, kept in one place so tests can hold the words to what the app does.
enum SettingsCopy {
    /// The pause is `DragTriggerMonitor.pauseDuration` (0.4 s) over Finder and the Desktop.
    static let pauseToggle = "Open when I pause mid-drag for half a second"
    static func ringFooter(gesture: String) -> String {
        "Start dragging a file from Finder or the Desktop, then \(gesture)."
    }
    static let revealToggle = "Show converted files in Finder"
    static let resultsFooter = "Show converted files in Finder brings Finder to the front with the new files selected. Problems always show, even with results turned off."
    static let previewsFooter = "Previews are made on this Mac. Turn them off to show plain icons, for example while sharing your screen."
    /// Exact and checkable: the worker that reads your files runs in App Sandbox with no network entitlement
    /// (Resources/HaloWorker.entitlements).
    static let privacyHeadline = "Conversions run in a helper macOS blocks from the network."
    static let privacyDetail = "Frenzy opens and converts your files in that helper, on this Mac."
}

struct GeneralSettingsPane: View {
    @ObservedObject var settings: HaloSettings
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Form {
            Section {
                Toggle(SettingsCopy.pauseToggle, isOn: $settings.opensOnPause)
                Picker(settings.opensOnPause ? "Or hold this key" : "Hold this key", selection: $settings.trigger) {
                    ForEach(TriggerKey.allCases, id: \.self) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                // Value and control on the trailing edge, like the trigger key's menu above.
                LabeledContent("Ring size") {
                    HStack(spacing: 8) {
                        Text("Up to \(settings.maxRingItems) choices")
                            .monospacedDigit()
                        Stepper("Ring size", value: $settings.maxRingItems, in: HaloSettings.ringItemsRange)
                            .labelsHidden()
                    }
                }
            } header: {
                Text("Ring")
            } footer: {
                Text(SettingsCopy.ringFooter(gesture: settings.gesture))
                    .foregroundStyle(WindowInk.detail(contrast))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Show progress and results", isOn: $settings.showToasts)
                Toggle(SettingsCopy.revealToggle, isOn: $settings.revealAfterConvert)
                Toggle("Play sounds", isOn: $settings.playSounds)
            } header: {
                Text("After converting")
            } footer: {
                Text(SettingsCopy.resultsFooter)
                    .foregroundStyle(WindowInk.detail(contrast))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Show file previews", isOn: $settings.showPreviews)
            } header: {
                Text("Privacy")
            } footer: {
                Text(SettingsCopy.previewsFooter)
                    .foregroundStyle(WindowInk.detail(contrast))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Startup") {
                Toggle("Open Frenzy at login", isOn: $settings.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        // Switches in the brand colour, not the system accent: on a Mac set to red they would read as an error.
        .tint(FrenzyPalette.accent)
        // Its natural height, so the window fits it, but it can still scroll (never clip) if larger text makes it taller
        // than the screen allows.
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct AboutPane: View {
    let version: String
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 14) {
            HaloGlyph()
                .frame(width: 64, height: 64)
            VStack(spacing: 3) {
                Text("Frenzy").frenzyLeadType()
                Text("Version \(version)").font(.frenzy(.label)).foregroundStyle(WindowInk.detail(contrast))
            }
            Text(SettingsCopy.privacyHeadline)
                .font(.frenzy(.body, weight: .medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(SettingsCopy.privacyDetail)
                .font(.frenzy(.label))
                .foregroundStyle(WindowInk.detail(contrast))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }
}

/// The brand mark, the same drawing as the app icon (scripts/make-icon.swift): six small bubbles around a glassy disc,
/// on the brand colour.
public struct HaloGlyph: View {
    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let white = LinearGradient(colors: [.white, .white.opacity(0.82)], startPoint: .top, endPoint: .bottom)
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous)
                    .fill(FrenzyPalette.accent.gradient)
                ForEach(0..<6, id: \.self) { index in
                    let angle = Double(index) * .pi / 3
                    Circle()
                        .fill(white)
                        .frame(width: side * 0.2, height: side * 0.2)
                        .offset(x: cos(angle) * side * 0.34, y: sin(angle) * side * 0.34)
                }
                Circle()
                    .fill(white)
                    .frame(width: side * 0.36, height: side * 0.36)
            }
            .frame(width: side, height: side)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityHidden(true)
    }
}
