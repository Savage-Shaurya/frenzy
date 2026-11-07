import Testing
import Foundation
import HaloCore
@testable import HaloUI

@MainActor
@Suite struct HaloSettingsTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "halo.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else { fatalError("suite") }
        return (defaults, name)
    }

    @Test func defaults() {
        let (store, name) = makeDefaults()
        defer { store.removePersistentDomain(forName: name) }
        let settings = HaloSettings(defaults: store)
        #expect(settings.trigger == .option)
        #expect(settings.maxRingItems == 10)
        #expect(settings.showToasts)
        #expect(!settings.playSounds)
        #expect(!settings.launchAtLogin)
        #expect(!settings.revealAfterConvert)
        #expect(settings.showPreviews, "previews are on until the user turns them off")
        #expect(!settings.hasCompletedOnboarding)
    }

    @Test func persistsAcrossInstances() {
        let (store, name) = makeDefaults()
        defer { store.removePersistentDomain(forName: name) }
        let first = HaloSettings(defaults: store)
        first.trigger = .control
        first.maxRingItems = 6
        first.showToasts = false
        first.playSounds = true
        first.launchAtLogin = true
        first.revealAfterConvert = true
        first.showPreviews = false
        first.hasCompletedOnboarding = true

        let second = HaloSettings(defaults: store)
        #expect(second.trigger == .control)
        #expect(second.maxRingItems == 6)
        #expect(!second.showToasts)
        #expect(second.playSounds)
        #expect(second.launchAtLogin)
        #expect(second.revealAfterConvert)
        #expect(!second.showPreviews)
        #expect(second.hasCompletedOnboarding)
    }

    @Test func ringSizeIsClamped() {
        let (store, name) = makeDefaults()
        defer { store.removePersistentDomain(forName: name) }
        let settings = HaloSettings(defaults: store)
        settings.maxRingItems = 40
        #expect(settings.maxRingItems == 12)
        settings.maxRingItems = 1
        #expect(settings.maxRingItems == 4)
        #expect(HaloSettings(defaults: store).maxRingItems == 4)
        store.set(99, forKey: HaloSettings.Key.maxRingItems)
        #expect(HaloSettings(defaults: store).maxRingItems == 12)
    }

    @Test func launchAtLoginCallbackFiresOnlyForUserChanges() {
        let (store, name) = makeDefaults()
        defer { store.removePersistentDomain(forName: name) }
        let settings = HaloSettings(defaults: store)
        var received: [Bool] = []
        settings.onLaunchAtLoginChange = { received.append($0) }
        settings.launchAtLogin = true
        settings.launchAtLogin = true
        settings.syncLaunchAtLogin(false)
        settings.launchAtLogin = true
        #expect(received == [true, true])
    }
}
