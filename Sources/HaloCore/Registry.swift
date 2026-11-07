import Foundation
import UniformTypeIdentifiers

/// Remembers how often each action is used, so the ring puts favourites first.
public protocol UsageStore: Sendable {
    func count(for id: ActionID) -> Int
    func recordUse(of id: ActionID)
}

/// `UserDefaults`-backed usage counts.
public final class DefaultsUsageStore: UsageStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = "halo.usage") {
        self.defaults = defaults
        self.key = key
    }

    public func count(for id: ActionID) -> Int {
        lock.withLock { (defaults.dictionary(forKey: key) as? [String: Int])?[id.rawValue] ?? 0 }
    }

    public func recordUse(of id: ActionID) {
        lock.withLock {
            var all = (defaults.dictionary(forKey: key) as? [String: Int]) ?? [:]
            all[id.rawValue, default: 0] += 1
            defaults.set(all, forKey: key)
        }
    }
}

/// In-memory store for tests and previews.
public final class MemoryUsageStore: UsageStore, @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [ActionID: Int] = [:]
    public init() {}
    public func count(for id: ActionID) -> Int { lock.withLock { counts[id] ?? 0 } }
    public func recordUse(of id: ActionID) { lock.withLock { counts[id, default: 0] += 1 } }
}

/// All known actions, and which ones fit a given drop.
public struct ActionRegistry: Sendable {
    public let all: [ConversionAction]
    public let usage: any UsageStore

    public init(actions: [ConversionAction], usage: any UsageStore) {
        var seen = Set<ActionID>()
        precondition(actions.allSatisfy { seen.insert($0.id).inserted }, "Duplicate ActionID in registry")
        self.all = actions
        self.usage = usage
    }

    public func action(_ id: ActionID) -> ConversionAction? { all.first { $0.id == id } }

    /// Actions that accept `inputs`, most used first, then by `defaultRank`, then title. At most `limit`.
    public func actions(for inputs: [InputFile], limit: Int = 12) -> [ConversionAction] {
        let types = Set(inputs.map(\.type))
        let matches = all.filter { $0.accepts(types: types, count: inputs.count) }
        let ranked = matches.sorted { a, b in
            let ua = usage.count(for: a.id), ub = usage.count(for: b.id)
            if ua != ub { return ua > ub }
            if a.defaultRank != b.defaultRank { return a.defaultRank < b.defaultRank }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        return Array(ranked.prefix(max(0, limit)))
    }
}
