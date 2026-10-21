import XCTest
@testable import PetCore

/// Per-key sounds, key-up sounds, stereo placement and quiet on calls (2026-10-21).
final class KeyRealismTests: XCTestCase {
    // Mac virtual key codes used below.
    let q: UInt16 = 12, a: UInt16 = 0, z: UInt16 = 6, p: UInt16 = 35, l: UInt16 = 37, semicolon: UInt16 = 41
    let one: UInt16 = 18, space: UInt16 = 49, enter: UInt16 = 36, delete: UInt16 = 51, left: UInt16 = 123

    /// A per-key pack: its own recordings for some keys, a generic set, classes.
    let perKeyPack = PackInventory(generic: 5, classes: [.space: 1, .enter: 1, .backspace: 1], perKey: [16, 30, 57])
    /// A per-row pack: per-row recordings and the pack's own key-up recordings.
    let perRowPack = PackInventory(classes: [.space: 1, .enter: 1, .backspace: 1], rows: [0: 1, 1: 1, 2: 1, 3: 1, 4: 1],
                              releaseGeneric: 1, releaseClasses: [.space: 1, .enter: 1, .backspace: 1])
    /// A plain pack (Cherry KC 1000, Old Clicky, the synth click): a handful of generic presses.
    let plain = PackInventory(generic: 4)

    // MARK: per-key lookup

    func testPerKeyRecordingsAreUsedByScancode() {
        let plan = KeySoundPlan(perKeyPack)
        XCTAssertEqual(plan.voice(q)!.press, .init(.perKey(16)), "Q plays its own recording (scancode 16)")
        XCTAssertEqual(plan.voice(a)!.press, .init(.perKey(30)), "A plays its own recording (scancode 30)")
        XCTAssertEqual(plan.voice(space)!.press, .init(.cls(.space)), "space keeps its own sound")
        XCTAssertEqual(plan.voice(enter)!.press, .init(.cls(.enter)))
        XCTAssertEqual(plan.voice(delete)!.press, .init(.cls(.backspace)))
        XCTAssertEqual(plan.voice(117)!.press, .init(.cls(.backspace)), "forward delete")
        // Z has no recording: it borrows the nearest key that has one (A), a little off A's pitch.
        XCTAssertEqual(plan.voice(z)!.press.source, .perKey(30), "Z borrows its neighbour A's recording")
        XCTAssertNotEqual(plan.voice(z)!.press.detune, 0, "…at its own pitch, so Z never sounds exactly like A")
    }

    func testRowRecordingsFollowTheKeyboardRow() {
        let plan = KeySoundPlan(perRowPack)
        func row(_ k: UInt16) -> Int? { if case .row(let r, _) = plan.voice(k)!.press.source { return r }; return nil }
        XCTAssertEqual(row(one), 0); XCTAssertEqual(row(q), 1); XCTAssertEqual(row(a), 2); XCTAssertEqual(row(z), 3)
        XCTAssertEqual(row(left), 4, "arrows play the bottom-row recording")
        XCTAssertEqual(plan.voice(space)!.press, .init(.cls(.space)))
        XCTAssertNotEqual(plan.voice(q)!.press, plan.voice(13)!.press, "Q and W share a row recording but not a pitch")
    }

    func testMissingRowFallsBackToThePack() {
        // A per-row pack with no row-3 recording.
        let plan = KeySoundPlan(PackInventory(rows: [0: 1, 1: 1, 2: 1, 4: 1]))
        guard case .row(let r, _) = plan.voice(z)!.press.source else { return XCTFail("still plays a recording") }
        XCTAssertTrue([0, 1, 2, 4].contains(r))
    }

    func testEveryKeyCodeHasAVoiceAndLookupIsATable() {
        for inv in [perKeyPack, perRowPack, plain, PackInventory(perKey: [16, 17, 30])] {
            let plan = KeySoundPlan(inv)
            XCTAssertEqual(plan.voices.count, 128, "one precomputed entry per key code")
            XCTAssertNil(plan.voice(128), "codes past the table have no voice: no click")
            XCTAssertNil(plan.voice(200))
        }
    }

    // MARK: fallback assignment

    func testFallbackIsStableAndKeysSoundDistinct() {
        // Packs with no per-key recordings (those borrow from a neighbour: AllKeysTests).
        for (inv, pool) in [(plain, 4), (PackInventory(generic: 1), 1), (PackInventory(generic: 6), 6), (PackInventory(generic: 13), 13), (PackInventory(generic: 32), 32)] {
            let first = KeySoundPlan(inv), again = KeySoundPlan(inv)
            XCTAssertEqual(first, again, "the same key always gets the same variant and pitch")
            // The main block in reading order (keys appended later, like JIS extras, are not
            // anyone's neighbour there).
            let letters = MacKeyboard.keys.filter { (1...3).contains($0.row) && KeyEventFilter.keyClass($0.keyCode) == .other && $0.scancode != nil }
            let sounds = letters.map { first.voice($0.keyCode)!.press }
            for (x, y) in zip(sounds, sounds.dropFirst()) { XCTAssertNotEqual(x, y, "neighbouring keys differ") }
            // Recording × pitch combinations: as many distinct sounds as the pack allows, up to most keys.
            XCTAssertGreaterThanOrEqual(Set(sounds).count, min(letters.count / 2, pool * KeySoundPlan.detuneCycle.count))
            for s in sounds { XCTAssertTrue((-3...3).contains(s.detune), "pitch offset stays small") }
        }
        let one = KeySoundPlan(PackInventory(generic: 1))
        XCTAssertEqual(Set(MacKeyboard.keys.map { one.voice($0.keyCode)!.press.detune }).count, 7,
                       "a single recording still gives keys distinct pitches")
    }

    func testDetuneRatesAreSubtle() {
        XCTAssertEqual(KeySoundPlan.rate(detune: 0), 1)
        XCTAssertEqual(KeySoundPlan.rate(detune: 3), pow(2, 60.0 / 1200), accuracy: 1e-12)
        XCTAssertLessThan(abs(KeySoundPlan.rate(detune: -3) - 1), 0.04)
    }

    func testVarispeedResample() {
        let ramp: [Float] = (0..<100).map(Float.init)
        XCTAssertEqual(SampleMath.varispeed(ramp, rate: 1), ramp, "rate 1 is a no-op")
        let fast = SampleMath.varispeed(ramp, rate: 2)
        XCTAssertEqual(fast.count, 50)
        XCTAssertEqual(fast[10], 20, accuracy: 1e-5)
        XCTAssertEqual(SampleMath.varispeed(ramp, rate: 0.5).count, 200)
        XCTAssertEqual(SampleMath.varispeed([], rate: 1.2), [])
    }

    // MARK: releases

    func testPackReleasesAreUsedWhenPresent() {
        let plan = KeySoundPlan(perRowPack)
        XCTAssertEqual(plan.voice(space)!.release, .pack(.init(.releaseClass(.space))))
        guard case .pack(let r) = plan.voice(q)!.release, case .releaseGeneric = r.source else { return XCTFail("generic key-up recording") }
        XCTAssertEqual(r.detune, plan.voice(q)!.press.detune, "release at the press's pitch")
    }

    func testReleasesAreDerivedFromTheKeysOwnPress() {
        let plan = KeySoundPlan(perKeyPack)
        XCTAssertEqual(plan.voice(q)!.release, .derived(.init(.perKey(16))))
        XCTAssertEqual(plan.voice(space)!.release, .derived(.init(.cls(.space))))
        for k in MacKeyboard.keys { XCTAssertEqual(plan.voice(k.keyCode)!.release, .derived(plan.voice(k.keyCode)!.press)) }
    }

    func testDerivedReleaseIsSofterAndShorter() {
        let sr = 44_100.0
        for c in KeyClass.allCases {
            let press = SynthClick.samples(c, variant: 1)
            let up = ReleaseSynth.derive(press, sampleRate: sr)
            XCTAssertFalse(up.isEmpty)
            XCTAssertLessThan(up.count, press.count, "shorter")
            XCTAssertLessThanOrEqual(Double(up.count) / sr, ReleaseSynth.length + 1e-9)
            XCTAssertLessThanOrEqual(SampleMath.peak(up), SampleMath.peak(press) * ReleaseSynth.gain + 1e-4, "≈ -10 dB")
            XCTAssertGreaterThan(SampleMath.peak(up), 0.01, "still audible")
            XCTAssertLessThan(abs(up.last ?? 1), 1e-3, "fades to silence: no click at the cut")
        }
    }

    // MARK: press / release pairing

    /// What the controller does on a key-down: a fresh press, played if the gate is open and the
    /// player schedules it (`scheduled`), and only then marked sounded with the live pack.
    func down(_ p: inout KeyPairing, _ code: UInt16, repeat isRepeat: Bool = false, gate: Bool = true,
              scheduled: Bool = true, generation: UInt32 = 1) -> Bool {
        guard p.keyDown(code, isRepeat: isRepeat), gate, scheduled else { return false }
        p.pressSounded(code, generation: generation)
        return true
    }

    func testPressReleasePairs() {
        var p = KeyPairing()
        XCTAssertTrue(down(&p, q))
        XCTAssertTrue(p.keyUp(q, generation: 1))
        XCTAssertFalse(p.keyUp(q, generation: 1), "one release per press")
        XCTAssertEqual(p.heldCount, 0)
    }

    func testAutoRepeatDoesNotStackPresses() {
        var p = KeyPairing()
        var presses = 0, releases = 0
        if down(&p, delete) { presses += 1 }
        for _ in 0..<40 { if down(&p, delete, repeat: true) { presses += 1 } }
        if p.keyUp(delete, generation: 1) { releases += 1 }
        XCTAssertEqual(presses, 1, "held key: one press")
        XCTAssertEqual(releases, 1, "and one release")
    }

    func testReleaseNeverPlaysWithoutAMatchingPress() {
        var p = KeyPairing()
        XCTAssertFalse(p.keyUp(a, generation: 1), "key-up with no press seen (held when Navi started)")
        XCTAssertFalse(down(&p, a, repeat: true), "repeat of a key pressed before Navi listened")
        XCTAssertFalse(p.keyUp(a, generation: 1))
        XCTAssertFalse(down(&p, z, gate: false), "muted press (on a call)")
        XCTAssertFalse(p.keyUp(z, generation: 1), "its release stays silent even if the call ended meanwhile")
        _ = down(&p, q)
        p.reset()
        XCTAssertFalse(p.keyUp(q, generation: 1), "switched off and on: old presses forgotten")
    }

    /// Review fix 1: sounded only after the player scheduled the press.
    func testUnscheduledPressNeverReleases() {
        var p = KeyPairing()
        XCTAssertFalse(down(&p, q, scheduled: false), "no engine / pack still loading / schedule raised")
        XCTAssertFalse(p.keyUp(q, generation: 1), "so no release without an audible press")
        p.pressSounded(z, generation: 1)
        XCTAssertFalse(p.keyUp(z, generation: 1), "marking a key that is not down does nothing")
        XCTAssertTrue(down(&p, q), "the next real press pairs normally")
        XCTAssertTrue(p.keyUp(q, generation: 1))
    }

    /// Review fix 2: a key held across a pack switch does not release with the new pack.
    func testReleaseAcrossPackSwitchIsSilent() {
        var p = KeyPairing()
        XCTAssertTrue(down(&p, a, generation: 4))
        XCTAssertFalse(p.keyUp(a, generation: 5), "new pack went live while A was held")
        XCTAssertFalse(p.keyUp(a, generation: 4), "and the key is cleared, not left half-held")
        XCTAssertTrue(down(&p, a, generation: 5))
        XCTAssertTrue(p.keyUp(a, generation: 5))
    }

    /// Review fix 3: tap disabled → reset; only a fresh key-down can release again.
    func testTapResetNeedsAFreshKeyDown() {
        var p = KeyPairing()
        XCTAssertTrue(down(&p, a))
        XCTAssertTrue(down(&p, z))
        p.reset()                                                     // tapDisabledByTimeout / ByUserInput
        XCTAssertEqual(p.heldCount, 0)
        XCTAssertFalse(down(&p, a, repeat: true), "A still held: its repeats do not re-arm it")
        XCTAssertFalse(p.keyUp(a, generation: 1), "a key-up after the gap does not release")
        XCTAssertFalse(p.keyUp(z, generation: 1))
        XCTAssertTrue(down(&p, z), "a fresh key-down does")
        XCTAssertTrue(p.keyUp(z, generation: 1))
    }

    /// Review fix 4: codes ≥ 128 never press and never release; the plan has no voice for them.
    func testCodesPastTheTableAreRejected() {
        var p = KeyPairing()
        for code: UInt16 in [128, 200, 300, .max] {
            XCTAssertFalse(p.keyDown(code, isRepeat: false), "\(code): no press")
            p.pressSounded(code, generation: 1)
            XCTAssertFalse(p.keyUp(code, generation: 1), "\(code): no release")
            XCTAssertNil(KeySoundPlan(plain).voice(code))
        }
        XCTAssertEqual(p.heldCount, 0)
        XCTAssertTrue(p.keyDown(127, isRepeat: false), "the last real code still works")
    }

    /// Review fix 5: the preview's release follows the same rules as a key's: none if the
    /// press did not play, and none if quiet-on-calls engaged in the 90 ms before it.
    func testPreviewReleaseRules() {
        func gate(mic: Bool) -> Bool { KeySoundGate.shouldPlay(enabled: true, soundOn: true, hidden: false, quietOnCalls: true, micInUse: mic) }
        let f: UInt16 = 3
        var p = KeyPairing()
        XCTAssertFalse(down(&p, f, gate: gate(mic: false), scheduled: false))
        XCTAssertFalse(p.keyUp(f, generation: 1) && gate(mic: false), "press failed: no release")
        XCTAssertTrue(down(&p, f, gate: gate(mic: false)))
        XCTAssertFalse(p.keyUp(f, generation: 1) && gate(mic: true), "call started before the release: silent")
        XCTAssertTrue(down(&p, f, gate: gate(mic: false)))
        XCTAssertTrue(p.keyUp(f, generation: 1) && gate(mic: false), "normal preview: press then release")
    }

    func testMissedKeyUpIsANewPressNotAStack() {
        var p = KeyPairing()
        XCTAssertTrue(down(&p, q))
        XCTAssertTrue(down(&p, q), "fresh press after a missed key-up")
        XCTAssertEqual(p.heldCount, 1)
        XCTAssertTrue(p.keyUp(q, generation: 1))
        XCTAssertFalse(p.keyUp(q, generation: 1))
    }

    func testRolloverKeysPairIndependently() {
        var p = KeyPairing()
        for k: UInt16 in [a, 1, 2, 127, 64, 63] { XCTAssertTrue(down(&p, k)) }
        XCTAssertEqual(p.heldCount, 6)
        for k: UInt16 in [63, 127, a, 64, 2, 1] { XCTAssertTrue(p.keyUp(k, generation: 1), "\(k)") }
        XCTAssertEqual(p.heldCount, 0)
    }

    // MARK: stereo placement

    func testPanFollowsTheKeyColumn() {
        XCTAssertEqual(StereoPan.pan(keyCode: space), 0, "space dead centre")
        XCTAssertLessThan(StereoPan.pan(keyCode: a), 0, "left keys lean left")
        XCTAssertLessThan(StereoPan.pan(keyCode: q), 0)
        XCTAssertGreaterThan(StereoPan.pan(keyCode: semicolon), 0, "right keys lean right")
        XCTAssertGreaterThan(StereoPan.pan(keyCode: p), 0)
        XCTAssertGreaterThan(StereoPan.pan(keyCode: enter), 0)
        XCTAssertEqual(StereoPan.pan(keyCode: 100_0), 0, "unknown key: centre")
        let home: [UInt16] = [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39]   // a s d f g h j k l ; '
        let pans = home.map { StereoPan.pan(keyCode: $0) }
        XCTAssertEqual(pans, pans.sorted(), "left to right along the home row")
        XCTAssertEqual(StereoPan.pan(keyCode: 48), -StereoPan.pan(keyCode: 36), accuracy: 0.02, "tab and return roughly mirror")
    }

    func testPanStaysSubtle() {
        for code in UInt16(0)..<UInt16(128) {
            XCTAssertLessThanOrEqual(abs(StereoPan.pan(keyCode: code)), StereoPan.maxPan)
        }
        XCTAssertLessThanOrEqual(StereoPan.maxPan, 0.35, "headphones: no hard-panned clicks")
        XCTAssertEqual(StereoPan.pan(keyCode: 82), StereoPan.maxPan, "keypad clamps to the right edge")
        let plan = KeySoundPlan(plain)
        XCTAssertEqual(plan.voice(a)!.pan, StereoPan.pan(keyCode: a), "plan carries the pan, precomputed")
    }

    func testLayoutIsSane() {
        let keys = MacKeyboard.keys
        XCTAssertEqual(Set(keys.map(\.keyCode)).count, keys.count, "no key code twice")
        XCTAssertEqual(MacKeyboard.geometry(q)?.scancode, 16)
        XCTAssertEqual(MacKeyboard.geometry(a)?.scancode, 30)
        XCTAssertEqual(MacKeyboard.geometry(space)?.scancode, 57)
        XCTAssertEqual(MacKeyboard.geometry(enter)?.scancode, 28)
        XCTAssertEqual(MacKeyboard.geometry(delete)?.scancode, 14)
        XCTAssertNil(MacKeyboard.geometry(52), "an unused key code is not on the layout")
        XCTAssertNil(MacKeyboard.geometry(500))
        // Every letter and digit is on the layout.
        for code: UInt16 in [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 31, 32, 34, 35, 37, 38, 40, 45, 46,
                             18, 19, 20, 21, 22, 23, 25, 26, 28, 29] {
            XCTAssertNotNil(MacKeyboard.geometry(code), "\(code)")
        }
    }

    // MARK: quiet on calls

    func testQuietOnCallsGate() {
        XCTAssertFalse(KeySoundGate.shouldPlay(enabled: true, soundOn: true, hidden: false, quietOnCalls: true, micInUse: true),
                       "on a call: no clicks")
        XCTAssertTrue(KeySoundGate.shouldPlay(enabled: true, soundOn: true, hidden: false, quietOnCalls: true, micInUse: false),
                      "call ended: clicks resume")
        XCTAssertTrue(KeySoundGate.shouldPlay(enabled: true, soundOn: true, hidden: false, quietOnCalls: false, micInUse: true),
                      "setting off: clicks during calls")
        XCTAssertFalse(KeySoundGate.shouldPlay(enabled: false, soundOn: true, hidden: false, quietOnCalls: false, micInUse: false))
    }

    func testMicActivityRule() {
        let me: Int32 = 42
        let siri = MicActivity.Process(pid: 666, runningInput: true, inputDevices: [])
        let zoom = MicActivity.Process(pid: 900, runningInput: true, inputDevices: [78])
        let navi = MicActivity.Process(pid: me, runningInput: true, inputDevices: [78])
        let player = MicActivity.Process(pid: 901, runningInput: false, inputDevices: [78])
        XCTAssertFalse(MicActivity.inUse([siri], runningDevices: [], selfPID: me), "Siri's always-on listener is not a call")
        XCTAssertFalse(MicActivity.inUse([siri], runningDevices: [78], selfPID: me))
        XCTAssertTrue(MicActivity.inUse([siri, zoom], runningDevices: [78], selfPID: me), "a call app on the mic")
        XCTAssertFalse(MicActivity.inUse([zoom], runningDevices: [], selfPID: me), "input claimed but the device is not running")
        XCTAssertFalse(MicActivity.inUse([navi], runningDevices: [78], selfPID: me), "Navi never mutes herself")
        XCTAssertFalse(MicActivity.inUse([player], runningDevices: [78], selfPID: me),
                       "a headset running for playback only (music, Navi's own clicks) is not a call")
        XCTAssertFalse(MicActivity.inUse([], runningDevices: [78], selfPID: me))
    }

    func testQuietOnCallsSettingPersistsAndOldSettingsKeepWorking() {
        let store = MemoryStringStore()
        store.values[KeySoundSettings.prefsKey] = #"{"enabled":true,"profile":"eklee-old","volume":0.3}"#
        let old = KeySoundSettings(store: store)
        XCTAssertEqual(old, KeySoundSettings(enabled: true, profile: "eklee-old", volume: 0.3, quietOnCalls: true),
                       "settings saved before this feature: still on, quiet on calls defaults on")
        KeySoundSettings(enabled: true, profile: nil, volume: 0.5, quietOnCalls: false).save(to: store)
        XCTAssertFalse(KeySoundSettings(store: store).quietOnCalls)
        XCTAssertTrue(KeySoundSettings(store: store).enabled)
    }

    func testCallMuteNoteAndCopy() {
        XCTAssertEqual(TypingMenu.statusNote(enabled: true, listener: .running, secureInput: false, callMuted: true),
                       "quiet · a microphone is in use")
        XCTAssertNil(TypingMenu.statusNote(enabled: true, listener: .running, secureInput: false, callMuted: false))
        XCTAssertEqual(TypingMenu.rows(enabled: true, listener: .running, secureInput: false, callMuted: true),
                       [.stats, .note("quiet · a microphone is in use")])
        XCTAssertTrue(TypingMenu.quietOnCallsTooltip.contains("no microphone permission"))
        XCTAssertTrue(TypingMenu.quietOnCallsTooltip.contains("never listens"))
    }

    // MARK: pack scanning

    func testScanFindsPerKeyRowAndReleaseFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("navi-real-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        func pack(_ id: String, _ files: [String]) throws {
            let p = dir.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
            for f in files { try Data().write(to: p.appendingPathComponent(f)) }
        }
        try pack("thock", ["key-01.wav", "sc16.wav", "sc30.wav", "sc3640.wav", "space-01.wav", "scx.wav", "sc-1.wav", "sc016.wav"])
        try pack("per-row", ["row0-01.mp3", "row1-01.mp3", "row4-01.mp3", "space-01.mp3", "up-key-01.mp3", "up-space-01.mp3"])
        try pack("only-keys", ["sc16.wav"])
        try pack("only-releases", ["up-key-01.wav"])
        let packs = SoundPackLibrary.scan(dir)
        XCTAssertEqual(packs.map(\.id), ["only-keys", "per-row", "thock", "synth"], "a pack needs presses; releases alone are not one")
        let thock = try XCTUnwrap(packs.first { $0.id == "thock" })
        XCTAssertEqual(Set(thock.perKey.keys), [16, 30, 3640], "only sc<number> files, no odd names")
        XCTAssertEqual(thock.samples[.other]?.count, 1)
        XCTAssertTrue(thock.releases.isEmpty)
        let kb = try XCTUnwrap(packs.first { $0.id == "per-row" })
        XCTAssertEqual(kb.rows.keys.sorted(), [0, 1, 4])
        XCTAssertEqual(kb.releases[.other]?.map(\.lastPathComponent), ["up-key-01.mp3"])
        XCTAssertEqual(kb.releases[.space]?.map(\.lastPathComponent), ["up-space-01.mp3"])
        XCTAssertNil(kb.samples[.other], "up-key files are not presses")
        XCTAssertTrue(kb.hasPresses)
    }
}
