import Foundation

/// What color Navi wears right now, and why. Port of the design mock §9 `updateEngine`:
///   0 threads → white · 1 distinct state → that color · 2+ → rotate every 1 s through
///   the live set (working → needs_input → blocked → idle) with a 200 ms crossfade.
///   sleeping overrides everything with grey.
/// Pure and time-stepped (`update(dt:)`) so tests can drive it deterministically.
public struct ColorEngine: Sendable {
    public static let rotationInterval: Double = 1.0
    public static let crossfade: Double = 0.2

    /// Distinct live states in rotation order (input, set by the caller each observation).
    public private(set) var live: [NaviState] = []
    public var sleeping = false
    public var workingColor = "#fff8ad"

    /// The state whose color is being targeted. nil = no threads (white).
    public private(set) var shown: NaviState? = nil
    public private(set) var rgb = RGB(hex: naviNoThreadsHex)
    private var fadeFrom: RGB? = nil
    private var fadeT: Double = 1
    private var rotIdx = 0
    private var rotT: Double = 0
    private var primed = false

    public init() {}

    public mutating func setLive(_ states: [NaviState]) {
        let ordered = NaviStateMapper.liveSet(states)
        if ordered != live { rotIdx = 0; rotT = 0 }
        live = ordered
    }

    public var targetHex: String {
        guard let s = shown else { return naviNoThreadsHex }
        return s.hex(workingColor: workingColor)
    }

    /// Advance by `dt` seconds. Returns true when the shown state changed this step.
    @discardableResult
    public mutating func update(dt: Double) -> Bool {
        var target: NaviState?
        if sleeping { target = .sleep }
        else if live.isEmpty { target = nil }
        else if live.count == 1 { target = live[0]; rotIdx = 0; rotT = 0 }
        else {
            rotT += dt
            if rotT >= ColorEngine.rotationInterval { rotT -= ColorEngine.rotationInterval; rotIdx = (rotIdx + 1) % live.count }
            target = live[rotIdx % live.count]
        }
        var changed = false
        if target != shown || !primed {
            // first observation snaps (no fade from nothing); later changes crossfade
            fadeFrom = primed ? rgb : nil
            fadeT = primed ? 0 : 1
            shown = target
            changed = primed
            primed = true
        }
        fadeT = min(1, fadeT + dt / ColorEngine.crossfade)
        let to = RGB(hex: targetHex)
        rgb = (fadeFrom != nil && fadeT < 1) ? fadeFrom!.mix(to, fadeT) : to
        return changed
    }
}

/// The symbol bubble above her head. Latest pop wins; lives ~2 s, fades over the last 0.5 s.
public struct SymbolBubble: Equatable, Sendable {
    public static let lifetime: Double = 2.0
    public var state: NaviState
    public var rgb: RGB
    public var at: Double

    public init(state: NaviState, rgb: RGB, at: Double) { self.state = state; self.rgb = rgb; self.at = at }

    public var symbol: String { state.symbol }

    /// nil once expired. Alpha ramps in over 120 ms, holds, then fades out over the last 500 ms.
    public func alpha(now: Double) -> Double? {
        let t = now - at
        if t > SymbolBubble.lifetime { return nil }
        if t < 0.12 { return max(0, t / 0.12) }
        if t > 1.5 { return max(0, 1 - (t - 1.5) / 0.5) }
        return 1
    }
}
