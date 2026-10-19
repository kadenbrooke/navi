import XCTest
@testable import PetCore

/// The menubar Triforce's dropdown: same data, same rows, same sort as Navi's own menu.
final class MenubarDropdownTests: XCTestCase {
    typealias Item = MenubarDropdown.Item
    let now = UsageFormat.parse("2026-10-11T12:10:00Z")!

    func threadLines(_ items: [Item]) -> [MenubarDropdown.ThreadLine] {
        items.compactMap { if case .thread(let l) = $0 { return l } else { return nil } }
    }
    func notes(_ items: [Item]) -> [String] {
        items.compactMap { if case .note(let n) = $0 { return n } else { return nil } }
    }

    // MARK: threads

    func testThreadsUseTheFairyMenusRowsAndSortUnpaged() {
        var resting = row("resting", .working, ago: 1); resting.idle = true
        resting.status = "working · resting"
        let rows = [row("old", .idle, ago: 90), resting, row("blocked", .blocked, ago: 30), row("new", .working, ago: 2)]
            + (1...8).map { row("w\($0)", .idle, ago: Double(100 + $0)) }
        for sort in [MenuSort.recent, .status] {
            var m = MenuModel(sort: sort); m.setRows(rows)
            let items = MenubarDropdown.threadSection(m, workingColor: "#fff8ad")
            XCTAssertEqual(items.first, .header("Build threads · \(sort.rawValue)"))
            let lines = threadLines(items)
            XCTAssertEqual(lines.map(\.id), m.sortedRows.map(\.id), "\(sort): same order as Navi's menu")
            XCTAssertEqual(lines.count, 12, "every row, not one page of 6")
            XCTAssertEqual(lines.last?.id, "resting", "idle rows last whatever the sort")
        }
        var m = MenuModel(); m.setRows(rows)
        let lines = threadLines(MenubarDropdown.threadSection(m, workingColor: "#fff8ad"))
        XCTAssertEqual(lines.first, .init(id: "new", name: "new", status: "", fullStatus: "", stateText: "⟳ working", hex: "#fff8ad", idle: false),
                       "working wears the configured working color")
        let r = lines.first { $0.id == "resting" }!
        XCTAssertEqual(r.stateText, "⟳ idle"); XCTAssertTrue(r.idle); XCTAssertEqual(r.status, "working · resting")
        XCTAssertEqual(lines.first { $0.id == "blocked" }?.hex, NaviState.blocked.hex(workingColor: ""))

        var chatty = row("chatty", .idle, ago: 1); chatty.status = String(repeating: "x", count: 200)
        var c = MenuModel(); c.setRows([chatty])
        let cl = threadLines(MenubarDropdown.threadSection(c, workingColor: "#fff8ad"))[0]
        XCTAssertEqual(cl.status.count, MenubarDropdown.maxLine, "long status capped so the menu stays narrow")
        XCTAssertEqual(cl.fullStatus.count, 200, "uncut text kept for the tooltip")
    }

    func testNoThreadsAndCollectorDown() {
        let empty = MenubarDropdown.threadSection(MenuModel(), workingColor: "#fff8ad")
        XCTAssertEqual(notes(empty), ["no build threads"])
        XCTAssertTrue(threadLines(empty).isEmpty)

        var m = MenuModel(); m.setRows([CollectorHealth.missing.menuRow!])
        let down = threadLines(MenubarDropdown.threadSection(m, workingColor: "#fff8ad"))
        XCTAssertEqual(down.map(\.id), [CollectorHealth.rowId], "the one collector row, clickable like in Navi's menu")
        XCTAssertEqual(down.first?.stateText, "! blocked")
        XCTAssertEqual(down.first?.status, CollectorHealth.installHint)
    }

    func testStateTextMatchesTheFairyRowRules() {
        XCTAssertEqual(MenuRow(id: "a", name: "a", state: .needsInput, changedAt: 0, status: "x").stateText, "? needs input")
        XCTAssertEqual(MenuRow(id: "a", name: "a", state: .needsInput, changedAt: 0, status: "x", idle: true).stateText, "? idle")
        XCTAssertEqual(MenuRow(id: "", name: "no build threads", state: .idle, changedAt: 0, status: "").stateText, "",
                       "placeholder row has no state text")
    }

    // MARK: usage

    func usageModel() -> MenuModel {
        var m = MenuModel()
        m.setUsage([
            UsageRow(harness: "claude", label: "Claude Code · Max 5x",
                     windows: [UsageWindow(name: "5h", usedPct: 38, resetsAt: "2026-10-11T14:24:00Z"), UsageWindow(name: "7d", usedPct: 72)]),
            UsageRow(harness: "windsurf", label: "Windsurf", windows: [], credits: UsageCredits(balance: 500, limit: 50000, unit: "prompt credits", resetsAt: "2026-10-14T12:10:00Z")),
            UsageRow(harness: "agy", label: "Antigravity", windows: [UsageWindow(name: "5h", usedPct: 99)], error: "Antigravity not running"),
            UsageRow(harness: "omnigent", label: "Omnigent", quota: false, costTodayUsd: 204.4),
        ])
        return m
    }

    func testUsageSectionMirrorsTheUsagePage() {
        let items = MenubarDropdown.usageSection(usageModel(), hasUsageData: true, polledAt: "2026-10-11T12:05:00Z", now: now)
        let rows = items.compactMap { if case .usage(let u) = $0 { return u } else { return nil } }
        XCTAssertEqual(rows.map(\.harness), ["claude", "windsurf", "agy"], "quota harnesses only, collector order")
        XCTAssertEqual(rows[0].lines, ["5h · 38% · resets in 2h 14m", "7d · 72%"])
        XCTAssertEqual(rows[0].hex, UsageBar.yellow, "worst window picks the color")
        XCTAssertEqual(rows[1].lines, ["credits · 500/50000 prompt credits · resets in 3d"])
        XCTAssertEqual(rows[2].lines, [], "error rows show the error, no numbers")
        XCTAssertNil(rows[2].hex); XCTAssertEqual(rows[2].error, "Antigravity not running")
        XCTAssertEqual(notes(items), ["no quota: omnigent ($204 today)", "polled 5m ago"])
    }

    func testUsageEmptyStatesAndTitle() {
        XCTAssertEqual(notes(MenubarDropdown.usageSection(MenuModel(), hasUsageData: false, polledAt: "2026-10-11T12:05:00Z", now: now)),
                       ["collector has no usage data yet"], "no polled line without data")
        XCTAssertEqual(notes(MenubarDropdown.usageSection(MenuModel(), hasUsageData: true, polledAt: nil, now: now)),
                       ["no harness reports a quota"])

        XCTAssertEqual(MenubarDropdown.usageTitle(MenuModel()), "Quota usage")
        XCTAssertEqual(MenubarDropdown.usageTitle(usageModel()), "Quota · Claude Code (weekly) 72%",
                       "names the harness and window; the error row's 99% does not count")
        var cursor = usageModel()
        cursor.setUsage(cursor.usage + [UsageRow(harness: "cursor", label: "Cursor · Pro", windows: [
            UsageWindow(name: "cycle total", usedPct: 100), UsageWindow(name: "cycle auto", usedPct: 40)])])
        XCTAssertEqual(MenubarDropdown.usageTitle(cursor), "Quota · Cursor (cycle) 100%")
        var blocked = usageModel()
        blocked.setUsage(blocked.usage + [UsageRow(harness: "codex", label: "Codex · Plus", windows: [UsageWindow(name: "7d", usedPct: 100)], blocked: true)])
        XCTAssertEqual(MenubarDropdown.usageTitle(blocked), "Quota · Codex blocked")
        blocked.setUsage(blocked.usage + [UsageRow(harness: "claude2", label: "Claude Code", windows: [UsageWindow(name: "5h", usedPct: 100)], blocked: true)])
        XCTAssertEqual(MenubarDropdown.usageTitle(blocked), "Quota · Codex blocked (+1)")
    }

    func testSharedUsageFormatting() {
        let r = UsageRow(harness: "codex", sharedBy: ["opencode"], windows: [UsageWindow(name: "7d", usedPct: 100)], blocked: true,
                         blockedReason: "out of messages", note: "Plus plan")
        XCTAssertEqual(r.accentHex, UsageBar.red)
        XCTAssertEqual(r.tooltip, "out of messages · shared by opencode · Plus plan")
        XCTAssertNil(UsageRow(harness: "x").tooltip)
        XCTAssertNil(UsageFormat.polledAgo(nil, now: now))
        XCTAssertEqual(UsageFormat.polledAgo("2026-10-11T12:09:30Z", now: now), "polled just now")
        XCTAssertEqual(UsageFormat.polledAgo("2026-10-11T09:00:00Z", now: now), "polled 3h ago")
    }

    // MARK: text

    func testMenuTextIsOnePlainLine() {
        XCTAssertEqual(MenuText.line("line one\nline two\r\n\tthree  "), "line one line two three", "whitespace collapsed")
        XCTAssertEqual(MenuText.line("a\u{202E}b\u{200B}c\u{07}d"), "abcd", "bidi, zero-width and control characters dropped")
        XCTAssertEqual(MenuText.line(String(repeating: "x", count: 10), max: 5), "xxxx…")
        XCTAssertEqual(MenuText.line(nil), "")
    }

    // MARK: titles

    func testTitles() {
        XCTAssertEqual(MenubarDropdown.visibilityTitle(hidden: true), "Show Navi")
        XCTAssertEqual(MenubarDropdown.visibilityTitle(hidden: false), "Hide Navi")
        XCTAssertEqual(MenubarDropdown.sleepTitle(sleeping: true), "Wake Navi")
        XCTAssertEqual(MenubarDropdown.sleepTitle(sleeping: false), "Sleep Navi")
    }
}
