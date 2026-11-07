// fz-tool: fixtures and verifiers for scripts/e2e-actions.sh. Apple frameworks only, no Halo code, so it checks
// Frenzy's outputs with an independent decoder.
//
// SAFETY: nothing here encodes video or HEIC/AVIF. The only exception is `movie`, which refuses to run unless
// FRENZY_VIDEO_TESTS=1 (the founder's Mac kernel-panicked from the hardware video encoder on 7 Nov 2026).
//
// Fixtures
//   fz-tool png OUT W H TEXT            opaque RGB PNG with big black TEXT on white (OCR-readable)
//   fz-tool jpeg-gps OUT TEXT           JPEG with EXIF and a GPS position
//   fz-tool gif-anim OUT TEXT           3-frame looping GIF
//   fz-tool pdf-text OUT PAGES          PDF with a real text layer, "Frenzy test page N" on each page
//   fz-tool pdf-scan OUT IMAGE          one image-only page (no text layer: a "scan")
//   fz-tool pdf-encrypt IN OUT PASS     password-protected copy of IN
//   fz-tool pdf-js OUT                  PDF with an OpenAction JavaScript and a JavaScript name tree
//   fz-tool wav OUT SECONDS             16-bit PCM 44.1 kHz stereo sine
//   fz-tool zip-entry OUT NAME TEXT     stored ZIP with one entry named NAME (for "../" path tests)
//   fz-tool movie OUT                   ONLY with FRENZY_VIDEO_TESTS=1: 1 s 320x240 H.264 movie
// Verifiers (exit 0 = OK, prints one line)
//   fz-tool image PATH                  decodes with ImageIO: "OK uti=… w=… h=… frames=… alpha=…"
//   fz-tool meta PATH                   "gps=0|1 exif=N" (EXIF keys other than orientation/colour/size)
//   fz-tool pdf PATH                    "OK pages=N locked=0 rotation=R chars=C" (opens with PDFKit, renders page 1)
//   fz-tool pdf-text-dump PATH          prints the text layer
//   fz-tool audio PATH                  decodes every frame: "OK frames=N rate=R channels=C seconds=S"
//   fz-tool movie-check PATH            "OK tracks=N seconds=S" (reads metadata only)
//   fz-tool name-check INPUT OUTPUT [INDEX]   output name rules (255 bytes, no "/", not .halo-, keeps the stem, " INDEX")

import AppKit
import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    print("FAIL \(message)")
    exit(1)
}

func need(_ n: Int, _ usage: String) {
    if args.count < n + 1 { fail("usage: fz-tool \(usage)") }
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: - Drawing

func drawText(_ text: String, in ctx: CGContext, x: CGFloat, y: CGFloat, size: CGFloat) {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    ctx.textMatrix = .identity
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
}

/// Opaque (no alpha) so Frenzy's Compress picks JPEG, never HEIC.
func makeImage(width: Int, height: Int, text: String, shade: CGFloat = 1) -> CGImage {
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fail("CGContext") }
    ctx.setFillColor(CGColor(red: shade, green: shade, blue: shade, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(red: 0.85, green: 0.2, blue: 0.2, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: max(4, height / 12)))
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    let size = CGFloat(min(height / 3, width / max(1, text.count) * 2))
    drawText(text, in: ctx, x: CGFloat(width) * 0.05, y: CGFloat(height) * 0.4, size: max(8, size))
    guard let image = ctx.makeImage() else { fail("makeImage") }
    return image
}

func write(_ image: CGImage, to path: String, type: UTType, properties: [CFString: Any] = [:]) {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
        fail("no ImageIO writer for \(type.identifier)")
    }
    CGImageDestinationAddImage(dest, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fail("write \(path)") }
}

// MARK: - PDF

func pdfWithText(path: String, pages: Int) {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let ctx = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box,
                              [kCGPDFContextTitle: "Frenzy test"] as CFDictionary) else { fail("PDF context") }
    for p in 1...max(1, pages) {
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        drawText("Frenzy test page \(p)", in: ctx, x: 72, y: 700, size: 28)
        drawText("The quick brown fox jumps over the lazy dog.", in: ctx, x: 72, y: 650, size: 14)
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

func pdfScan(path: String, imagePath: String) {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: imagePath) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("read \(imagePath)") }
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let ctx = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil) else { fail("PDF context") }
    ctx.beginPDFPage(nil)
    let w = 540.0, h = w * Double(image.height) / Double(image.width)
    ctx.draw(image, in: CGRect(x: 36, y: 792 - 72 - h, width: w, height: h))
    ctx.endPDFPage()
    ctx.closePDF()
}

func pdfJS(path: String) {
    let content = "BT /F1 24 Tf 72 700 Td (Frenzy javascript page) Tj ET"
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R /OpenAction 4 0 R /Names << /JavaScript << /Names [(frenzy) 4 0 R] >> >> >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << /Font << /F1 6 0 R >> >> >>",
        "<< /S /JavaScript /JS (app.alert\\('Frenzy test'\\);) >>",
        "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    var out = "%PDF-1.4\n%\u{00E2}\u{00E3}\n"
    var data = Data(out.utf8)
    var offsets: [Int] = []
    for (i, body) in objects.enumerated() {
        offsets.append(data.count)
        data.append(Data("\(i + 1) 0 obj\n\(body)\nendobj\n".utf8))
    }
    let xref = data.count
    out = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
    for o in offsets { out += String(format: "%010ld 00000 n \n", o) }
    out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
    data.append(Data(out.utf8))
    do { try data.write(to: URL(fileURLWithPath: path)) } catch { fail("write \(path): \(error)") }
}

// MARK: - Audio / ZIP bytes

func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }

func wav(path: String, seconds: Double) {
    let rate = 44_100, channels = 2
    let frames = Int(Double(rate) * seconds)
    var pcm = [UInt8](); pcm.reserveCapacity(frames * channels * 2)
    for i in 0..<frames {
        let t = Double(i) / Double(rate)
        let s = Int(sin(2 * Double.pi * 440 * t) * 12_000 * (t < 0.05 ? t / 0.05 : 1))
        for _ in 0..<channels { pcm += le16(s & 0xFFFF) }
    }
    var bytes = [UInt8]("RIFF".utf8) + le32(36 + pcm.count) + [UInt8]("WAVEfmt ".utf8)
    bytes += le32(16) + le16(1) + le16(channels) + le32(rate) + le32(rate * channels * 2) + le16(channels * 2) + le16(16)
    bytes += [UInt8]("data".utf8) + le32(pcm.count) + pcm
    do { try Data(bytes).write(to: URL(fileURLWithPath: path)) } catch { fail("write \(path)") }
}

let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
    var c = UInt32(n)
    for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    return c
}
func crc32(_ data: [UInt8]) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
    return c ^ 0xFFFF_FFFF
}

func zipEntry(path: String, name: String, text: String) {
    let nameBytes = [UInt8](name.utf8), body = [UInt8](text.utf8)
    let crc = Int(crc32(body))
    var local = [UInt8]([0x50, 0x4B, 0x03, 0x04]) + le16(20) + le16(0x0800) + le16(0) + le16(0) + le16(0x21)
    local += le32(crc) + le32(body.count) + le32(body.count) + le16(nameBytes.count) + le16(0) + nameBytes + body
    var central = [UInt8]([0x50, 0x4B, 0x01, 0x02]) + le16(20) + le16(20) + le16(0x0800) + le16(0) + le16(0) + le16(0x21)
    central += le32(crc) + le32(body.count) + le32(body.count) + le16(nameBytes.count) + le16(0) + le16(0) + le16(0) + le16(0)
    central += le32(0o100644 << 16) + le32(0) + nameBytes
    let end = [UInt8]([0x50, 0x4B, 0x05, 0x06]) + le16(0) + le16(0) + le16(1) + le16(1) + le32(central.count) + le32(local.count) + le16(0)
    do { try Data(local + central + end).write(to: URL(fileURLWithPath: path)) } catch { fail("write \(path)") }
}

// MARK: - Verifiers

func imageInfo(_ path: String) {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          let uti = CGImageSourceGetType(src) else { fail("ImageIO can't open \(path)") }
    let count = CGImageSourceGetCount(src)
    guard count > 0, let image = CGImageSourceCreateImageAtIndex(src, 0, nil), image.width > 0, image.height > 0 else {
        fail("no decodable image in \(path)")
    }
    // Force a real decode of the pixels.
    guard let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("ctx") }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let alpha: Bool
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast: alpha = false
    default: alpha = true
    }
    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] ?? [:]
    let orientation = (props[kCGImagePropertyOrientation as String] as? Int) ?? 1
    let (w, h) = orientation >= 5 ? (image.height, image.width) : (image.width, image.height)
    print("OK uti=\(uti) w=\(w) h=\(h) frames=\(count) alpha=\(alpha ? 1 : 0)")
}

func meta(_ path: String) {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { fail("ImageIO can't open \(path)") }
    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] ?? [:]
    let gps = (props[kCGImagePropertyGPSDictionary as String] as? [String: Any]).map { !$0.isEmpty } ?? false
    let ignored: Set<String> = ["ColorSpace", "PixelXDimension", "PixelYDimension", "Orientation"]
    let exif = (props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]).keys.filter { !ignored.contains($0) }.count
    print("gps=\(gps ? 1 : 0) exif=\(exif)")
}

func pdfInfo(_ path: String) {
    guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { fail("PDFKit can't open \(path)") }
    if doc.isLocked { print("OK pages=\(doc.pageCount) locked=1 rotation=0 chars=0"); exit(0) }
    guard doc.pageCount > 0, let page = doc.page(at: 0) else { fail("no pages in \(path)") }
    let thumb = page.thumbnail(of: CGSize(width: 64, height: 64), for: .mediaBox)
    guard thumb.size.width > 0 else { fail("page 1 does not render") }
    var chars = 0
    for i in 0..<min(doc.pageCount, 50) { chars += doc.page(at: i)?.string?.count ?? 0 }
    print("OK pages=\(doc.pageCount) locked=0 rotation=\(page.rotation) chars=\(chars)")
}

func audioInfo(_ path: String) {
    let file: AVAudioFile
    do { file = try AVAudioFile(forReading: URL(fileURLWithPath: path)) } catch { fail("AVAudioFile can't open \(path): \(error.localizedDescription)") }
    let format = file.processingFormat
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else { fail("buffer") }
    var frames: Int64 = 0
    while true {
        do { try file.read(into: buffer) } catch { break }
        if buffer.frameLength == 0 { break }
        frames += Int64(buffer.frameLength)
    }
    guard frames > 0 else { fail("no audio frames decoded from \(path)") }
    let seconds = Double(frames) / format.sampleRate
    print(String(format: "OK frames=%lld rate=%.0f channels=%d seconds=%.3f", frames, format.sampleRate, Int(format.channelCount), seconds))
}

func nameCheck(input: String, output: String, index: Int?) {
    if output.utf8.count > 255 { fail("name is \(output.utf8.count) UTF-8 bytes (max 255)") }
    if output.contains("/") { fail("name contains /") }
    if output.hasPrefix(".halo-") { fail("name looks like Frenzy's scratch (.halo-)") }
    if output.isEmpty { fail("empty name") }
    // The stem: up to the first dot, ignoring a leading dot.
    var stem = input
    if let dot = stem.dropFirst().firstIndex(of: ".") { stem = String(stem[..<dot]) }
    let head = String(stem.prefix(6))
    let allowed = ["Archive", "Frenzy output"]
    if !output.hasPrefix(head) && !allowed.contains(where: { output.hasPrefix($0) }) {
        fail("'\(output)' does not start with '\(head)' from '\(input)'")
    }
    if let index {
        let base = (output as NSString).deletingPathExtension
        var core = base
        if core.hasSuffix(".tar") { core = (core as NSString).deletingPathExtension }
        if !(core.hasSuffix(" \(index)") || output.hasSuffix(" \(index)")) { fail("'\(output)' is not numbered ' \(index)'") }
    }
    print("OK \(output.utf8.count) bytes")
}

// MARK: - Video (gated)

func movie(path: String) {
    guard ProcessInfo.processInfo.environment["FRENZY_VIDEO_TESTS"] == "1" else {
        fail("refused: video encoding is off on this Mac (set FRENZY_VIDEO_TESTS=1 for one deliberate run)")
    }
    let url = URL(fileURLWithPath: path)
    do {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 240])
        writer.add(input)
        guard writer.startWriting() else { fail("startWriting: \(writer.error?.localizedDescription ?? "?")") }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<30 {
            while !input.isReadyForMoreMediaData { usleep(5_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { fail("pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(i * 8 % 255), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { fail("writer: \(writer.error?.localizedDescription ?? "?")") }
        print("OK \(path)")
    } catch { fail("movie: \(error.localizedDescription)") }
}

func movieCheck(_ path: String) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let done = DispatchSemaphore(value: 0)
    final class Box: @unchecked Sendable { var tracks = 0; var seconds = 0.0; var error: String? }
    let box = Box()
    Task {
        do {
            box.tracks = try await asset.load(.tracks).count
            box.seconds = try await asset.load(.duration).seconds
        } catch { box.error = error.localizedDescription }
        done.signal()
    }
    done.wait()
    if let e = box.error { fail("AVFoundation can't read \(path): \(e)") }
    guard box.tracks > 0, box.seconds > 0 else { fail("no tracks or zero duration") }
    print(String(format: "OK tracks=%d seconds=%.3f", box.tracks, box.seconds))
}

// MARK: - Dispatch

guard let command = args.first else { fail("usage: see the header of tool.swift") }
switch command {
case "png":
    need(4, "png OUT W H TEXT")
    write(makeImage(width: Int(args[2]) ?? 800, height: Int(args[3]) ?? 300, text: args[4]), to: args[1], type: .png)
case "jpeg-gps":
    need(2, "jpeg-gps OUT TEXT")
    let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 28.6139, kCGImagePropertyGPSLatitudeRef: "N",
                                kCGImagePropertyGPSLongitude: 77.2090, kCGImagePropertyGPSLongitudeRef: "E"]
    let exif: [CFString: Any] = [kCGImagePropertyExifUserComment: "Frenzy test", kCGImagePropertyExifLensModel: "Test lens"]
    write(makeImage(width: 1200, height: 400, text: args[2]), to: args[1], type: .jpeg,
          properties: [kCGImagePropertyGPSDictionary: gps, kCGImagePropertyExifDictionary: exif,
                       kCGImageDestinationLossyCompressionQuality: 0.9])
case "gif-anim":
    need(2, "gif-anim OUT TEXT")
    let url = URL(fileURLWithPath: args[1])
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 3, nil) else { fail("gif writer") }
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for i in 0..<3 {
        let frame = makeImage(width: 600, height: 200, text: args[2], shade: 1 - CGFloat(i) * 0.05)
        CGImageDestinationAddImage(dest, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
    }
    guard CGImageDestinationFinalize(dest) else { fail("write gif") }
case "pdf-text":
    need(2, "pdf-text OUT PAGES")
    pdfWithText(path: args[1], pages: Int(args[2]) ?? 1)
case "pdf-scan":
    need(2, "pdf-scan OUT IMAGE")
    pdfScan(path: args[1], imagePath: args[2])
case "pdf-encrypt":
    need(3, "pdf-encrypt IN OUT PASS")
    guard let doc = PDFDocument(url: URL(fileURLWithPath: args[1])) else { fail("open \(args[1])") }
    let ok = doc.write(to: URL(fileURLWithPath: args[2]), withOptions: [.userPasswordOption: args[3], .ownerPasswordOption: args[3] + "-owner"])
    if !ok { fail("encrypt") }
case "pdf-js":
    need(1, "pdf-js OUT")
    pdfJS(path: args[1])
case "wav":
    need(2, "wav OUT SECONDS")
    wav(path: args[1], seconds: Double(args[2]) ?? 2)
case "zip-entry":
    need(3, "zip-entry OUT NAME TEXT")
    zipEntry(path: args[1], name: args[2], text: args[3])
case "movie":
    need(1, "movie OUT")
    movie(path: args[1])
case "image":
    need(1, "image PATH"); imageInfo(args[1])
case "meta":
    need(1, "meta PATH"); meta(args[1])
case "pdf":
    need(1, "pdf PATH"); pdfInfo(args[1])
case "pdf-text-dump":
    need(1, "pdf-text-dump PATH")
    guard let doc = PDFDocument(url: URL(fileURLWithPath: args[1])) else { fail("PDFKit can't open \(args[1])") }
    print(doc.string ?? "")
case "audio":
    need(1, "audio PATH"); audioInfo(args[1])
case "movie-check":
    need(1, "movie-check PATH"); movieCheck(args[1])
case "name-check":
    need(2, "name-check INPUT OUTPUT [INDEX]")
    nameCheck(input: args[1], output: args[2], index: args.count > 3 ? Int(args[3]) : nil)
default:
    fail("unknown command \(command)")
}
