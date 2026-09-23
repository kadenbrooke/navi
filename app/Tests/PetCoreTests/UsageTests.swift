import XCTest
@testable import PetCore

final class UsageTests: XCTestCase {
    func many(_ n: Int) -> [MenuRow] { n == 0 ? [] : (1...n).map { row("workflow-\($0)", .idle, ago: Double($0)) } }
    func usageRows() -> [UsageRow] {
        [UsageRow(harness: "claude", label: "Claude Code · Max 5x", windows: [UsageWindow(name: "5h", usedPct: 38), UsageWindow(name: "7d", usedPct: 12)]),
         UsageRow(harness: "codex", label: "Codex · Plus", windows: [UsageWindow(name: "7d", usedPct: 100)], blocked: true, blockedReason: "out of messages"),
         UsageRow(harness: "agy", label: "Antigravity", error: "Antigravity not running"),
         UsageRow(harness: "opencode", label: "OpenCode", quota: false, note: "API keys, no quota"),
         UsageRow(harness: "omnigent", label: "Omnigent", quota: false, costTodayUsd: 12.35)]
    }

    // MARK: paging

    func testUsagePageIsAlwaysLastForEveryThreadCount() {
        for (n, threadPages) in [(0, 1), (1, 1), (6, 1), (7, 2), (20, 4)] {
            var m = MenuModel(); m.setRows(many(n)); m.setUsage(usageRows())
            XCTAssertEqual(m.threadPageCount, threadPages, "\(n) threads")
            XCTAssertEqual(m.pageCount, threadPages + 1, "\(n) threads")
            XCTAssertEqual(m.usagePageIndex, threadPages, "\(n) threads")
            _ = m.open()
            XCTAssertFalse(m.isUsagePage, "opens on page 1")
            // ← from page 1 wraps to the usage page; → from usage wraps to page 1
            XCTAssertEqual(m.turn(-1, land: .first), .menuTurn)
            XCTAssertTrue(m.isUsagePage, "\(n) threads: ← from page 1 lands on usage")
            XCTAssertEqual(m.pagerText, "\(threadPages + 1) / \(threadPages + 1)")
            XCTAssertEqual(m.pageNote, "usage")
            XCTAssertEqual(m.turn(1, land: .first), .menuTurn)
            XCTAssertEqual(m.page, 0, "\(n) threads: → from usage wraps to page 1")
            XCTAssertEqual(m.pageNote, "recent")
            // → all the way forward also reaches usage as the last page
            for _ in 0..<threadPages { _ = m.turn(1, land: .first) }
            XCTAssertTrue(m.isUsagePage, "\(n) threads: → × threadPages lands on usage")
        }
    }

    func testUsageRowsAreQuotaOnlyAndFooterIsTheRest() {
        var m = MenuModel(); m.setUsage(usageRows())
        XCTAssertEqual(m.usageRows.map(\.harness), ["claude", "codex", "agy"])
        XCTAssertEqual(m.usageFooterRows.map(\.footerText), ["opencode", "omnigent ($12 today)"])
    }

    func testCursorMovesAcrossUsageRowsWithCursorSound() {
        var m = MenuModel(); m.setRows(many(3)); m.setUsage(usageRows()); _ = m.open()
        XCTAssertEqual(m.turn(1, land: .first), .menuTurn)
        XCTAssertTrue(m.isUsagePage)
        XCTAssertEqual(m.currentRowCount, 3)
        XCTAssertEqual(m.idx, 0)
        XCTAssertEqual(m.selectedUsage?.harness, "claude")
        XCTAssertEqual(m.move(1), .menuCursor); XCTAssertEqual(m.selectedUsage?.harness, "codex")
        XCTAssertEqual(m.move(1), .menuCursor); XCTAssertEqual(m.selectedUsage?.harness, "agy")
        XCTAssertNil(m.moveTo(2), "same row → no sound")
        XCTAssertEqual(m.move(1), .menuTurn, "down past the last usage row wraps to page 1")
        XCTAssertEqual(m.page, 0); XCTAssertEqual(m.idx, 0)
        XCTAssertEqual(m.move(-1), .menuTurn, "up from page 1 lands on the LAST usage row")
        XCTAssertTrue(m.isUsagePage); XCTAssertEqual(m.idx, 2)
        XCTAssertNil(m.selected, "thread selection is nil on the usage page")
    }

    func testEnterAndSortAreNoOpsOnUsagePage() {
        var m = MenuModel(); m.setRows(many(3)); m.setUsage(usageRows()); _ = m.open()
        _ = m.turn(-1, land: .first)
        XCTAssertTrue(m.isUsagePage)
        XCTAssertNil(m.select())
        XCTAssertNil(m.toggleSort())
        XCTAssertEqual(m.sort, .recent)
        XCTAssertTrue(m.isUsagePage, "toggleSort did not reset the page")
    }

    func testRefreshKeepsUsagePageWhenThreadsShrink() {
        var m = MenuModel(); m.setRows(many(7)); m.setUsage(usageRows()); _ = m.open()
        _ = m.turn(-1, land: .first)
        XCTAssertEqual(m.page, 2); XCTAssertTrue(m.isUsagePage)
        _ = m.moveTo(2)
        m.setRows(many(2))                                   // thread pages 2 → 1
        XCTAssertTrue(m.isUsagePage); XCTAssertEqual(m.page, 1)
        XCTAssertEqual(m.idx, 2, "highlight survives")
        m.setUsage(Array(usageRows().prefix(1)))             // usage rows 3 → 1
        XCTAssertEqual(m.idx, 0, "highlight clamps to the shorter list")
        m.setUsage([])
        XCTAssertEqual(m.idx, -1)
    }

    func testEmptyUsageWithNoThreads() {
        var m = MenuModel(); m.setRows([]); _ = m.open()
        XCTAssertEqual(m.pageCount, 2)
        _ = m.turn(1, land: .first)
        XCTAssertTrue(m.isUsagePage)
        XCTAssertEqual(m.currentRowCount, 0); XCTAssertEqual(m.idx, -1)
        XCTAssertNil(m.moveTo(0))
    }

    // MARK: colors + format

    func testBarColorThresholds() {
        XCTAssertEqual(UsageBar.hex(forPct: 0), "#3fb950")
        XCTAssertEqual(UsageBar.hex(forPct: 69.9), "#3fb950")
        XCTAssertEqual(UsageBar.hex(forPct: 70), "#fff8ad")
        XCTAssertEqual(UsageBar.hex(forPct: 89.9), "#fff8ad")
        XCTAssertEqual(UsageBar.hex(forPct: 90), "#e5283a")
        XCTAssertEqual(UsageBar.hex(forPct: 100), "#e5283a")
        XCTAssertEqual(UsageBar.hex(forPct: 150), "#e5283a")
        XCTAssertEqual(UsageBar.red, NaviState.blocked.hex(workingColor: "#000000"), "same red as the blocked state")
    }

    func testBarFillClamps() {
        XCTAssertEqual(UsageBar.fill(forPct: 38), 0.38, accuracy: 1e-9)
        XCTAssertEqual(UsageBar.fill(forPct: 108), 1.0)
        XCTAssertEqual(UsageBar.fill(forPct: -5), 0.0)
        XCTAssertEqual(UsageFormat.pct(108.4), "108%")
        XCTAssertEqual(UsageFormat.pct(69.5), "70%")
    }

    func testResetsInHumanizer() {
        let now = UsageFormat.parse("2026-09-18T20:00:00Z")!
        func at(_ s: TimeInterval) -> String { UsageFormat.resetsIn(ISO8601DateFormatter().string(from: now.addingTimeInterval(s)), now: now) }
        XCTAssertEqual(at(30), "30s")
        XCTAssertEqual(at(14 * 60), "14m")
        XCTAssertEqual(at(2 * 3600 + 14 * 60), "2h 14m")
        XCTAssertEqual(at(3 * 86400), "3d")
        XCTAssertEqual(at(3 * 86400 + 5 * 3600), "3d 5h")
        XCTAssertEqual(at(-10), "now")
        XCTAssertEqual(UsageFormat.resetsIn(nil, now: now), "")
        XCTAssertEqual(UsageFormat.resetsIn("garbage", now: now), "")
        XCTAssertEqual(UsageFormat.resetsIn("2026-09-18T23:30:00.828Z", now: now), "3h 30m", "fractional seconds accepted")
    }

    func testCreditsText() {
        XCTAssertEqual(UsageCredits(balance: 500, limit: 50000, unit: "prompt credits").text, "500/50000 prompt credits")
        XCTAssertEqual(UsageCredits(balance: 3.5, unit: "credits").text, "3.5 credits")
        XCTAssertEqual(UsageCredits(balance: 0, limit: 0, unit: "credits").text, "0/0 credits")
    }

    // MARK: decode

    func testDecodeSnapshotWithUsage() throws {
        let json = """
        {"threads":[],"usagePolledAt":"2026-09-18T20:00:00.000Z","usage":[
          {"harness":"claude","label":"Claude Code · Max 5x","plan":"Max 5x","quota":true,
           "windows":[{"name":"5h","usedPct":38,"resetsAt":"2026-09-18T23:30:00.828Z","severity":"normal","active":true},
                      {"name":"7d Fable","usedPct":12,"resetsAt":"2026-09-25T08:00:00.000Z","scope":{"model":"Fable"}}],
           "blocked":false,"source":"x","fetchedAt":"2026-09-18T20:00:00.000Z","error":null},
          {"harness":"openrouter","label":"OpenRouter · free","sharedBy":["hermes","pi"],"quota":true,
           "windows":[{"name":"daily free reqs","usedPct":108,"resetsAt":"2026-09-19T00:00:00.000Z"}],"blocked":true,"blockedReason":"54/50","error":null},
          {"harness":"nous","label":"Nous · Free","quota":true,"windows":[],"credits":{"balance":0,"limit":0,"unit":"credits","resetsAt":"2026-10-02T21:03:53.000Z"},"blocked":false,"error":null},
          {"harness":"agy","label":"Antigravity","quota":true,"windows":[],"blocked":false,"error":"Antigravity not running"},
          {"harness":"omnigent","label":"Omnigent","quota":false,"windows":[],"blocked":false,"costTodayUsd":12.35,"note":"$12 today","error":null},
          {"harness":"future","weird":true}
        ]}
        """
        let snap = try ThreadsParser.parse(Data(json.utf8))
        let usage = try XCTUnwrap(snap.usage)
        XCTAssertEqual(usage.count, 6)
        XCTAssertEqual(snap.usagePolledAt, "2026-09-18T20:00:00.000Z")
        XCTAssertEqual(usage[0].windows.count, 2)
        XCTAssertEqual(usage[0].windows[0].usedPct, 38)
        XCTAssertEqual(usage[0].windows[0].active, true)
        XCTAssertEqual(usage[0].windows[1].name, "7d Fable", "unknown keys like scope are ignored")
        XCTAssertEqual(usage[1].sharedBy, ["hermes", "pi"])
        XCTAssertTrue(usage[1].blocked)
        XCTAssertEqual(usage[1].windows[0].usedPct, 108)
        XCTAssertEqual(usage[2].credits?.text, "0/0 credits")
        XCTAssertEqual(usage[2].detailLineCount, 1)
        XCTAssertEqual(usage[3].error, "Antigravity not running")
        XCTAssertEqual(usage[3].detailLineCount, 0)
        XCTAssertFalse(usage[4].quota)
        XCTAssertEqual(usage[4].footerText, "omnigent ($12 today)")
        XCTAssertEqual(usage[5].label, "future", "label falls back to harness")
        XCTAssertTrue(usage[5].quota, "quota defaults to true")
        XCTAssertEqual(usage[5].windows, [])
    }

    func testDecodeSnapshotWithoutUsage() throws {
        let snap = try ThreadsParser.parse(fixtureData("threads-sample.json"))
        XCTAssertNil(snap.usage, "older collector → nil, the menu shows 'collector has no usage data yet'")
        XCTAssertNil(snap.usagePolledAt)
        var m = MenuModel(); m.setUsage(snap.usage ?? [])
        XCTAssertEqual(m.usageRows, [])
        XCTAssertEqual(m.pageCount, 2, "the usage page still exists")
    }

    func testUsageNeverChangesNaviState() throws {
        // Guard: usage rows are not threads, so the state mapper never sees them.
        let json = """
        {"threads":[{"id":"x","name":"x","state":"idle"}],"usage":[{"harness":"codex","quota":true,"blocked":true,"windows":[{"name":"7d","usedPct":100}]}]}
        """
        let snap = try ThreadsParser.parse(Data(json.utf8))
        XCTAssertEqual(NaviStateMapper.liveSet(snap.threads.map { NaviStateMapper.state(for: $0) }), [.idle])
    }
}
