import AppKit

/// Monochrome template glyph for the menu-bar item: two stacked, tilted outline cards.
/// Drawn in code so it stays crisp at any scale.
enum MenuBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            func card(center: NSPoint, degrees: CGFloat) -> NSBezierPath {
                let path = NSBezierPath(roundedRect: NSRect(x: -4.6, y: -6, width: 9.2, height: 12),
                                        xRadius: 1.8, yRadius: 1.8)
                var t = AffineTransform(translationByX: center.x, byY: center.y)
                t.rotate(byDegrees: degrees)
                path.transform(using: t)
                path.lineWidth = 1.5
                return path
            }
            NSColor.black.set()
            card(center: NSPoint(x: 6.6, y: 10.2), degrees: 10).stroke()          // back, up-left
            let front = card(center: NSPoint(x: 10.6, y: 8.4), degrees: -9)
            NSGraphicsContext.current?.compositingOperation = .clear              // hide back card behind front
            front.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            front.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Quick Study"
        return image
    }
}
