import SwiftUI
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
import HaloCore

// PUBLIC CONTRACT used by HaloDrag and HaloApp. Keep these signatures stable; the visuals behind them are free.

/// What one ring segment shows.
public struct RingItem: Identifiable, Sendable, Equatable {
    public let id: ActionID
    public let title: String
    public let subtitle: String?
    public let symbolName: String
    public let category: ActionCategory

    public init(id: ActionID, title: String, subtitle: String?, symbolName: String, category: ActionCategory) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.symbolName = symbolName; self.category = category
    }

    public init(_ action: ConversionAction) {
        self.init(id: action.id, title: action.title, subtitle: action.subtitle, symbolName: action.symbolName, category: action.category)
    }

    /// The id of the "More" wedge. Not a conversion: a drop on it opens the Halo window with every choice.
    public static let moreID: ActionID = "halo.more"

    /// True for the "More" wedge.
    public var isMore: Bool { id == Self.moreID }

    /// What the ring shows for `items` (already ranked) when it holds at most `limit` wedges: all of them when they
    /// fit, else the first `limit - 1` and a "More" wedge, so nothing that fits is ever out of reach.
    public static func fitted(_ items: [RingItem], limit: Int) -> [RingItem] {
        let limit = max(2, limit)
        guard items.count > limit else { return items }
        let hidden = items.count - (limit - 1)
        // The category is unused for this wedge: the view draws it neutral.
        let more = RingItem(id: moreID, title: "More", subtitle: "\(hidden) more in Frenzy",
                            symbolName: "ellipsis.circle", category: items[limit - 1].category)
        return Array(items.prefix(limit - 1)) + [more]
    }
}

/// Live state of the ring. HaloDrag drives it; RingView renders it.
@MainActor
public final class RingModel: ObservableObject {
    public enum Phase: Sendable, Equatable { case hidden, presenting, shown, committing(ActionID), dismissing }

    @Published public var items: [RingItem] = []
    /// Index into `items` under the cursor, or nil when in the centre / outside.
    @Published public var hoveredIndex: Int?
    @Published public var phase: Phase = .hidden
    /// Short text in the ring's centre, e.g. "3 files" or "photo.heic".
    @Published public var centerLabel: String = ""
    /// SF Symbol for the centre disc. Nil picks "doc" or "doc.on.doc" from `centerLabel`. (Added by HaloUI.)
    @Published public var centerSymbolName: String?
    /// The one item being dragged; the centre shows its Finder icon, then its Quick Look thumbnail. Nil for several.
    @Published public var centerFile: URL?
    /// Finder's icons for the first three dragged items: one is shown at once while the thumbnail is drawn, several
    /// fan out like a little stack.
    @Published public var centerIcons: [NSImage] = []
    /// Quick Look's thumbnail of `centerFile` once the system has drawn it (out of process).
    @Published public var centerThumbnail: CGImage?
    /// "2.4 MB" for one file, "12 items" for one folder; nil for packages and several items.
    @Published public var centerDetail: String?

    /// False when the user turned off file previews: the centre keeps Finder's icon and never asks Quick Look.
    public var showsThumbnails = true {
        didSet { if !showsThumbnails { centerThumbnail = nil } }
    }

    private var previewTask: Task<Void, Never>?

    public init() {}

    /// Points the centre at what is being dragged: icons for its types now (no disk access, so a slow volume can't
    /// stall the drag); for one item, its Finder icon and size or item count, then its thumbnail, all worked out off
    /// the main thread. Reads file-system metadata only; Quick Look draws the thumbnail in its own process.
    public func showFiles(_ urls: [URL]) {
        clearFiles()
        guard !urls.isEmpty else { return }
        centerIcons = urls.prefix(3).map { NSWorkspace.shared.icon(for: Self.iconType(for: $0)) }
        guard urls.count == 1, let url = urls.first else { return }
        centerFile = url
        previewTask = Task { [weak self] in
            let lookup = Task.detached(priority: .userInitiated) {
                Facts(detail: RingModel.detailText(for: url), icon: NSWorkspace.shared.icon(forFile: url.path))
            }
            // The lookup is detached, so pass a cancellation on to it (a huge folder stops counting).
            let facts = await withTaskCancellationHandler { await lookup.value } onCancel: { lookup.cancel() }
            guard let self, !Task.isCancelled, self.centerFile == url else { return }
            self.centerDetail = facts.detail
            self.centerIcons = [facts.icon]
            guard self.showsThumbnails else { return }
            let image = await RingModel.thumbnail(for: url)
            guard !Task.isCancelled, self.centerFile == url, self.showsThumbnails else { return }
            self.centerThumbnail = image
        }
    }

    /// What the off-main lookup hands back. NSImage isn't Sendable; this one is made there and only read after.
    private struct Facts: @unchecked Sendable {
        let detail: String?
        let icon: NSImage
    }

    /// The type to draw an icon for, from the name alone: a folder for a directory URL, else the extension's type.
    nonisolated static func iconType(for url: URL) -> UTType {
        if url.hasDirectoryPath { return .folder }
        return UTType(filenameExtension: url.pathExtension) ?? .data
    }

    /// Empties the centre and stops any thumbnail still being drawn (the ring has gone).
    public func clearFiles() {
        previewTask?.cancel()
        previewTask = nil
        centerFile = nil
        centerIcons = []
        centerThumbnail = nil
        centerDetail = nil
    }

    /// Folders with more visible items than this say "1,000+ items" (counting stops there).
    nonisolated static let itemCountCap = 1_000

    /// "2.4 MB" for a plain file, "12 items" for a folder (its visible top level only, up to `itemCountCap`); nil
    /// for packages, anything unreadable, or when the task is cancelled.
    nonisolated static func detailText(for url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey, .isPackageKey])
        else { return nil }
        if values.isRegularFile == true, let bytes = values.fileSize {
            return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
        guard values.isDirectory == true, values.isPackage != true,
              let entries = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants,
                                                                     .skipsPackageDescendants])
        else { return nil }
        var count = 0
        while entries.nextObject() != nil {
            count += 1
            if count > itemCountCap {
                return "\(itemCountCap.formatted())+ items"
            }
            if count % 256 == 0, Task.isCancelled { return nil }
        }
        return count == 1 ? "1 item" : "\(count) items"
    }

    /// A Quick Look thumbnail sized for the centre; the request is cancelled with the task.
    nonisolated static func thumbnail(for url: URL) async -> CGImage? {
        let side = RingCenterMetrics.thumbnail
        // The request is immutable once made, and QLThumbnailGenerator's cancel may be called from any thread.
        guard !Task.isCancelled else { return nil }
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
        nonisolated(unsafe) let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                                       scale: scale, representationTypes: .thumbnail)
        return await withTaskCancellationHandler {
            try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
        } onCancel: {
            QLThumbnailGenerator.shared.cancel(request)
        }
    }
}

/// Fixed sizes shared by the overlay window and the view.
public enum RingMetrics {
    /// Side of the square overlay window, in points.
    public static let canvasSize: CGFloat = 440
    public static let innerRadius: CGFloat = 62
    public static let outerRadius: CGFloat = 170
}

/// Pure geometry so hit-testing in HaloDrag and drawing in RingView always agree.
public enum RingGeometry {
    /// Where segment 0 begins (radians, 0 = 12 o'clock, clockwise). Two choices start at 6 o'clock, so the first
    /// sits on the left and the pair reads left to right like the window's tiles; every other count starts at 12.
    public static func startOffset(count: Int) -> Double {
        count == 2 ? .pi : 0
    }

    /// Angle (radians, 0 = 12 o'clock, clockwise) at the centre of segment `index` of `count`.
    public static func centerAngle(index: Int, count: Int) -> Double {
        guard count > 0 else { return 0 }
        return startOffset(count: count) + (Double(index) + 0.5) * (2 * .pi / Double(count))
    }

    /// Segment under `point` (view coordinates, origin top-left, y down), relative to `center`.
    /// Nil inside `innerRadius` or beyond `outerRadius + slop`.
    public static func index(at point: CGPoint, center: CGPoint, count: Int,
                             innerRadius: CGFloat = RingMetrics.innerRadius,
                             outerRadius: CGFloat = RingMetrics.outerRadius,
                             slop: CGFloat = 60) -> Int? {
        guard count > 0 else { return nil }
        let dx = point.x - center.x, dy = point.y - center.y
        let r = (dx * dx + dy * dy).squareRoot()
        guard r >= innerRadius, r <= outerRadius + slop else { return nil }
        var angle = atan2(Double(dx), Double(-dy)) - startOffset(count: count) // 0 at segment 0's start, clockwise
        while angle < 0 { angle += 2 * .pi }
        return min(count - 1, Int(angle / (2 * .pi / Double(count))))
    }
}

// `RingView(model:)` lives in RingView.swift.

/// Small result notices near the cursor or top-right.
@MainActor
public protocol ToastPresenting: AnyObject {
    func showProgress(_ title: String, fraction: Double)
    func showSuccess(_ title: String, outputs: [URL])
    func showFailure(_ title: String, message: String)
}
