import Foundation
import Combine
import HaloCore

/// User preferences, persisted to `UserDefaults` on every change. Observe with `$property` publishers.
@MainActor
public final class HaloSettings: ObservableObject {
    public enum Key {
        public static let trigger = "halo.trigger"
        public static let opensOnPause = "halo.opensOnPause"
        public static let maxRingItems = "halo.maxRingItems"
        public static let showToasts = "halo.showToasts"
        public static let playSounds = "halo.playSounds"
        public static let launchAtLogin = "halo.launchAtLogin"
        public static let revealAfterConvert = "halo.revealAfterConvert"
        public static let showPreviews = "halo.showPreviews"
        public static let hasCompletedOnboarding = "halo.hasCompletedOnboarding"
    }

    public static let ringItemsRange: ClosedRange<Int> = 4...12

    private let defaults: UserDefaults
    private var suppressLaunchCallback = false

    /// Called when the user flips "Launch at login". The app applies it with `SMAppService`.
    public var onLaunchAtLoginChange: ((Bool) -> Void)?

    @Published public var trigger: TriggerKey {
        didSet { defaults.set(trigger.rawValue, forKey: Key.trigger) }
    }

    /// The ring opens by itself when a file drag holds still, no key needed. The trigger key still opens it at once.
    @Published public var opensOnPause: Bool {
        didSet { defaults.set(opensOnPause, forKey: Key.opensOnPause) }
    }

    /// How to open the ring, for "Start dragging a file and …". The pause is `DragTriggerMonitor.pauseDuration`, 0.4 s
    /// over Finder and the Desktop, so "half a second" is enough and says how long "a moment" is.
    public static let pauseGesture = "pause for half a second"
    public var gesture: String { opensOnPause ? Self.pauseGesture : "hold \(trigger.displayName)" }

    /// Most segments the ring shows, clamped to `ringItemsRange`.
    @Published public var maxRingItems: Int {
        didSet {
            let clamped = Self.clampRingItems(maxRingItems)
            if clamped != maxRingItems { maxRingItems = clamped; return }
            defaults.set(maxRingItems, forKey: Key.maxRingItems)
        }
    }

    @Published public var showToasts: Bool {
        didSet { defaults.set(showToasts, forKey: Key.showToasts) }
    }

    @Published public var playSounds: Bool {
        didSet { defaults.set(playSounds, forKey: Key.playSounds) }
    }

    /// Stored preference only; see `onLaunchAtLoginChange` and `syncLaunchAtLogin(_:)`.
    @Published public var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
            if !suppressLaunchCallback, launchAtLogin != oldValue { onLaunchAtLoginChange?(launchAtLogin) }
        }
    }

    @Published public var revealAfterConvert: Bool {
        didSet { defaults.set(revealAfterConvert, forKey: Key.revealAfterConvert) }
    }

    /// Quick Look thumbnails of the user's files in the window, the ring's centre and result cards. Off shows Finder
    /// icons only, so nothing inside a file appears on screen (screen sharing, a projector).
    @Published public var showPreviews: Bool {
        didSet { defaults.set(showPreviews, forKey: Key.showPreviews) }
    }

    @Published public var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        trigger = defaults.string(forKey: Key.trigger).flatMap(TriggerKey.init(rawValue:)) ?? .option
        opensOnPause = defaults.object(forKey: Key.opensOnPause) as? Bool ?? true
        maxRingItems = Self.clampRingItems(defaults.object(forKey: Key.maxRingItems) as? Int ?? 10)
        showToasts = defaults.object(forKey: Key.showToasts) as? Bool ?? true
        playSounds = defaults.object(forKey: Key.playSounds) as? Bool ?? false
        launchAtLogin = defaults.object(forKey: Key.launchAtLogin) as? Bool ?? false
        revealAfterConvert = defaults.object(forKey: Key.revealAfterConvert) as? Bool ?? false
        showPreviews = defaults.object(forKey: Key.showPreviews) as? Bool ?? true
        hasCompletedOnboarding = defaults.object(forKey: Key.hasCompletedOnboarding) as? Bool ?? false
    }

    /// Record the real login-item state (e.g. from `SMAppService.mainApp.status`) without firing the callback.
    public func syncLaunchAtLogin(_ enabled: Bool) {
        suppressLaunchCallback = true
        launchAtLogin = enabled
        suppressLaunchCallback = false
    }

    static func clampRingItems(_ value: Int) -> Int {
        min(max(value, ringItemsRange.lowerBound), ringItemsRange.upperBound)
    }
}
