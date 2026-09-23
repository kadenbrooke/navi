import AppKit

/// Transparent, borderless, non-activating floating panel that lives on every Space and
/// over full-screen apps. It is moved every frame to keep Navi centred; mouse events are
/// only accepted while the cursor is on her (see `AppDelegate.tick`), so everything else
/// clicks through to whatever is underneath.
final class PetPanel: NSPanel {
    static let size = NSSize(width: 320, height: 320)

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: PetPanel.size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Scene ↔ Cocoa coordinate helpers. Scene = whole desktop, y down, origin at the top-left
/// of the primary screen.
enum Screens {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 900 }

    static func toScene(_ p: NSPoint) -> NSPoint { NSPoint(x: p.x, y: primaryHeight - p.y) }
    static func toCocoa(_ p: NSPoint) -> NSPoint { NSPoint(x: p.x, y: primaryHeight - p.y) }

    /// The screen containing a scene point (or the main one), as a scene-coords rect.
    static func stage(containing scene: NSPoint) -> CGRect {
        let cocoa = toCocoa(scene)
        let s = NSScreen.screens.first { $0.frame.contains(cocoa) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let f = s?.frame else { return CGRect(x: 0, y: 0, width: 1440, height: 900) }
        return CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
    }

    static var mouseScene: NSPoint { toScene(NSEvent.mouseLocation) }
}
