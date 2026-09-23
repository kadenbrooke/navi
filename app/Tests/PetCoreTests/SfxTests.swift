import XCTest
@testable import PetCore

final class SfxTests: XCTestCase {
    func testNaviInRateLimitedTo700ms() {
        var g = SfxGate()
        XCTAssertTrue(g.request(.naviIn, now: 10))
        XCTAssertFalse(g.request(.naviIn, now: 10.05))
        XCTAssertFalse(g.request(.naviIn, now: 10.69))
        XCTAssertTrue(g.request(.naviIn, now: 10.7))
        XCTAssertEqual(g.log.filter { $0 == .naviIn }.count, 2)
    }

    func testOtherSoundsNeverLimited() {
        var g = SfxGate()
        for _ in 0..<5 { XCTAssertTrue(g.request(.menuCursor, now: 1)) }
        XCTAssertEqual(g.log.count, 5)
    }

    func testDisabledPlaysNothing() {
        var g = SfxGate(); g.enabled = false
        XCTAssertFalse(g.request(.menuOpen, now: 0))
        XCTAssertTrue(g.log.isEmpty)
    }

    func testNoNaviOutExists() {
        XCTAssertFalse(SoundID.allCases.map(\.rawValue).contains("navi-out"))
        XCTAssertEqual(SoundID.allCases.count, 6)
    }
}
