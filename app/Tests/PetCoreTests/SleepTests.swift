import XCTest
@testable import PetCore

final class SleepTests: XCTestCase {
    func testNapsAfterThresholdOfNoChanges() {
        var s = SleepTimer(threshold: 600, now: 0)
        XCTAssertFalse(s.tick(now: 599))
        XCTAssertFalse(s.sleeping)
        XCTAssertTrue(s.tick(now: 600))
        XCTAssertTrue(s.sleeping)
        XCTAssertFalse(s.tick(now: 601), "only reports the tick she falls asleep")
    }

    func testChangeResetsTimer() {
        var s = SleepTimer(threshold: 600, now: 0)
        _ = s.tick(now: 500)
        XCTAssertFalse(s.noteChange(now: 500), "not asleep, nothing to wake")
        XCTAssertFalse(s.tick(now: 1000))
        XCTAssertTrue(s.tick(now: 1100))
    }

    func testChangeWakes() {
        var s = SleepTimer(threshold: 600, now: 0)
        _ = s.tick(now: 600)
        XCTAssertTrue(s.sleeping)
        XCTAssertTrue(s.noteChange(now: 700))
        XCTAssertFalse(s.sleeping)
        XCTAssertFalse(s.tick(now: 1299))
        XCTAssertTrue(s.tick(now: 1300))
    }

    func testManualSleepAndClickWake() {
        var s = SleepTimer(threshold: 600, now: 0)
        s.sleep(now: 10)
        XCTAssertTrue(s.sleeping)
        XCTAssertTrue(s.wake(now: 20))
        XCTAssertFalse(s.wake(now: 21), "already awake")
        XCTAssertFalse(s.tick(now: 619))
        XCTAssertTrue(s.tick(now: 620), "timer restarts from the wake")
    }

    func testZeroThresholdNeverAutoSleeps() {
        var s = SleepTimer(threshold: 0, now: 0)
        XCTAssertFalse(s.tick(now: 1_000_000))
    }
}
