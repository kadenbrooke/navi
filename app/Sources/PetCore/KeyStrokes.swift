import Foundation

// Every physical key clicks, not only the ones macOS reports as key presses (2026-10-21).
// A modifier on its own (shift, ⌃, ⌥, ⌘, fn, caps lock) arrives as a flag change; the top row of
// a MacBook in its default media mode (brightness, volume, play…) arrives as a system-defined
// event, sometimes beside a legacy key code (mute = 74); and a few top-row keys (Mission Control,
// Spotlight, Dictation…) as key codes past 127. This turns every representation of a physical key
// into that one key going down or up, so each press makes exactly one press and one release.
//
// PRIVACY: same rule as KeySounds.swift. A key code is used in the moment to pick a sound and
// placement. The only state is, for the modifier / caps lock / top-row keys routed here, the
// current press of each (held or not, a generation number) and, for the last `duplicateWindow`
// (30 ms) only, which sources reported its down and up and when, to tell a second report of one
// press from a new press; and whether caps lock is locked. Ordinary keys leave nothing here.
// Nothing is stored, logged or sent.

/// One physical key (code 0…127) going down or up.
public enum KeyStroke: Equatable, Sendable {
    case down(UInt16)
    case up(UInt16)
    /// The key went up while Navi was not told (an event lost to the system): forget its press
    /// without a sound. A release played late would be a stray click.
    case lost(UInt16)
}

/// Where a report of a key came from. Two reports of one press come from two different
/// sources (a media event and a key code, a flag change and the globe code); one source never
/// reports a press twice.
public enum KeySource: Equatable, Sendable {
    case keyCode(UInt16)
    case flags
    /// A media event, by its NX key type (F9's next and fast-forward are two reports).
    case media(Int)
    /// Navi's own timed caps lock release (macOS sends caps lock no key-up).
    case timer
}

/// Event time in seconds on the uptime clock (`ProcessInfo.systemUptime`, `NSEvent.timestamp`).
/// `CGEvent.timestamp` is documented as nanoseconds but is mach absolute time on some Macs
/// (Apple silicon: 125/3 ns per tick), so the reading that lands on the current uptime wins.
public enum EventClock {
    /// `timestamp` = the event's raw value, `nowNanos` = the uptime clock now (CLOCK_UPTIME_RAW),
    /// `numer`/`denom` = the mach timebase. A zero timestamp (a synthetic event) reads as now.
    public static func seconds(timestamp: UInt64, nowNanos: UInt64, numer: UInt32, denom: UInt32) -> TimeInterval {
        let now = Double(nowNanos)
        guard timestamp > 0, denom > 0 else { return now / 1e9 }
        let asNanos = Double(timestamp), asTicks = Double(timestamp) * Double(numer) / Double(denom)
        let best = abs(asNanos - now) <= abs(asTicks - now) ? asNanos : asTicks
        return best / 1e9
    }
}

/// Pure decoding of the raw tap fields; no state.
public enum KeyTap {
    public static let capsLock: UInt16 = 57
    /// CGEventFlags.maskAlphaShift: caps lock is locked.
    public static let alphaShift: UInt64 = 0x10000

    // CGEventFlags: the generic modifier masks, and the per-side (device-dependent) bits
    // from IOLLEvent.h (NX_DEVICELSHIFTKEYMASK …).
    static let shift: UInt64 = 0x20000, control: UInt64 = 0x40000, option: UInt64 = 0x80000
    static let command: UInt64 = 0x10_0000, fn: UInt64 = 0x80_0000

    /// Modifier key code → (its own per-side bit, all per-side bits of its kind, generic mask).
    static let modifiers: [UInt16: (side: UInt64, kind: UInt64, generic: UInt64)] = [
        56: (0x02, 0x06, shift), 60: (0x04, 0x06, shift),            // left / right shift
        59: (0x01, 0x2001, control), 62: (0x2000, 0x2001, control),  // left / right ⌃
        58: (0x20, 0x60, option), 61: (0x40, 0x60, option),          // left / right ⌥
        55: (0x08, 0x18, command), 54: (0x10, 0x18, command),        // left / right ⌘
        63: (0, 0, fn),                                              // fn / globe
    ]
    static let modifierCodes: [UInt16] = modifiers.keys.sorted()

    /// Whether the modifier `keyCode` is down according to `flags` (any event's flags: a flag
    /// change, or a key-down). nil = not a modifier (caps lock is a lock, see `KeyStrokeRouter`).
    /// The per-side bit decides when the keyboard sets them, so releasing left shift while right
    /// shift is held reads as up; otherwise the generic mask does.
    public static func modifierIsDown(keyCode: UInt16, flags: UInt64) -> Bool? {
        guard let m = modifiers[keyCode] else { return nil }
        if m.side != 0, flags & m.kind != 0 { return flags & m.side != 0 }
        return flags & m.generic != 0
    }

    public static let fKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]   // F1–F12

    /// The keys `KeyStrokeRouter` tracks itself: modifiers, caps lock, and F1–F12, the keys macOS
    /// may report twice (a media event and a key code) or not as key presses at all.
    public static let routedKeys: Set<UInt16> = Set(modifiers.keys).union([capsLock]).union(fKeys)

    /// NX_SUBTYPE_AUX_CONTROL_BUTTONS: the system-defined events media keys send.
    public static let auxControlSubtype = 8

    /// Media key (NX_KEYTYPE_*) → the MacBook top-row key it is printed on. Left out on purpose:
    /// caps lock (4) and num lock (10), whose own events click; the arrow and help reports (8, 9,
    /// 5), whose key codes click; power, contrast, mirroring and the light toggle, which no
    /// current Mac keyboard has as a key.
    static let mediaKeys: [Int: UInt16] = [
        3: 122, 2: 120,          // brightness down / up: F1, F2
        13: 118,                 // launch panel (Launchpad): F4
        22: 96, 21: 97,          // keyboard light down / up: F5, F6
        18: 98, 20: 98,          // previous / rewind: F7
        16: 100,                 // play: F8
        17: 101, 19: 101,        // next / fast-forward: F9
        7: 109, 1: 103, 0: 111,  // mute, volume down / up: F10, F11, F12
        14: 111,                 // eject (older keyboards, right of F12)
    ]

    /// A system-defined event's subtype and data1: the physical key, down or up, auto-repeat.
    /// nil = not a media key.
    public static func mediaKey(subtype: Int, data1: Int) -> (keyCode: UInt16, type: Int, down: Bool, isRepeat: Bool)? {
        let type = (data1 >> 16) & 0xFFFF
        guard subtype == auxControlSubtype, let code = mediaKeys[type] else { return nil }
        let state = (data1 >> 8) & 0xFF
        guard state == 0x0A || state == 0x0B else { return nil }
        return (code, type, state == 0x0A, data1 & 0x1 != 0)
    }

    /// Key codes that stand for another key: the legacy volume codes (the same physical keys as
    /// the media events above) and the codes past 127 that Apple keyboards send for top-row keys.
    static let aliases: [UInt16: UInt16] = [
        74: 109, 73: 103, 72: 111,   // mute, volume down / up: F10, F11, F12
        160: 99,                     // Mission Control: F3
        131: 118, 177: 118,          // Launchpad / Spotlight: F4
        176: 96,                     // Dictation: F5
        178: 97,                     // Do Not Disturb: F6
        179: 63,                     // globe: fn
    ]

    /// The physical key a key-down / key-up code stands for: the alias above, else itself below
    /// 128, nil for anything else.
    public static func physicalKey(_ keyCode: UInt16) -> UInt16? {
        if let a = aliases[keyCode] { return a }
        return keyCode < 128 ? keyCode : nil
    }
}

/// Turns the tap's key-downs, key-ups, flag changes and media-key events into `KeyStroke`s,
/// one down and one up per physical press. Times are the events' own timestamps (`EventClock`),
/// so a slow callback (the audio engine waking) never moves two reports of one press apart.
///
/// Ordinary keys pass straight through (`KeyPairing` keeps its rules for them). Every routed key
/// (`KeyTap.routedKeys`: modifiers, caps lock, F1–F12), whichever way macOS reports it (key code,
/// flag change, media event), goes through one model, the **logical press**: a generation number,
/// whether it is still down, and, for `duplicateWindow` only, which sources reported its down and
/// its up, and when.
/// - A down is a second report of the current press's down (dropped) only when another source
///   reported that same down within the window. Anything else starts a new press: a source that
///   already reported this down (down, up, down from one source is two presses however fast), a
///   down after the window, or a down with no press to join. A down can never join an earlier up.
/// - An up releases the press if it is down (the first up wins, from any source); an up from
///   another source within the window of that release is its twin (dropped); any other up is
///   stray. An up can never join a down.
/// - A new press while the previous one is still down (its up was lost) forgets the old one
///   (`.lost`, no sound) before it plays.
/// - Every flag change and key-down carries the live modifier flags: a modifier still down here
///   whose flag is gone went up unseen (`.lost`), and caps lock's lock state is resynced.
/// - Caps lock: a flag change that changes the lock state is a down from the flags source; one
///   that does not (macOS reporting the key-up too) is nothing. A key code 57, if a keyboard sends
///   one, is just another source of the same press. macOS sends caps lock no key-up, so the caller
///   releases every caps press `capsReleaseDelay` later (`releaseCaps`, by generation).
/// - Auto-repeat never makes a stroke; in a shortcut each key is its own press (⌘C: ⌘ once, C once).
public struct KeyStrokeRouter: Sendable {
    public static let capsReleaseDelay: TimeInterval = 0.09
    /// Two reports of one press carry (nearly) the same event time; a real re-press of the same
    /// key takes far longer than this.
    public static let duplicateWindow: TimeInterval = 0.03

    private struct LogicalPress: Sendable {
        var generation: UInt32
        var down: Bool
        /// Sources that reported this press's down / up, while the window lasts (then emptied).
        var downSources: [KeySource]
        var downAt: TimeInterval
        var upSources: [KeySource] = []
        var upAt: TimeInterval = -.infinity
    }

    /// The current press of each routed key that has one.
    private var presses: [UInt16: LogicalPress] = [:]
    private var lastGeneration: UInt32 = 0
    /// Caps lock's lock state as last reported; nil = not known yet (start, or after a reset).
    private var capsLocked: Bool?

    public init() {}

    /// A key-down from the tap, with the event's flags and time.
    public mutating func keyDown(_ keyCode: UInt16, isRepeat: Bool, flags: UInt64, now: TimeInterval) -> [KeyStroke] {
        var out = reconcile(flags: flags, except: nil)
        syncCaps(flags)
        guard !isRepeat, let code = KeyTap.physicalKey(keyCode) else { return out }
        guard KeyTap.routedKeys.contains(code) else { return out + [.down(code)] }
        out += down(code, from: .keyCode(keyCode), at: now)
        return out
    }

    /// A key-up from the tap.
    public mutating func keyUp(_ keyCode: UInt16, now: TimeInterval) -> [KeyStroke] {
        guard let code = KeyTap.physicalKey(keyCode) else { return [] }
        guard KeyTap.routedKeys.contains(code) else { return [.up(code)] }
        return up(code, from: .keyCode(keyCode), at: now)
    }

    /// A flag change from the tap.
    public mutating func flagsChanged(keyCode: UInt16, flags: UInt64, now: TimeInterval) -> [KeyStroke] {
        if keyCode == KeyTap.capsLock {
            let out = reconcile(flags: flags, except: nil)
            let locked = flags & KeyTap.alphaShift != 0
            guard capsLocked != locked else { return out }   // the lock did not change: not a press
            capsLocked = locked
            return out + down(keyCode, from: .flags, at: now)
        }
        var out = reconcile(flags: flags, except: keyCode)
        syncCaps(flags)
        guard let isDown = KeyTap.modifierIsDown(keyCode: keyCode, flags: flags) else { return out }
        out += isDown ? down(keyCode, from: .flags, at: now) : up(keyCode, from: .flags, at: now)
        return out
    }

    /// A media-key event from the tap.
    public mutating func mediaKey(subtype: Int, data1: Int, now: TimeInterval) -> [KeyStroke] {
        guard let m = KeyTap.mediaKey(subtype: subtype, data1: data1) else { return [] }
        if m.down { return m.isRepeat ? [] : down(m.keyCode, from: .media(m.type), at: now) }
        return up(m.keyCode, from: .media(m.type), at: now)
    }

    /// The generation of `key`'s current press (the caller's caps release timer carries it).
    public func generation(of key: UInt16) -> UInt32? { presses[key]?.generation }

    /// Caps lock's timed release, for the press of `generation`: nothing when that press was
    /// already released, replaced by a newer press, or reset.
    public mutating func releaseCaps(generation g: UInt32, now: TimeInterval) -> [KeyStroke] {
        guard presses[KeyTap.capsLock]?.generation == g else { return [] }
        return up(KeyTap.capsLock, from: .timer, at: now)
    }

    /// Ends the duplicate window for reports older than it at `now`: their sources and times are
    /// dropped (a released press is forgotten entirely; a held one keeps only that it is held).
    public mutating func expire(now: TimeInterval) {
        for (k, p) in presses {
            let last = max(p.downAt, p.upAt)
            guard now - last >= KeyStrokeRouter.duplicateWindow else { continue }
            if p.down {
                if !p.downSources.isEmpty { presses[k] = LogicalPress(generation: p.generation, down: true, downSources: [], downAt: -.infinity) }
            } else {
                presses[k] = nil
            }
        }
    }

    /// Presses still carrying report sources or times (none once `expire` has run past the window).
    public var pendingReports: Int { presses.values.filter { !$0.downSources.isEmpty || !$0.down }.count }

    /// Forget everything (tap disabled by the system, feature off): every press, its reports, the
    /// caps lock state; a pending caps release then finds nothing.
    public mutating func reset() {
        presses.removeAll()
        capsLocked = nil
    }

    public var heldCount: Int { presses.values.filter(\.down).count }

    // MARK: the logical press

    private mutating func down(_ k: UInt16, from s: KeySource, at t: TimeInterval) -> [KeyStroke] {
        if var p = presses[k], !p.downSources.isEmpty, !p.downSources.contains(s), abs(t - p.downAt) < KeyStrokeRouter.duplicateWindow {
            p.downSources.append(s)   // another report of this same down
            presses[k] = p
            return []
        }
        var out: [KeyStroke] = []
        if presses[k]?.down == true { out.append(.lost(k)) }   // its up never came: forget it, no sound
        lastGeneration &+= 1
        presses[k] = LogicalPress(generation: lastGeneration, down: true, downSources: [s], downAt: t)
        out.append(.down(k))
        return out
    }

    private mutating func up(_ k: UInt16, from s: KeySource, at t: TimeInterval) -> [KeyStroke] {
        guard var p = presses[k] else { return [] }
        if p.down {
            p.down = false; p.upSources = [s]; p.upAt = t
            presses[k] = p
            return [.up(k)]
        }
        if !p.upSources.isEmpty, !p.upSources.contains(s), abs(t - p.upAt) < KeyStrokeRouter.duplicateWindow {
            p.upSources.append(s)     // another report of this same up
            presses[k] = p
        }
        return []
    }

    /// Modifiers still down here whose flag is gone: they went up unseen.
    private mutating func reconcile(flags: UInt64, except: UInt16?) -> [KeyStroke] {
        var out: [KeyStroke] = []
        for m in KeyTap.modifierCodes where m != except && presses[m]?.down == true && KeyTap.modifierIsDown(keyCode: m, flags: flags) == false {
            presses[m] = nil
            out.append(.lost(m))
        }
        return out
    }

    private mutating func syncCaps(_ flags: UInt64) { capsLocked = flags & KeyTap.alphaShift != 0 }
}
