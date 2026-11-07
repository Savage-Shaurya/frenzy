import AppKit
import SwiftUI

/// Owns the app's few windows (the main Halo window, Settings, onboarding). An accessory app has no menu bar of its own, so each
/// window activates the app when shown and is kept alive after closing for instant reopening.
@MainActor
final class WindowPresenter: NSObject, NSWindowDelegate {
    private var windows: [String: NSWindow] = [:]
    private var onClose: [String: () -> Void] = [:]

    /// `chromeless` hides the title text and lets the content run under a transparent title bar (the main window).
    /// `size` fixes the content size up front; without it the window follows the content's preferred size.
    func show(id: String, title: String, content: AnyView, chromeless: Bool = false, size: CGSize? = nil,
              onClose: (() -> Void)? = nil) {
        let window = windows[id] ?? makeWindow(id: id, title: title, content: content, chromeless: chromeless, size: size)
        if let onClose { self.onClose[id] = onClose }
        // Centred once when created; after that the window reopens where the user left it.
        // macOS 14+ activation is only a request the system may decline (e.g. right after launch from Finder
        // or a script), and then makeKeyAndOrderFront leaves an accessory app's window off screen. Order it in
        // regardless, on the active Space, and then ask for activation so it can also take keyboard focus.
        window.orderFrontRegardless()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close(id: String) { windows[id]?.close() }

    /// Swaps a kept window's content, so it reopens fresh instead of where it was left.
    func replaceContent(id: String, with content: AnyView) {
        (windows[id]?.contentViewController as? NSHostingController<AnyView>)?.rootView = content
    }

    func isVisible(id: String) -> Bool { windows[id]?.isVisible ?? false }

    func window(id: String) -> NSWindow? { windows[id] }

    private func makeWindow(id: String, title: String, content: AnyView, chromeless: Bool, size: CGSize?) -> NSWindow {
        let host = NSHostingController(rootView: content)
        // The preferred size arrives only after SwiftUI's first layout pass; a chromeless window created before it
        // stayed 1 x 0 pt (invisible, and missing from the accessibility tree). A known size is set up front.
        host.sizingOptions = size == nil ? [.preferredContentSize] : []
        let window = NSWindow(contentViewController: host)
        if let size { window.setContentSize(size) }
        window.center()
        window.title = title
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.identifier = NSUserInterfaceItemIdentifier(id)
        if chromeless {
            window.styleMask.insert(.miniaturizable)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
        window.delegate = self
        windows[id] = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard let id = (notification.object as? NSWindow)?.identifier?.rawValue else { return }
        onClose.removeValue(forKey: id)?()
    }
}

/// A minimal main menu. Halo is an accessory app, so macOS never shows this menu bar, but AppKit still routes key
/// equivalents through it while a Halo window is key: ⌘O converts files, ⌘W closes, ⌘M minimises, ⌘, opens Settings, ⌘Q quits, and
/// the Edit shortcuts work in text fields.
@MainActor
enum MainMenu {
    static func install(controller: AppController) {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            return item
        }
        submenu("Frenzy", [
            item("About Frenzy", #selector(AppController.showAbout), "", target: controller),
            item("Settings…", #selector(AppController.showSettings), ",", target: controller),
            .separator(),
            item("Hide Frenzy", #selector(NSApplication.hide(_:)), "h"),
            item("Quit Frenzy", #selector(AppController.quit), "q", target: controller),
        ])
        submenu("File", [
            item("Open Frenzy", #selector(AppController.showHome), "n", target: controller),
            item("Convert Files…", #selector(AppController.convertFiles), "o", target: controller),
            item("Show Latest Result", #selector(AppController.showLatestResult), "l", target: controller),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "Z"),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        NSApp.mainMenu = main
    }
}
