import XCTest
@testable import PetCore

final class ColorEngineTests: XCTestCase {
    /// Steps the engine at 60 fps for `seconds`, returning the shown state after each step.
    private func run(_ e: inout ColorEngine, seconds: Double) -> [NaviState?] {
        var seen: [NaviState?] = []
        let steps = Int(seconds * 60)
        for _ in 0..<steps { e.update(dt: 1.0 / 60); seen.append(e.shown) }
        return seen
    }

    func testNoThreadsIsWhite() {
        var e = ColorEngine()
        e.setLive([])
        e.update(dt: 0.016)
        XCTAssertNil(e.shown)
        XCTAssertEqual(e.rgb, RGB(hex: "#ede6e6"))
    }

    func testAllIdleIsGreen() {
        var e = ColorEngine()
        e.setLive([.idle, .idle])
        e.update(dt: 0.016)
        XCTAssertEqual(e.shown, .idle)
        XCTAssertEqual(e.rgb, RGB(63, 185, 80))
    }

    func testSingleStateHoldsWithoutRotating() {
        var e = ColorEngine()
        e.setLive([.blocked])
        let seen = run(&e, seconds: 3)
        XCTAssertEqual(Set(seen.map { $0! }), [.blocked])
    }

    func testTwoStatesRotateEverySecondInOrder() {
        var e = ColorEngine()
        e.setLive([.blocked, .needsInput])
        let seen = run(&e, seconds: 3.05)
        // 0-1s needs_input, 1-2s blocked, 2-3s needs_input
        XCTAssertEqual(seen[30], .needsInput)
        XCTAssertEqual(seen[90], .blocked)
        XCTAssertEqual(seen[150], .needsInput)
        XCTAssertEqual(Set(seen.map { $0! }), [.needsInput, .blocked])
    }

    func testFourWayRotationIncludesIdleLast() {
        var e = ColorEngine()
        e.setLive([.idle, .blocked, .working, .needsInput])
        let seen = run(&e, seconds: 4.05)
        XCTAssertEqual(seen[30], .working)
        XCTAssertEqual(seen[90], .needsInput)
        XCTAssertEqual(seen[150], .blocked)
        XCTAssertEqual(seen[210], .idle)
        XCTAssertEqual(seen[240], .working, "wraps back to the start")
    }

    func testCrossfadeTakes200ms() {
        var e = ColorEngine()
        e.setLive([.idle])
        e.update(dt: 0.016)
        XCTAssertEqual(e.rgb, RGB(63, 185, 80))
        e.setLive([.blocked])
        e.update(dt: 0.1)                                   // half way
        let mid = e.rgb
        XCTAssertNotEqual(mid, RGB(63, 185, 80))
        XCTAssertNotEqual(mid, RGB(hex: "#e5283a"))
        XCTAssertEqual(mid.r, 63 + (229 - 63) * 0.5, accuracy: 1)
        e.update(dt: 0.1)
        XCTAssertEqual(e.rgb, RGB(hex: "#e5283a"))
    }

    func testFirstObservationSnapsNoFade() {
        var e = ColorEngine()
        e.setLive([.working])
        e.update(dt: 0.001)
        XCTAssertEqual(e.rgb, RGB(hex: "#fff8ad"))
    }

    func testSleepOverridesEverything() {
        var e = ColorEngine()
        e.setLive([.blocked, .working])
        e.sleeping = true
        run(&e, seconds: 2)
        XCTAssertEqual(e.shown, .sleep)
        XCTAssertEqual(e.rgb, RGB(hex: "#8a8a8a"))
        e.sleeping = false
        run(&e, seconds: 0.5)
        XCTAssertEqual(e.shown, .working)
    }

    func testWorkingColorPrefFlowsThrough() {
        var e = ColorEngine()
        e.workingColor = "#00ff00"
        e.setLive([.working])
        e.update(dt: 0.016)
        XCTAssertEqual(e.rgb, RGB(0, 255, 0))
    }

    func testUpdateReportsShownChanges() {
        var e = ColorEngine()
        e.setLive([.idle])
        XCTAssertFalse(e.update(dt: 0.016), "first observation is not a change")
        XCTAssertFalse(e.update(dt: 0.016))
        e.setLive([.blocked])
        XCTAssertTrue(e.update(dt: 0.016))
    }

    func testBubbleLifetime() {
        let b = SymbolBubble(state: .blocked, rgb: RGB(hex: "#e5283a"), at: 10)
        XCTAssertEqual(b.symbol, "!")
        XCTAssertEqual(b.alpha(now: 10.06)!, 0.5, accuracy: 0.01)
        XCTAssertEqual(b.alpha(now: 11), 1)
        XCTAssertEqual(b.alpha(now: 11.75)!, 0.5, accuracy: 0.01)
        XCTAssertNil(b.alpha(now: 12.1))
    }
}
