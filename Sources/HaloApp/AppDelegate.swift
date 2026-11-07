import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?
    /// Read while the launch Apple event is still current (it is gone by applicationDidFinishLaunching on some systems).
    private var launchedAsLoginItem = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        launchedAsLoginItem = Self.isLoginItemLaunch
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = AppController()
        self.controller = controller
        // Opened by the user (Finder, Spotlight, Launchpad): show the main window. Started at login: stay quiet.
        controller.start(showWindow: !launchedAsLoginItem)

        DistributedNotificationCenter.default().addObserver(
            forName: SingleInstance.reopenNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller?.reopen(from: "second launch") }
        }
    }

    /// The launch Apple event says whether macOS opened Halo as a login item.
    private static var isLoginItemLaunch: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Opening Halo again while it runs (Finder, Spotlight, the Dock-less double-click) always brings the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.reopen(from: "macOS reopen event, visible windows: \(flag)")
        return true
    }

    /// Quit or logout while converting: cancel the jobs, wait for their cleanup (temp files removed, worker staging
    /// discarded), then let the app terminate. Never leaves half-written files behind.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller, controller.activeJobs > 0 else { return .terminateNow }
        Task { @MainActor in
            await controller.cancelAllAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }

    /// Closing the main, Settings or onboarding window must never quit a menu-bar app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
