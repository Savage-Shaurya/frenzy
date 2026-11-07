import Foundation

/// The last successful conversions, for the main window and the menu. Stored in UserDefaults on this Mac only.
@MainActor
final class RecentConversions {
    struct Entry: Codable, Equatable {
        let actionTitle: String
        /// At most `maxPaths` outputs are stored per entry.
        let outputs: [URL]
        let date: Date
        /// How many outputs the conversion produced (nil in entries saved before the cap existed).
        var total: Int?

        var count: Int { max(total ?? outputs.count, outputs.count) }

        /// Menu label: the first output's name, plus a count for batches.
        var label: String {
            guard let first = outputs.first else { return actionTitle }
            return count == 1 ? first.lastPathComponent : "\(first.lastPathComponent) + \(count - 1) more"
        }
    }

    static let limit = 20
    /// Paths stored per entry. A 500-file batch keeps 20 (enough to reveal) plus its count.
    static let maxPaths = 20
    private let defaults: UserDefaults
    private let key = "halo.recentConversions"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Newest first. Entries whose files were all moved or deleted are hidden.
    var entries: [Entry] {
        load().filter { entry in entry.outputs.contains { FileManager.default.fileExists(atPath: $0.path) } }
    }

    func record(actionTitle: String, outputs: [URL]) {
        guard !outputs.isEmpty else { return }
        var all = load()
        all.insert(Entry(actionTitle: actionTitle, outputs: Array(outputs.prefix(Self.maxPaths)), date: Date(),
                         total: outputs.count), at: 0)
        save(Array(all.prefix(Self.limit)))
    }

    func clear() { defaults.removeObject(forKey: key) }

    private func load() -> [Entry] {
        guard let data = defaults.data(forKey: key) else { return [] }
        let entries = (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
        // Older builds stored every path; trim on read.
        return entries.prefix(Self.limit).map { e in
            Entry(actionTitle: e.actionTitle, outputs: Array(e.outputs.prefix(Self.maxPaths)), date: e.date, total: e.count)
        }
    }

    private func save(_ entries: [Entry]) {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) }
    }
}
