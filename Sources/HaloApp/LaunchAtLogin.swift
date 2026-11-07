import Foundation
import ServiceManagement
import os

/// "Open at login" through `SMAppService.mainApp` (macOS 13+). Only works when Halo runs from a real `.app`
/// bundle with a bundle identifier; `swift run` builds report it as unavailable. On register, macOS shows a
/// "Login Items added" notice and lists Halo in System Settings > General > Login Items.
@MainActor
final class LaunchAtLogin {
    private let log = Logger(subsystem: "com.snappycrew.frenzy", category: "login-item")

    /// False for unbundled development builds, where SMAppService has no app to register.
    var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    var status: SMAppService.Status { isAvailable ? SMAppService.mainApp.status : .notFound }
    var isEnabled: Bool { status == .enabled }
    /// Registered, but the user switched Halo off in System Settings > Login Items.
    var needsApproval: Bool { status == .requiresApproval }

    /// Applies the choice and returns the resulting state (true = Halo will open at login).
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard isAvailable else {
            log.notice("Launch at login needs Frenzy.app; ignored for this development build")
            return false
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
        if enabled && needsApproval { SMAppService.openSystemSettingsLoginItems() }
        return isEnabled
    }
}
