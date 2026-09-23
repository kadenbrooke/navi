import Foundation

/// One row of Navi's menu.
public struct MenuRow: Equatable, Sendable {
    public var id: String
    public var name: String
    public var state: NaviState
    /// Seconds since 1970 of the last Navi-state change the pet saw for this thread.
    public var changedAt: Double
    /// One-line plain-English status from the collector (stateLabel / detail).
    public var status: String
    /// Collector says this live row has been resting past its active window. Still listed,
    /// drawn dimmed, sorted after the rows that are doing something.
    public var idle: Bool

    public init(id: String, name: String, state: NaviState, changedAt: Double, status: String, idle: Bool = false) {
        self.id = id; self.name = name; self.state = state; self.changedAt = changedAt; self.status = status; self.idle = idle
    }
}

/// Which sound an operation asks for. The app maps these to clips; tests assert on them.
public enum SoundID: String, CaseIterable, Sendable {
    case menuOpen = "menu-open"
    case menuClose = "menu-close"
    case menuCursor = "menu-cursor"
    case menuSelect = "menu-select"
    case menuTurn = "menu-turn"
    case naviIn = "navi-in"
}

/// Paging + cursor + sort math for the menu, port of the design mock §10. Rows are sorted across
/// ALL threads first, then cut into pages of `perPage`. `idx` is within the current page.
///
/// The LAST page is always the usage page (per-harness quota). It participates in ←/→ and
/// ↑/↓ paging exactly like a thread page; its rows are `usageRows` (quota harnesses only).
/// Enter on a usage row is a no-op and sort does not apply there.
public struct MenuModel: Sendable {
    public static let perPage = 6

    public private(set) var rows: [MenuRow] = []
    public private(set) var usage: [UsageRow] = []
    public private(set) var page = 0
    public private(set) var idx = -1
    public var sort: MenuSort = .recent
    public private(set) var isOpen = false

    public init(sort: MenuSort = .recent) { self.sort = sort }

    public enum Land: Sendable { case first, last, keep }

    // MARK: derived

    /// Pages of threads (min 1, so an empty list still has a "no build threads" page).
    public var threadPageCount: Int { max(1, Int(ceil(Double(rows.count) / Double(MenuModel.perPage)))) }
    /// Thread pages + the usage page.
    public var pageCount: Int { threadPageCount + 1 }
    public var usagePageIndex: Int { pageCount - 1 }
    public var isUsagePage: Bool { page == usagePageIndex }

    /// Rows shown on the usage page: every harness that has a quota, in collector order.
    public var usageRows: [UsageRow] { usage.filter(\.quota) }
    /// `quota:false` rows folded into the footer line.
    public var usageFooterRows: [UsageRow] { usage.filter { !$0.quota } }
    /// Row count of whatever page is showing (drives cursor math).
    public var currentRowCount: Int { isUsagePage ? usageRows.count : pageRows.count }
    /// Highlighted usage row, if the cursor is on the usage page.
    public var selectedUsage: UsageRow? {
        guard isUsagePage else { return nil }
        let u = usageRows
        return idx >= 0 && idx < u.count ? u[idx] : nil
    }

    /// Active rows first, idle rows after, whatever the sort; within each half the chosen
    /// sort applies (`recent` = newest activity / state change first).
    public var sortedRows: [MenuRow] {
        let byRecent: (MenuRow, MenuRow) -> Bool = { a, b in
            if a.changedAt != b.changedAt { return a.changedAt > b.changedAt }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        let inner: (MenuRow, MenuRow) -> Bool
        switch sort {
        case .recent: inner = byRecent
        case .status: inner = { a, b in
            if a.state.statusRank != b.state.statusRank { return a.state.statusRank < b.state.statusRank }
            return byRecent(a, b)
        }
        }
        return rows.sorted { a, b in
            if a.idle != b.idle { return !a.idle }
            return inner(a, b)
        }
    }

    /// Thread rows on this page; empty on the usage page.
    public var pageRows: [MenuRow] {
        guard !isUsagePage else { return [] }
        let all = sortedRows
        let lo = min(all.count, page * MenuModel.perPage)
        let hi = min(all.count, lo + MenuModel.perPage)
        return Array(all[lo..<hi])
    }

    public var selected: MenuRow? {
        let pr = pageRows
        return idx >= 0 && idx < pr.count ? pr[idx] : nil
    }

    /// `◂ 1 / N ▸` — always shown now that the usage page makes every menu 2+ pages.
    public var pagerText: String? { pageCount > 1 ? "\(page + 1) / \(pageCount)" : nil }
    /// The note after the pager: `· usage` on the usage page, else the sort name.
    public var pageNote: String { isUsagePage ? "usage" : sort.rawValue }

    // MARK: rows

    /// Replace the rows (collector refresh). Keeps the page clamped and the highlight on the
    /// same thread id if it is still on this page.
    public mutating func setRows(_ new: [MenuRow]) {
        let keepId = selected?.id
        let wasUsage = isUsagePage
        rows = new
        page = wasUsage ? usagePageIndex : min(page, usagePageIndex - 1)
        if wasUsage { clampIdx(); return }
        if isOpen, let keepId, let i = pageRows.firstIndex(where: { $0.id == keepId }) { idx = i }
        else if isOpen { idx = pageRows.isEmpty ? -1 : min(max(idx, 0), pageRows.count - 1) }
    }

    /// Replace the usage rows (collector refresh). Keeps the highlight clamped on the usage page.
    public mutating func setUsage(_ new: [UsageRow]) {
        usage = new
        if isUsagePage { clampIdx() }
    }

    private mutating func clampIdx() {
        guard isOpen else { idx = -1; return }
        let n = currentRowCount
        idx = n == 0 ? -1 : min(max(idx, 0), n - 1)
    }

    // MARK: open / close

    /// Opens on page 1 with the first row highlighted (no cursor sound). Returns menu-open.
    public mutating func open() -> SoundID {
        isOpen = true; page = 0; idx = -1
        _ = moveTo(0, quiet: true)
        return .menuOpen
    }

    /// Returns menu-close unless `silent` (select and sleep close silently).
    public mutating func close(silent: Bool = false) -> SoundID? {
        guard isOpen else { return nil }
        isOpen = false; idx = -1
        return silent ? nil : .menuClose
    }

    // MARK: cursor

    /// Highlight row `i` on this page (clamped). Cursor sound only when it actually changes.
    @discardableResult
    public mutating func moveTo(_ i: Int, quiet: Bool = false) -> SoundID? {
        guard isOpen else { return nil }
        let n = currentRowCount
        guard n > 0 else { idx = -1; return nil }
        let j = max(0, min(n - 1, i))
        guard j != idx else { return nil }
        idx = j
        return quiet ? nil : .menuCursor
    }

    /// ↑/↓. Past the last row → next page's first; past the first → previous page's last.
    /// On a single page it wraps within the page with the cursor sound.
    public mutating func move(_ delta: Int) -> SoundID? {
        guard isOpen else { return nil }
        let n = currentRowCount
        let t = idx + delta
        if t >= n { return pageCount > 1 ? turn(1, land: .first) : moveTo(0) }
        if t < 0 { return pageCount > 1 ? turn(-1, land: .last) : moveTo(n - 1) }
        return moveTo(t)
    }

    /// ←/→ or the pager tabs. Wraps. Plays menu-turn, never menu-cursor. No-op on one page.
    public mutating func turn(_ delta: Int, land: Land) -> SoundID? {
        guard isOpen, pageCount > 1 else { return nil }
        let prev = idx
        page = ((page + delta) % pageCount + pageCount) % pageCount
        idx = -1
        let n = currentRowCount
        let target: Int
        switch land {
        case .first: target = 0
        case .last: target = n - 1
        case .keep: target = min(max(prev, 0), n - 1)
        }
        _ = moveTo(target, quiet: true)
        return .menuTurn
    }

    /// Tab or the header button. Resets to page 1, first row. Plays menu-select.
    /// No-op on the usage page (sort only orders threads).
    public mutating func toggleSort() -> SoundID? {
        guard isOpen, !isUsagePage else { return nil }
        sort = sort.toggled
        page = 0; idx = -1
        _ = moveTo(0, quiet: true)
        return .menuSelect
    }

    /// Enter. Returns the row to act on (and menu-select) or nil when nothing is highlighted.
    /// Always nil on the usage page — Enter there is a no-op.
    public mutating func select() -> (row: MenuRow, sound: SoundID)? {
        guard isOpen, !isUsagePage, let row = selected else { return nil }
        return (row, .menuSelect)
    }
}

/// Rate limit + log for sounds. `navi-in` (the one notification sound) is capped at one per
/// 700 ms; everything else always plays. Clock injected so tests can step time.
/// `hidden` (Navi ordered out via the menubar Triforce) swallows everything: a hidden fairy
/// makes no noise. The caller flips `hidden` off before requesting the show sound.
public struct SfxGate: Sendable {
    public static let naviInMinGap: Double = 0.7
    public private(set) var log: [SoundID] = []
    private var lastNaviIn: Double = -.infinity
    public var enabled = true
    public var hidden = false

    public init() {}

    /// Returns true if the sound should play now (and records it).
    public mutating func request(_ id: SoundID, now: Double) -> Bool {
        guard enabled, !hidden else { return false }
        if id == .naviIn {
            if now - lastNaviIn + 1e-9 < SfxGate.naviInMinGap { return false }
            lastNaviIn = now
        }
        log.append(id)
        return true
    }

    public mutating func clearLog() { log.removeAll() }
}
