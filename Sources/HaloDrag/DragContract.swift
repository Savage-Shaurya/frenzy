import AppKit
import HaloCore
import HaloUI

// PUBLIC CONTRACT used by HaloApp. Keep signatures stable.

public extension TriggerKey {
    var flags: NSEvent.ModifierFlags {
        switch self {
        case .option: .option
        case .shift: .shift
        case .control: .control
        case .function: .function
        }
    }
}

/// Watches the system for "a file drag is in progress AND the trigger key is held".
@MainActor
public protocol DragTriggerMonitoring: AnyObject {
    var trigger: TriggerKey { get set }
    /// Fired when the ring should appear: the dragged file URLs and the cursor in screen coordinates.
    var onSummon: (([URL], NSPoint) -> Void)? { get set }
    /// Fired when the drag ends without a drop on the ring, or the key is released.
    var onDismiss: (() -> Void)? { get set }
    func start()
    func stop()
}

/// Shows `RingView` in a floating, non-activating panel centred on a screen point that accepts the drop.
@MainActor
public protocol RingOverlayPresenting: AnyObject {
    /// `onDrop` gets the chosen action and the dropped file URLs.
    func present(at screenPoint: NSPoint, items: [RingItem], centerLabel: String,
                 onDrop: @escaping (ActionID, [URL]) -> Void)
    func dismiss(animated: Bool)
    var isPresented: Bool { get }
}
