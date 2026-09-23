import Foundation

/// Navi's five states. The color is what she wears; the symbol is what pops above her
/// head when a thread changes state. Colors come from the original design mock.
public enum NaviState: String, Codable, CaseIterable, Sendable {
    case working
    case needsInput = "needs_input"
    case blocked
    case idle
    case sleep

    /// Rotation order when 2+ distinct states are live: working → needs_input → blocked → idle.
    /// The mock's LIVE_ORDER plus idle appended (green belongs in the rotation).
    public static let liveOrder: [NaviState] = [.working, .needsInput, .blocked, .idle]

    public var label: String {
        switch self {
        case .working: return "working"
        case .needsInput: return "needs input"
        case .blocked: return "blocked"
        case .idle: return "idle"
        case .sleep: return "sleep"
        }
    }

    public var symbol: String {
        switch self {
        case .working: return "⟳"
        case .needsInput: return "?"
        case .blocked: return "!"
        case .idle: return "✓"
        case .sleep: return "zzz"
        }
    }

    /// Hex color. `working` takes the user's "Working color" pref (mock: coreColor).
    public func hex(workingColor: String) -> String {
        switch self {
        case .working: return workingColor
        case .needsInput: return "#4aa8ff"
        case .blocked: return "#e5283a"
        case .idle: return "#3fb950"
        case .sleep: return "#8a8a8a"
        }
    }

    /// Menu "status" sort: blocked → needs_input → idle → working (recent within).
    public var statusRank: Int {
        switch self {
        case .blocked: return 0
        case .needsInput: return 1
        case .idle: return 2
        case .working: return 3
        case .sleep: return 4
        }
    }
}

/// Zero threads / no collector: white ("0 threads → white #ede6e6").
public let naviNoThreadsHex = "#ede6e6"

/// RGB triple 0...255, mirrors the mock's `[r,g,b]` arrays.
public struct RGB: Equatable, Sendable {
    public var r: Double, g: Double, b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

    public init(hex: String) {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let n = UInt32(s, radix: 16) ?? 0xEDE6E6
        self.init(Double((n >> 16) & 255), Double((n >> 8) & 255), Double(n & 255))
    }

    public var hex: String {
        String(format: "#%02x%02x%02x", Int(r.rounded()), Int(g.rounded()), Int(b.rounded()))
    }

    public func mix(_ o: RGB, _ t: Double) -> RGB {
        RGB(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t)
    }

    public func lighten(_ t: Double) -> RGB { mix(RGB(255, 255, 255), t) }
}

// MARK: - collector thread → NaviState

/// The ONE place collector data becomes a Navi state. First match wins, top to bottom.
/// Documented in README ("How Navi reads a thread"). Uses only fields the collector emits.
///
/// "Working" means the PARENT agent is mid-turn — nothing else. Design rule:
/// an Omnigent parent going idle while its sub-agents still run is exactly the moment to
/// be told about, so neither a child's `running` nor "seen a minute ago" may keep a row
/// yellow. Recency only gates `failed` (an old failure is history, not a red light); the
/// 10-minute dim rule for long-idle rows is the collector's `idle` flag, separate from this.
public enum NaviStateMapper {
    /// A failed session only counts while it is recent — same window as the collector's
    /// ACTIVE_SESSION_MINUTES (10).
    public static let liveSessionWindow: TimeInterval = 10 * 60

    /// optional agent-state hook statuses (README → Optional: Claude Code hook): running / waiting / blocked
    /// (`waiting` = the turn ended = idle). Omnigent adds running / idle / failed. Codex is "unknown".
    static let runningStatuses: Set<String> = ["running", "busy"]
    static let failedStatuses: Set<String> = ["failed", "error", "crashed"]
    /// `blocked` from the hook = "needs permission or input" — that is a question for you.
    static let askingStatuses: Set<String> = ["blocked"]

    public static func state(for t: BuildThread, now: Date = Date()) -> NaviState {
        let sessions = t.sessions ?? []
        let seenRecently: (ThreadSession) -> Bool = { s in
            guard let iso = s.lastSeen, let d = ISO8601DateFormatter.lenient(iso) else { return false }
            return now.timeIntervalSince(d) <= liveSessionWindow
        }
        let status: (ThreadSession) -> String = { ($0.status ?? "").lowercased() }
        let isParent: (ThreadSession) -> Bool = { !($0.child ?? false) }
        let hasFailed = sessions.contains { failedStatuses.contains(status($0)) && seenRecently($0) }
        let hasAsking = sessions.contains { askingStatuses.contains(status($0)) }
        let parentRunning = sessions.contains { isParent($0) && runningStatuses.contains(status($0)) }

        // 1. something broke: the branch rotted, an agent in it failed just now, or a chat row errored
        if t.state == .stale || t.state == .blocked || hasFailed { return .blocked }
        // 2. you are the blocker: PR reviewed and waiting on the merge, an agent asking,
        //    or a chat row waiting on a reply
        if t.state == .prOpen && (t.reviewReady ?? false) { return .needsInput }
        if t.state == .needsInput || hasAsking { return .needsInput }
        // 3. the parent agent is on it (the collector's `active` is the same parent-only verdict)
        if t.state == .active || parentRunning { return .working }
        // 4. nobody on it and it is not saved: abandoned work is a problem, not a quiet thread
        if t.state == .uncommitted { return .blocked }
        // 5. nobody on it, committed but not on GitHub: one push from safe — ask
        if t.state == .unpushed { return .needsInput }
        // 6. pushed / PR open (waiting on a reviewer, not you) / merged / quiet
        return .idle
    }

    /// Distinct states across all threads, in rotation order. Empty for zero threads.
    public static func liveSet(_ states: [NaviState]) -> [NaviState] {
        let set = Set(states)
        return NaviState.liveOrder.filter { set.contains($0) }
    }
}

extension ISO8601DateFormatter {
    /// Accepts both `2026-09-17T05:55:58.538Z` and `2026-09-17T05:55:58Z`.
    static func lenient(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
