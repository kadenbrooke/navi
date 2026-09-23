import AppKit
import PetCore

/// The menubar glyph: a Triforce — three equilateral triangles, two on the bottom row and
/// one on top — drawn with NSBezierPath into a template image, so it is crisp at 1x/2x and
/// follows the light/dark menubar automatically. No bitmap asset, no SF Symbol.
///
/// Alert (anything blocked / needs input) = a small filled dot at the bottom-right corner,
/// chosen over hollowing the top triangle because it stays readable at 16 pt and reads as
/// a "badge" the way other menubar apps do. Hidden = the whole glyph at 45 % opacity.
enum TriforceIcon {
    static let size = NSSize(width: 20, height: 16)

    static func image(_ spec: MenubarIconSpec) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.black.withAlphaComponent(spec.opacity).setFill()
            triforce(in: rect).fill()
            if spec.alert {
                // badge: knock a 1 pt ring out of the triangle corner first so the dot reads
                // as its own shape instead of a blob
                let d: CGFloat = 5.5
                let dot = NSRect(x: rect.maxX - d, y: rect.minY, width: d, height: d)
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSColor.black.setFill()
                NSBezierPath(ovalIn: dot.insetBy(dx: -1, dy: -1)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.black.withAlphaComponent(spec.opacity).setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = spec.hidden ? "Navi hidden" : "Navi"
        return img
    }

    /// Three triangles of side `s`, sharing a common apex layout; a hair of gap between them
    /// keeps the hollow centre visible at small sizes.
    static func triforce(in rect: NSRect) -> NSBezierPath {
        let s: CGFloat = 8            // side of each small triangle
        let h = s * sqrt(3) / 2       // height of each small triangle
        let gap: CGFloat = 0.6
        let originX = rect.midX - s   // big triangle spans 2s wide, 2h tall
        let originY = rect.midY - h - 0.5
        let path = NSBezierPath()
        func tri(_ x: CGFloat, _ y: CGFloat) {
            path.move(to: NSPoint(x: x + gap, y: y + gap * 0.5))
            path.line(to: NSPoint(x: x + s - gap, y: y + gap * 0.5))
            path.line(to: NSPoint(x: x + s / 2, y: y + h - gap))
            path.close()
        }
        tri(originX, originY)                 // bottom-left
        tri(originX + s, originY)             // bottom-right
        tri(originX + s / 2, originY + h)     // top
        return path
    }
}
