import AppKit

/// Menu bar icon: a monochrome lemon slice (rind ring + 8 segments), drawn as a template image so it
/// adapts to light/dark menu bars and the highlighted state.
enum LemonGlyph {
    static func menuBarImage(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let outer = size / 2 - 0.75
            NSColor.black.setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
            ring.lineWidth = 1.5
            ring.stroke()

            NSColor.black.setFill()
            let segments = 8
            let span = 2 * CGFloat.pi / CGFloat(segments)
            let gap: CGFloat = 0.2
            let inner: CGFloat = size * 0.07, flesh = outer - 2.3
            for i in 0..<segments {
                let a0 = CGFloat(i) * span - span / 2 + gap / 2
                let a1 = CGFloat(i + 1) * span - span / 2 - gap / 2
                let path = NSBezierPath()
                let steps = 8
                for k in 0...steps {
                    let a = a0 + (a1 - a0) * CGFloat(k) / CGFloat(steps)
                    let p = CGPoint(x: c.x + flesh * sin(a), y: c.y + flesh * cos(a))
                    k == 0 ? path.move(to: p) : path.line(to: p)
                }
                path.line(to: CGPoint(x: c.x + inner * sin(a1), y: c.y + inner * cos(a1)))
                path.line(to: CGPoint(x: c.x + inner * sin(a0), y: c.y + inner * cos(a0)))
                path.close()
                path.fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Zest"
        return image
    }
}
