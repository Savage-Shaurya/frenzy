import AppKit
import HaloCore
import HaloUI
import os

/// Glues a `DragTriggerMonitoring` to a `RingOverlayPresenting`. No app logic: the app decides which items to
/// show (`itemsFor`) and what a drop does (`onConvert`).
@MainActor
public final class DragCoordinator {
    public typealias ItemsProvider = ([URL]) -> (items: [RingItem], centerLabel: String)

    public let monitor: any DragTriggerMonitoring
    public let overlay: any RingOverlayPresenting
    /// After the mouse comes up over the ring, how long to wait for `performDragOperation` before dismissing.
    public var dropGracePeriod: TimeInterval = 0.5
    /// Optional: items for drags that carry only file promises (needs `DragTriggerMonitor.summonsForFilePromises`).
    /// Receives the promised content type identifiers.
    public var promisedItemsFor: (([String]) -> (items: [RingItem], centerLabel: String))?
    /// Optional: an SF Symbol for the ring's centre (a folder, a zip). Used when the overlay is a `RingOverlayController`.
    public var centerSymbolFor: (([URL]) -> String?)?
    /// Optional: the same for a promised drag, from the promised types.
    public var promisedSymbolFor: (([String]) -> String?)?
    /// The key was pressed during a drag of a bare web link, which can't become a ring. Say why.
    public var onLinkDrag: (() -> Void)?

    private let itemsFor: ItemsProvider
    private let onConvert: (ActionID, [URL]) -> Void
    private var pendingPayload: DragPayload?
    private var dismissGeneration = 0

    public var trigger: TriggerKey {
        get { monitor.trigger }
        set { monitor.trigger = newValue }
    }

    public init(monitor: (any DragTriggerMonitoring)? = nil,
                overlay: (any RingOverlayPresenting)? = nil,
                itemsFor: @escaping ItemsProvider,
                onConvert: @escaping (ActionID, [URL]) -> Void) {
        self.monitor = monitor ?? DragTriggerMonitor()
        self.overlay = overlay ?? RingOverlayController()
        self.itemsFor = itemsFor
        self.onConvert = onConvert
        if let live = self.monitor as? DragTriggerMonitor {
            live.onSummonPayload = { [weak self] payload, _ in self?.pendingPayload = payload }
            live.onPausePointer = { [weak self] point in (self?.overlay as? RingOverlayController)?.pointerMoved(to: point) }
            live.pauseLeaveCenter = { [weak self] in (self?.overlay as? RingOverlayController)?.ringCenter }
            live.holdsOpen = { [weak self] in (self?.overlay as? RingOverlayController)?.isHoveringWedge ?? false }
            live.onLinkDrag = { [weak self] in self?.onLinkDrag?() }
        }
        self.monitor.onSummon = { [weak self] urls, point in self?.summon(urls, at: point) }
        self.monitor.onDismiss = { [weak self] in self?.monitorDismissed() }
    }

    public func start() { monitor.start() }

    public func stop() {
        monitor.stop()
        overlay.dismiss(animated: false)
    }

    private func summon(_ urls: [URL], at point: NSPoint) {
        dismissGeneration += 1
        defer { pendingPayload = nil }
        if overlay.isPresented {
            // A chosen wedge is still flashing: that drop stands, and this drag gets no ring.
            if let ring = overlay as? RingOverlayController, case .committing = ring.model.phase { return }
            // Left over from the last drag (its drop-grace dismiss was just cancelled above): clear it at once and
            // open a fresh ring for this drag.
            overlay.dismiss(animated: false)
        }
        let content: (items: [RingItem], centerLabel: String)
        let promised = Self.promisedTypes(of: pendingPayload)
        if urls.isEmpty, !promised.isEmpty, let promisedItemsFor {
            content = promisedItemsFor(promised)
        } else if !urls.isEmpty {
            content = itemsFor(urls)
        } else {
            return
        }
        guard !content.items.isEmpty else { return }
        if let live = monitor as? DragTriggerMonitor {
            Logger(subsystem: "com.snappycrew.frenzy", category: "app").notice("Ring opened: \(live.summonedByPause ? "pause" : "key", privacy: .public) \(live.flagDiagnostics, privacy: .public)")
        }
        let fallback = urls
        let onDrop: (ActionID, [URL]) -> Void = { [weak self] id, dropped in
            self?.onConvert(id, dropped.isEmpty ? fallback : dropped)
        }
        if let ring = overlay as? RingOverlayController {
            ring.letsDropsThroughHub = (monitor as? DragTriggerMonitor)?.summonedByPause ?? false
            let symbol = urls.isEmpty ? promisedSymbolFor?(promised) : centerSymbolFor?(urls)
            ring.present(at: point, items: content.items, centerLabel: content.centerLabel, centerSymbolName: symbol,
                         files: Self.filesForCentre(urls), onDrop: onDrop)
        } else {
            overlay.present(at: point, items: content.items, centerLabel: content.centerLabel, onDrop: onDrop)
        }
    }

    /// Promised files, or the image bytes that stand in for one.
    private static func promisedTypes(of payload: DragPayload?) -> [String] {
        guard let payload else { return [] }
        return payload.hasFilePromises ? payload.promisedTypeIdentifiers : (payload.inlineImageType.map { [$0] } ?? [])
    }

    /// What the ring's centre may look into. It counts a folder's items, and listing a guarded folder (Desktop, Documents,
    /// a removable disk) makes macOS ask for permission in the middle of the drag. Those show the plain glyph instead.
    static func filesForCentre(_ urls: [URL]) -> [URL] {
        guard urls.count == 1, let url = urls.first, url.hasDirectoryPath || url.pathExtension.isEmpty,
              PrivacyFolders.isProtected(url) else { return urls }
        return []
    }

    private func monitorDismissed() {
        guard overlay.isPresented else { return }
        // A drop already landed; this is just the poll noticing the button came up. Let the chosen wedge finish.
        if let ring = overlay as? RingOverlayController, case .committing = ring.model.phase { return }
        let reason = (monitor as? DragTriggerMonitor)?.lastDismissReason
        let flags = (monitor as? DragTriggerMonitor)?.flagDiagnostics ?? ""
        Logger(subsystem: "com.snappycrew.frenzy", category: "app").notice("Ring dismissed: \(String(describing: reason), privacy: .public) \(flags, privacy: .public)")
        let awaiting = (overlay as? any DropPendingReporting)?.isAwaitingDrop ?? false
        // The mouse came up over the ring: performDragOperation may arrive a moment after the button state flips.
        if reason == .dragEnded && awaiting && dropGracePeriod > 0 {
            dismissGeneration += 1
            let gen = dismissGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + dropGracePeriod) {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, self.dismissGeneration == gen else { return }
                    self.dismissIfStillShown()
                }
            }
            return
        }
        overlay.dismiss(animated: true)
    }

    private func dismissIfStillShown() {
        if let controller = overlay as? RingOverlayController, case .committing = controller.model.phase { return }
        overlay.dismiss(animated: true)
    }
}
