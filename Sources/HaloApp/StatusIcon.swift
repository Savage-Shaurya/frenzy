import AppKit

/// The menu-bar glyph: a thin ring with a small offset bead, drawn as a template image so it follows the menu
/// bar's light, dark and tinted appearances and stays crisp at every scale (it's vector, drawn per backing scale).
enum StatusIcon {
    static func image(paused: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 6.4
            let ring = NSBezierPath()
            ring.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            ring.lineWidth = 1.6
            if paused { ring.setLineDash([2.2, 2.0], count: 2, phase: 0) }
            NSColor.black.setStroke()
            ring.stroke()

            if !paused {
                // The "drop target" bead sitting on the ring at about 2 o'clock.
                let angle = CGFloat.pi / 4
                let bead = NSPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: bead.x - 2.3, y: bead.y - 2.3, width: 4.6, height: 4.6)).fill()
            }
            // Small centre dot: the file at the heart of the ring.
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = paused ? "Frenzy (paused)" : "Frenzy"
        return image
    }
}
