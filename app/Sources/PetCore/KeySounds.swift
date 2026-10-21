import Foundation

// Typing sounds (a TapNoise-style click for every key press, anywhere) and the typing-speed
// meter. Everything here is pure; the event tap and the audio engine live in the AppKit target.
//
// PRIVACY: which key was pressed is never stored, logged or sent. The key code
// is used in memory only: as an index into the sound plan precomputed at pack load (the key's
// own sound and its stereo position, `KeySoundPlan`), and in the held-keys set (a bit per key) that
// pairs a key-up with its press (`KeyPairing`). The WPM math gets a bare timestamp. Nothing
// persisted carries a key: `TypingStats` holds counts and durations only, and `KeyPrivacyTests`
// proves the saved bytes are identical whichever keys were typed.

/// The coarse kind of a key: space, enter and backspace keep their own sounds. Not Codable on purpose.
public enum KeyClass: CaseIterable, Sendable {
    case other, space, enter, backspace

    /// File-name prefix of this class's samples in a pack folder (`key-01.wav`, `space-01.wav`).
    public var filePrefix: String {
        switch self {
        case .other: return "key"
        case .space: return "space"
        case .enter: return "enter"
        case .backspace: return "backspace"
        }
    }
}

/// Turns a raw key-down into what the WPM meter may use, and drops what it must not react to.
public enum KeyEventFilter {
    // macOS virtual key codes (Carbon `kVK_*`), so PetCore needs no Carbon import.
    static let space: UInt16 = 49, returnKey: UInt16 = 36, keypadEnter: UInt16 = 76
    static let delete: UInt16 = 51, forwardDelete: UInt16 = 117

    public struct Press: Equatable, Sendable {
        public var keyClass: KeyClass
        /// False for shortcuts (⌘ / ⌃ held): they click but are not typing.
        public var countsAsTyping: Bool
    }

    /// nil = ignore (auto-repeat while a key is held: no click, no count).
    public static func press(keyCode: UInt16, isRepeat: Bool, command: Bool, control: Bool) -> Press? {
        if isRepeat { return nil }
        return Press(keyClass: keyClass(keyCode), countsAsTyping: !command && !control)
    }

    public static func keyClass(_ keyCode: UInt16) -> KeyClass {
        switch keyCode {
        case space: return .space
        case returnKey, keypadEnter: return .enter
        case delete, forwardDelete: return .backspace
        default: return .other
        }
    }
}

/// What the user sets: on/off (OFF until turned on), profile, volume, quiet on calls
/// (ON by default). One JSON blob under one defaults key, like the look & behaviour config.
public struct KeySoundSettings: Codable, Equatable, Sendable {
    public var enabled: Bool = false
    /// Pack id; nil = the first available pack (`SoundPackLibrary.resolve`).
    public var profile: String? = nil
    /// 0…1.
    public var volume: Double = 0.5
    /// No clicks while any app is using a microphone (`MicActivity`).
    public var quietOnCalls: Bool = true

    public init(enabled: Bool = false, profile: String? = nil, volume: Double = 0.5, quietOnCalls: Bool = true) {
        self.enabled = enabled; self.profile = profile; self.volume = KeySoundSettings.clamp(volume); self.quietOnCalls = quietOnCalls
    }

    private enum CodingKeys: String, CodingKey { case enabled, profile, volume, quietOnCalls }

    /// Every field optional, so settings saved before a field existed keep the rest (a blob from
    /// before *Quiet on calls* stays on, with quiet on calls defaulting on).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
                  profile: try c.decodeIfPresent(String.self, forKey: .profile),
                  volume: try c.decodeIfPresent(Double.self, forKey: .volume) ?? 0.5,
                  quietOnCalls: try c.decodeIfPresent(Bool.self, forKey: .quietOnCalls) ?? true)
    }

    public static func clamp(_ v: Double) -> Double { v.isFinite ? min(1, max(0, v)) : 0.5 }

    public static let prefsKey = "keySounds"

    /// Missing or unreadable → defaults (off). Never throws.
    public init(store: StringStore) {
        guard let s = store.string(forKey: KeySoundSettings.prefsKey),
              let v = try? JSONDecoder().decode(KeySoundSettings.self, from: Data(s.utf8)) else { self.init(); return }
        self.init(enabled: v.enabled, profile: v.profile, volume: v.volume, quietOnCalls: v.quietOnCalls)
    }

    public func save(to store: StringStore) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        store.set(String(decoding: data, as: UTF8.self), forKey: KeySoundSettings.prefsKey)
    }
}

/// The two UserDefaults calls the typing feature needs (JSON strings), so tests can use a dictionary.
public protocol StringStore {
    func string(forKey key: String) -> String?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: StringStore {}

/// When a click is allowed to play. The Typing sounds toggle alone
/// controls clicks. The master Sound switch (agent chimes) and a hidden Navi do NOT mute them;
/// both are taken here only so the tests pin that down. The listener (and WPM) runs whenever
/// the feature is on. Asleep is not a mute either: she naps on her own after 10 quiet minutes.
/// The one other mute is *Quiet on calls*: while it is on and a microphone is in
/// use, no clicks (WPM still counts).
public enum KeySoundGate {
    public static func shouldPlay(enabled: Bool, soundOn: Bool, hidden: Bool, quietOnCalls: Bool, micInUse: Bool) -> Bool {
        enabled && !(quietOnCalls && micInUse)
    }
}

/// Round-robin voices: the next press takes the voice that started longest ago, so fast typing
/// overlaps clicks instead of cutting each one off, and a burst never needs more voices.
/// `count` is the number of voices that actually exist (engine setup can fail part-way); with
/// none, `take()` returns nil and nothing plays.
public struct VoicePool: Sendable {
    public let count: Int
    private var next = 0
    public init(count: Int) { self.count = max(0, count) }
    public mutating func take() -> Int? {
        guard count > 0 else { return nil }
        defer { next = (next + 1) % count }
        return next
    }
}

/// Which pack load is current. Decoding runs off the main thread; a profile switch while one
/// pack is still decoding must not let the older result land after the newer one.
public struct PackLoadTracker: Sendable {
    public struct Ticket: Equatable, Sendable { let generation: Int }
    private var generation = 0
    /// The pack last asked for (may still be decoding).
    public private(set) var requestedID: String?
    /// The pack whose buffers are live.
    public private(set) var loadedID: String?

    public init() {}

    public mutating func request(_ id: String) -> Ticket {
        generation += 1
        requestedID = id
        return Ticket(generation: generation)
    }

    /// True = this result is the newest request: swap it in. `loadedID` can differ from the
    /// requested id (a pack that does not decode lands as the synth click).
    public mutating func complete(_ t: Ticket, loadedID id: String) -> Bool {
        guard t.generation == generation else { return false }
        loadedID = id
        return true
    }
}

/// Picks a sample variant for a sound slot that has several (space, enter, backspace), never the
/// same one twice in a row (sounds less robotic).
public struct VariantPicker {
    private var last: [Int: Int] = [:]
    public init() {}
    public mutating func pick<R: RandomNumberGenerator>(_ c: Int, count: Int, using rng: inout R) -> Int {
        guard count > 1 else { return 0 }
        var i = Int.random(in: 0..<(count - 1), using: &rng)
        if let l = last[c], i >= l { i += 1 }
        last[c] = i
        return i
    }
}

/// Cuts leading and trailing near-silence off a sample: leading silence is latency, trailing
/// silence holds a voice for nothing (some packs ship 1 s files for a 60 ms click).
public enum SampleTrim {
    /// ~-50 dBFS.
    public static let threshold: Float = 0.003

    /// The range to keep, with a small pre-roll before the first loud sample and a tail after
    /// the last. Empty when the whole sample is silent.
    public static func range<C: RandomAccessCollection>(_ s: C, sampleRate: Double, threshold: Float = threshold,
                                                        preRoll: Double = 0.002, tail: Double = 0.03) -> Range<Int>
        where C.Element == Float, C.Index == Int {
        guard let first = s.firstIndex(where: { abs($0) > threshold }),
              let last = s.lastIndex(where: { abs($0) > threshold }) else { return 0..<0 }
        let lo = max(0, first - Int(preRoll * sampleRate))
        let hi = min(s.count, last + 1 + Int(tail * sampleRate))
        return lo..<hi
    }
}

/// The built-in profile: a synthesized click, so the feature works with no packs fetched.
/// Deterministic (seeded noise) so the samples are testable.
public enum SynthClick {
    public static let variants = 4

    public static func samples(_ c: KeyClass, variant: Int, sampleRate: Double = 44_100) -> [Float] {
        // (body pitch Hz, length s, gain)
        let (pitch, length, gain): (Double, Double, Double) = {
            switch c {
            case .other: return (2400 + Double(variant) * 140, 0.035, 0.5)
            case .space: return (900 + Double(variant) * 60, 0.06, 0.55)
            case .enter: return (1300 + Double(variant) * 80, 0.055, 0.55)
            case .backspace: return (1900 + Double(variant) * 100, 0.04, 0.45)
            }
        }()
        let n = Int(length * sampleRate)
        var seed = UInt64(0x9E37_79B9_7F4A_7C15) &+ UInt64(variant) &* 0x100_0000_01B3 &+ UInt64(pitch)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Double(Int64(bitPattern: seed >> 1) % 2001) / 1000 - 1
            let click = exp(-t / 0.002) * noise                     // 2 ms noise transient
            let body = exp(-t / (length / 4)) * sin(2 * .pi * pitch * t) // short pitched decay
            out[i] = Float(gain * (0.6 * click + 0.4 * body))
        }
        return out
    }
}
