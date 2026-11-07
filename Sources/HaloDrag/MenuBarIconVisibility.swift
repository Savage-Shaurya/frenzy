import AppKit

/// Can the user actually see Halo's menu-bar icon? `NSStatusItem.isVisible` only says the item exists: macOS may
/// still lay it out under the camera notch (a crowded menu bar on a MacBook), off every screen, or not at all.
///
/// Pure maths so it can be tested: the app passes the status button's window frame (global AppKit coordinates)
/// and each screen's frame plus its notch side areas (`NSScreen.auxiliaryTopLeftArea` / `...TopRightArea`, in
/// screen-local coordinates as AppKit reports them).
public enum MenuBarIconVisibility: Equatable, Sendable {
    case visible
    /// No real frame yet (height or width 0). Measure again later.
    case notLaidOut
    /// The frame isn't on any screen.
    case offScreen
    /// The icon sits in the gap between the notch's left and right areas, where nothing is drawn.
    case behindNotch
    /// On screen but the window server reports it as not visible (hidden in System Settings, or covered).
    case occluded

    public var isHidden: Bool { self == .offScreen || self == .behindNotch || self == .occluded }

    public struct Screen: Sendable {
        public let frame: CGRect
        public let notchLeft: CGRect?
        public let notchRight: CGRect?

        public init(frame: CGRect, notchLeft: CGRect? = nil, notchRight: CGRect? = nil) {
            self.frame = frame
            self.notchLeft = notchLeft
            self.notchRight = notchRight
        }

        /// The notch itself in global coordinates: between the two side areas, across the menu-bar strip.
        var notchGap: CGRect? {
            guard let l = notchLeft, let r = notchRight, r.minX > l.maxX else { return nil }
            return CGRect(x: frame.minX + l.maxX, y: frame.minY + min(l.minY, r.minY),
                          width: r.minX - l.maxX, height: max(l.height, r.height))
        }
    }

    /// `occlusionVisible` is the window's `occlusionState.contains(.visible)`. Pass `menuBarShown: false` when the
    /// menu bar is auto-hidden (full screen), since every status item is then legitimately not visible.
    public static func classify(iconFrame: CGRect, screens: [Screen], occlusionVisible: Bool,
                                menuBarShown: Bool = true) -> MenuBarIconVisibility {
        guard iconFrame.width >= 1, iconFrame.height >= 1 else { return .notLaidOut }
        let center = CGPoint(x: iconFrame.midX, y: iconFrame.midY)
        guard let screen = screens.first(where: { $0.frame.contains(center) }) else { return .offScreen }
        if let gap = screen.notchGap, gap.contains(center) { return .behindNotch }
        if !occlusionVisible && menuBarShown { return .occluded }
        return .visible
    }
}
