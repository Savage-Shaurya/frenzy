import AppKit
import SwiftUI
import os
import HaloCore
import HaloUI
import HaloDrag

// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
// The ONE place where HaloApp picks concrete types from HaloUI and HaloDrag. `AppController` only talks to
// `DragTriggerMonitoring`, `RingOverlayPresenting` and `ToastPresenting` through what this file returns.
// Every `// INTEGRATION:` line marks a seam to re-check if another module changes its public API.
// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

@MainActor
enum Integration {
    static func makeSettings() -> HaloSettings {
        // INTEGRATION: HaloUI.HaloSettings (persists to UserDefaults; keys "halo.*").
        HaloSettings()
    }

    /// Where conversions run. Halo.app always uses the sandboxed XPC worker. Only an unbundled development build
    /// (`swift run`, which has no XPCServices folder) falls back to converting in-process, and says so in the log.
    static func makeBackend(registry: ActionRegistry) -> any ConversionBackend {
        let bundled = Bundle.main.bundleURL.pathExtension == "app"
        if bundled { return XPCConversionBackend(registry: registry) }
        Logger(subsystem: "com.snappycrew.frenzy", category: "app")
            .warning("Unbundled build: converting IN-PROCESS without the sandboxed worker. Use scripts/run-dev.sh for the real app.")
        return InProcessBackend(runner: ConversionRunner(registry: registry), staged: true,
                                savePolicy: .standard(inbox: PromiseInbox().root))
    }

    static func makeToasts(settings: HaloSettings) -> any JobToastPresenting {
        // INTEGRATION: HaloUI.ToastCenter. It also plays sounds and reveals outputs in Finder when the matching
        // settings are on, so AppController must not reveal files itself.
        ToastCenter(settings: settings)
    }

    static func makeMonitor() -> any DragTriggerMonitoring {
        // INTEGRATION: HaloDrag.DragTriggerMonitor (no Accessibility / Input Monitoring permission needed).
        // Drags from Photos, Mail and browsers carry promises, not files. AppController says what they can become.
        let monitor = DragTriggerMonitor()
        monitor.summonsForFilePromises = true
        return monitor
    }

    static func makeOverlay() -> any RingOverlayPresenting {
        // INTEGRATION: HaloDrag.RingOverlayController (floating panel hosting HaloUI.RingView).
        RingOverlayController()
    }

    /// Glues monitor and overlay. `itemsFor` decides what the ring shows (empty = no ring),
    /// `onConvert` receives the chosen action and the dropped files.
    static func makeDragCoordinator(monitor: any DragTriggerMonitoring,
                                    overlay: any RingOverlayPresenting,
                                    itemsFor: @escaping ([URL]) -> (items: [RingItem], centerLabel: String),
                                    onConvert: @escaping (ActionID, [URL]) -> Void) -> DragCoordinator {
        // INTEGRATION: HaloDrag.DragCoordinator owns monitor.onSummon / onDismiss and the drop grace period.
        DragCoordinator(monitor: monitor, overlay: overlay, itemsFor: itemsFor, onConvert: onConvert)
    }

    static func settingsView(settings: HaloSettings, version: String) -> AnyView {
        // INTEGRATION: HaloUI.SettingsView. Its "Launch at login" toggle reaches SMAppService through
        // `settings.onLaunchAtLoginChange`, set up in AppController.
        AnyView(SettingsView(settings: settings, version: version))
    }

    static func homeView(model: HomeModel, settings: HaloSettings) -> AnyView {
        // INTEGRATION: HaloUI.HomeView, the main window. AppController fills `model` and sets its callbacks.
        AnyView(HomeView(model: model, settings: settings))
    }

    static func onboardingView(settings: HaloSettings, tryIt: OnboardingTry?, onFinish: @escaping () -> Void) -> AnyView {
        // INTEGRATION: HaloUI.OnboardingView. HaloDrag needs no permission, so the permission step is hidden.
        // `tryIt` adds the last step, a real conversion of Halo's sample photo; AppController reports its progress.
        AnyView(OnboardingView(settings: settings,
                               permissions: OnboardingPermissions(isRequired: false, request: {}),
                               tryIt: tryIt, onFinish: onFinish))
    }
}
