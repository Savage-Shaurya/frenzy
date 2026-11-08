import AppKit

/// The menu-bar glyph: a thin ring with a small offset bead, drawn as a template image so it follows the menu
/// bar's light, dark and tinted appearances and stays crisp at every scale (it's vector, drawn per backing scale).
enum StatusIcon {
    static func image(paused: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        // The folded paper arrow of the app icon ("Ember glow"), as a menu-bar template glyph: two folds meeting at
        // the tip, with a thin crease between them. Paused: the same arrow as a dashed outline.
        let image = NSImage(size: size, flipped: false) { _ in
            let tip = NSPoint(x: 16.2, y: 9.0)
            let top = NSPoint(x: 2.4, y: 15.6)
            let notch = NSPoint(x: 6.6, y: 9.0)
            let bottom = NSPoint(x: 2.4, y: 2.4)
            let arrow = NSBezierPath()
            arrow.move(to: tip); arrow.line(to: top); arrow.line(to: notch); arrow.line(to: bottom); arrow.close()
            arrow.lineJoinStyle = .round
            NSColor.black.set()
            if paused {
                arrow.lineWidth = 1.4
                arrow.setLineDash([2.2, 1.8], count: 2, phase: 0)
                arrow.stroke()
            } else {
                arrow.fill()
                // The crease: cleared, so the menu bar shows through like a fold line.
                NSGraphicsContext.current?.compositingOperation = .clear
                let crease = NSBezierPath()
                crease.move(to: notch); crease.line(to: NSPoint(x: tip.x - 1.2, y: tip.y))
                crease.lineWidth = 1.1
                crease.lineCapStyle = .round
                crease.stroke()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = paused ? "Frenzy (paused)" : "Frenzy"
        return image
    }
}
