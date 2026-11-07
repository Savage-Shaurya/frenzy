import Testing
import SwiftUI
import AppKit
import HaloCore
@testable import HaloUI

@MainActor
@Suite struct RingRenderTests {
    static let sample: [RingItem] = [
        RingItem(id: "image.to-jpg", title: "JPG", subtitle: "Smaller file", symbolName: "photo", category: .image),
        RingItem(id: "image.to-png", title: "PNG", subtitle: "Lossless", symbolName: "photo.on.rectangle", category: .image),
        RingItem(id: "pdf.from-images", title: "PDF", subtitle: "One page each", symbolName: "doc.richtext", category: .pdf),
        RingItem(id: "text.ocr", title: "Text", subtitle: "Copy the words", symbolName: "text.viewfinder", category: .text),
        RingItem(id: "image.resize-half", title: "Resize", subtitle: "Half size", symbolName: "arrow.down.right.and.arrow.up.left", category: .image),
        RingItem(id: "image.to-heic", title: "HEIC", subtitle: "Best quality", symbolName: "photo.stack", category: .image),
        RingItem(id: "video.to-mp4", title: "MP4", subtitle: "Plays anywhere", symbolName: "film", category: .video),
        RingItem(id: "audio.to-m4a", title: "M4A", subtitle: "AAC audio", symbolName: "waveform", category: .audio),
        RingItem(id: "pdf.compress", title: "Compress", subtitle: "Smaller PDF", symbolName: "arrow.down.doc", category: .pdf),
        RingItem(id: "document.to-pdf", title: "Document", subtitle: "Rich text", symbolName: "doc.text", category: .document),
        RingItem(id: "image.to-tiff", title: "TIFF", subtitle: nil, symbolName: "photo.artframe", category: .image),
        RingItem(id: "image.strip-metadata", title: "Strip info", subtitle: "Remove EXIF", symbolName: "eye.slash", category: .image),
    ]

    /// Ring previews go with the other design-review renders (temp unless HALO_SHOTS is set), never into docs/.
    static var docsDirectory: URL { HomeRenderTests.shotsDirectory }

    private func render(count: Int, hovered: Int?, label: String, scheme: ColorScheme = .light) -> NSImage? {
        let model = RingModel()
        model.items = Array(Self.sample.prefix(count))
        model.centerLabel = label
        model.phase = .shown
        model.hoveredIndex = hovered
        let side = RingMetrics.canvasSize
        let content = ZStack {
            // Stand-in wallpaper so the glass reads the way it will over a real desktop.
            LinearGradient(colors: [Color(red: 0.36, green: 0.52, blue: 0.78), Color(red: 0.86, green: 0.62, blue: 0.56)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RingView(model: model)
        }
        .frame(width: side, height: side)
        .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return renderer.nsImage
    }

    private func savePNG(_ image: NSImage, name: String) throws {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            Issue.record("could not encode \(name)"); return
        }
        try FileManager.default.createDirectory(at: Self.docsDirectory, withIntermediateDirectories: true)
        try png.write(to: Self.docsDirectory.appendingPathComponent(name))
    }

    @Test func sixItemRingRenders() throws {
        let image = try #require(render(count: 6, hovered: 1, label: "photo.heic"))
        #expect(image.size.width >= RingMetrics.canvasSize)
        #expect(image.size.height >= RingMetrics.canvasSize)
        try savePNG(image, name: "ring-preview.png")
    }

    @Test func smallAndLargeRingsRender() throws {
        let two = try #require(render(count: 2, hovered: 0, label: "report.pdf"))
        try savePNG(two, name: "ring-preview-2.png")
        let twelve = try #require(render(count: 12, hovered: 8, label: "3 files"))
        try savePNG(twelve, name: "ring-preview-12.png")
        let dark = try #require(render(count: 6, hovered: 3, label: "photo.heic", scheme: .dark))
        try savePNG(dark, name: "ring-preview-dark.png")
    }

    @Test(arguments: [0, 1, 3, 7, 12])
    func everyCountRendersWithoutCrashing(count: Int) {
        #expect(render(count: count, hovered: nil, label: "file.txt") != nil)
    }

    @Test func phasesCanBeDrivenWithoutCrashing() {
        let model = RingModel()
        model.items = Array(Self.sample.prefix(5))
        let view = RingView(model: model)
        for phase: RingModel.Phase in [.presenting, .shown, .committing("image.to-jpg"), .dismissing, .hidden] {
            model.phase = phase
            #expect(ImageRenderer(content: view).nsImage != nil)
        }
    }
}
