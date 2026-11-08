#!/usr/bin/env swift
// Draws the background of Frenzy's installer window (the DMG) at 1x and 2x and writes them as PNGs.
//
//   swift scripts/make-dmg-background.swift OUT_DIR        (run from apps/halo)
//
// Writes OUT_DIR/background.png (660x400) and OUT_DIR/background@2x.png (1320x800). build-app.sh joins them into one
// HiDPI TIFF for Finder and places the icons to match: Frenzy at (180, 196), Applications at (480, 196), in window
// points from the top left. The artwork has no app icon baked in, so a new icon needs no new background.
//
// Design: a warm pearl canvas lit by soft ember glows from the app icon (FrenzyPalette: flame, gold, peach) with a
// touch of rose, a fine grain so the gradients never band, two soft halos of light for the icons, a light trail
// with a chevron between them, the Frenzy wordmark at the top and one short line at the bottom.
// Why light: Finder always draws icon labels in black on a background picture (tested on macOS 26 in dark mode,
// whatever the window's background colour), so a dark canvas would hide the names "Frenzy" and "Applications".

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: make-dmg-background.swift OUT_DIR\n".data(using: .utf8)!)
    exit(64)
}
let outDir = URL(fileURLWithPath: args[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let width: CGFloat = 660
let height: CGFloat = 400
let iconY: CGFloat = 196          // icon centre, from the top
let leftX: CGFloat = 180, rightX: CGFloat = 480
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                            CGFloat(hex & 0xFF) / 255, alpha])!
}

// FrenzyPalette (Sources/HaloUI/RingBubble.swift): accent 0xC4420F, flame 0xEF6823, gold 0xFDAB3E; the icon's
// peach fold 0xFCA37D and its warm tile 0xF9E5D9.
let accentDeep: UInt32 = 0xC4420F
let accentLight: UInt32 = 0xEF6823
let gold: UInt32 = 0xFDAB3E
let peach: UInt32 = 0xFCA37D
let canvasTop: UInt32 = 0xFBEADF
let canvasBottom: UInt32 = 0xFFFBF8
let ink: UInt32 = 0x2A1712

func radial(_ ctx: CGContext, center: CGPoint, radius: CGFloat, _ hex: UInt32, _ alpha: CGFloat) {
    let g = CGGradient(colorsSpace: space, colors: [color(hex, alpha), color(hex, alpha * 0.45), color(hex, 0)] as CFArray,
                       locations: [0, 0.4, 1])!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

func drawText(_ ctx: CGContext, _ text: String, font: NSFont, hex: UInt32, alpha: CGFloat, centerX: CGFloat,
              baselineFromTop: CGFloat, tracking: CGFloat = 0) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor(cgColor: color(hex, alpha))!, .kern: tracking,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    let w = CTLineGetTypographicBounds(line, nil, nil, nil) - Double(tracking) // no trailing kern in the centring
    ctx.textPosition = CGPoint(x: centerX - CGFloat(w) / 2, y: height - baselineFromTop)
    CTLineDraw(line, ctx)
}

/// Rounded display face for the wordmark, falling back to the system font.
func wordmarkFont(_ size: CGFloat) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: .semibold)
    if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
    return base
}

func render(scale: CGFloat) -> CGImage {
    let pw = Int(width * scale), ph = Int(height * scale)
    let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    let y = height - iconY

    // 1. Canvas: warm pearl, a touch more peach at the top, like the icon's tile.
    let ground = CGGradient(colorsSpace: space, colors: [color(canvasTop), color(canvasBottom)] as CFArray,
                            locations: [0, 1])!
    ctx.drawLinearGradient(ground, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])

    // 2. Embers: flame from the top left, gold from the top right, peach low on the left, a soft rose low on the right.
    //    Kept light, so Finder's black icon labels stay easy to read.
    radial(ctx, center: CGPoint(x: 90, y: height + 40), radius: 360, accentLight, 0.30)
    radial(ctx, center: CGPoint(x: width - 60, y: height + 20), radius: 320, gold, 0.30)
    radial(ctx, center: CGPoint(x: -20, y: 40), radius: 300, peach, 0.26)
    radial(ctx, center: CGPoint(x: width + 20, y: -30), radius: 260, 0xF6B3A0, 0.24)
    // A calm, bright stage across the middle, so the icons and their labels sit on near white.
    let stage = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.75), color(0xFFFFFF, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.saveGState()
    ctx.translateBy(x: width / 2, y: height - iconY - 30)
    ctx.scaleBy(x: 1.9, y: 1)
    ctx.drawRadialGradient(stage, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 190, options: [])
    ctx.restoreGState()

    // 3. Where each icon rests: a soft halo of light behind it and a faint contact shadow under it. No hard shapes,
    //    so any icon (square, round, folder) sits well on it.
    for cx in [leftX, rightX] {
        let halo = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.95), color(0xFFFFFF, 0.5), color(0xFFFFFF, 0)] as CFArray,
                              locations: [0, 0.5, 1])!
        let c = CGPoint(x: cx, y: y + 4)
        ctx.drawRadialGradient(halo, startCenter: c, startRadius: 0, endCenter: c, endRadius: 98, options: [])
        ctx.saveGState()
        ctx.translateBy(x: cx, y: y - 56)
        ctx.scaleBy(x: 1, y: 0.16)
        let shadow = CGGradient(colorsSpace: space, colors: [color(0x5A2414, 0.18), color(0x5A2414, 0)] as CFArray,
                                locations: [0, 1])!
        ctx.drawRadialGradient(shadow, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 64, options: [])
        ctx.restoreGState()
    }

    // 4. The trail: a hairline that deepens toward Applications, a soft glow under it, a chevron at the end.
    let x0 = leftX + 88, x1 = rightX - 90
    let trail = CGMutablePath()
    trail.move(to: CGPoint(x: x0, y: y))
    trail.addLine(to: CGPoint(x: x1 - 3, y: y))
    for (w, a) in [(CGFloat(8), CGFloat(0.14)), (CGFloat(2), CGFloat(1))] {
        ctx.saveGState()
        ctx.addPath(trail)
        ctx.setLineWidth(w)
        ctx.setLineCap(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let g = CGGradient(colorsSpace: space, colors: [color(accentLight, 0), color(accentLight, 0.6 * a),
                                                        color(accentDeep, a)] as CFArray,
                           locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: x0, y: y), end: CGPoint(x: x1, y: y), options: [])
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 6, color: color(accentLight, 0.6))
    ctx.setStrokeColor(color(accentDeep))
    ctx.setLineWidth(2)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: x1 - 8, y: y + 8))
    ctx.addLine(to: CGPoint(x: x1, y: y))
    ctx.addLine(to: CGPoint(x: x1 - 8, y: y - 8))
    ctx.strokePath()
    ctx.restoreGState()

    // 5. Type: the wordmark, small and spaced, and the one instruction.
    drawText(ctx, "Frenzy", font: wordmarkFont(18), hex: ink, alpha: 0.92, centerX: width / 2,
             baselineFromTop: 60, tracking: 0.4)
    drawText(ctx, "Drag to Applications to install", font: NSFont.systemFont(ofSize: 12, weight: .medium),
             hex: 0x5A3E34, alpha: 0.78, centerX: width / 2, baselineFromTop: 360, tracking: 0.2)

    // 7. Grain: fine, monochrome, very faint. Seeded, so every build draws the same picture.
    var seed: UInt64 = 0x5EED_F2E1
    func next() -> CGFloat {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((seed >> 33) & 0xFFFF) / 65535
    }
    let dot = 1 / scale
    for _ in 0..<Int(width * height * scale * scale * 0.18) {
        let px = (next() * width * scale).rounded(.down) / scale
        let py = (next() * height * scale).rounded(.down) / scale
        let light = next() > 0.5
        ctx.setFillColor(color(light ? 0xFFFFFF : 0x000000, light ? 0.05 : 0.035))
        ctx.fill(CGRect(x: px, y: py, width: dot, height: dot))
    }
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ name: String, dpi: CGFloat) throws {
    let url = outDir.appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "dmg-bg", code: 1)
    }
    CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "dmg-bg", code: 2) }
    print("wrote \(url.path)")
}

try writePNG(render(scale: 1), "background.png", dpi: 72)
try writePNG(render(scale: 2), "background@2x.png", dpi: 144)
