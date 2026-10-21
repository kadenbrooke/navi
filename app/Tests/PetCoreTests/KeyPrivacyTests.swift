import XCTest
@testable import PetCore

/// Rule: never store, log or send which keys were pressed. These tests run the same
/// pipeline the app runs on every key-down (filter → meter → save) and prove the persisted
/// state carries no trace of the keys.
final class KeyPrivacyTests: XCTestCase {
    let day = "2026-10-20"

    /// What the app does with one key-down, minus the click: filter, count, and (periodically) save.
    func session(_ keyCodes: [UInt16], store: MemoryStringStore) {
        KeySoundSettings(enabled: true, profile: "eklee-old", volume: 0.7).save(to: store)
        var meter = TypingMeter(stats: TypingStats.load(from: store, today: day) ?? TypingStats(day: day))
        // The in-memory sound path runs too (plan lookup + press/release pairing); none of it
        // may reach the store.
        let plan = KeySoundPlan(PackInventory(generic: 5, classes: [.space: 1], rows: [1: 1], perKey: [16, 30]))
        var pairing = KeyPairing()
        var router = KeyStrokeRouter()
        for (i, code) in keyCodes.enumerated() {
            let t = Double(i)
            for case .down(let c) in router.keyDown(code, isRepeat: false, flags: 0, now: t) where pairing.keyDown(c, isRepeat: false) && plan.voice(c) != nil {
                pairing.pressSounded(c, generation: 1)
            }
            for case .up(let c) in router.keyUp(code, now: t + 0.1) where pairing.keyUp(c, generation: 1) { _ = plan.voice(c)?.release }
            // A modifier tapped on its own between keys: same in-memory path, nothing saved.
            for case .down(let c) in router.flagsChanged(keyCode: 56, flags: 0x20002, now: t + 0.2) { _ = pairing.keyDown(c, isRepeat: false) }
            for case .up(let c) in router.flagsChanged(keyCode: 56, flags: 0, now: t + 0.3) { _ = pairing.keyUp(c, generation: 1) }
            guard let press = KeyEventFilter.press(keyCode: code, isRepeat: false, command: false, control: false) else { continue }
            if press.countsAsTyping { meter.record(at: 100 + Double(i) * 0.15, day: day) }
            if i % 50 == 49 { meter.stats.save(to: store) }
        }
        meter.stats.save(to: store)
    }

    /// "my password is hunter2" vs a different, same-length key sequence including space,
    /// enter and backspace: same timings, so the saved bytes must be identical.
    func testPersistedStateIsIdenticalWhicheverKeysWereTyped() {
        let secret: [UInt16] = [46, 16, 49, 35, 0, 1, 1, 13, 31, 15, 2, 49, 34, 1, 49, 4, 32, 45, 17, 14, 15, 19]
        let other: [UInt16] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 51, 36, 49, 117, 76, 6, 7, 8, 9, 11]
        XCTAssertEqual(secret.count, other.count)
        let a = MemoryStringStore(), b = MemoryStringStore()
        session(Array(repeating: secret, count: 20).flatMap { $0 }, store: a)
        session(Array(repeating: other, count: 20).flatMap { $0 }, store: b)
        XCTAssertEqual(a.values.keys.sorted(), b.values.keys.sorted())
        for k in a.values.keys {
            XCTAssertEqual(a.values[k] as? String, b.values[k] as? String, "\(k) differs with the keys typed → it leaks them")
        }
    }

    func testOnlyAllowlistedKeysAndFieldsArePersisted() throws {
        let store = MemoryStringStore()
        session((0..<300).map { UInt16($0 % 128) }, store: store)
        XCTAssertEqual(Set(store.values.keys), [KeySoundSettings.prefsKey, TypingStats.prefsKey])

        let stats = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(store.string(forKey: TypingStats.prefsKey)).utf8)) as? [String: Any])
        XCTAssertEqual(Set(stats.keys), ["day", "keystrokes", "activeSeconds", "bestWPM"])
        for (k, v) in stats where k != "day" { XCTAssertTrue(v is NSNumber, "\(k) must be a bare count/duration") }
        XCTAssertEqual(stats["day"] as? String, day)

        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(store.string(forKey: KeySoundSettings.prefsKey)).utf8)) as? [String: Any])
        XCTAssertEqual(Set(settings.keys), ["enabled", "profile", "volume", "quietOnCalls"])
    }

    func testStatsTypeHasNoRoomForKeyData() {
        // If someone adds a field to TypingStats, this fails and makes them look at this rule.
        let fields = Mirror(reflecting: TypingStats(day: day)).children.compactMap(\.label)
        XCTAssertEqual(fields, ["day", "keystrokes", "activeSeconds", "bestWPM"])
        // The meter's only input is a time and a day: no key code, no class.
        var m = TypingMeter(stats: TypingStats(day: day))
        m.record(at: 1, day: day)
        let meterFields = Set(Mirror(reflecting: m).children.compactMap(\.label))
        XCTAssertEqual(meterFields, ["stats", "recent", "last", "burstStart", "dirty"])
    }
}
