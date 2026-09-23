import XCTest
@testable import PetCore

/// In-memory stand-in for UserDefaults.
final class MemoryStore: KeyValueStore {
    var bools: [String: Bool] = [:]
    func bool(forKey key: String) -> Bool { bools[key] ?? false }
    func set(_ value: Bool, forKey key: String) { bools[key] = value }
}

final class VisibilityTests: XCTestCase {
    func testStartsShownAndToggles() {
        var v = NaviVisibility()
        XCTAssertFalse(v.hidden)
        XCTAssertTrue(v.toggle())
        XCTAssertTrue(v.hidden)
        XCTAssertFalse(v.toggle())
        XCTAssertFalse(v.hidden)
    }

    func testHideShowReportOnlyRealChanges() {
        var v = NaviVisibility()
        XCTAssertFalse(v.show(), "already shown")
        XCTAssertTrue(v.hide())
        XCTAssertFalse(v.hide(), "already hidden")
        XCTAssertTrue(v.show())
    }

    func testPersistenceRoundTrip() {
        let store = MemoryStore()
        XCTAssertFalse(NaviVisibility(store: store).hidden, "fresh install → shown")
        var v = NaviVisibility(store: store)
        v.hide()
        v.save(to: store)
        XCTAssertTrue(NaviVisibility(store: store).hidden, "relaunch restores hidden")
        v.show()
        v.save(to: store)
        XCTAssertFalse(NaviVisibility(store: store).hidden)
        XCTAssertEqual(Array(store.bools.keys), [NaviVisibility.prefsKey])
    }

    func testHiddenSwallowsPops() {
        var v = NaviVisibility()
        XCTAssertEqual(v.pop(.blocked), .blocked)
        v.hide()
        XCTAssertNil(v.pop(.blocked), "blocked while hidden: no pop, no auto-show — the dot is the signal")
        XCTAssertNil(v.pop(.needsInput))
        XCTAssertFalse(v.allowsSound)
        v.show()
        XCTAssertEqual(v.pop(.idle), .idle)
        XCTAssertTrue(v.allowsSound)
    }

    func testHiddenGateSwallowsSounds() {
        var g = SfxGate()
        g.hidden = true
        XCTAssertFalse(g.request(.naviIn, now: 0))
        XCTAssertFalse(g.request(.menuOpen, now: 0))
        XCTAssertTrue(g.log.isEmpty, "nothing logged while hidden")
        g.hidden = false
        XCTAssertTrue(g.request(NaviVisibility.showSound, now: 1), "show plays navi-in")
        XCTAssertEqual(g.log, [.naviIn])
    }

    func testShowSoundIsNaviInAndStillRateLimited() {
        var g = SfxGate()
        XCTAssertEqual(NaviVisibility.showSound, .naviIn)
        XCTAssertTrue(g.request(.naviIn, now: 5))
        g.hidden = true
        XCTAssertFalse(g.request(.naviIn, now: 5.1))
        g.hidden = false
        XCTAssertFalse(g.request(.naviIn, now: 5.2), "gap still enforced after unhiding")
        XCTAssertTrue(g.request(.naviIn, now: 5.8))
    }

    func testTooltipSuffix() {
        var v = NaviVisibility()
        XCTAssertEqual(v.tooltip("3 threads · 1 blocked"), "3 threads · 1 blocked")
        v.hide()
        XCTAssertEqual(v.tooltip("3 threads · 1 blocked"), "3 threads · 1 blocked · hidden")
    }

    func testMenubarIconSpec() {
        XCTAssertEqual(MenubarIconSpec(live: [.working, .idle], hidden: false), MenubarIconSpec(alert: false, hidden: false))
        XCTAssertTrue(MenubarIconSpec(live: [.blocked], hidden: false).alert)
        XCTAssertTrue(MenubarIconSpec(live: [.working, .needsInput], hidden: true).alert, "alert dot survives hiding")
        XCTAssertEqual(MenubarIconSpec(live: [], hidden: true).opacity, 0.45)
        XCTAssertEqual(MenubarIconSpec(live: [], hidden: false).opacity, 1)
    }
}
