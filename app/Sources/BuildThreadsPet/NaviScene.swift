import AppKit
import PetCore

/// Navi's body, physics, particles and drawing. Straight port of the design mock §6–8
/// (`emit` / `updateParticles` / `drawParticles` / `drawBody` / `drawFairy` / `drawBubble` /
/// `updateGoal` / `physics`). Units are the mock's canvas px at 1x = points here.
///
/// Coordinates are "scene" coordinates: the whole desktop, y DOWN, origin at the top-left of
/// the primary screen (so the mock's math ports untouched). `AppDelegate` converts to Cocoa.
final class NaviScene {
    struct Point { var x: Double; var y: Double }

    // fairy body (mock `F`)
    var x = 0.0, y = 0.0, vx = 0.0, vy = 0.0          // anchor + velocity
    var home = Point(x: 0, y: 0)
    var goal = Point(x: 0, y: 0)
    var scale = 1.0, sx = 1.0, sy = 1.0
    var rot = 0.0, lean = 0.0
    var bright = 0.0
    var hover = false, dragging = false
    var wingPhase = 0.0, bobPhase = 0.0, ringPhase = 0.0
    var shake = 0.0
    var awake = 1.0
    var fidget = 0.0
    var rx = 0.0, ry = 0.0                             // render position (after bob + shake + hotspot push)

    // inputs, set by the owner each frame
    var params = NaviParams()
    var mode = "follow"
    var rgb = RGB(hex: naviNoThreadsHex)
    var sleeping = false
    var bubble: SymbolBubble?
    var mouse = Point(x: -999, y: -999)
    var mouseInside = true
    /// Screen bounds in scene coords: the screen `home` is on.
    var stage = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private struct Particle {
        var x, y, vx, vy, life, max, size: Double
        var rgb: RGB
        var tw, spin, grav: Double
        var star: Bool
    }
    private struct Floater { var x, y, life, max, ph: Double }
    private var particles: [Particle] = []
    private var floaters: [Floater] = []
    private var emitAcc = 0.0
    private var pixCache: CGContext?
    private var pixSide = 0
    private(set) var now = 0.0

    // live params (mock `L`)
    private var L = NaviParams()

    // MARK: live params

    private func computeLive() {
        L = params
        if sleeping { L.glowIntensity *= 0.35; L.trailDensity = 0; L.wingSpeed *= 0.35; L.bobFreq *= 0.25; L.bobAmp *= 0.3 }
        L.glowIntensity *= 1 + bright * 0.5
        L.wingSpeed *= 1 + bright * 0.6
        if dragging { L.trailDensity *= 3; L.trailSpread *= 1.4 }
    }

    // MARK: particles

    struct EmitOpts {
        var x: Double? = nil, y: Double? = nil, vx: Double? = nil, vy: Double? = nil
        var spread: Double? = nil, speed: Double? = nil, life: Double? = nil, size: Double? = nil
        var rgb: RGB? = nil, grav: Double? = nil
    }

    private func emit(_ n: Int, _ o: EmitOpts = EmitOpts()) {
        let spread = o.spread ?? L.trailSpread
        let base = o.rgb ?? rgb
        for _ in 0..<n {
            if particles.count > 900 { particles.removeFirst() }
            let a = Double.random(in: 0..<(.pi * 2)), r = Double.random(in: 0..<max(spread, 0.0001))
            let sp = o.speed ?? 12
            particles.append(Particle(
                x: (o.x ?? x) + cos(a) * r, y: (o.y ?? y) + sin(a) * r,
                vx: (o.vx ?? 0) + cos(a) * sp * Double.random(in: 0..<1) - vx * 0.12,
                vy: (o.vy ?? -14) + sin(a) * sp * Double.random(in: 0..<1) - vy * 0.12,
                life: 0, max: (o.life ?? L.trailLength) * (0.6 + Double.random(in: 0..<0.8)) + 0.05,
                size: (o.size ?? (0.8 + Double.random(in: 0..<2.2))) * (params.size / 14),
                rgb: base.lighten(Double.random(in: 0..<0.5)), tw: Double.random(in: 0..<(.pi * 2)),
                spin: Double.random(in: 3..<9), grav: o.grav ?? 0, star: Double.random(in: 0..<1) < 0.25))
        }
    }

    func burst(_ n: Int, _ o: EmitOpts = EmitOpts()) {
        var opts = o
        opts.x = o.x ?? rx; opts.y = o.y ?? ry
        opts.spread = o.spread ?? 4; opts.speed = o.speed ?? 140; opts.life = o.life ?? 0.7; opts.size = o.size ?? 2
        emit(n, opts)
    }

    private func updateParticles(_ dt: Double) {
        var i = particles.count - 1
        while i >= 0 {
            particles[i].life += dt
            if particles[i].life >= particles[i].max { particles.remove(at: i); i -= 1; continue }
            var p = particles[i]
            p.vy += (p.grav != 0 ? p.grav : -6) * dt; p.vx *= 0.985; p.vy *= 0.985
            p.x += p.vx * dt; p.y += p.vy * dt
            particles[i] = p
            i -= 1
        }
        i = floaters.count - 1
        while i >= 0 {
            floaters[i].life += dt
            floaters[i].y -= 22 * dt
            floaters[i].x += sin(floaters[i].life * 3 + floaters[i].ph) * 10 * dt
            if floaters[i].life > floaters[i].max { floaters.remove(at: i) }
            i -= 1
        }
    }

    private func drawParticles(_ c: CGContext) {
        c.saveGState()
        c.setBlendMode(.plusLighter)
        let px = params.pixel ? params.pixelSize : 0
        for p in particles {
            let t = p.life / p.max
            let fade = t < 0.15 ? t / 0.15 : 1 - (t - 0.15) / 0.85
            let tw = 0.6 + 0.4 * sin(p.tw + now * p.spin)
            let a = max(0, fade * tw * 0.9)
            let s = p.size * (1 - t * 0.5)
            if px > 0 {
                c.setFillColor(cg(p.rgb, a))
                let q = max(px, (s * 2 / px).rounded() * px)
                c.fill(CGRect(x: (p.x / px).rounded() * px, y: (p.y / px).rounded() * px, width: q, height: q))
            } else if p.star && s > 1 {
                c.setFillColor(cg(p.rgb, a))
                let r1 = s * 2.2, r2 = s * 0.5
                c.beginPath()
                for k in 0..<8 {
                    let r = k % 2 == 1 ? r2 : r1, ang = Double(k) * .pi / 4
                    let pt = CGPoint(x: p.x + cos(ang) * r, y: p.y + sin(ang) * r)
                    k == 0 ? c.move(to: pt) : c.addLine(to: pt)
                }
                c.closePath(); c.fillPath()
            } else {
                radial(c, at: CGPoint(x: p.x, y: p.y), r: s * 2, stops: [(0, p.rgb, a), (1, p.rgb, 0)])
            }
        }
        c.restoreGState()
        for f in floaters {
            let a = f.life < 0.2 ? f.life / 0.2 : 1 - (f.life - 0.2) / (f.max - 0.2)
            guard let font = TextFonts.floater(size: 11 + f.life * 5) else { continue }
            let color = NSColor(srgbRed: rgb.r / 255, green: rgb.g / 255, blue: rgb.b / 255, alpha: max(0, min(1, a)) * 0.9)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            ("z" as NSString).draw(at: NSPoint(x: f.x, y: f.y - 12), withAttributes: attrs)
        }
    }

    // MARK: body

    /// k = pixel scale factor (1 = normal). Draws relative to (0,0) after the caller's transform.
    private func drawBody(_ c: CGContext, t: Double, k: Double) {
        let S = params.size * k * scale
        let gi = L.glowIntensity

        // glow + bloom (additive)
        c.saveGState(); c.setBlendMode(.plusLighter)
        let gr = S * L.glowRadius
        let breathe = 1 + 0.06 * sin(t * 2.1) + 0.03 * sin(t * 5.3)
        radial(c, at: .zero, r: gr * breathe, stops: [(0, rgb, 0.55 * gi), (0.25, rgb, 0.22 * gi), (1, rgb, 0)])
        radial(c, at: .zero, r: S * 2.2, stops: [(0, rgb.lighten(0.5), 0.6 * gi), (1, rgb, 0)])
        c.restoreGState()

        // halo
        if params.halo {
            c.saveGState(); c.setBlendMode(.plusLighter)
            let hr = S * 2.9 * (1 + 0.04 * sin(t * 1.7))
            c.setStrokeColor(cg(rgb, 0.16 * gi)); c.setLineWidth(S * 0.55)
            c.addEllipse(in: CGRect(x: -hr, y: -hr, width: hr * 2, height: hr * 2)); c.strokePath()
            c.restoreGState()
        }

        // wings (behind core)
        c.saveGState(); c.setBlendMode(.plusLighter)
        let n = L.wingCount
        let flap = 0.5 + 0.5 * cos(wingPhase)
        let wl = S * 2.6 * params.wingSize, ww = S * 1.25 * params.wingSize
        let angles: [Double] = n == 2 ? [-0.55, 0.55] : n == 4 ? [-0.62, 0.62, -2.15, 2.15] : []
        for (i, ang) in angles.enumerated() {
            let upper = abs(ang) < 1.5
            c.saveGState()
            let sweep = ang * (0.62 + 0.38 * flap) + sin(wingPhase * 0.5 + Double(i)) * 0.06
            c.rotate(by: sweep)
            c.scaleBy(x: 0.7 + 0.3 * flap, y: 1)
            let a = L.wingOpacity * (upper ? 1 : 0.7)
            let path = CGMutablePath()
            if params.geometric {
                path.move(to: .zero); path.addLine(to: CGPoint(x: -ww * 0.55, y: -wl * 0.45)); path.addLine(to: CGPoint(x: 0, y: -wl))
                path.addLine(to: CGPoint(x: ww * 0.55, y: -wl * 0.45)); path.closeSubpath()
            } else {
                path.move(to: .zero)
                path.addCurve(to: CGPoint(x: 0, y: -wl), control1: CGPoint(x: -ww, y: -wl * 0.35), control2: CGPoint(x: -ww * 0.7, y: -wl))
                path.addCurve(to: .zero, control1: CGPoint(x: ww * 0.7, y: -wl), control2: CGPoint(x: ww, y: -wl * 0.35))
            }
            c.saveGState()
            c.addPath(path); c.clip()
            linear(c, from: .zero, to: CGPoint(x: 0, y: -wl),
                   stops: [(0, rgb.lighten(0.75), a), (0.55, rgb.lighten(0.35), a * 0.75), (1, rgb, a * 0.12)])
            c.restoreGState()
            c.addPath(path)
            c.setStrokeColor(cg(rgb.lighten(0.8), a * 0.5)); c.setLineWidth(max(0.6, S * 0.06)); c.strokePath()
            // vein
            c.setStrokeColor(cg(rgb.lighten(0.9), a * 0.35))
            c.move(to: .zero); c.addLine(to: CGPoint(x: 0, y: -wl * 0.9)); c.strokePath()
            c.restoreGState()
        }
        c.restoreGState()

        // core
        c.saveGState()
        let corePath = CGMutablePath()
        if params.geometric {
            for i in 0..<6 {
                let a = Double(i) * .pi / 3 + t * 0.6
                let pt = CGPoint(x: cos(a) * S, y: sin(a) * S)
                i == 0 ? corePath.move(to: pt) : corePath.addLine(to: pt)
            }
            corePath.closeSubpath()
        } else {
            corePath.addEllipse(in: CGRect(x: -S, y: -S, width: S * 2, height: S * 2))
        }
        c.addPath(corePath); c.clip()
        radial(c, at: .zero, r: S, start: CGPoint(x: -S * 0.25, y: -S * 0.25),
               stops: [(0, RGB(255, 255, 255), 1), (0.35, rgb.lighten(0.75), 1), (1, rgb, 0.9)])
        c.restoreGState()
        // specular
        c.saveGState()
        c.translateBy(x: -S * 0.3, y: -S * 0.35); c.rotate(by: -0.6)
        c.setFillColor(CGColor(gray: 1, alpha: 0.75))
        c.fillEllipse(in: CGRect(x: -S * 0.28, y: -S * 0.18, width: S * 0.56, height: S * 0.36))
        c.restoreGState()

        // thin ring
        if params.ring {
            c.saveGState(); c.setBlendMode(.plusLighter)
            c.rotate(by: ringPhase)
            c.setStrokeColor(cg(rgb.lighten(0.4), 0.7 * gi)); c.setLineWidth(max(1, S * 0.08))
            c.setLineDash(phase: 0, lengths: [S * 0.9, S * 0.5])
            c.addEllipse(in: CGRect(x: -S * 1.75, y: -S * 1.75, width: S * 3.5, height: S * 3.5)); c.strokePath()
            c.restoreGState()
        }
    }

    /// Draws everything into `c` (a flipped, y-down context) whose origin is scene point `origin`.
    func draw(in c: CGContext, origin: CGPoint) {
        c.saveGState()
        c.translateBy(x: -origin.x, y: -origin.y)
        drawParticles(c)

        c.saveGState()
        c.translateBy(x: rx, y: ry); c.rotate(by: rot + lean); c.scaleBy(x: sx, y: sy)
        if params.pixel {
            let px = params.pixelSize
            let ext = params.size * scale * max(L.glowRadius, 3.2 * params.wingSize) * 1.05
            let side = Int(ceil(ext * 2 / px))
            if let off = pixContext(side) {
                off.clear(CGRect(x: 0, y: 0, width: side, height: side))
                off.saveGState()
                off.translateBy(x: Double(side) / 2, y: Double(side) / 2)
                drawBody(off, t: now, k: 1 / px)
                off.restoreGState()
                if let img = off.makeImage() {
                    c.interpolationQuality = .none
                    c.draw(img, in: CGRect(x: -Double(side) * px / 2, y: -Double(side) * px / 2, width: Double(side) * px, height: Double(side) * px))
                    c.interpolationQuality = .default
                }
            }
        } else {
            drawBody(c, t: now, k: 1)
        }
        c.restoreGState()

        if let b = bubble, let a = b.alpha(now: now) {
            drawBubble(c, x: rx, y: ry - params.size * scale * 2.6 - 10, text: b.symbol, rgb: b.rgb, alpha: a)
        }
        c.restoreGState()
    }

    private func pixContext(_ side: Int) -> CGContext? {
        if let ctx = pixCache, pixSide == side { return ctx }
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        pixCache = ctx; pixSide = side
        return ctx
    }

    private func drawBubble(_ c: CGContext, x: Double, y: Double, text: String, rgb: RGB, alpha: Double) {
        let r: Double = text.count > 1 ? 16 : 12
        let yy = y - r - sin(now * 4) * 2
        c.saveGState()
        c.setAlpha(alpha)
        c.setFillColor(CGColor(red: 237 / 255, green: 230 / 255, blue: 230 / 255, alpha: 0.96))
        c.setStrokeColor(cg(rgb, 0.9)); c.setLineWidth(1.5)
        c.addEllipse(in: CGRect(x: x - r, y: yy - r, width: r * 2, height: r * 2)); c.drawPath(using: .fillStroke)
        c.move(to: CGPoint(x: x - 4, y: yy + r - 2)); c.addLine(to: CGPoint(x: x, y: yy + r + 6)); c.addLine(to: CGPoint(x: x + 4, y: yy + r - 2))
        c.closePath(); c.fillPath()
        guard let font = TextFonts.bubble(size: text.count > 1 ? 13 : r * 1.25) else { c.restoreGState(); return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 20 / 255, alpha: alpha)]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: x - size.width / 2, y: yy - size.height / 2 + 1), withAttributes: attrs)
        c.restoreGState()
    }

    // MARK: movement

    private var override: (x: Double, y: Double, until: Double, then: (() -> Void)?)?

    /// "Come here": dart to a point, then run `then` (a burst), mock `F.override`.
    func comeHere(x px: Double, y py: Double) {
        home = Point(x: px, y: py); clampHome()
        override = (px, py, now + 0.9, { [weak self] in self?.burst(18, EmitOpts(speed: 110, life: 0.6)) })
    }

    func clampHome() {
        home.x = max(stage.minX + 30, min(stage.maxX - 30, home.x))
        home.y = max(stage.minY + 30, min(stage.maxY - 110, home.y))
    }

    private func updateGoal(_ dt: Double) {
        if let o = override {
            goal = Point(x: o.x, y: o.y)
            if now > o.until { override = nil; o.then?() }
            return
        }
        if dragging { goal = mouse; return }
        if sleeping {                                  // park at the nearest vertical edge as a dot
            let left = home.x < stage.midX
            goal.x = left ? stage.minX + 26 : stage.maxX - 26
            goal.y = min(stage.maxY - 110, max(stage.minY + 60, home.y))
            return
        }
        if mode == "follow" {
            if mouseInside { goal = Point(x: mouse.x - 34, y: mouse.y - 30) } else { goal = home }
        } else {                                       // hover (every other mock mode needs the fake desktop)
            goal = home
            if now > fidget {
                fidget = now + 4 + Double.random(in: 0..<6)
                home.x += Double.random(in: -20..<20); home.y += Double.random(in: -12..<12); clampHome()
            }
        }
    }

    private func physics(_ dt: Double) {
        let lag = dragging ? 0.05 : override != nil ? 0.12 : sleeping ? 0.25 : L.followLag
        let k = (1 / (lag * lag)) * 0.9 * (mode == "follow" ? 1 : L.speed)
        let damp = override != nil ? 0.62 : 0.85
        let cc = 2 * sqrt(k) * damp
        let ax = (goal.x - x) * k - vx * cc, ay = (goal.y - y) * k - vy * cc
        vx += ax * dt; vy += ay * dt
        x += vx * dt; y += vy * dt
        let targetLean = max(-0.5, min(0.5, vx / 900))
        lean += (targetLean - lean) * min(1, dt * 8)
        wingPhase += dt * .pi * 2 * L.wingSpeed
        bobPhase += dt * .pi * 2 * L.bobFreq
        ringPhase += dt * 0.35
        if shake > 0 { shake -= dt * 3 }
        sx += (1 - sx) * min(1, dt * 9); sy += (1 - sy) * min(1, dt * 9)
        let target = sleeping ? 0.32 : 1.0
        scale += (target - scale) * min(1, dt * 2.5)
        awake += ((sleeping ? 0 : 1) - awake) * min(1, dt * 3)

        // render position: bob + shake, then keep the core off the cursor hotspot
        let bob = L.bobAmp * (sin(bobPhase) * 0.8 + sin(bobPhase * 2.3 + 1) * 0.2)
        var dx = 0.0, dy = bob
        if shake > 0 { let s = shake * 14; dx += Double.random(in: -0.5..<0.5) * s * 2; dy += Double.random(in: -0.5..<0.5) * s }
        rx = x + dx; ry = y + dy
        if mouseInside && !dragging {
            let excl = params.size * scale + 6
            let ddx = rx - mouse.x, ddy = ry - mouse.y
            let d = (ddx * ddx + ddy * ddy).squareRoot()
            if d < excl {
                if d < 0.001 { ry = mouse.y - excl } else { rx += ddx / d * (excl - d); ry += ddy / d * (excl - d) }
            }
        }

        // hover detection + brightness
        let hr = params.size * scale * 2.6
        hover = mouseInside && hypot(mouse.x - rx, mouse.y - ry) < hr + 8
        bright += ((hover ? 1 : 0) - bright) * min(1, dt * 7)

        // trail emission — more when moving
        let v = hypot(vx, vy)
        let rate = L.trailDensity * (1 + v / 260) * awake
        emitAcc += rate * dt
        while emitAcc >= 1 { emitAcc -= 1; emit(1, EmitOpts(x: rx, y: ry, vx: -vx * 0.15, vy: -vy * 0.15 - 14)) }
        // drifting z's while asleep
        if sleeping && awake < 0.5 && Double.random(in: 0..<1) < dt * 0.9 {
            floaters.append(Floater(x: rx + params.size * scale + 4, y: ry - params.size * scale - 4, life: 0, max: 2.2, ph: Double.random(in: 0..<6)))
        }
    }

    /// One frame. `t` = seconds (monotonic).
    func step(t: Double) {
        let dt = min(0.05, max(0.001, now == 0 ? 1.0 / 60 : t - now))
        now = t
        computeLive()
        updateGoal(dt)
        physics(dt)
        updateParticles(dt)
    }

    /// Radius that counts as "on her" for hit-testing (mock: hr + 8).
    var hitRadius: Double { params.size * scale * 2.6 + 8 }

    // MARK: cg helpers

    /// Fonts for the bubble symbol and the sleep "z" floaters.
    ///
    /// `NSFont.monospacedSystemFont(ofSize:weight:)` is declared non-optional, but at
    /// runtime it can hand back a null reference (observed 2026-09-19 on macOS 26.7 during a
    /// nap: two floaters in one frame). Swift trusts the declaration, the null goes into the
    /// attribute dictionary, and CoreText throws NSInvalidArgumentException ("attempt to
    /// insert nil object from objects[0]") from `-[NSString sizeWithAttributes:]` /
    /// `drawAtPoint:` — an uncaught ObjC exception, so the app aborts. That was every one of
    /// Navi's "quit by herself" crashes: the sleep pop at `sleepMin` (10 min) is the first
    /// text she draws in a quiet session.
    ///
    /// So: fonts are created once per size bucket and cached; the factory is never called
    /// from the render loop; a null result is detected, logged once, and the text is skipped
    /// for that frame instead of crashing.
    enum TextFonts {
        private static var cache: [String: NSFont] = [:]
        private static var warned = false

        static func bubble(size: Double) -> NSFont? { font(size: size, weight: .bold, key: "b") }
        /// Floater size grows continuously with life; bucket to 0.5 pt so the cache stays small.
        static func floater(size: Double) -> NSFont? { font(size: (size * 2).rounded() / 2, weight: .semibold, key: "f") }

        private static func font(size: Double, weight: NSFont.Weight, key: String) -> NSFont? {
            let k = "\(key)\(size)"
            if let f = cache[k] { return f }
            let raw = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            guard unsafeBitCast(raw, to: Int.self) != 0 else {
                if !warned { NSLog("Navi: NSFont.monospacedSystemFont returned nil (size %.1f) — skipping text this frame", size); warned = true }
                return nil
            }
            cache[k] = raw
            return raw
        }
    }

    private func cg(_ c: RGB, _ a: Double) -> CGColor {
        CGColor(srgbRed: c.r / 255, green: c.g / 255, blue: c.b / 255, alpha: max(0, min(1, a)))
    }

    private func radial(_ c: CGContext, at center: CGPoint, r: Double, start: CGPoint? = nil, stops: [(Double, RGB, Double)]) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let colors = stops.map { cg($0.1, $0.2) } as CFArray
        let locs = stops.map { CGFloat($0.0) }
        guard let g = CGGradient(colorsSpace: space, colors: colors, locations: locs) else { return }
        c.saveGState()
        c.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)); c.clip()
        c.drawRadialGradient(g, startCenter: start ?? center, startRadius: 0, endCenter: center, endRadius: r, options: [.drawsAfterEndLocation])
        c.restoreGState()
    }

    private func linear(_ c: CGContext, from: CGPoint, to: CGPoint, stops: [(Double, RGB, Double)]) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let colors = stops.map { cg($0.1, $0.2) } as CFArray
        let locs = stops.map { CGFloat($0.0) }
        guard let g = CGGradient(colorsSpace: space, colors: colors, locations: locs) else { return }
        c.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
}
