#!/usr/bin/env swift
// Draws Frenzy's app icon with Core Graphics and writes every macOS iconset size plus Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift            (run from apps/halo)
//
// Each size is drawn from vectors at its own pixel size (no downscaling), so small sizes stay sharp.
// Design: the product itself. A squircle in the brand violet holds a glassy disc (your file) with six small glass
// bubbles around it (the choices), in the same places as the live ring: none straight up, one each at 3 and 9 o'clock.
// At 32 px and below it drops the fine detail and grows the bubbles, so it still reads at 16 px.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Frenzy-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

// sRGB, so the violet is exactly FrenzyPalette.accent (Sources/HaloUI/RingBubble.swift): light 0x6340DB, dark 0x8F6BFF.
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                            CGFloat(hex & 0xFF) / 255, alpha])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

/// Apple-style continuous-corner rounded rect ("squircle"), approximated with a superellipse (n = 5).
func squircle(_ rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let n: CGFloat = 5
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = pow(abs(c), 2 / n) * a * (c < 0 ? -1 : 1)
        let y = pow(abs(s), 2 / n) * b * (s < 0 ? -1 : 1)
        let p = CGPoint(x: rect.midX + x, y: rect.midY + y)
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
}

func circle(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
    CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
}

/// Sizes on the 1024-unit canvas, so one drawing serves every pixel size.
struct Art {
    /// The tile's margin. Apple's grid leaves 100 for the shadow; tiny icons have no room for that and need the pixels.
    let margin: CGFloat
    let discRadius: CGFloat
    let bubbleRadius: CGFloat
    let orbit: CGFloat
    /// Soft shadows, highlights and rims: lovely at 1024, mud at 16.
    let detailed: Bool

    init(pixels: Int) {
        if pixels <= 32 {
            margin = 64; discRadius = 156; bubbleRadius = 92; orbit = 290; detailed = false
        } else {
            margin = 100; discRadius = 146; bubbleRadius = 74; orbit = 262; detailed = true
        }
    }
}

/// Draws the icon on a 1024-unit canvas scaled to `pixels`. Core Graphics origin is bottom-left.
func render(pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let k = CGFloat(pixels) / 1024
    ctx.scaleBy(x: k, y: k)
    // Shadow offset and blur are in device pixels (the CTM doesn't scale them), so scale them by hand. Unscaled, a
    // 64 px icon got a 28 px blur that reached the canvas edge and showed as a faint square in the window header.
    func setShadow(dy: CGFloat, blur: CGFloat, color: CGColor) {
        ctx.setShadow(offset: CGSize(width: 0, height: dy * k), blur: blur * k, color: color)
    }

    let art = Art(pixels: pixels)
    let body = CGRect(x: art.margin, y: art.margin, width: 1024 - art.margin * 2, height: 1024 - art.margin * 2)
    let bodyPath = squircle(body)
    let center = CGPoint(x: 512, y: 512)

    // 1. Grounding shadow under the tile: soft and low, like the system icons.
    if art.detailed {
        ctx.saveGState()
        setShadow(dy: -12, blur: 28, color: color(0x1A0F4D, 0.34))
        ctx.addPath(bodyPath)
        ctx.setFillColor(color(0x6340DB))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 2. The tile: the brand violet, lit from above. The bright end is the accent's dark-mode value, the middle its
    // light-mode value.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0x8F6BFF)), (0.5, color(0x6340DB)), (1, color(0x4A2BB8))]),
                           start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
    if art.detailed {
        // A soft top light, like a softbox above the tile.
        ctx.drawRadialGradient(gradient([(0, color(0xFFFFFF, 0.22)), (1, color(0xFFFFFF, 0))]),
                               startCenter: CGPoint(x: 512, y: body.maxY + 40), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: body.maxY + 40), endRadius: 620, options: [])
        // A light rim along the top edge, darker along the bottom, so the tile has thickness.
        ctx.addPath(bodyPath)
        ctx.setLineWidth(6)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(gradient([(0, color(0xFFFFFF, 0.42)), (0.5, color(0xFFFFFF, 0.04)), (1, color(0x1A0F4D, 0.3))]),
                               start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
    }
    ctx.restoreGState()

    // 3. The glass: six bubbles, then the disc over them.
    func ball(_ c: CGPoint, _ r: CGFloat) {
        guard art.detailed else {
            ctx.addEllipse(in: circle(c, r))
            ctx.setFillColor(color(0xFFFFFF))
            ctx.fillPath()
            return
        }
        // It floats: a soft violet shadow on the tile, only outside the ball, so the glass stays clear of its own shadow.
        ctx.saveGState()
        ctx.addRect(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        ctx.addEllipse(in: circle(c, r))
        ctx.clip(using: .evenOdd)
        setShadow(dy: -r * 0.16, blur: r * 0.42, color: color(0x1F1066, 0.55))
        ctx.addEllipse(in: circle(c, r))
        ctx.setFillColor(color(0xFFFFFF))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addEllipse(in: circle(c, r))
        ctx.clip()
        // Frosted body: near white at the top, thinning so the tile's violet shows through toward the bottom.
        ctx.drawLinearGradient(gradient([(0, color(0xFFFFFF, 0.97)), (0.5, color(0xF0EBFF, 0.84)), (1, color(0xC6B8FF, 0.5))]),
                               start: CGPoint(x: c.x, y: c.y + r), end: CGPoint(x: c.x, y: c.y - r), options: [])
        // Light gathering inside the lower edge, the way it does in a real glass ball.
        ctx.drawRadialGradient(gradient([(0, color(0xFFFFFF, 0.8)), (0.55, color(0xFFFFFF, 0.28)), (1, color(0xFFFFFF, 0))]),
                               startCenter: CGPoint(x: c.x, y: c.y - r * 1.12), startRadius: r * 0.1,
                               endCenter: CGPoint(x: c.x, y: c.y - r * 1.12), endRadius: r * 1.05, options: [])
        ctx.restoreGState()

        // The window-light highlight across the top.
        let shine = CGRect(x: c.x - r * 0.66, y: c.y + r * 0.2, width: r * 1.32, height: r * 0.68)
        ctx.saveGState()
        ctx.addEllipse(in: shine)
        ctx.clip()
        ctx.drawLinearGradient(gradient([(0, color(0xFFFFFF, 0.95)), (1, color(0xFFFFFF, 0))]),
                               start: CGPoint(x: c.x, y: shine.maxY), end: CGPoint(x: c.x, y: shine.minY), options: [])
        ctx.restoreGState()

        // A crisp rim, bright on top, fading underneath.
        ctx.saveGState()
        ctx.addEllipse(in: circle(c, r - r * 0.018))
        ctx.setLineWidth(max(3, r * 0.036))
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(gradient([(0, color(0xFFFFFF, 1)), (0.6, color(0xFFFFFF, 0.5)), (1, color(0xFFFFFF, 0.8))]),
                               start: CGPoint(x: c.x, y: c.y + r), end: CGPoint(x: c.x, y: c.y - r), options: [])
        ctx.restoreGState()
    }

    for index in 0..<6 {
        let angle = CGFloat(index) * .pi / 3
        ball(CGPoint(x: center.x + art.orbit * cos(angle), y: center.y + art.orbit * sin(angle)), art.bubbleRadius)
    }
    ball(center, art.discRadius)

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "make-icon", code: 1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "make-icon", code: 2) }
}

// iconutil's required names: icon_<pt>x<pt>[@2x].png
let entries: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for entry in entries {
    try writePNG(render(pixels: entry.pixels), to: iconset.appendingPathComponent("\(entry.name).png"))
}
let preview = resources.appendingPathComponent("AppIcon-1024.png")
try writePNG(render(pixels: 1024), to: preview)

let icns = resources.appendingPathComponent("AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed (\(task.terminationStatus))\n".data(using: .utf8)!)
    exit(1)
}
try? FileManager.default.removeItem(at: iconset)
print("Wrote \(icns.path)")
print("Wrote \(preview.path)")
