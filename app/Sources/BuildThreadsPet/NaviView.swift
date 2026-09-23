import AppKit
import PetCore

/// The panel's content view: draws the scene centred on Navi and turns mouse events into
/// click / drag / right-click. Drag threshold 4 px; a drag never opens the menu.
final class NaviView: NSView {
    let scene: NaviScene

    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onDropped: (() -> Void)?

    private var downAt: NSPoint?
    private var moved = false

    init(scene: NaviScene) {
        self.scene = scene
        super.init(frame: NSRect(origin: .zero, size: PetPanel.size))
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Scene origin of this view's top-left, given the panel is centred on the render point.
    var sceneOrigin: CGPoint { CGPoint(x: scene.rx - bounds.width / 2, y: scene.ry - bounds.height / 2) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        scene.draw(in: ctx, origin: sceneOrigin)
    }

    // MARK: mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only Navi herself catches clicks (the panel is click-through otherwise anyway).
        let p = convert(point, from: superview)
        let sp = CGPoint(x: p.x + sceneOrigin.x, y: p.y + sceneOrigin.y)
        return hypot(sp.x - scene.rx, sp.y - scene.ry) <= scene.hitRadius ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        downAt = Screens.mouseScene
        moved = false
        scene.dragging = true                              // the mock starts a drag on pointerdown while hovering
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt else { return }
        let m = Screens.mouseScene
        if !moved, hypot(m.x - start.x, m.y - start.y) > 4 { moved = true }
    }

    override func mouseUp(with event: NSEvent) {
        defer { downAt = nil }
        scene.dragging = false
        if moved {                                          // drop: squash then spring back
            scene.home = NaviScene.Point(x: scene.x, y: scene.y); scene.clampHome()
            scene.sx = 1.35; scene.sy = 0.65; scene.vy += 60
            scene.burst(10, NaviScene.EmitOpts(vy: 20, speed: 60, life: 0.5))
            onDropped?()
        } else {
            scene.sx = 1.45; scene.sy = 1.45
            scene.burst(22, NaviScene.EmitOpts(speed: 150, life: 0.7))
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
