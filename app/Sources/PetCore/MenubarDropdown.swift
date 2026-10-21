import Foundation

/// The menubar Triforce's dropdown: everything Navi's own menu shows (build threads and
/// quota usage), so you can keep her hidden and still read status from the menubar. Pure: it reads the same `MenuModel` the fairy's menu reads (same rows,
/// same idle-last rule, same sort) and returns plain items; the AppKit side only draws them.
public enum MenubarDropdown {
    /// One item in a dropdown section. Text is final (already formatted and cleaned by
    /// `MenuText`); colors are hex.
    public enum Item: Equatable, Sendable {
        case header(String)
        case thread(ThreadLine)
        case usage(UsageLine)
        case note(String)
        case separator
    }

    public struct ThreadLine: Equatable, Sendable {
        public var id: String
        public var name: String
        /// Capped at `maxLine`; `fullStatus` is the uncut text for the tooltip.
        public var status: String
        public var fullStatus: String
        /// `⟳ working`, `✓ idle` — the same text the fairy's menu shows on the right.
        public var stateText: String
        public var hex: String
        public var idle: Bool
        /// Where a click opens it (`Open in iTerm`, `Open in Omnigent`, `Open PR in browser`),
        /// shown on hover so the row stays narrow. nil = the click does nothing.
        public var opensIn: String? = nil
    }

    public struct UsageLine: Equatable, Sendable {
        public var harness: String
        public var label: String
        /// One per window (`5h  38%  resets in 2h 14m`), then credits. Empty on an error row.
        public var lines: [String]
        /// Dot color; nil for an error row (drawn dim).
        public var hex: String?
        public var blocked: Bool
        public var error: String?
        public var tooltip: String?
    }

    /// Longest status / body line, so one chatty row cannot stretch the whole dropdown
    /// (a native menu is as wide as its widest item). The full text is the item's tooltip.
    public static let maxLine = 80

    // MARK: titles

    /// Top of the dropdown, with ⌥⌘N. Rebuilt on every open, so it is never stale.
    public static func visibilityTitle(hidden: Bool) -> String { hidden ? "Show Navi" : "Hide Navi" }
    public static func sleepTitle(sleeping: Bool) -> String { sleeping ? "Wake Navi" : "Sleep Navi" }

    /// Hover text for the Sound item (fairy menu and dropdown): it covers her chimes only.
    public static let soundTooltip = "Navi's state and menu chimes. Typing sounds have their own switch."

    /// Names the harness and window closest to its limit: `Quota · Cursor (cycle) 100%`, or
    /// `Quota · Codex blocked` when one is blocked (`+1` when more are). `Quota usage` with
    /// nothing to say. Error rows have no numbers and never count.
    public static func usageTitle(_ model: MenuModel) -> String {
        let rows = model.usageRows.filter { $0.error == nil }
        let blocked = rows.filter(\.blocked)
        if let b = blocked.first { return "Quota · \(b.plainName) blocked" + (blocked.count > 1 ? " (+\(blocked.count - 1))" : "") }
        var top: (row: UsageRow, window: UsageWindow)?
        for r in rows { for w in r.windows where w.usedPct > (top?.window.usedPct ?? -1) { top = (r, w) } }
        guard let top else { return "Quota usage" }
        return "Quota · \(top.row.plainName) (\(UsageFormat.plainWindow(top.window.name))) \(UsageFormat.pct(top.window.usedPct))"
    }

    /// The dropdown's top line and the Triforce tooltip: `4 threads · 2 working · 1 needs input`,
    /// `0 threads · none open`, with the collector or the Omnigent feed called out when either
    /// is down, so a blind spot never reads as "nothing open".
    public static func summary(states: [NaviState], health: CollectorHealth, feed: OmnigentFeed, sleeping: Bool) -> String {
        if let down = health.summary { return down }
        let n = states.count
        var parts: [String] = []
        if feed == .unavailable { parts.append("Omnigent feed unavailable") }
        if n > 0 || feed != .unavailable {
            parts.append("\(n) \(feed == .unavailable ? "other " : "")thread\(n == 1 ? "" : "s")")
        }
        let before = parts.count
        for s in NaviState.liveOrder {
            let c = states.filter { $0 == s }.count
            if c > 0 { parts.append("\(c) \(s.label)") }
        }
        if parts.count == before, feed != .unavailable { parts.append(n == 0 ? "none open" : "all idle") }
        if case .lastKnown = feed { parts.append("last known") }
        if sleeping { parts.append("sleeping") }
        return parts.joined(separator: " · ")
    }

    // MARK: sections

    /// Every thread row, sorted exactly like the fairy's menu (`sortedRows`: active first,
    /// idle after, then the chosen sort) — unpaged, the dropdown scrolls instead. A feed note
    /// leads when the Omnigent chats are last-known or missing. `threads` + `prefs` give each
    /// row its "opens in" hint (the same primaryAction a click runs).
    public static func threadSection(_ model: MenuModel, workingColor: String, threads: [BuildThread] = [],
                                     prefs: OpenPrefs = OpenPrefs(), feed: OmnigentFeed = .ok, now: Date = Date()) -> [Item] {
        var items: [Item] = [.header("Build threads · \(model.sort.rawValue)")]
        if let note = feed.note(now: now) { items.append(.note(note)) }
        let rows = model.sortedRows
        if rows.isEmpty, feed != .unavailable { items.append(.note("no build threads")) }
        for r in rows {
            let opens = threads.first { $0.id == r.id }?.primaryAction(prefs)?.label
            items.append(.thread(ThreadLine(id: r.id, name: r.name, status: MenuText.line(r.status, max: maxLine), fullStatus: r.status, stateText: r.stateText,
                                            hex: r.state.hex(workingColor: workingColor), idle: r.idle, opensIn: opens)))
        }
        return items
    }

    /// The developer tools, out of the status menus' top level into one submenu at the bottom.
    public enum Advanced {
        public static let title = "Advanced"
        public static let openDataFolder = "Open status data folder"
        public static let openSoundsFolder = "Open sound clips folder"
        public static let copySettings = "Copy look & behaviour settings"
        public static let pasteSettings = "Paste look & behaviour settings"
        public static let resetSettings = "Reset look & behaviour…"
        public static let resetConfirmTitle = "Reset Navi's look & behaviour?"
        public static let resetConfirmBody = "Her colours, movement, size, sound and menu sort go back to the defaults. Threads and your other settings stay as they are."
        public static let resetConfirmButton = "Reset"
    }

    /// The usage page's content: one item per quota harness, the same empty-state notes,
    /// the no-quota footer and the polled line.
    public static func usageSection(_ model: MenuModel, hasUsageData: Bool, polledAt: String?, now: Date) -> [Item] {
        var items: [Item] = []
        let rows = model.usageRows
        if !hasUsageData { items.append(.note("collector has no usage data yet")) }
        else if rows.isEmpty { items.append(.note("no harness reports a quota")) }
        for r in rows {
            items.append(.usage(UsageLine(harness: r.harness, label: r.label, lines: r.error == nil ? UsageFormat.lines(r, now: now) : [],
                                          hex: r.accentHex, blocked: r.blocked, error: r.error, tooltip: r.tooltip)))
        }
        let footer = model.usageFooterRows
        if !footer.isEmpty { items.append(.note("no quota: " + footer.map(\.footerText).joined(separator: ", "))) }
        if hasUsageData, let p = UsageFormat.polledAgo(polledAt, now: now) { items.append(.note(p)) }
        return items
    }
}

// MARK: - formatting shared by the fairy's menu and the dropdown

extension MenuRow {
    /// `⟳ working`, or `✓ idle` for a row resting past its active window. Empty for the
    /// placeholder row (no id, no status).
    public var stateText: String { status.isEmpty && id.isEmpty ? "" : "\(state.symbol) \(idle ? "idle" : state.label)" }
}

extension UsageRow {
    /// Accent color: red when blocked, else the worst window's bar color; nil on an error row.
    public var accentHex: String? {
        if error != nil { return nil }
        if blocked { return UsageBar.red }
        return UsageBar.hex(forPct: windows.map(\.usedPct).max() ?? 0)
    }

    /// Hover text: blocked reason · shared by … · note. nil when there is nothing to say.
    public var tooltip: String? {
        var parts: [String] = []
        if let blockedReason { parts.append(blockedReason) }
        if let sharedBy, !sharedBy.isEmpty { parts.append("shared by \(sharedBy.joined(separator: ", "))") }
        if let note { parts.append(note) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension UsageRow {
    /// `Claude Code · Max 5x` → `Claude Code`: the harness, without the plan.
    public var plainName: String {
        label.components(separatedBy: " · ").first.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 } ?? harness
    }
}

extension UsageFormat {
    /// Window names as people say them: `5h` → `5-hour`, `7d` → `weekly`,
    /// `cycle total` → `cycle`. Anything else is already plain and passes through.
    public static func plainWindow(_ name: String) -> String {
        switch name.lowercased() {
        case "5h": return "5-hour"
        case "1d", "24h": return "daily"
        case "7d": return "weekly"
        case "cycle total": return "cycle"
        default: return name
        }
    }

    /// `polled just now` / `polled 12m ago` / `polled 3h ago`; nil without a time.
    public static func polledAgo(_ iso: String?, now: Date) -> String? {
        guard let iso else { return nil }
        let ago = parse(iso).map { Int(now.timeIntervalSince($0)) } ?? 0
        return ago < 90 ? "polled just now" : (ago < 5400 ? "polled \(ago / 60)m ago" : "polled \(ago / 3600)h ago")
    }

    /// Text lines for one harness: `5h · 38% · resets in 2h 14m` per window, then
    /// `credits · 500/50000 prompt credits · resets in 3d`.
    public static func lines(_ row: UsageRow, now: Date) -> [String] {
        var out = row.windows.map { w -> String in
            let until = resetsIn(w.resetsAt, now: now)
            return "\(w.name) · \(pct(w.usedPct))" + (until.isEmpty ? "" : " · resets in \(until)")
        }
        if let c = row.credits {
            let until = resetsIn(c.resetsAt, now: now)
            out.append("credits · \(c.text)" + (until.isEmpty ? "" : " · resets in \(until)"))
        }
        return out
    }
}

/// Text as a menu line shows it: control and bidi/zero-width characters removed (a thread's
/// status is whatever its agent last printed), whitespace collapsed to single spaces, capped.
public enum MenuText {
    private static func isSpoofing(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F...0x9F: return true
        case 0x061C, 0x200B...0x200F, 0x2028...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF: return true
        default: return false
        }
    }

    public static func line(_ text: String?, max: Int = 120) -> String {
        guard let text else { return "" }
        var out = String.UnicodeScalarView()
        for s in text.unicodeScalars where !isSpoofing(s) { out.append(s) }
        let collapsed = String(out).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.count > max ? String(collapsed.prefix(max - 1)) + "…" : collapsed
    }
}
