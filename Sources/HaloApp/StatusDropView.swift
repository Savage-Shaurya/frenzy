import AppKit
import HaloDrag

/// A transparent layer over the menu-bar button that accepts dropped files, so Halo also works without the
/// trigger key: drag a file onto the icon and pick a conversion from the menu that opens.
///
/// It sits on top of the button but never takes a click (see `hitTest`), so clicking still opens Halo's menu.
/// Only real files are accepted; promises (Photos, Mail) are refused, like the ring does in V0.
@MainActor
final class StatusDropView: NSView {
    var onDrop: (([URL]) -> Void)?
    /// Called when a file drag first enters the icon (diagnostics: the e2e test reads it from the log).
    var onEnter: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var button: NSButton? { superview as? NSButton }

    private func files(in info: any NSDraggingInfo) -> [URL] {
        let raw = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return DragPasteboardReader.resolveFileURLs(raw)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !files(in: sender).isEmpty else { return [] }
        onEnter?()
        button?.highlight(true)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        files(in: sender).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { button?.highlight(false) }

    override func draggingEnded(_ sender: any NSDraggingInfo) { button?.highlight(false) }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = files(in: sender)
        button?.highlight(false)
        guard !urls.isEmpty else { return false }
        // Let the drag session finish before a menu starts tracking.
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onDrop?(urls) } }
        return true
    }

    // Invisible to clicks: every mouse event lands on the button underneath, so Halo's menu always opens.
    // If AppKit's drag lookup also hit-tests, drops simply aren't received here; clicks are never at risk.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
