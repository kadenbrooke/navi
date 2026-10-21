import XCTest
@testable import PetCore

/// In-memory stand-in for UserDefaults' string API.
final class MemoryStringStore: StringStore {
    var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

/// Deterministic RNG for the picker / jitter tests.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class KeySoundsTests: XCTestCase {
    // MARK: key filter

    func testCoarseClasses() {
        XCTAssertEqual(KeyEventFilter.press(keyCode: 49, isRepeat: false, command: false, control: false)?.keyClass, .space)
        XCTAssertEqual(KeyEventFilter.press(keyCode: 36, isRepeat: false, command: false, control: false)?.keyClass, .enter)
        XCTAssertEqual(KeyEventFilter.press(keyCode: 76, isRepeat: false, command: false, control: false)?.keyClass, .enter, "keypad enter")
        XCTAssertEqual(KeyEventFilter.press(keyCode: 51, isRepeat: false, command: false, control: false)?.keyClass, .backspace)
        XCTAssertEqual(KeyEventFilter.press(keyCode: 117, isRepeat: false, command: false, control: false)?.keyClass, .backspace, "forward delete")
        for code: UInt16 in [0, 1, 12, 35, 50, 122] {
            XCTAssertEqual(KeyEventFilter.press(keyCode: code, isRepeat: false, command: false, control: false)?.keyClass, .other)
        }
    }

    func testAutoRepeatIsIgnored() {
        XCTAssertNil(KeyEventFilter.press(keyCode: 0, isRepeat: true, command: false, control: false))
        XCTAssertNil(KeyEventFilter.press(keyCode: 51, isRepeat: true, command: false, control: false), "held backspace: one click, not a machine gun")
    }

    func testShortcutsClickButDoNotCountAsTyping() {
        let p = KeyEventFilter.press(keyCode: 8, isRepeat: false, command: true, control: false)
        XCTAssertEqual(p?.keyClass, .other)
        XCTAssertEqual(p?.countsAsTyping, false)
        XCTAssertEqual(KeyEventFilter.press(keyCode: 8, isRepeat: false, command: false, control: true)?.countsAsTyping, false)
        XCTAssertEqual(KeyEventFilter.press(keyCode: 8, isRepeat: false, command: false, control: false)?.countsAsTyping, true)
    }

    // MARK: settings

    func testSettingsDefaultOff() {
        let s = KeySoundSettings(store: MemoryStringStore())
        XCTAssertFalse(s.enabled, "off until turned on")
        XCTAssertNil(s.profile)
        XCTAssertEqual(s.volume, 0.5)
    }

    func testSettingsPersistAcrossRestart() {
        let store = MemoryStringStore()
        KeySoundSettings(enabled: true, profile: "eklee-old", volume: 0.3).save(to: store)
        let back = KeySoundSettings(store: store)
        XCTAssertEqual(back, KeySoundSettings(enabled: true, profile: "eklee-old", volume: 0.3))
        XCTAssertEqual(Array(store.values.keys), [KeySoundSettings.prefsKey], "one defaults key")
    }

    func testSettingsGarbageOrPartialFallsBack() {
        let store = MemoryStringStore()
        store.values[KeySoundSettings.prefsKey] = "{not json"
        XCTAssertEqual(KeySoundSettings(store: store), KeySoundSettings())
        store.values[KeySoundSettings.prefsKey] = #"{"enabled":true,"volume":7}"#
        let s = KeySoundSettings(store: store)
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.volume, 1, "volume clamped to 0…1")
        XCTAssertEqual(KeySoundSettings(volume: -2).volume, 0)
        XCTAssertEqual(KeySoundSettings.clamp(.nan), 0.5)
    }

    // MARK: gate

    func testGate() {
        XCTAssertTrue(KeySoundGate.shouldPlay(enabled: true, soundOn: true, hidden: false))
        XCTAssertFalse(KeySoundGate.shouldPlay(enabled: false, soundOn: true, hidden: false))
        XCTAssertFalse(KeySoundGate.shouldPlay(enabled: true, soundOn: false, hidden: false), "master Sound off silences clicks too")
        XCTAssertFalse(KeySoundGate.shouldPlay(enabled: true, soundOn: true, hidden: true), "hidden means nothing plays")
        XCTAssertNil(KeySoundGate.muteReason(soundOn: true, hidden: false))
        XCTAssertEqual(KeySoundGate.muteReason(soundOn: false, hidden: true), "muted · Sound is off")
        XCTAssertEqual(KeySoundGate.muteReason(soundOn: true, hidden: true), "muted · Navi is hidden")
    }

    // MARK: polyphony + variants

    func testVoicePoolRoundRobinStealsOldest() {
        var pool = VoicePool(count: 3)
        XCTAssertEqual((0..<7).map { _ in pool.take() }, [0, 1, 2, 0, 1, 2, 0])
    }

    func testVoicePoolUsesOnlyTheVoicesThatExist() {
        // Engine setup failed part-way: the pool is sized to the real node count, so an index
        // can never run past the nodes array; with none it fails closed.
        var none = VoicePool(count: 0)
        XCTAssertNil(none.take())
        XCTAssertNil(none.take())
        var negative = VoicePool(count: -3)
        XCTAssertNil(negative.take())
        var partial = VoicePool(count: 4)
        XCTAssertTrue((0..<100).compactMap { _ in partial.take() }.allSatisfy { (0..<4).contains($0) })
    }

    func testPackLoadTrackerDropsStaleDecodes() {
        var t = PackLoadTracker()
        XCTAssertNil(t.loadedID)
        let a = t.request("cherry-kc1000")
        let b = t.request("eklee-old")                  // switched profile while A was decoding
        XCTAssertEqual(t.requestedID, "eklee-old")
        XCTAssertTrue(t.complete(b, loadedID: "eklee-old"))
        XCTAssertFalse(t.complete(a, loadedID: "cherry-kc1000"), "older decode finishing last must not win")
        XCTAssertEqual(t.loadedID, "eklee-old")
        let c = t.request("broken")
        XCTAssertTrue(t.complete(c, loadedID: "synth"), "a pack that does not decode lands as the synth click")
        XCTAssertEqual(t.loadedID, "synth")
        XCTAssertEqual(t.requestedID, "broken", "not re-requested on every menu open")
    }

    func testVariantPickerNeverRepeatsBackToBack() {
        var picker = VariantPicker()
        var rng = SplitMix64(state: 42)
        var last = -1
        var seen = Set<Int>()
        for _ in 0..<500 {
            let i = picker.pick(.other, count: 4, using: &rng)
            XCTAssertTrue((0..<4).contains(i))
            XCTAssertNotEqual(i, last)
            last = i; seen.insert(i)
        }
        XCTAssertEqual(seen, [0, 1, 2, 3], "every variant gets used")
        XCTAssertEqual(picker.pick(.space, count: 1, using: &rng), 0)
    }

    // MARK: trim + synth

    func testTrimDropsLeadingAndTrailingSilence() {
        let sr = 1000.0
        let s = [Float](repeating: 0, count: 100) + [0.5, -0.4, 0.2] + [Float](repeating: 0.0001, count: 500)
        let r = SampleTrim.range(s, sampleRate: sr, preRoll: 0.002, tail: 0.01)
        XCTAssertEqual(r.lowerBound, 98, "2 ms pre-roll at 1 kHz")
        XCTAssertEqual(r.upperBound, 113, "last loud sample + 10 ms tail")
        XCTAssertTrue(SampleTrim.range([0, 0, 0.001], sampleRate: sr).isEmpty, "all silent")
        XCTAssertTrue(SampleTrim.range([], sampleRate: sr).isEmpty)
        XCTAssertEqual(SampleTrim.range([1, 1], sampleRate: sr, tail: 1), 0..<2, "clamped to the sample")
    }

    func testSynthClickIsShortAudibleAndDeterministic() {
        for c in KeyClass.allCases {
            for v in 0..<SynthClick.variants {
                let s = SynthClick.samples(c, variant: v)
                XCTAssertGreaterThan(s.count, 1000)
                XCTAssertLessThan(Double(s.count) / 44_100, 0.1, "a click, not a chime")
                let peak = s.map(abs).max() ?? 0
                XCTAssertGreaterThan(peak, 0.05)
                XCTAssertLessThanOrEqual(peak, 1)
                XCTAssertEqual(s, SynthClick.samples(c, variant: v))
            }
        }
        XCTAssertNotEqual(SynthClick.samples(.other, variant: 0), SynthClick.samples(.other, variant: 1))
    }
}
