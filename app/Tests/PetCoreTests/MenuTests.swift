import XCTest
@testable import PetCore

final class MenuTests: XCTestCase {
    /// The mock's default rows: staggered `ago` minutes so "recent" sort is visible.
    func defaultRows() -> [MenuRow] {
        [row("build-threads", .working, ago: 2), row("pet", .idle, ago: 45), row("hygiene", .idle, ago: 15),
         row("phone-layer", .idle, ago: 180), row("docs", .idle, ago: 8)]
    }
    func many(_ n: Int) -> [MenuRow] { (1...n).map { row("workflow-\($0)", .idle, ago: Double($0)) } }

    func testPagingMath() {
        // thread pages + 1 usage page, always
        var m = MenuModel()
        m.setRows(many(20))
        XCTAssertEqual(m.threadPageCount, 4); XCTAssertEqual(m.pageCount, 5)
        m.setRows(many(6)); XCTAssertEqual(m.threadPageCount, 1); XCTAssertEqual(m.pageCount, 2)
        m.setRows(many(7)); XCTAssertEqual(m.threadPageCount, 2); XCTAssertEqual(m.pageCount, 3)
        m.setRows([]); XCTAssertEqual(m.threadPageCount, 1); XCTAssertEqual(m.pageCount, 2)
        XCTAssertEqual(m.pagerText, "1 / 2", "the pager always shows now that the usage page exists")
        m.setRows(many(13)); XCTAssertEqual(m.pagerText, "1 / 4")
    }

    func testOpenHighlightsFirstRowSilently() {
        var m = MenuModel()
        m.setRows(defaultRows())
        XCTAssertEqual(m.open(), .menuOpen)
        XCTAssertEqual(m.idx, 0)
        XCTAssertEqual(m.page, 0)
        XCTAssertEqual(m.selected?.name, "build-threads")
    }

    func testArrowsMoveWithCursorSoundOnlyOnChange() {
        var m = MenuModel(); m.setRows(defaultRows()); _ = m.open()
        XCTAssertEqual(m.move(1), .menuCursor); XCTAssertEqual(m.idx, 1)
        XCTAssertEqual(m.move(-1), .menuCursor); XCTAssertEqual(m.idx, 0)
        XCTAssertNil(m.moveTo(0), "same row → no sound")
        XCTAssertEqual(m.moveTo(3), .menuCursor)
    }

    func testSingleThreadPageWrapsThroughUsagePage() {
        var m = MenuModel(); m.setRows(defaultRows()); _ = m.open()
        XCTAssertEqual(m.move(-1), .menuTurn, "up past the first row turns to the usage page")
        XCTAssertTrue(m.isUsagePage)
        XCTAssertEqual(m.idx, -1, "no usage rows yet → nothing highlighted")
        XCTAssertEqual(m.move(1), .menuTurn, "down on an empty usage page wraps to page 1")
        XCTAssertEqual(m.page, 0); XCTAssertEqual(m.idx, 0)
    }

    func testTurnWrapsAndKeepsRow() {
        var m = MenuModel(); m.setRows(many(20)); _ = m.open()
        XCTAssertEqual(m.turn(1, land: .keep), .menuTurn)
        XCTAssertEqual(m.page, 1); XCTAssertEqual(m.idx, 0); XCTAssertEqual(m.pagerText, "2 / 5")
        XCTAssertEqual(m.turn(-1, land: .keep), .menuTurn)
        XCTAssertEqual(m.turn(-1, land: .keep), .menuTurn)
        XCTAssertEqual(m.page, 4, "wraps to the last page, which is usage"); XCTAssertTrue(m.isUsagePage)
        XCTAssertEqual(m.pageRows.count, 0)
        XCTAssertEqual(m.pagerText, "5 / 5")
        XCTAssertEqual(m.turn(-1, land: .keep), .menuTurn)
        XCTAssertEqual(m.page, 3, "last THREAD page"); XCTAssertEqual(m.pageRows.count, 2)
        _ = m.turn(1, land: .keep); _ = m.turn(1, land: .keep)   // back to page 1
        XCTAssertEqual(m.page, 0)
        _ = m.moveTo(5)
        _ = m.turn(1, land: .keep); _ = m.turn(1, land: .keep); _ = m.turn(1, land: .keep)
        XCTAssertEqual(m.page, 3); XCTAssertEqual(m.idx, 1, "keep clamps to the short last thread page")
    }

    func testTurnOnSingleThreadPageGoesToUsage() {
        var m = MenuModel(); m.setRows(defaultRows()); _ = m.open()
        XCTAssertEqual(m.turn(1, land: .keep), .menuTurn)
        XCTAssertTrue(m.isUsagePage); XCTAssertEqual(m.page, 1)
        XCTAssertEqual(m.turn(1, land: .keep), .menuTurn)
        XCTAssertEqual(m.page, 0, "wraps back to page 1")
    }

    func testDownPastLastRowTurnsPageToFirstRow() {
        var m = MenuModel(); m.setRows(many(20)); _ = m.open()
        for _ in 0..<5 { XCTAssertEqual(m.move(1), .menuCursor) }
        XCTAssertEqual(m.idx, 5)
        XCTAssertEqual(m.move(1), .menuTurn, "turn, not cursor")
        XCTAssertEqual(m.page, 1); XCTAssertEqual(m.idx, 0)
        XCTAssertEqual(m.move(-1), .menuTurn)
        XCTAssertEqual(m.page, 0); XCTAssertEqual(m.idx, 5, "up past the first lands on the previous page's last row")
        XCTAssertEqual(m.move(-1), .menuCursor); XCTAssertEqual(m.idx, 4)
    }

    func testRecentSortDefault() {
        var m = MenuModel(); m.setRows(defaultRows())
        XCTAssertEqual(m.sort, .recent)
        XCTAssertEqual(m.sortedRows.map(\.name), ["build-threads", "docs", "hygiene", "pet", "phone-layer"])
    }

    func testStatusSortRedBlueGreenYellowRecentWithin() {
        var rows = defaultRows()
        rows[3].state = .blocked; rows[3].changedAt = 1_000_000 - 3          // phone-layer, red, oldest of the reds
        rows[1].state = .needsInput; rows[1].changedAt = 1_000_000 - 2       // pet, blue
        rows[2].state = .blocked; rows[2].changedAt = 1_000_000 - 1          // hygiene, red, newest
        var m = MenuModel(); m.setRows(rows); _ = m.open()
        XCTAssertEqual(m.sortedRows.map(\.name), ["hygiene", "pet", "phone-layer", "build-threads", "docs"])
        XCTAssertEqual(m.toggleSort(), .menuSelect)
        XCTAssertEqual(m.sort, .status)
        XCTAssertEqual(m.sortedRows.map(\.name), ["hygiene", "phone-layer", "pet", "docs", "build-threads"])
        XCTAssertEqual(m.page, 0); XCTAssertEqual(m.idx, 0)
        _ = m.toggleSort()
        XCTAssertEqual(m.sort, .recent)
    }

    func testSortAppliesAcrossPages() {
        var rows = many(15)
        rows[14].state = .blocked; rows[14].changedAt = 2_000_000
        var m = MenuModel(sort: .status); m.setRows(rows); _ = m.open()
        XCTAssertEqual(m.pageRows.first?.name, "workflow-15")
        let all = m.sortedRows
        _ = m.turn(1, land: .keep)
        XCTAssertEqual(m.pageRows, Array(all[6..<12]), "page 2 continues the same sorted list")
    }

    func testToggleAndKeysInertWhenClosed() {
        var m = MenuModel(); m.setRows(defaultRows())
        XCTAssertNil(m.toggleSort())
        XCTAssertNil(m.move(1))
        XCTAssertNil(m.turn(1, land: .keep))
        XCTAssertEqual(m.idx, -1)
        XCTAssertNil(m.close())
    }

    func testCloseSounds() {
        var m = MenuModel(); m.setRows(defaultRows()); _ = m.open()
        XCTAssertEqual(m.close(), .menuClose)
        _ = m.open()
        XCTAssertNil(m.close(silent: true))
        XCTAssertFalse(m.isOpen)
    }

    func testSelectReturnsHighlightedRow() {
        var m = MenuModel(); m.setRows(defaultRows()); _ = m.open()
        _ = m.move(1)
        let sel = m.select()
        XCTAssertEqual(sel?.row.name, "docs")
        XCTAssertEqual(sel?.sound, .menuSelect)
        m.setRows([])
        XCTAssertNil(m.select())
    }

    func testRefreshKeepsHighlightOnSameThread() {
        var m = MenuModel(); m.setRows(defaultRows()); _ = m.open()
        _ = m.moveTo(2)                                        // hygiene
        var rows = defaultRows()
        rows[2].changedAt = 5_000_000                          // hygiene becomes most recent → first
        m.setRows(rows)
        XCTAssertEqual(m.selected?.name, "hygiene")
        XCTAssertEqual(m.idx, 0)
    }

    func testEmptyRowsSelectNothing() {
        var m = MenuModel(); m.setRows([]); _ = m.open()
        XCTAssertEqual(m.idx, -1)
        XCTAssertNil(m.select())
        XCTAssertEqual(m.move(1), .menuTurn, "down on the empty page turns to the usage page")
        XCTAssertTrue(m.isUsagePage)
        XCTAssertNil(m.select())
    }
}
