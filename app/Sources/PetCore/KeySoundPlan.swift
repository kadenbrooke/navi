import Foundation

// Which sound every key plays, worked out once per pack load so a key press is one array
// lookup (no added latency). Pure: the player decodes the files, describes what decoded as a
// `PackInventory`, and turns the plan into buffers.
//
// PRIVACY: the key code is an array index here and nothing else. A plan holds no history of
// presses and is never saved.

/// What a pack's decoded samples offer, as counts (no audio, no URLs).
public struct PackInventory: Equatable, Sendable {
    /// `key-NN`: the pack's generic key presses.
    public var generic: Int
    /// `space-` / `enter-` / `backspace-NN` (`.other` is ignored here: that is `generic`).
    public var classes: [KeyClass: Int]
    /// `row<r>-NN`: per-row presses (rows 0…4), row → count.
    public var rows: [Int: Int]
    /// `sc<scancode>`: one recording per key (Mechvibes packs), by Mechvibes scancode.
    public var perKey: Set<Int>
    /// `up-key-NN`: generic key releases.
    public var releaseGeneric: Int
    /// `up-space-` / `up-enter-` / `up-backspace-NN`.
    public var releaseClasses: [KeyClass: Int]

    public init(generic: Int = 0, classes: [KeyClass: Int] = [:], rows: [Int: Int] = [:], perKey: Set<Int> = [],
                releaseGeneric: Int = 0, releaseClasses: [KeyClass: Int] = [:]) {
        self.generic = generic; self.classes = classes; self.rows = rows; self.perKey = perKey
        self.releaseGeneric = releaseGeneric; self.releaseClasses = releaseClasses
    }

    /// The pack has at least one press sample a key can fall back on.
    public var hasPresses: Bool { generic > 0 || !perKey.isEmpty || rows.values.contains { $0 > 0 } }
    public var hasReleases: Bool { releaseGeneric > 0 || releaseClasses.values.contains { $0 > 0 } }
}

public struct KeySoundPlan: Equatable, Sendable {
    /// One decoded recording.
    public enum Source: Hashable, Sendable {
        case generic(Int)
        /// Every variant of a class; the player rotates them (never the same twice in a row).
        case cls(KeyClass)
        case row(Int, Int)
        case perKey(Int)
        case releaseGeneric(Int)
        /// Every release variant of a class, rotated like `cls`.
        case releaseClass(KeyClass)
    }

    /// A recording at a fixed pitch offset (`detune` steps of `centsPerStep`).
    public struct Sound: Hashable, Sendable {
        public var source: Source
        public var detune: Int
        public init(_ source: Source, detune: Int = 0) { self.source = source; self.detune = detune }
    }

    public enum Release: Hashable, Sendable {
        /// The pack's own key-up recording.
        case pack(Sound)
        /// No key-up recordings: a quieter, shorter sound made from this press (`ReleaseSynth`).
        case derived(Sound)
    }

    public struct Voice: Hashable, Sendable {
        public var press: Sound
        public var release: Release
        public var pan: Float
    }

    /// Pitch step of the fallback assignment: 20 cents, so ±3 steps stays within ~±4 %.
    public static let centsPerStep = 20.0
    /// Fallback detune order: neighbours in reading order land on different pitches.
    public static let detuneCycle = [0, 2, -2, 1, -1, 3, -3]

    public static func rate(detune: Int) -> Double { pow(2, Double(detune) * centsPerStep / 1200) }

    /// Indexed by key code 0…127. Codes ≥ 128 are not Mac keyboard keys: they have no voice,
    /// so they never click (and `KeyPairing` never pairs them).
    public let voices: [Voice]

    public func voice(_ keyCode: UInt16) -> Voice? { Int(keyCode) < voices.count ? voices[Int(keyCode)] : nil }

    /// Every distinct sound the plan uses, so the player decodes / detunes each once.
    public var sounds: Set<Sound> {
        var s = Set<Sound>()
        for v in voices {
            s.insert(v.press)
            switch v.release { case .pack(let r): s.insert(r); case .derived(let p): s.insert(p) }
        }
        return s
    }

    /// Precedence for a key's press:
    ///   1. space / enter / backspace (and forward delete, keypad enter) play their class
    ///      recordings when the pack has them;
    ///   2. the key's own recording (`sc<scancode>`, Mechvibes per-key data);
    ///   3. the nearest key that has a real recording (per-key packs, and the class keys above),
    ///      at a fixed pitch offset so it never sounds exactly like the key it borrows from. Wide
    ///      keys and modifiers (`MacKeyboard.bigKeyCodes`) borrow only from wide keys (shift,
    ///      return, space…), other keys only from other keys, so ⌘ never plays a letter and an
    ///      arrow or F-key plays a key near it. A wide key with no wide recording to borrow but
    ///      class recordings (a per-row pack, the synth click) plays the nearest of space / return / delete;
    ///   4. its row's recording (per-row packs), with the key's fixed pitch offset;
    ///   5. the stable fallback: the key's place in reading order picks one of the pack's
    ///      presses (`generic`, or else every per-key and row recording) and a fixed pitch offset,
    ///      so the same key always sounds the same and neighbouring keys differ.
    /// Release: the pack's key-up recordings when it has them (class first, the class of the
    /// sound the press plays, then generic, at the press's pitch offset), otherwise derived from
    /// the key's own press.
    public init(_ inv: PackInventory) {
        let pool: [Source] = inv.generic > 0
            ? (0..<inv.generic).map { .generic($0) }
            : inv.perKey.sorted().map { .perKey($0) } + inv.rows.keys.sorted().flatMap { r in (0..<(inv.rows[r] ?? 0)).map { .row(r, $0) } }

        func stable(_ order: Int, count n: Int) -> (variant: Int, detune: Int) {
            guard n > 0 else { return (0, 0) }
            // Each pass through the pool moves the pitch 3 places along the 7-step cycle: every
            // recording gets all 7 pitches whatever the pool size (3 and 7 share no factor).
            let o = max(0, order)
            return (o % n, KeySoundPlan.detuneCycle[(3 * (o / n) + o % n) % KeySoundPlan.detuneCycle.count])
        }

        /// The key's own real recording, if the pack has one (steps 1–2).
        func own(_ code: Int, _ g: KeyGeometry?) -> Source? {
            let c = KeyEventFilter.keyClass(UInt16(truncatingIfNeeded: code))
            if c != .other, (inv.classes[c] ?? 0) > 0 { return .cls(c) }
            if let sc = g?.scancode, inv.perKey.contains(sc) { return .perKey(sc) }
            return nil
        }

        // Keys on the layout that have a real recording, split by size (step 3 donors). A class
        // recording (space / return / delete) is a big-key sound wherever it sits: forward
        // delete lends it to wide keys only, never to a letter.
        var donors: (big: [(KeyGeometry, Source)], small: [(KeyGeometry, Source)]) = ([], [])
        for g in MacKeyboard.keys {
            guard let src = own(Int(g.keyCode), g) else { continue }
            if case .cls = src { donors.big.append((g, src)) } else if g.big { donors.big.append((g, src)) } else { donors.small.append((g, src)) }
        }
        func nearest(_ g: KeyGeometry, in set: [(KeyGeometry, Source)]) -> Source? {
            var best: (d: Double, order: Int, src: Source)?
            for (k, src) in set {
                let dx = k.x - g.x, dy = Double(k.row - g.row)
                let d = dx * dx + dy * dy
                if best == nil || d < best!.d || (d == best!.d && k.order < best!.order) { best = (d, k.order, src) }
            }
            return best?.src
        }
        /// Never 0: a borrowed recording is always a little off its donor's pitch.
        func borrowedDetune(_ order: Int) -> Int {
            let c = KeySoundPlan.detuneCycle
            return c[1 + max(0, order) % (c.count - 1)]
        }

        func press(_ code: Int, _ g: KeyGeometry?) -> Sound {
            if let src = own(code, g) { return Sound(src) }
            let order = g?.order ?? (1000 + code)
            if let g {
                if let borrowed = nearest(g, in: g.big ? donors.big : donors.small) { return Sound(borrowed, detune: borrowedDetune(order)) }
                if let n = inv.rows[g.row], n > 0 {
                    let (v, d) = stable(order, count: n)
                    return Sound(.row(g.row, v), detune: d)
                }
            }
            if pool.isEmpty { return Sound(.generic(0)) }   // no presses at all: the player falls back to the synth
            let (v, d) = stable(order, count: pool.count)
            return Sound(pool[v], detune: d)
        }

        func release(_ code: Int, _ g: KeyGeometry?, _ p: Sound) -> Release {
            // The class of the sound the press plays (a shift borrowing space releases like
            // space), else the key's own.
            let c: KeyClass
            if case .cls(let k) = p.source { c = k } else { c = KeyEventFilter.keyClass(UInt16(truncatingIfNeeded: code)) }
            if c != .other, (inv.releaseClasses[c] ?? 0) > 0 { return .pack(Sound(.releaseClass(c), detune: p.detune)) }
            if inv.releaseGeneric > 0 {
                let (v, _) = stable(g?.order ?? (1000 + code), count: inv.releaseGeneric)
                return .pack(Sound(.releaseGeneric(v), detune: p.detune))
            }
            return .derived(p)
        }

        voices = (0..<128).map { code in
            let g = MacKeyboard.geometry(UInt16(code))
            let p = press(code, g)
            return Voice(press: p, release: release(code, g, p), pan: g.map { StereoPan.pan(x: $0.x) } ?? 0)
        }
    }
}

/// Small sample maths for the plan: fixed per-key pitch offsets and derived releases.
public enum SampleMath {
    /// Plays `s` at `rate` × speed (pitch and length change together, like a varispeed), by
    /// linear interpolation. Rate 1 returns the input unchanged.
    public static func varispeed(_ s: [Float], rate: Double) -> [Float] {
        guard rate.isFinite, rate > 0, abs(rate - 1) > 1e-9, s.count > 1 else { return s }
        let n = max(1, Int(Double(s.count) / rate))
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let pos = Double(i) * rate
            let j = Int(pos)
            guard j < s.count - 1 else { out[i] = s[s.count - 1]; continue }
            let f = Float(pos - Double(j))
            out[i] = s[j] + (s[j + 1] - s[j]) * f
        }
        return out
    }

    public static func peak<C: Sequence>(_ s: C) -> Float where C.Element == Float { s.reduce(0) { max($0, abs($1)) } }
}

/// A key-up for packs that recorded none: the press's attack, a little brighter, much quieter
/// and cut short with a smooth fade. Real switches return with a lighter, higher tick.
public enum ReleaseSynth {
    /// Release level relative to the press (≈ -10 dB).
    public static let gain: Float = 0.32
    /// Kept length of the press's attack.
    public static let length: Double = 0.035
    /// Pitch lift (≈ +1.4 semitones): the upstroke is lighter than the bottom-out.
    public static let rate: Double = 1.08

    /// `pitch` = the press's own pitch offset (a detuned key's release follows it).
    public static func derive(_ press: [Float], sampleRate: Double, pitch: Double = 1) -> [Float] {
        // Only the attack is kept: resample just the head of the press, not all of it.
        let r = rate * pitch
        let want = max(1, Int(length * sampleRate))
        let bright = SampleMath.varispeed(Array(press.prefix(Int(Double(want) * r) + 2)), rate: r)
        let n = min(bright.count, want)
        guard n > 0 else { return [] }
        var out = Array(bright[0..<n])
        let fade = max(1, n / 2)
        for i in 0..<n {
            // Flat for the first half, then a raised-cosine fade to silence.
            let k = i - (n - fade)
            let env: Float = k < 0 ? 1 : Float(0.5 * (1 + cos(Double.pi * Double(k + 1) / Double(fade))))
            out[i] *= gain * env
        }
        return out
    }
}

/// Pairs key-ups with the presses that clicked, in memory only (held-keys bits and the pack
/// generation each press played from; no history).
/// - auto-repeat never makes a press (holding a key = one click),
/// - key codes outside 0…127 are not keys Navi plays: no press, no release,
/// - a press counts as sounded only once the player has actually scheduled it
///   (`pressSounded`): no engine, a pack still loading, or a failed schedule = no release,
/// - a release plays only from the pack generation its press played from: a key held across
///   a profile switch releases silently instead of with the new pack,
/// - `reset()` (feature off, event tap disabled by the system) forgets every held key; a key
///   still down then needs a fresh key-down before it can release,
/// - a fresh key-down for a key still marked down (its key-up was missed) is a new press, not
///   a stacked one: still one entry, one release.
public struct KeyPairing: Sendable {
    public static let keyCount = 128

    private var down: (UInt64, UInt64) = (0, 0)
    private var sounded: (UInt64, UInt64) = (0, 0)
    private var generation = [UInt32](repeating: 0, count: KeyPairing.keyCount)

    public init() {}

    /// A key-down. True = a fresh press the caller may try to play. Repeats and codes ≥ 128
    /// return false and change nothing. The press is not sounded until `pressSounded`.
    public mutating func keyDown(_ code: UInt16, isRepeat: Bool) -> Bool {
        guard !isRepeat, code < KeyPairing.keyCount else { return false }
        set(&down, code, true)
        set(&sounded, code, false)
        return true
    }

    /// The player scheduled this key's press, from pack `generation`.
    public mutating func pressSounded(_ code: UInt16, generation g: UInt32) {
        guard code < KeyPairing.keyCount, get(down, code) else { return }
        set(&sounded, code, true)
        generation[Int(code)] = g
    }

    /// A key-up. True = play the release: its press sounded, from the same pack generation, and
    /// nothing has released or reset it since. Always clears the key.
    public mutating func keyUp(_ code: UInt16, generation g: UInt32) -> Bool {
        guard code < KeyPairing.keyCount, get(down, code) else { return false }
        let play = get(sounded, code) && generation[Int(code)] == g
        set(&down, code, false)
        set(&sounded, code, false)
        return play
    }

    /// Forget every held key.
    public mutating func reset() { down = (0, 0); sounded = (0, 0) }

    public var heldCount: Int { down.0.nonzeroBitCount + down.1.nonzeroBitCount }

    private func get(_ b: (UInt64, UInt64), _ c: UInt16) -> Bool {
        c < 64 ? b.0 & (1 << UInt64(c)) != 0 : b.1 & (1 << UInt64(c - 64)) != 0
    }

    private func set(_ b: inout (UInt64, UInt64), _ c: UInt16, _ on: Bool) {
        if c < 64 {
            let m: UInt64 = 1 << UInt64(c); b.0 = on ? b.0 | m : b.0 & ~m
        } else {
            let m: UInt64 = 1 << UInt64(c - 64); b.1 = on ? b.1 | m : b.1 & ~m
        }
    }
}

/// "Is someone on a call?" without asking for microphone permission: CoreAudio says which
/// processes are running audio input and which devices are running at all. A process counts
/// only when it is not Navi, its input is running, AND one of its input devices is actually
/// running. That second check matters: Siri's listener (`corespeechd`) reports input running
/// all the time on Apple silicon, with no device in use (it listens on the always-on processor).
public enum MicActivity {
    public struct Process: Equatable, Sendable {
        public var pid: Int32
        public var runningInput: Bool
        public var inputDevices: [UInt32]
        public init(pid: Int32, runningInput: Bool, inputDevices: [UInt32]) {
            self.pid = pid; self.runningInput = runningInput; self.inputDevices = inputDevices
        }
    }

    public static func inUse(_ processes: [Process], runningDevices: Set<UInt32>, selfPID: Int32) -> Bool {
        processes.contains { p in
            p.pid != selfPID && p.runningInput && p.inputDevices.contains { runningDevices.contains($0) }
        }
    }
}
