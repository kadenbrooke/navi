import XCTest
@testable import PetCore

/// Every physical key makes a sound, and the profile picker stars the packs that recorded every
/// key (2026-10-21).
final class AllKeysTests: XCTestCase {
    // MARK: the keyboard

    let modifiers: [UInt16] = [56, 60, 59, 62, 58, 61, 55, 54, 63, 57]          // ⇧ ⇧ ⌃ ⌃ ⌥ ⌥ ⌘ ⌘ fn ⇪
    let arrows: [UInt16] = [123, 124, 125, 126]
    let fKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]  // F1–F12
    let fKeysFullSize: [UInt16] = [105, 107, 113, 106, 64, 79, 80, 90]           // F13–F20
    let keypad: [UInt16] = [65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
    let punctuation: [UInt16] = [50, 27, 24, 33, 30, 42, 41, 39, 43, 47, 44]     // ` - = [ ] \ ; ' , . /
    let numberRow: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
    let letters: [UInt16] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
    let nav: [UInt16] = [114, 115, 116, 117, 119, 121]                           // help home pgup ⌦ end pgdn
    let others: [UInt16] = [53, 48, 36, 51, 49, 10, 93, 94, 95, 102, 104, 110]  // esc tab ⏎ ⌫ space § JIS menu

    var standardKeys: [UInt16] {
        modifiers + arrows + fKeys + fKeysFullSize + keypad + punctuation + numberRow + letters + nav + others
    }

    func testEveryStandardKeyIsOnTheLayoutWithAPlace() {
        XCTAssertEqual(letters.count, 26)
        XCTAssertEqual(Set(standardKeys).count, standardKeys.count)
        for code in standardKeys {
            XCTAssertNotNil(MacKeyboard.geometry(code), "key \(code) has a place on the keyboard")
        }
        XCTAssertEqual(Set(MacKeyboard.keys.map(\.keyCode)), Set(standardKeys), "and nothing else is")
    }

    // MARK: every style, every key

    /// Each style's data, as the fetch script installs it (see keysounds/README.md).
    static let thockScancodes: Set<Int> = Set(Array(1...69) + [78, 87, 88, 3640, 3655, 3657, 3663, 3665, 3666, 3675, 3676, 57416, 57419, 57421, 57424])
    static let partialScancodes: Set<Int> = Set(Array(15...27) + Array(30...38) + Array(44...50))
    let styles: [(String, PackInventory)] = [
        ("thock per-key", PackInventory(generic: 5, classes: [.space: 1, .enter: 1, .backspace: 1], perKey: thockScancodes)),
        ("partial per-key", PackInventory(classes: [.space: 1, .enter: 1, .backspace: 1], perKey: partialScancodes)),
        ("per-row", PackInventory(classes: [.space: 1, .enter: 1, .backspace: 1], rows: [0: 1, 1: 1, 2: 1, 3: 1, 4: 1],
                                releaseGeneric: 1, releaseClasses: [.space: 1, .enter: 1, .backspace: 1])),
        ("per-row, rows only", PackInventory(rows: [0: 1, 1: 1, 2: 1, 3: 1, 4: 1], releaseGeneric: 1)),
        ("a pack missing a row", PackInventory(rows: [0: 1, 1: 1, 2: 1, 4: 1])),
        ("Cherry KC 1000", PackInventory(generic: 32)),
        ("Old Clicky", PackInventory(generic: 6)),
        // The backup click (also what a pack that fails to decode plays).
        ("synth click", PackInventory(generic: SynthClick.variants,
                                      classes: [.space: SynthClick.variants, .enter: SynthClick.variants, .backspace: SynthClick.variants])),
    ]

    /// The recording a plan sound points at really exists in the pack (so the player has a buffer for it).
    func exists(_ s: KeySoundPlan.Source, in inv: PackInventory) -> Bool {
        switch s {
        case .generic(let i): return i >= 0 && i < inv.generic
        case .cls(let c): return (inv.classes[c] ?? 0) > 0
        case .row(let r, let v): return v >= 0 && v < (inv.rows[r] ?? 0)
        case .perKey(let sc): return inv.perKey.contains(sc)
        case .releaseGeneric(let v): return v >= 0 && v < inv.releaseGeneric
        case .releaseClass(let c): return (inv.releaseClasses[c] ?? 0) > 0
        }
    }

    func testEveryKeyHasAPressAndAReleaseInEveryStyle() {
        for (name, inv) in styles {
            let plan = KeySoundPlan(inv)
            for code in standardKeys {
                guard let v = plan.voice(code) else { XCTFail("\(name): key \(code) has no voice"); continue }
                XCTAssertTrue(exists(v.press.source, in: inv), "\(name): key \(code) press \(v.press) is silent")
                switch v.release {
                case .pack(let r): XCTAssertTrue(exists(r.source, in: inv), "\(name): key \(code) release \(r) is silent")
                case .derived(let p): XCTAssertEqual(p, v.press, "\(name): key \(code) release is made from its own press")
                }
                XCTAssertEqual(v.pan, StereoPan.pan(keyCode: code), "\(name): key \(code) is placed by its column")
            }
        }
    }

    func testModifiersAndWideKeysBorrowABigKey() {
        for (name, inv) in styles {
            let plan = KeySoundPlan(inv)
            for code in MacKeyboard.bigKeyCodes {
                let s = plan.voice(code)!.press.source
                if case .perKey(let sc) = s {
                    let donor = MacKeyboard.keys.first { $0.scancode == sc }!
                    XCTAssertTrue(donor.big, "\(name): wide key \(code) plays a letter-sized key (\(donor.keyCode))")
                }
            }
        }
        // The per-row pack has no shift / ⌘ recordings: they play the nearest of space / return / delete.
        let perRow = KeySoundPlan(styles[2].1)
        XCTAssertEqual(perRow.voice(56)!.press.source, .cls(.space), "left shift → space bar")
        XCTAssertEqual(perRow.voice(55)!.press.source, .cls(.space), "⌘ → space bar")
        XCTAssertEqual(perRow.voice(60)!.press.source, .cls(.enter), "right shift → return, its neighbour")
        XCTAssertNotEqual(perRow.voice(56)!.press.detune, 0, "never exactly the space bar's own sound")
        XCTAssertEqual(perRow.voice(56)!.release, .pack(.init(.releaseClass(.space), detune: perRow.voice(56)!.press.detune)),
                       "and it lets go like the key it borrowed")
        XCTAssertEqual(perRow.voice(49)!.release, .pack(.init(.releaseClass(.space))), "space itself: unchanged")
        guard case .row = perRow.voice(0)!.press.source else { return XCTFail("letters still play their row on a per-row pack") }
        // A per-key pack missing right ⌃ and fn: they borrow the modifier next to them.
        let thock = KeySoundPlan(styles[0].1)
        XCTAssertEqual(thock.voice(62)!.press.source, .perKey(3640), "right ⌃ → right ⌥")
        XCTAssertEqual(thock.voice(63)!.press.source, .perKey(29), "fn → ⌃")
        XCTAssertEqual(thock.voice(56)!.press, .init(.perKey(42)), "left shift has its own recording")
        // The synth click: wide keys get its deep space / return thump.
        let synth = KeySoundPlan(styles.last!.1)
        for code: UInt16 in [56, 60, 48, 57, 59, 58, 55, 54, 61, 62, 63] {
            guard case .cls = synth.voice(code)!.press.source else { XCTFail("synth: wide key \(code) plays a big-key sound"); continue }
        }
    }

    func testArrowsFKeysAndPunctuationBorrowANearbyKey() {
        let inv = styles[1].1   // partial per-key: letters, [ ] and tab only
        let plan = KeySoundPlan(inv)
        let recorded = MacKeyboard.keys.filter { !$0.big && $0.scancode.map(inv.perKey.contains) == true }
        for g in MacKeyboard.keys where !g.big && KeyEventFilter.keyClass(g.keyCode) == .other && g.scancode.map(inv.perKey.contains) != true {
            let p = plan.voice(g.keyCode)!.press
            guard case .perKey(let sc) = p.source, let donor = recorded.first(where: { $0.scancode == sc }) else {
                XCTFail("key \(g.keyCode) borrows a recorded key"); continue
            }
            func d(_ k: KeyGeometry) -> Double { pow(k.x - g.x, 2) + pow(Double(k.row - g.row), 2) }
            XCTAssertEqual(d(donor), recorded.map(d).min()!, accuracy: 1e-9, "key \(g.keyCode) borrows the nearest recorded key")
            XCTAssertNotEqual(p.detune, 0, "key \(g.keyCode) never sounds exactly like its donor")
        }
        XCTAssertEqual(plan.voice(122)!.press.source, .perKey(16), "F1 → Q, the recorded key under it")
        XCTAssertEqual(plan.voice(18)!.press.source, .perKey(16), "1 → Q")
        XCTAssertEqual(plan.voice(41)!.press.source, .perKey(38), "; → L")
    }

    func testKeysWithTheirOwnRecordingAreUnchanged() {
        let plan = KeySoundPlan(styles[0].1)
        for g in MacKeyboard.keys {
            guard let sc = g.scancode, Self.thockScancodes.contains(sc), KeyEventFilter.keyClass(g.keyCode) == .other else { continue }
            XCTAssertEqual(plan.voice(g.keyCode)!.press, .init(.perKey(sc)), "key \(g.keyCode) plays its own recording")
        }
    }

    // MARK: the event path: modifiers, caps lock, media keys

    /// The controller's path: router → pairing (every press schedules) → counts per key. Each
    /// event is 0.1 s after the last unless `dt` says otherwise (a second report of one press
    /// arrives well under a millisecond after the first).
    struct Rig {
        var router = KeyStrokeRouter()
        var pairing = KeyPairing()
        var presses: [UInt16] = [], releases: [UInt16] = [], lost: [UInt16] = []
        var t: TimeInterval = 100
        mutating func apply(_ s: KeyStroke?) {
            switch s {
            case .down(let c)?:
                if pairing.keyDown(c, isRepeat: false) { pairing.pressSounded(c, generation: 1); presses.append(c) }
            case .up(let c)?:
                if pairing.keyUp(c, generation: 1) { releases.append(c) }
            case .lost(let c)?:
                _ = pairing.keyUp(c, generation: 1); lost.append(c)
            case nil: break
            }
        }
        mutating func apply(_ s: [KeyStroke]) { s.forEach { apply($0) } }
        mutating func tick(_ dt: TimeInterval) -> TimeInterval { t += dt; return t }
        mutating func down(_ c: UInt16, repeat r: Bool = false, flags f: UInt64 = 0, dt: TimeInterval = 0.1) {
            apply(router.keyDown(c, isRepeat: r, flags: f, now: tick(dt)))
        }
        mutating func up(_ c: UInt16, dt: TimeInterval = 0.1) { apply(router.keyUp(c, now: tick(dt))) }
        mutating func flags(_ c: UInt16, _ f: UInt64, dt: TimeInterval = 0.1) { apply(router.flagsChanged(keyCode: c, flags: f, now: tick(dt))) }
        mutating func media(_ key: Int, down: Bool, repeat r: Bool = false, dt: TimeInterval = 0.1) {
            apply(router.mediaKey(subtype: 8, data1: key << 16 | (down ? 0x0A : 0x0B) << 8 | (r ? 1 : 0), now: tick(dt)))
        }
        mutating func capsRelease(dt: TimeInterval = 0.09) {
            t += dt; apply(router.releaseCaps(generation: router.generation(of: 57) ?? 0, now: t))
        }
    }

    // CGEventFlags: generic masks and per-side bits; caps lock's lock bit.
    let shiftL: UInt64 = 0x20002, shiftR: UInt64 = 0x20004, ctrlL: UInt64 = 0x40001, ctrlR: UInt64 = 0x42000
    let optL: UInt64 = 0x80020, optR: UInt64 = 0x80040, cmdL: UInt64 = 0x100008, cmdR: UInt64 = 0x100010, fnFlag: UInt64 = 0x800000
    let locked: UInt64 = 0x10000

    func testEachModifierAloneMakesOnePressAndOneRelease() {
        for (code, flag) in [(UInt16(56), shiftL), (60, shiftR), (59, ctrlL), (62, ctrlR), (58, optL), (61, optR), (55, cmdL), (54, cmdR), (63, fnFlag)] {
            var r = Rig()
            r.flags(code, flag)
            XCTAssertEqual(r.presses, [code], "modifier \(code) down: one press")
            XCTAssertEqual(r.releases, [], "no release while it is held")
            r.flags(code, 0x100)  // up (only a non-modifier bit left)
            r.flags(code, 0)      // a stray second up
            XCTAssertEqual(r.presses, [code])
            XCTAssertEqual(r.releases, [code], "modifier \(code) up: one release")
            XCTAssertEqual(r.router.heldCount, 0)
        }
    }

    func testShortcutClicksEachKeyOnce() {
        var r = Rig()
        r.flags(55, cmdL)                                   // ⌘ down
        r.down(8, flags: cmdL); r.down(8, repeat: true, flags: cmdL)   // C, held long enough to repeat
        r.up(8)
        r.flags(55, 0)                                      // ⌘ up
        XCTAssertEqual(r.presses, [55, 8], "⌘C: ⌘ once, C once")
        XCTAssertEqual(r.releases, [8, 55])
        // ⇧⌘4: two modifiers, each its own key.
        var s = Rig()
        s.flags(56, shiftL); s.flags(55, shiftL | cmdL); s.down(21, flags: shiftL | cmdL); s.up(21); s.flags(55, shiftL); s.flags(56, 0)
        XCTAssertEqual(s.presses, [56, 55, 21]); XCTAssertEqual(s.releases, [21, 55, 56])
        XCTAssertEqual(s.lost, [])
    }

    func testLeftAndRightModifiersAreTracked() {
        var r = Rig()
        r.flags(56, shiftL)
        r.flags(60, 0x20006)                               // right shift down too
        r.flags(56, 0x20004)                               // left up, right still held
        XCTAssertEqual(r.presses, [56, 60]); XCTAssertEqual(r.releases, [56], "left shift released, right still down")
        r.flags(60, 0)
        XCTAssertEqual(r.releases, [56, 60])
        // A keyboard that sets no per-side bits: the generic mask decides.
        var g = Rig()
        g.flags(58, 0x80000); g.flags(58, 0)
        XCTAssertEqual(g.presses, [58]); XCTAssertEqual(g.releases, [58])
    }

    // MARK: caps lock

    func testCapsLockPressesOnceAndReleasesItself() {
        var r = Rig()
        r.flags(57, locked)                         // lock on: one flag change, no key-up
        XCTAssertEqual(r.presses, [57])
        let first = r.router.generation(of: 57)!
        r.flags(57, locked, dt: 0.05)               // a report that does not change the lock (key-up): nothing
        XCTAssertEqual(r.presses, [57], "no lock change, no press")
        r.apply(r.router.releaseCaps(generation: first, now: r.tick(0.04)))   // the controller's timed release
        r.apply(r.router.releaseCaps(generation: first, now: r.tick(0.01)))
        XCTAssertEqual(r.releases, [57], "exactly one release")
        r.flags(57, 0)                              // lock off: a new press
        XCTAssertEqual(r.presses, [57, 57])
        XCTAssertEqual(r.router.releaseCaps(generation: first, now: r.tick(0.01)), [], "an older press's timer cannot release a newer press")
        r.capsRelease()
        XCTAssertEqual(r.releases, [57, 57])
    }

    func testCapsLockRapidSecondPressIsNotLost() {
        // Two presses 40 ms apart (faster than the timed release): each toggles the lock, each clicks.
        var r = Rig()
        r.flags(57, locked)
        let first = r.router.generation(of: 57)!
        r.flags(57, 0, dt: 0.04)
        XCTAssertEqual(r.presses, [57, 57], "the second press plays")
        XCTAssertEqual(r.lost, [57], "the first, still waiting for its timed release, is let go silently")
        XCTAssertEqual(r.router.releaseCaps(generation: first, now: r.tick(0.05)), [], "the first press's timer is spent")
        r.capsRelease()
        XCTAssertEqual(r.releases, [57])
        // macOS reporting the lock turning off on key-up instead: the down report changes nothing.
        var u = Rig()
        u.flags(57, locked); u.capsRelease()
        u.flags(57, locked, dt: 0.3)      // second press goes down: still locked
        u.flags(57, 0, dt: 0.1)           // ...and turns off on its key-up
        XCTAssertEqual(u.presses, [57, 57], "one press per physical press either way")
    }

    func testCapsLockAfterResetIsNotLost() {
        var r = Rig()
        r.flags(57, locked); r.capsRelease()
        r.router.reset(); r.pairing.reset()          // tap disabled by the system, re-enabled
        r.flags(57, locked, dt: 0.01)                // a press right after recovery (lock state unknown now)
        XCTAssertEqual(r.presses, [57, 57], "the first press after a reset always counts")
        // The lock state also resyncs from any event's flags: a caps toggle lost while the tap was down.
        var s = Rig()
        s.flags(57, locked); s.capsRelease()
        s.router.reset(); s.pairing.reset()
        s.down(0, flags: 0); s.up(0)                 // a letter: lock is off now
        s.flags(57, locked)                          // next caps press turns it on: a press
        XCTAssertEqual(s.presses, [57, 0, 57])
    }

    // MARK: media keys

    func testMediaKeysClickAsTheirTopRowKey() {
        // (NX key type, F-key it is printed on)
        for (key, fKey) in [(3, UInt16(122)), (2, 120), (13, 118), (22, 96), (21, 97), (18, 98), (16, 100), (17, 101), (7, 109), (1, 103), (0, 111)] {
            var r = Rig()
            r.media(key, down: true); r.media(key, down: true, repeat: true); r.media(key, down: true, repeat: true)
            r.media(key, down: false)
            XCTAssertEqual(r.presses, [fKey], "media key \(key): one press as F-key \(fKey), repeats do not stack")
            XCTAssertEqual(r.releases, [fKey])
        }
        var r = Rig()
        r.media(17, down: true); r.media(19, down: true, dt: 0.001)   // next, then fast-forward on the same key
        r.media(19, down: false); r.media(17, down: false, dt: 0.001)
        XCTAssertEqual(r.presses, [101]); XCTAssertEqual(r.releases, [101])
        XCTAssertEqual(r.router.mediaKey(subtype: 7, data1: 0 << 16 | 0x0A << 8, now: 0), [], "other system-defined subtypes are ignored")
        XCTAssertEqual(r.router.mediaKey(subtype: 8, data1: 4 << 16 | 0x0A << 8, now: 0), [], "caps lock reports here too: its flag change clicks instead")
        XCTAssertEqual(r.router.mediaKey(subtype: 8, data1: 0 << 16 | 0x0C << 8, now: 0), [], "unknown key state")
    }

    /// Every way macOS may report one physical top-row key, mixed: still one press, one release.
    func testMixedMediaReportsCanonicalize() {
        // (media type, legacy / extended key code, F-key)
        let keys: [(Int?, UInt16?, UInt16)] = [(7, 74, 109), (1, 73, 103), (0, 72, 111), (13, 131, 118), (13, 177, 118), (nil, 160, 99), (3, 122, 122), (22, 176, 96), (21, 178, 97)]
        for (media, code, fKey) in keys {
            let orders: [[String]] = [
                ["media↓", "code↓", "code↑", "media↑"],
                ["code↓", "media↓", "media↑", "code↑"],
                ["code↓", "code↑"],                         // old keyboard: the key code alone
                ["media↓", "media↑"],
            ]
            for order in orders where media != nil || !order.contains(where: { $0.hasPrefix("media") }) {
                guard code != nil || !order.contains(where: { $0.hasPrefix("code") }) else { continue }
                var r = Rig()
                for (i, step) in order.enumerated() {
                    let dt = i == 0 ? 0.1 : (step.hasSuffix("↓") && order[i - 1].hasSuffix("↑") ? 0.001 : 0.0005)
                    switch step {
                    case "media↓": r.media(media!, down: true, dt: i == 1 ? 0.0005 : dt)
                    case "media↑": r.media(media!, down: false, dt: order[i - 1] == "media↓" ? 0.08 : 0.0005)
                    case "code↓": r.down(code!, dt: i == 1 ? 0.0005 : dt)
                    default: r.up(code!, dt: order[i - 1] == "code↓" ? 0.08 : 0.0005)
                    }
                }
                XCTAssertEqual(r.presses, [fKey], "\(order) for F-key \(fKey): one press")
                XCTAssertEqual(r.releases, [fKey], "\(order) for F-key \(fKey): one release")
            }
            // The twin handled only after the first source's whole press, but stamped with the
            // press's own event times: still one press.
            if let media, let code {
                var r = Rig()
                r.media(media, down: true); let t = r.t
                r.media(media, down: false, dt: 0.08)
                r.apply(r.router.keyDown(code, isRepeat: false, flags: 0, now: t + 0.0004))
                r.apply(r.router.keyUp(code, now: t + 0.0804))
                XCTAssertEqual(r.presses, [fKey], "late-handled twin for F-key \(fKey): one press")
                XCTAssertEqual(r.releases, [fKey], "late-handled twin for F-key \(fKey): one release")
            }
        }
        // F-keys used as F-keys (fn held, or the standard-function-keys setting) still click.
        var f = Rig()
        f.down(122, flags: fnFlag); f.up(122); f.down(122, flags: fnFlag); f.up(122)
        XCTAssertEqual(f.presses, [122, 122]); XCTAssertEqual(f.releases, [122, 122])
    }

    func testExtendedTopRowCodesMapToTheirKey() {
        for (code, key) in [(UInt16(160), UInt16(99)), (131, 118), (177, 118), (176, 96), (178, 97), (179, 63), (74, 109), (73, 103), (72, 111)] {
            var r = Rig()
            let f: UInt64 = key == 63 ? fnFlag : 0   // the globe key's own events carry the fn flag
            r.down(code, flags: f); r.down(code, repeat: true, flags: f); r.up(code)
            XCTAssertEqual(r.presses, [key], "code \(code) clicks as key \(key)"); XCTAssertEqual(r.releases, [key])
        }
        // The globe key may send both a flag change and a key code: still one click.
        var g = Rig()
        g.flags(63, fnFlag); g.down(179, flags: fnFlag, dt: 0.0005); g.up(179, dt: 0.08); g.flags(63, 0, dt: 0.0005)
        XCTAssertEqual(g.presses, [63]); XCTAssertEqual(g.releases, [63])
        XCTAssertNil(KeyTap.physicalKey(200), "other codes past 127 stay silent")
        var fresh = KeyStrokeRouter()
        XCTAssertEqual(fresh.keyDown(300, isRepeat: false, flags: 0, now: 0), [])
    }

    func testOrdinaryKeysPassStraightThrough() {
        var router = KeyStrokeRouter()
        XCTAssertEqual(router.keyDown(0, isRepeat: false, flags: 0, now: 1), [.down(0)])
        XCTAssertEqual(router.keyDown(0, isRepeat: true, flags: 0, now: 1.1), [], "auto-repeat never makes a stroke")
        XCTAssertEqual(router.keyUp(0, now: 1.2), [.up(0)])
        XCTAssertEqual(router.keyUp(0, now: 1.3), [.up(0)], "pairing, not the router, drops a stray key-up")
        XCTAssertEqual(router.heldCount, 0, "ordinary keys are not held here")
        XCTAssertEqual(router.flagsChanged(keyCode: 0, flags: 0, now: 2), [], "a flag change for a non-modifier is nothing")
    }

    // MARK: twins vs fresh presses (event time, source identity)

    func testSameSourceRapidRepressIsAlwaysTwoPresses() {
        // Down, up, down from one source, 5 ms apart: a genuine fast double tap.
        var k = Rig()
        k.down(122); k.up(122, dt: 0.005); k.down(122, dt: 0.005); k.up(122, dt: 0.005)
        XCTAssertEqual(k.presses, [122, 122], "F1 key code twice: two presses"); XCTAssertEqual(k.releases, [122, 122])
        var m = Rig()
        m.media(7, down: true); m.media(7, down: false, dt: 0.005); m.media(7, down: true, dt: 0.005); m.media(7, down: false, dt: 0.005)
        XCTAssertEqual(m.presses, [109, 109], "mute media event twice: two presses"); XCTAssertEqual(m.releases, [109, 109])
        var f = Rig()
        f.flags(56, shiftL); f.flags(56, 0, dt: 0.005); f.flags(56, shiftL, dt: 0.005); f.flags(56, 0, dt: 0.005)
        XCTAssertEqual(f.presses, [56, 56], "shift flag changes twice: two presses"); XCTAssertEqual(f.releases, [56, 56])
        // One source repeating a down with no up between (its up was lost): still a press.
        var d = Rig()
        d.down(122); d.down(122, dt: 0.002)
        XCTAssertEqual(d.presses, [122, 122])
    }

    func testTwoMixedSourcePressesCloseTogetherAreTwoPresses() {
        // Mute reported as a media event and key code 74. Each press: both downs, held 50 ms, both
        // ups; the second press starts 10 ms after the first ended. A down never joins an earlier up.
        for mediaFirst in [true, false] {
            var r = Rig()
            func downs() {
                if mediaFirst { r.media(7, down: true, dt: 0.01); r.down(74, dt: 0.0004) } else { r.down(74, dt: 0.01); r.media(7, down: true, dt: 0.0004) }
            }
            func ups() {
                if mediaFirst { r.media(7, down: false, dt: 0.05); r.up(74, dt: 0.0004) } else { r.up(74, dt: 0.05); r.media(7, down: false, dt: 0.0004) }
            }
            downs(); ups(); downs(); ups()
            XCTAssertEqual(r.presses, [109, 109], "media first: \(mediaFirst): two presses")
            XCTAssertEqual(r.releases, [109, 109], "media first: \(mediaFirst): two releases")
            XCTAssertEqual(r.lost, [])
            // The second press opening with the other source than the first ended with.
            var x = Rig()
            x.media(7, down: true); x.down(74, dt: 0.0004); x.up(74, dt: 0.05); x.media(7, down: false, dt: 0.0004)
            x.down(74, dt: 0.01); x.media(7, down: true, dt: 0.0004); x.media(7, down: false, dt: 0.05); x.up(74, dt: 0.0004)
            XCTAssertEqual(x.presses, [109, 109]); XCTAssertEqual(x.releases, [109, 109])
        }
        // A quick press (20 ms) and the next 5 ms later: still two.
        var q = Rig()
        q.media(0, down: true); q.down(72, dt: 0.0004); q.media(0, down: false, dt: 0.02); q.up(72, dt: 0.0004)
        q.down(72, dt: 0.005); q.media(0, down: true, dt: 0.0004); q.up(72, dt: 0.02); q.media(0, down: false, dt: 0.0004)
        XCTAssertEqual(q.presses, [111, 111]); XCTAssertEqual(q.releases, [111, 111])
    }

    func testTwinsAreMatchedByEventTimeNotArrival() {
        // The engine wakes on the first click and blocks the main thread ~150 ms, so the twin is
        // *handled* late, but it carries the same event time: still one press.
        var r = Rig()
        r.media(7, down: true)                               // event time t
        let t = r.t
        r.apply(r.router.keyDown(74, isRepeat: false, flags: 0, now: t + 0.0004))   // handled 150 ms later, stamped t + 0.4 ms
        r.apply(r.router.keyUp(74, now: t + 0.08)); r.apply(r.router.mediaKey(subtype: 8, data1: 7 << 16 | 0x0B << 8, now: t + 0.0804))
        XCTAssertEqual(r.presses, [109]); XCTAssertEqual(r.releases, [109])
        // A report from another source whose event time is well apart is a press of its own.
        var s = Rig()
        s.media(7, down: true); s.media(7, down: false, dt: 0.05)
        s.down(74, dt: 0.1); s.up(74, dt: 0.05)
        XCTAssertEqual(s.presses, [109, 109]); XCTAssertEqual(s.releases, [109, 109])
    }

    /// Mute reported as a media event (type 7) or key code 74, at absolute event times.
    func muteEvent(_ r: inout Rig, media: Bool, down: Bool, at t: TimeInterval) {
        if media {
            r.apply(r.router.mediaKey(subtype: 8, data1: 7 << 16 | (down ? 0x0A : 0x0B) << 8, now: t))
        } else if down {
            r.apply(r.router.keyDown(74, isRepeat: false, flags: 0, now: t))
        } else {
            r.apply(r.router.keyUp(74, now: t))
        }
    }

    func testRepressFromTheOtherSourceInsideTheWindowIsANewPress() {
        // A press reported by one source only goes down and up; the next press comes from the
        // other source 25 ms after the first went down (inside the window), after its up.
        for mediaFirst in [true, false] {
            var r = Rig(); let t = r.t
            muteEvent(&r, media: mediaFirst, down: true, at: t)
            muteEvent(&r, media: mediaFirst, down: false, at: t + 0.02)
            muteEvent(&r, media: !mediaFirst, down: true, at: t + 0.025)
            muteEvent(&r, media: !mediaFirst, down: false, at: t + 0.045)
            XCTAssertEqual(r.presses, [109, 109], "media first: \(mediaFirst): the re-press is not a twin")
            XCTAssertEqual(r.releases, [109, 109], "media first: \(mediaFirst)")
            XCTAssertEqual(r.lost, [])
            XCTAssertEqual(r.router.heldCount, 0)
        }
    }

    func testLateUpFromAnEarlierPressNeverReleasesTheNewOne() {
        // Press A is reported by both sources; one source's up releases it; press B starts from
        // the other source; only then is A's second up handled, stamped before B went down.
        for mediaFirst in [true, false] {
            var r = Rig(); let t = r.t
            muteEvent(&r, media: mediaFirst, down: true, at: t)
            muteEvent(&r, media: !mediaFirst, down: true, at: t + 0.0004)
            muteEvent(&r, media: mediaFirst, down: false, at: t + 0.02)           // A released
            muteEvent(&r, media: !mediaFirst, down: true, at: t + 0.025)          // B goes down
            muteEvent(&r, media: !mediaFirst, down: false, at: t + 0.0204)        // A's late twin up
            XCTAssertEqual(r.presses, [109, 109], "media first: \(mediaFirst)")
            XCTAssertEqual(r.releases, [109], "media first: \(mediaFirst): the late up is A's, not B's")
            XCTAssertEqual(r.router.heldCount, 1, "B is still held")
            muteEvent(&r, media: mediaFirst, down: true, at: t + 0.0254)          // B's twin down
            muteEvent(&r, media: !mediaFirst, down: false, at: t + 0.06)
            muteEvent(&r, media: mediaFirst, down: false, at: t + 0.0604)
            XCTAssertEqual(r.presses, [109, 109], "media first: \(mediaFirst): B's twin down joins B")
            XCTAssertEqual(r.releases, [109, 109], "media first: \(mediaFirst): B's own up releases it")
            XCTAssertEqual(r.lost, [])
            XCTAssertEqual(r.router.heldCount, 0)
        }
    }

    func testEventClockReadsEitherTimestampUnit() {
        let now: UInt64 = 63_182_281_687_000   // 63 182 s of uptime, in ns
        // Apple silicon: mach ticks of 125/3 ns.
        let ticks = now * 3 / 125
        XCTAssertEqual(EventClock.seconds(timestamp: ticks, nowNanos: now, numer: 125, denom: 3), 63_182.281_687, accuracy: 1e-5)
        // Documented nanoseconds (Intel: timebase 1/1, both readings agree).
        XCTAssertEqual(EventClock.seconds(timestamp: now - 2_000_000, nowNanos: now, numer: 125, denom: 3), 63_182.279_687, accuracy: 1e-6)
        XCTAssertEqual(EventClock.seconds(timestamp: now, nowNanos: now, numer: 1, denom: 1), 63_182.281_687, accuracy: 1e-6)
        XCTAssertEqual(EventClock.seconds(timestamp: 0, nowNanos: now, numer: 125, denom: 3), 63_182.281_687, accuracy: 1e-6,
                       "a synthetic event with no timestamp reads as now")
    }

    func testReportsExpireAfterTheWindow() {
        var r = Rig()
        r.down(0); r.up(0)
        XCTAssertEqual(r.router.pendingReports, 0, "ordinary keys leave nothing behind")
        r.flags(56, shiftL); r.media(0, down: true, dt: 0.001)
        XCTAssertEqual(r.router.pendingReports, 2)
        r.router.expire(now: r.t + KeyStrokeRouter.duplicateWindow - 0.001)
        XCTAssertEqual(r.router.pendingReports, 1, "the shift report is older than the window")
        r.router.expire(now: r.t + KeyStrokeRouter.duplicateWindow)
        XCTAssertEqual(r.router.pendingReports, 0, "nothing outlives the window")
        XCTAssertEqual(r.router.heldCount, 2, "held state is separate: still down")
    }

    func testCapsPressFromAKeyCodeGetsItsReleaseToo() {
        // Some keyboards could send caps lock as a key code: it is one more source of the same
        // logical press, released by the same timer.
        var r = Rig()
        r.down(57)
        XCTAssertEqual(r.presses, [57])
        XCTAssertNotNil(r.router.generation(of: 57))
        r.capsRelease()
        XCTAssertEqual(r.releases, [57])
    }

    func testCapsLockFlagAndKeyCodeAreOnePress() {
        // flagsChanged then keyDown(57), and the other order: one press, one release, one timer.
        for flagsFirst in [true, false] {
            var r = Rig()
            if flagsFirst {
                r.flags(57, locked); r.down(57, flags: locked, dt: 0.0004)
            } else {
                r.down(57, flags: 0); r.flags(57, locked, dt: 0.0004)
            }
            XCTAssertEqual(r.presses, [57], "flags first: \(flagsFirst): one press")
            let g = r.router.generation(of: 57)!
            r.up(57, dt: 0.08)                       // a key-up for it, if the keyboard sends one
            r.apply(r.router.releaseCaps(generation: g, now: r.tick(0.01)))   // the timer finds it released
            XCTAssertEqual(r.releases, [57], "flags first: \(flagsFirst): one release")
            // And with no key-up at all: the timer is the one release.
            var n = Rig()
            if flagsFirst { n.flags(57, locked); n.down(57, flags: locked, dt: 0.0004) } else { n.down(57, flags: 0); n.flags(57, locked, dt: 0.0004) }
            n.capsRelease(); n.capsRelease()
            XCTAssertEqual(n.presses, [57]); XCTAssertEqual(n.releases, [57])
        }
    }

    // MARK: lost key-ups

    func testLostModifierUpIsReconciledFromFlags() {
        // ⌘ goes down, then the user switches apps and the ⌘ key-up never reaches Navi.
        var r = Rig()
        r.flags(55, cmdL)
        r.down(48, flags: cmdL); r.up(48)            // ⌘Tab
        // Next event: a letter typed with no ⌘ held. The ⌘ flag is gone, so ⌘ went up unseen.
        r.down(0, flags: 0); r.up(0)
        XCTAssertEqual(r.lost, [55], "the lost ⌘ is forgotten")
        XCTAssertEqual(r.releases, [48, 0], "with no late release click")
        XCTAssertEqual(r.router.heldCount, 0)
        r.flags(55, cmdL)                            // the next real ⌘ press plays
        r.flags(55, 0)
        XCTAssertEqual(r.presses, [55, 48, 0, 55]); XCTAssertEqual(r.releases, [48, 0, 55])
        // The same through another modifier's flag change: shift goes down with no ⌘ flag.
        var s = Rig()
        s.flags(55, cmdL); s.flags(56, shiftL); s.flags(56, 0)
        XCTAssertEqual(s.lost, [55]); XCTAssertEqual(s.presses, [55, 56]); XCTAssertEqual(s.releases, [56])
    }

    func testLostUpThenFreshPressIsAPressNotAStrayRelease() {
        // A modifier whose up was lost and whose flag reads down again (pressed again before any
        // other event): the new down is a fresh press, and its own up a normal release.
        var r = Rig()
        r.flags(56, shiftL)
        r.flags(56, shiftL, dt: 0.4)                 // up lost, pressed again 400 ms later
        r.flags(56, 0)
        XCTAssertEqual(r.presses, [56, 56], "the fresh press plays")
        XCTAssertEqual(r.releases, [56], "one release, for the press that was let go")
        // A media key whose up was lost (focus moved to a password field, an app took the event).
        var m = Rig()
        m.media(0, down: true)
        m.media(0, down: true, dt: 0.5)              // the next real press
        m.media(0, down: false)
        XCTAssertEqual(m.presses, [111, 111]); XCTAssertEqual(m.releases, [111])
    }

    func testEveryStandardKeyReachesAVoiceThroughTheTap() {
        // How each key arrives from macOS → the stroke it must become.
        let plan = KeySoundPlan(styles.last!.1)
        for code in standardKeys {
            var r = Rig()
            if code == 57 {
                r.flags(57, locked); r.capsRelease()
            } else if let flag = [56: shiftL, 60: shiftR, 59: ctrlL, 62: ctrlR, 58: optL, 61: optR, 55: cmdL, 54: cmdR, 63: fnFlag][code] {
                r.flags(code, flag); r.flags(code, 0)
            } else {
                r.down(code); r.up(code)
            }
            XCTAssertEqual(r.presses, [code], "key \(code): one press"); XCTAssertEqual(r.releases, [code], "key \(code): one release")
            XCTAssertNotNil(plan.voice(code))
        }
    }

    func testResetForgetsEverything() {
        var r = Rig()
        r.flags(56, shiftL); r.media(0, down: true); r.flags(57, locked | shiftL)
        let caps = r.router.generation(of: 57)!
        XCTAssertEqual(r.router.heldCount, 3)
        r.router.reset(); r.pairing.reset()
        XCTAssertEqual(r.router.heldCount, 0)
        XCTAssertEqual(r.router.releaseCaps(generation: caps, now: r.tick(0.05)), [], "a pending caps release does nothing after a reset")
        r.flags(56, 0)
        XCTAssertEqual(r.releases, [], "a key-up after a reset needs a fresh key-down first")
        r.flags(56, shiftL, dt: 0.001)
        XCTAssertEqual(r.presses.last, 56, "and a fresh press works, even right away (reports are forgotten too)")
        r.media(0, down: true, dt: 0.001)
        XCTAssertEqual(r.presses.last, 111)
    }

    func testPanCoversModifiersAndNewKeys() {
        XCTAssertLessThan(StereoPan.pan(keyCode: 56), 0, "left shift leans left")
        XCTAssertLessThan(StereoPan.pan(keyCode: 55), 0, "left ⌘ leans left")
        XCTAssertGreaterThan(StereoPan.pan(keyCode: 54), 0, "right ⌘ leans right")
        XCTAssertGreaterThan(StereoPan.pan(keyCode: 60), 0, "right shift leans right")
        XCTAssertEqual(StereoPan.pan(keyCode: 105), StereoPan.maxPan, "F13 (above the nav block): right edge")
        XCTAssertLessThan(StereoPan.pan(keyCode: 102), 0, "JIS 英数 sits left of space")
    }

    // MARK: the star

    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("navi-allkeys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func makePack(_ id: String, _ files: [String]) throws {
        let p = dir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        for f in files { try Data().write(to: p.appendingPathComponent(f)) }
        try Data(#"{"name":"\#(id)","license":"x","tier":"local"}"#.utf8).write(to: p.appendingPathComponent("pack.json"))
    }

    /// Fixture folders shaped like what the fetch script installs for each style.
    func testStarsGoToPacksWithEveryKeyRecorded() throws {
        let classes = ["space-01.wav", "enter-01.wav", "backspace-01.wav"]
        let thock = Self.thockScancodes.sorted().map { "sc\($0).wav" } + (1...5).map { String(format: "key-%02d.wav", $0) } + classes
        try makePack("thock", thock)
        try makePack("thock-missing-backtick", thock.filter { $0 != "sc41.wav" })
        // Space / return / delete recorded only as class files still count as recorded.
        try makePack("thock-classes-only", thock.filter { !["sc57.wav", "sc28.wav", "sc14.wav"].contains($0) })
        try makePack("thock-no-classes", thock.filter { !classes.contains($0) })
        try makePack("partial", Self.partialScancodes.sorted().map { "sc\($0).wav" } + classes)
        try makePack("per-row", (0...4).map { "row\($0)-01.mp3" } + classes + ["up-key-01.mp3"])
        try makePack("plain", (1...32).map { String(format: "key-%02d.wav", $0) })
        let packs = SoundPackLibrary.scan(dir)
        let starred = Set(packs.filter(\.hasEveryKey).map(\.id))
        XCTAssertEqual(starred, ["thock", "thock-classes-only", "thock-no-classes"],
                       "a star only where every key of a standard Mac keyboard (fn excluded) has its own recording")
        for p in packs {
            XCTAssertEqual(p.menuTitle.contains(SoundPack.everyKeyMark), p.hasEveryKey, p.id)
            XCTAssertEqual(p.tooltip.contains("has its own real recording (fn aside"), p.hasEveryKey, p.id)
        }
        XCTAssertEqual(packs.first { $0.id == "thock" }!.menuTitle, "thock ★ · local")
        XCTAssertFalse(SoundPack.synth.hasEveryKey)
        XCTAssertEqual(TypingMenu.everyKeyHint(packs), "★ = a real recording for every key (fn aside)")
        XCTAssertNil(TypingMenu.everyKeyHint(packs.filter { !$0.hasEveryKey }), "no hint without a star")
    }

    /// The two public styles (keysounds/packs-public.tsv) map generic `key:` presses only, so no
    /// public pack earns the star; the fallback still gives every key a sound from them.
    func testPublicStylesHaveNoStarButEveryKeySounds() throws {
        try makePack("cherry-kc1000", (1...32).map { String(format: "key-%02d.wav", $0) })
        try makePack("eklee-old", (1...6).map { String(format: "key-%02d.wav", $0) })
        let packs = SoundPackLibrary.scan(dir)
        XCTAssertEqual(packs.map(\.id), ["cherry-kc1000", "eklee-old", "synth"])
        XCTAssertTrue(packs.allSatisfy { !$0.hasEveryKey && !$0.menuTitle.contains(SoundPack.everyKeyMark) })
        XCTAssertNil(TypingMenu.everyKeyHint(packs), "no star, so no hint line")
        for p in packs where p.tier != .builtin {
            let inv = PackInventory(generic: p.samples[.other]?.count ?? 0)
            let plan = KeySoundPlan(inv)
            for code in standardKeys {
                guard let v = plan.voice(code) else { XCTFail("\(p.id): key \(code) has no voice"); continue }
                XCTAssertTrue(exists(v.press.source, in: inv), "\(p.id): key \(code) press is silent")
            }
        }
    }

    /// The star means: every key of a standard Mac keyboard (MacBook layout), fn excluded. fn is
    /// laptop-only and has no scancode, so no pack records it; requiring it would star nothing.
    func testTheStarMeansEveryStandardKeyFnExcluded() {
        let set = MacKeyboard.starKeyCodes
        for code in letters + numberRow + punctuation + fKeys + arrows + [53, 48, 36, 51, 49, 57, 56, 60, 59, 58, 61, 55, 54] {
            XCTAssertTrue(set.contains(code), "key \(code) is required for the star")
        }
        XCTAssertFalse(set.contains(63), "fn is excluded: no pack can record it")
        XCTAssertNil(MacKeyboard.geometry(63)?.scancode, "…because it has no scancode")
        for code in keypad + nav + fKeysFullSize + [62, 10] {
            XCTAssertFalse(set.contains(code), "key \(code) is a full-size / ISO extra, not required")
        }
        for code in set { XCTAssertNotNil(MacKeyboard.geometry(code)?.scancode, "key \(code) can be recorded by name") }
    }

    func testStarFollowsWhatDecoded() throws {
        let thock = Self.thockScancodes.sorted().map { "sc\($0).wav" } + ["space-01.wav", "enter-01.wav", "backspace-01.wav"]
        try makePack("thock", thock)
        var pack = try XCTUnwrap(SoundPackLibrary.scan(dir).first { $0.id == "thock" })
        XCTAssertTrue(pack.hasEveryKey, "by its files, before any load")
        pack.decodedEveryKey = false
        XCTAssertFalse(pack.hasEveryKey, "a load found recordings that do not decode: no star")
        XCTAssertFalse(pack.menuTitle.contains(SoundPack.everyKeyMark))
        pack.decodedEveryKey = true
        XCTAssertTrue(pack.hasEveryKey)
        // The rule the player applies to what decoded.
        let all = Self.thockScancodes
        XCTAssertTrue(MacKeyboard.recordsEveryKey(perKey: all, classes: []))
        XCTAssertFalse(MacKeyboard.recordsEveryKey(perKey: all.subtracting([30]), classes: [.space, .enter, .backspace]), "A failed to decode")
        XCTAssertTrue(MacKeyboard.recordsEveryKey(perKey: all.subtracting([57, 28, 14]), classes: [.space, .enter, .backspace]))
        XCTAssertFalse(MacKeyboard.recordsEveryKey(perKey: [], classes: [.space, .enter, .backspace]))
    }

    func testDecodedStarFollowsTheFilesNotJustTheirNames() throws {
        let thock = Self.thockScancodes.sorted().map { "sc\($0).wav" } + ["space-01.wav", "enter-01.wav", "backspace-01.wav"]
        try makePack("thock", thock)
        func scan() throws -> [SoundPack] { SoundPackLibrary.scan(dir) }
        var stars = DecodedStars()
        var packs = try scan()
        let pack = try XCTUnwrap(packs.first { $0.id == "thock" })
        let fp = PackFingerprint.of(pack)
        XCTAssertEqual(fp, PackFingerprint.of(pack), "stable while nothing changes")
        XCTAssertEqual(fp.entries.count, thock.count + 1, "every file it plays from, plus pack.json")
        stars.record("thock", fingerprint: fp, everyKey: false)   // a load found a bad recording
        stars.apply(to: &packs) { PackFingerprint.of($0) }
        XCTAssertEqual(packs.first { $0.id == "thock" }!.decodedEveryKey, false)
        XCTAssertFalse(packs.first { $0.id == "thock" }!.hasEveryKey)

        let folder = dir.appendingPathComponent("thock")
        // Each of these must drop the cached result: same names, different files.
        let changes: [(String, () throws -> Void)] = [
            ("a recording re-fetched with other bytes", { try Data([1, 2, 3]).write(to: folder.appendingPathComponent("sc30.wav")) }),
            ("a class recording replaced", { try Data([9]).write(to: folder.appendingPathComponent("space-01.wav")) }),
            ("only the modification time", {
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)],
                                                      ofItemAtPath: folder.appendingPathComponent("sc16.wav").path) }),
            ("pack.json rewritten by a refetch", { try Data(#"{"name":"thock","license":"x","tier":"local","sha256":"new"}"#.utf8).write(to: folder.appendingPathComponent("pack.json")) }),
        ]
        for (what, change) in changes {
            packs = try scan()
            let before = PackFingerprint.of(packs.first { $0.id == "thock" }!)
            stars.record("thock", fingerprint: before, everyKey: false)
            try change()
            packs = try scan()
            let after = PackFingerprint.of(packs.first { $0.id == "thock" }!)
            XCTAssertNotEqual(before, after, "\(what): the fingerprint changes (so the controller reloads the pack)")
            stars.apply(to: &packs) { PackFingerprint.of($0) }
            XCTAssertNil(packs.first { $0.id == "thock" }!.decodedEveryKey, "\(what): the stale result is dropped")
            XCTAssertTrue(packs.first { $0.id == "thock" }!.hasEveryKey, "\(what): back to its file names until loaded again")
            stars.apply(to: &packs) { PackFingerprint.of($0) }
            XCTAssertNil(packs.first { $0.id == "thock" }!.decodedEveryKey, "\(what): and it stays dropped")
        }
        XCTAssertEqual(PackFingerprint.of(.synth).entries, [], "the synth click has no files")
    }
}
