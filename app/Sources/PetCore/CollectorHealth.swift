import Foundation

/// Is the collector alive? `threads.json` is rewritten every minute by launchd
/// (`com.navi.collector`); a snapshot older than `staleAfter` means the collector has
/// stopped and everything in the file is history. Navi must never present stale sessions as
/// live — on `.missing` / `.stale` she shows one "collector not running" row, wears the
/// no-threads white, and says so in the menubar tooltip.
public enum CollectorHealth: Equatable, Sendable {
    /// No `threads.json` at all (collector never installed / ran).
    case missing
    /// Fresh snapshot; `age` in seconds since `generatedAt`.
    case fresh(age: TimeInterval)
    /// Snapshot older than `staleAfter` (or with no parseable `generatedAt`).
    case stale(age: TimeInterval?)

    /// Three collector ticks. One missed tick is normal (a slow `gh`); three is dead.
    public static let staleAfter: TimeInterval = 3 * 60
    public static let rowId = "__collector"
    public static let installHint = "run ./install.sh"

    public static func check(snapshot: ThreadsSnapshot?, fileExists: Bool, now: Date = Date()) -> CollectorHealth {
        guard fileExists, let snapshot else { return .missing }
        guard let iso = snapshot.generatedAt, let at = ISO8601DateFormatter.lenient(iso) else { return .stale(age: nil) }
        let age = now.timeIntervalSince(at)
        return age > staleAfter ? .stale(age: age) : .fresh(age: max(0, age))
    }

    /// True only for a fresh snapshot: the one case where thread rows and live states apply.
    public var isLive: Bool { if case .fresh = self { return true } else { return false } }

    /// The single row the menu shows instead of threads when the collector is down.
    public var menuRow: MenuRow? {
        switch self {
        case .fresh: return nil
        case .missing:
            return MenuRow(id: CollectorHealth.rowId, name: "collector not running", state: .blocked, changedAt: 0,
                           status: CollectorHealth.installHint)
        case .stale(let age):
            let since = age.map { "threads.json is \(CollectorHealth.ageText($0)) old" } ?? "threads.json has no generatedAt"
            return MenuRow(id: CollectorHealth.rowId, name: "collector not running", state: .blocked, changedAt: 0,
                           status: "\(since) · \(CollectorHealth.installHint)")
        }
    }

    /// Menubar tooltip / status line when the collector is down; nil when it is fine.
    public var summary: String? {
        switch self {
        case .fresh: return nil
        case .missing: return "collector not running — \(CollectorHealth.installHint)"
        case .stale(let age):
            let a = age.map { " (last snapshot \(CollectorHealth.ageText($0)) ago)" } ?? ""
            return "collector stale\(a) — \(CollectorHealth.installHint)"
        }
    }

    public static func ageText(_ s: TimeInterval) -> String {
        let secs = Int(s.rounded())
        if secs < 90 { return "\(secs)s" }
        if secs < 5400 { return "\(secs / 60)m" }
        if secs < 172_800 { return "\(secs / 3600)h" }
        return "\(secs / 86_400)d"
    }
}
