import XCTest
@testable import PetCore

/// The collector → Navi mapping, one branch per test. Mirrors the README table.
final class StateMappingTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var fresh: Date { now.addingTimeInterval(-60) }
    var old: Date { now.addingTimeInterval(-3 * 3600) }

    func testStaleIsBlocked() {
        XCTAssertEqual(NaviStateMapper.state(for: thread("a", .stale), now: now), .blocked)
        // even with a live agent — rot outranks activity
        XCTAssertEqual(NaviStateMapper.state(for: thread("a", .stale, sessions: [session("claude", "running", seen: fresh)]), now: now), .blocked)
    }

    func testFailedSessionIsBlockedOnlyWhileRecent() {
        XCTAssertEqual(NaviStateMapper.state(for: thread("a", .idle, sessions: [session("omnigent", "failed", seen: fresh)]), now: now), .blocked)
        XCTAssertEqual(NaviStateMapper.state(for: thread("a", .idle, sessions: [session("omnigent", "failed", seen: old)]), now: now), .idle)
    }

    func testReviewReadyPRNeedsInput() {
        XCTAssertEqual(NaviStateMapper.state(for: thread("a", .prOpen, reviewReady: true), now: now), .needsInput)
        XCTAssertEqual(NaviStateMapper.state(for: thread("a", .prOpen, reviewReady: false), now: now), .idle, "waiting on a reviewer is not waiting on you")
    }

    func testAgentAskingForPermissionNeedsInputRegardlessOfAge() {
        let t = thread("a", .uncommitted, sessions: [session("claude", "blocked", seen: old)])
        XCTAssertEqual(NaviStateMapper.state(for: t, now: now), .needsInput)
    }

    func testLiveAgentIsWorking() {
        XCTAssertEqual(NaviStateMapper.state(for: thread("a", .active), now: now), .working)
        XCTAssertEqual(NaviStateMapper.state(for: thread("a", .idle, sessions: [session("claude", "running", seen: fresh)]), now: now), .working)
        XCTAssertEqual(NaviStateMapper.state(for: thread("a", .uncommitted, sessions: [session("omnigent", "running", seen: old)]), now: now), .working, "running counts even if the last state change was long ago")
    }

    // Design rule: idle means the PARENT's turn ended — recency and children never
    // keep a row yellow. (Previously "seen within 10 min" read as working; that is the 10-minute
    // dim rule's job, carried by the collector's `idle` flag, not a state.)
    func testTurnFinishedIsIdleEvenWhenSeenSecondsAgo() {
        XCTAssertEqual(NaviStateMapper.state(for: thread("a", .idle, sessions: [session("claude", "waiting", seen: fresh)]), now: now), .idle)
        XCTAssertEqual(NaviStateMapper.state(for: thread("a", .idle, sessions: [session("omnigent", "idle", seen: fresh)]), now: now), .idle)
    }

    func testRunningSubAgentNeverMakesParentRowWorking() {
        var child = session("omnigent", "running", seen: fresh)
        child.child = true
        let parent = session("omnigent", "idle", seen: fresh)
        XCTAssertEqual(NaviStateMapper.state(for: thread("a", .idle, sessions: [parent, child]), now: now), .idle)
        // the collector's own verdict is the same parent-only rule; `active` still wins
        XCTAssertEqual(NaviStateMapper.state(for: thread("a", .active, sessions: [parent, child]), now: now), .working)
        // a child asking a question is still a question for you
        var asking = session("claude", "blocked", seen: fresh)
        asking.child = true
        XCTAssertEqual(NaviStateMapper.state(for: thread("a", .idle, sessions: [parent, asking]), now: now), .needsInput)
    }

    func testAbandonedUncommittedIsBlocked() {
        XCTAssertEqual(NaviStateMapper.state(for: thread("a", .uncommitted), now: now), .blocked)
        XCTAssertEqual(NaviStateMapper.state(for: thread("a", .uncommitted, sessions: [session("claude", "waiting", seen: old)]), now: now), .blocked)
    }

    func testAbandonedUnpushedNeedsInput() {
        XCTAssertEqual(NaviStateMapper.state(for: thread("a", .unpushed), now: now), .needsInput)
    }

    func testQuietStatesAreIdle() {
        for s: ThreadState in [.idle, .merged, .unknown] {
            XCTAssertEqual(NaviStateMapper.state(for: thread("a", s), now: now), .idle, "\(s)")
        }
    }

    func testPriorityFailedBeatsAsking() {
        let t = thread("a", .idle, sessions: [session("claude", "blocked", seen: fresh), session("omnigent", "failed", seen: fresh)])
        XCTAssertEqual(NaviStateMapper.state(for: t, now: now), .blocked)
    }

    func testRealSampleMapsWithoutCrashing() throws {
        let snap = try ThreadsParser.parse(fixtureData("threads-sample.json"))
        let states = snap.threads.map { NaviStateMapper.state(for: $0, now: now) }
        XCTAssertEqual(states.count, 16)
        XCTAssertEqual(NaviStateMapper.state(for: snap.threads.first { $0.name == "demo-recording" }!, now: now), .blocked)
    }

    func testLiveSetIsDistinctInRotationOrderIncludingIdle() {
        XCTAssertEqual(NaviStateMapper.liveSet([.idle, .blocked, .idle, .working, .needsInput]), [.working, .needsInput, .blocked, .idle])
        XCTAssertEqual(NaviStateMapper.liveSet([.idle, .idle]), [.idle])
        XCTAssertEqual(NaviStateMapper.liveSet([]), [])
    }

    func testColorsAndSymbols() {
        XCTAssertEqual(NaviState.working.hex(workingColor: "#fff8ad"), "#fff8ad")
        XCTAssertEqual(NaviState.working.hex(workingColor: "#123456"), "#123456")
        XCTAssertEqual(NaviState.idle.hex(workingColor: "#fff8ad"), "#3fb950")
        XCTAssertEqual(NaviState.needsInput.hex(workingColor: "#fff8ad"), "#4aa8ff")
        XCTAssertEqual(NaviState.blocked.hex(workingColor: "#fff8ad"), "#e5283a")
        XCTAssertEqual(NaviState.sleep.hex(workingColor: "#fff8ad"), "#8a8a8a")
        XCTAssertEqual(NaviState.allCases.map(\.symbol), ["⟳", "?", "!", "✓", "zzz"])
        XCTAssertEqual(RGB(hex: "#3fb950"), RGB(63, 185, 80))
        XCTAssertEqual(RGB(hex: "#3fb950").hex, "#3fb950")
    }
}
