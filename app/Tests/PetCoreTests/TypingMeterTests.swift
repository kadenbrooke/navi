import XCTest
@testable import PetCore

final class TypingMeterTests: XCTestCase {
    let day = "2026-10-20"

    /// `perSecond` presses a second for `seconds`, starting at `from`. Returns the last press time.
    @discardableResult
    func type(_ m: inout TypingMeter, perSecond: Double, seconds: Double, from: Double = 1000, day: String? = nil) -> Double {
        let n = Int(perSecond * seconds)
        var t = from
        for i in 0..<n { t = from + Double(i) / perSecond; m.record(at: t, day: day ?? self.day) }
        return t
    }

    func testSteadyTypingReadsItsSpeed() {
        var m = TypingMeter(stats: TypingStats(day: day))
        let last = type(&m, perSecond: 5, seconds: 30)   // 5 keys/s = 60 wpm
        XCTAssertEqual(m.liveWPM(at: last), 60, accuracy: 2)
        XCTAssertEqual(m.stats.bestWPM, 60, accuracy: 2)
        XCTAssertEqual(m.stats.averageWPM ?? 0, 60, accuracy: 2)
        XCTAssertEqual(m.stats.keystrokes, 150)
        XCTAssertEqual(m.stats.activeSeconds, 29.8, accuracy: 0.01)
        XCTAssertTrue(m.dirty)
    }

    func testLiveIsZeroAfterAPauseAndPausesAreNotTypingTime() {
        var m = TypingMeter(stats: TypingStats(day: day))
        let end = type(&m, perSecond: 5, seconds: 20)
        XCTAssertEqual(m.liveWPM(at: end + 2), 48, accuracy: 3, "slows as the window empties")
        XCTAssertEqual(m.liveWPM(at: end + TypingMeter.pauseGap + 0.1), 0)
        let active = m.stats.activeSeconds
        type(&m, perSecond: 5, seconds: 20, from: end + 600)   // ten minutes later
        XCTAssertEqual(m.stats.activeSeconds, active * 2, accuracy: 0.01, "the 10-minute gap is not typing time")
        XCTAssertEqual(m.stats.averageWPM ?? 0, 60, accuracy: 2)
    }

    func testFirstPressesDoNotSpike() {
        var m = TypingMeter(stats: TypingStats(day: day))
        m.record(at: 0, day: day); m.record(at: 0.1, day: day); m.record(at: 0.2, day: day)
        XCTAssertLessThanOrEqual(m.liveWPM(at: 0.2), 12, "3 presses over a 3 s floor, not 360 wpm")
        XCTAssertEqual(m.stats.bestWPM, 0, "best waits for a full window")
        XCTAssertNil(m.stats.averageWPM, "average waits for 10 s of typing")
    }

    func testFasterBurstRaisesBestOnly() {
        var m = TypingMeter(stats: TypingStats(day: day))
        let a = type(&m, perSecond: 5, seconds: 15)
        let b = type(&m, perSecond: 10, seconds: 15, from: a + 60)
        XCTAssertEqual(m.stats.bestWPM, 120, accuracy: 3)
        type(&m, perSecond: 3, seconds: 15, from: b + 60)
        XCTAssertEqual(m.stats.bestWPM, 120, accuracy: 3, "a slower burst does not lower best")
    }

    func testNewDayStartsFresh() {
        var m = TypingMeter(stats: TypingStats(day: "2026-10-19", keystrokes: 900, activeSeconds: 600, bestWPM: 99))
        XCTAssertEqual(m.today(day), TypingStats(day: day), "yesterday's stats never read as today")
        m.record(at: 5, day: day)
        XCTAssertEqual(m.stats.day, day)
        XCTAssertEqual(m.stats.keystrokes, 1)
        XCTAssertEqual(m.stats.bestWPM, 0)
    }

    func testDayKeyIsLocalCalendarDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let late = ISO8601DateFormatter().date(from: "2026-10-21T05:30:00Z")!   // 22:30 the 20th in Los Angeles
        XCTAssertEqual(TypingStats.dayKey(late, calendar: cal), "2026-10-20")
    }

    func testStatsPersistForTheSameDayOnly() {
        let store = MemoryStringStore()
        let s = TypingStats(day: day, keystrokes: 1234, activeSeconds: 321.5, bestWPM: 88)
        s.save(to: store)
        XCTAssertEqual(TypingStats.load(from: store, today: day), s)
        XCTAssertNil(TypingStats.load(from: store, today: "2026-10-21"), "a restart on a new day starts fresh")
        store.values[TypingStats.prefsKey] = "garbage"
        XCTAssertNil(TypingStats.load(from: store, today: day))
        XCTAssertNil(TypingStats.load(from: MemoryStringStore(), today: day))
    }

    func testRecentWindowStaysBounded() {
        var m = TypingMeter(stats: TypingStats(day: day))
        let last = type(&m, perSecond: 20, seconds: 120)
        // 20 keys/s for 2 minutes: the live count only ever holds the last window.
        XCTAssertEqual(m.liveWPM(at: last), 240, accuracy: 4)
    }
}
