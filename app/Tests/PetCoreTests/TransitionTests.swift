import XCTest
@testable import PetCore

final class TransitionTests: XCTestCase {
    typealias Obs = (id: String, state: NaviState)

    func testFirstObservationIsSilent() {
        var d = TransitionDetector()
        XCTAssertEqual(d.observe([("a", .blocked), ("b", .working)]).count, 0)
    }

    func testUnchangedObservationIsSilent() {
        var d = TransitionDetector()
        _ = d.observe([("a", .blocked)])
        for _ in 0..<20 { XCTAssertTrue(d.observe([("a", .blocked)]).isEmpty) }
    }

    func testAnyThreadChangePops() {
        var d = TransitionDetector()
        _ = d.observe([("a", .idle), ("b", .idle)])
        let ch = d.observe([("a", .idle), ("b", .working)])
        XCTAssertEqual(ch, [.init(id: "b", from: .idle, to: .working)])
    }

    func testPopsEvenWhenColorSetIsUnchanged() {
        // a: blocked, b: needs_input → b also blocked. Set {blocked, needs_input} → {blocked}?
        // No: keep set identical: a needs_input→blocked while c stays needs_input.
        var d = TransitionDetector()
        _ = d.observe([("a", .needsInput), ("b", .blocked), ("c", .needsInput)])
        let ch = d.observe([("a", .blocked), ("b", .blocked), ("c", .needsInput)])
        XCTAssertEqual(ch.map(\.id), ["a"])
        XCTAssertEqual(TransitionDetector.popState(for: ch), .blocked)
    }

    func testNewThreadPopsRemovedThreadDoesNot() {
        var d = TransitionDetector()
        _ = d.observe([("a", .idle)])
        let ch = d.observe([("b", .working)])
        XCTAssertEqual(ch, [.init(id: "b", from: nil, to: .working)])
    }

    func testLatestWinsWhenSeveralChangeAtOnce() {
        var d = TransitionDetector()
        _ = d.observe([("a", .idle), ("b", .idle)])
        let ch = d.observe([("a", .blocked), ("b", .needsInput)])
        XCTAssertEqual(ch.count, 2)
        XCTAssertEqual(TransitionDetector.popState(for: ch), .needsInput)
        XCTAssertNil(TransitionDetector.popState(for: []))
    }

    func testFallingBackToIdlePopsCheck() {
        var d = TransitionDetector()
        _ = d.observe([("a", .working)])
        XCTAssertEqual(TransitionDetector.popState(for: d.observe([("a", .idle)])), .idle)
    }

    // MARK: idle alerts — the "waiting on you" notification

    func testIdleAlertFiresOnlyOnWorkingToIdle() {
        var d = TransitionDetector()
        let threads = [thread("omnigent:p1", .idle), thread("cli", .idle)]
        _ = d.observe([("omnigent:p1", .working), ("cli", .working), ("x", .blocked)])
        let ch = d.observe([("omnigent:p1", .idle), ("cli", .needsInput), ("x", .idle)])
        let alerts = IdleAlert.alerts(for: ch, threads: threads)
        XCTAssertEqual(alerts, [IdleAlert(id: "omnigent:p1", name: "omnigent:p1")])
        XCTAssertEqual(alerts[0].message, "omnigent:p1 is waiting on you")
    }

    func testIdleAlertUsesThreadNameAndSkipsNewAndUnchangedRows() {
        var d = TransitionDetector()
        var named = thread("omnigent:p1", .idle)
        named.name = "ship the thing"
        // first observation: silent, even if a row starts idle
        XCTAssertTrue(IdleAlert.alerts(for: d.observe([("omnigent:p1", .idle)]), threads: [named]).isEmpty)
        // idle → idle: nothing
        XCTAssertTrue(IdleAlert.alerts(for: d.observe([("omnigent:p1", .idle)]), threads: [named]).isEmpty)
        // idle → working → idle: one alert, named for people
        _ = d.observe([("omnigent:p1", .working)])
        let alerts = IdleAlert.alerts(for: d.observe([("omnigent:p1", .idle)]), threads: [named])
        XCTAssertEqual(alerts.map(\.message), ["ship the thing is waiting on you"])
        // a brand-new row appearing idle: no alert
        XCTAssertTrue(IdleAlert.alerts(for: d.observe([("omnigent:p1", .idle), ("new", .idle)]), threads: [named]).isEmpty)
    }

    func testIdleAlertCooldownIsPerThreadAndExpiresAtTheBoundary() {
        var cooldown = IdleAlertCooldown(interval: 60)

        XCTAssertTrue(cooldown.shouldPost(threadID: "a", now: 100))
        XCTAssertFalse(cooldown.shouldPost(threadID: "a", now: 159.999))
        XCTAssertTrue(cooldown.shouldPost(threadID: "b", now: 159.999))
        XCTAssertTrue(cooldown.shouldPost(threadID: "a", now: 160))
    }
}
