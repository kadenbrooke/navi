import Foundation

/// Mirror of `snapshot.usage[]` written by `collector/usage.mjs` — one row per
/// harness. Decoding is lenient: only `harness` is required so a collector change never
/// crashes the pet. NOTE: usage never drives Navi's color or pops; it is menu-only.
/// TODO: decide whether ≥90% on any window should pop Navi red. Left out on purpose.

public struct UsageWindow: Codable, Equatable, Sendable {
    public var name: String
    public var usedPct: Double
    public var resetsAt: String?
    public var severity: String?
    public var active: Bool?

    public init(name: String, usedPct: Double, resetsAt: String? = nil, severity: String? = nil, active: Bool? = nil) {
        self.name = name; self.usedPct = usedPct; self.resetsAt = resetsAt; self.severity = severity; self.active = active
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "window"
        usedPct = try c.decodeIfPresent(Double.self, forKey: .usedPct) ?? 0
        resetsAt = try c.decodeIfPresent(String.self, forKey: .resetsAt)
        severity = try c.decodeIfPresent(String.self, forKey: .severity)
        active = try c.decodeIfPresent(Bool.self, forKey: .active)
    }
}

public struct UsageCredits: Codable, Equatable, Sendable {
    public var balance: Double?
    public var limit: Double?
    public var unit: String?
    public var resetsAt: String?

    public init(balance: Double? = nil, limit: Double? = nil, unit: String? = nil, resetsAt: String? = nil) {
        self.balance = balance; self.limit = limit; self.unit = unit; self.resetsAt = resetsAt
    }

    /// `500/50000 prompt credits` or `3.5 credits`.
    public var text: String {
        func f(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
        var s = f(balance ?? 0)
        if let limit { s += "/\(f(limit))" }
        if let unit, !unit.isEmpty { s += " \(unit)" }
        return s
    }
}

public struct UsageRow: Codable, Equatable, Sendable {
    public var harness: String
    public var label: String
    public var plan: String?
    public var sharedBy: [String]?
    public var quota: Bool
    public var windows: [UsageWindow]
    public var credits: UsageCredits?
    public var blocked: Bool
    public var blockedReason: String?
    public var error: String?
    public var note: String?
    public var costTodayUsd: Double?
    public var fetchedAt: String?

    public init(harness: String, label: String? = nil, plan: String? = nil, sharedBy: [String]? = nil, quota: Bool = true,
                windows: [UsageWindow] = [], credits: UsageCredits? = nil, blocked: Bool = false, blockedReason: String? = nil,
                error: String? = nil, note: String? = nil, costTodayUsd: Double? = nil, fetchedAt: String? = nil) {
        self.harness = harness; self.label = label ?? harness; self.plan = plan; self.sharedBy = sharedBy; self.quota = quota
        self.windows = windows; self.credits = credits; self.blocked = blocked; self.blockedReason = blockedReason
        self.error = error; self.note = note; self.costTodayUsd = costTodayUsd; self.fetchedAt = fetchedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        harness = try c.decode(String.self, forKey: .harness)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? harness
        plan = try c.decodeIfPresent(String.self, forKey: .plan)
        sharedBy = try c.decodeIfPresent([String].self, forKey: .sharedBy)
        quota = try c.decodeIfPresent(Bool.self, forKey: .quota) ?? true
        windows = try c.decodeIfPresent([UsageWindow].self, forKey: .windows) ?? []
        credits = try c.decodeIfPresent(UsageCredits.self, forKey: .credits)
        blocked = try c.decodeIfPresent(Bool.self, forKey: .blocked) ?? false
        blockedReason = try c.decodeIfPresent(String.self, forKey: .blockedReason)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        costTodayUsd = try c.decodeIfPresent(Double.self, forKey: .costTodayUsd)
        fetchedAt = try c.decodeIfPresent(String.self, forKey: .fetchedAt)
    }

    /// Lines drawn under the label: one per window, plus a credits line when present.
    public var detailLineCount: Int {
        if error != nil { return 0 }
        return windows.count + (credits == nil ? 0 : 1)
    }

    /// Footer text for `quota:false` rows: `omnigent ($12 today)`.
    public var footerText: String {
        if let usd = costTodayUsd { return "\(harness) ($\(Int(usd.rounded())) today)" }
        if let error { return "\(harness) (\(error))" }
        return harness
    }
}

/// Bar color thresholds. Same red as Navi's blocked state.
public enum UsageBar {
    public static let green = "#3fb950"
    public static let yellow = "#fff8ad"
    public static let red = NaviState.blocked.hex(workingColor: "")

    public static func hex(forPct pct: Double) -> String {
        if pct >= 90 { return red }
        if pct >= 70 { return yellow }
        return green
    }

    /// 0...1 fill fraction; usedPct may exceed 100 but the bar never overflows.
    public static func fill(forPct pct: Double) -> Double { min(max(pct, 0), 100) / 100 }
}

public enum UsageFormat {
    /// `2h 14m`, `3d`, `3d 5h`, `14m`, `now`. Empty when the date is missing/unparseable.
    public static func resetsIn(_ iso: String?, now: Date = Date()) -> String {
        guard let iso, let d = parse(iso) else { return "" }
        let secs = Int(d.timeIntervalSince(now).rounded())
        if secs <= 0 { return "now" }
        if secs < 60 { return "\(secs)s" }
        let mins = Int((Double(secs) / 60).rounded())
        if mins < 60 { return "\(mins)m" }
        let hours = mins / 60
        if hours < 24 { return "\(hours)h \(mins % 60)m" }
        let days = hours / 24
        return hours % 24 == 0 ? "\(days)d" : "\(days)d \(hours % 24)h"
    }

    public static func parse(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)
    }

    /// `38%` — rounded, may exceed 100.
    public static func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }
}
