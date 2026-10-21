import Foundation

/// Today's typing, persisted across restarts. Counts and durations only — no key, no class,
/// no per-press timestamps (see `KeyPrivacyTests`).
public struct TypingStats: Codable, Equatable, Sendable {
    /// Local calendar day, `yyyy-MM-dd`. A press on a new day starts fresh stats.
    public var day: String
    public var keystrokes: Int = 0
    /// Seconds spent typing: the sum of gaps between presses no longer than `TypingMeter.pauseGap`.
    public var activeSeconds: Double = 0
    /// Highest live WPM today, taken only once a burst has run a full window (no spikes).
    public var bestWPM: Int = 0

    public init(day: String, keystrokes: Int = 0, activeSeconds: Double = 0, bestWPM: Int = 0) {
        self.day = day; self.keystrokes = keystrokes; self.activeSeconds = activeSeconds; self.bestWPM = bestWPM
    }

    /// Average WPM over typing time (a word = 5 key presses); nil until there is enough of it.
    public var averageWPM: Int? {
        guard activeSeconds >= TypingMeter.minActive else { return nil }
        return Int((Double(keystrokes) / 5 / (activeSeconds / 60)).rounded())
    }

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static let prefsKey = "typingStats"

    /// nil when nothing is saved, it is unreadable, or it is from another day.
    public static func load(from store: StringStore, today: String) -> TypingStats? {
        guard let s = store.string(forKey: prefsKey),
              let v = try? JSONDecoder().decode(TypingStats.self, from: Data(s.utf8)), v.day == today else { return nil }
        return v
    }

    public func save(to store: StringStore) {
        let e = JSONEncoder(); e.outputFormatting = .sortedKeys
        guard let data = try? e.encode(self) else { return }
        store.set(String(decoding: data, as: UTF8.self), forKey: TypingStats.prefsKey)
    }
}

/// Live WPM over a short sliding window, plus today's best and average. Takes only the time of
/// a press: nothing about which key it was can get in.
public struct TypingMeter: Sendable {
    /// Live WPM looks at the last 10 s.
    public static let window: TimeInterval = 10
    /// A gap longer than this is a pause: not typing time, and live WPM reads 0.
    public static let pauseGap: TimeInterval = 3
    /// Average needs at least this much typing time.
    public static let minActive: TimeInterval = 10

    public private(set) var stats: TypingStats
    /// Press times inside the window (bounded: ~200 at 20 keys/s). In memory only.
    private var recent: [TimeInterval] = []
    private var last: TimeInterval?
    private var burstStart: TimeInterval?
    /// Set on every change, cleared by whoever saves.
    public var dirty = false

    public init(stats: TypingStats) { self.stats = stats }

    /// One typing key press at `t` (seconds, any monotonic-enough clock) on local day `day`.
    public mutating func record(at t: TimeInterval, day: String) {
        if stats.day != day { stats = TypingStats(day: day) }
        if let last, t >= last, t - last <= TypingMeter.pauseGap {
            stats.activeSeconds += t - last
        } else {
            burstStart = t
            recent.removeAll(keepingCapacity: true)
        }
        last = t
        stats.keystrokes += 1
        recent.append(t)
        if let drop = recent.firstIndex(where: { $0 > t - TypingMeter.window }), drop > 0 { recent.removeFirst(drop) }
        if let b = burstStart, t - b >= TypingMeter.window { stats.bestWPM = max(stats.bestWPM, liveWPM(at: t)) }
        dirty = true
    }

    /// Words per minute right now: presses in the window (or the burst so far, if shorter, but
    /// at least 3 s so the first few presses do not read as 400 wpm). 0 once paused.
    public func liveWPM(at now: TimeInterval) -> Int {
        guard let last, let burstStart, now - last <= TypingMeter.pauseGap else { return 0 }
        let span = max(3, min(TypingMeter.window, now - burstStart))
        let n = recent.filter { $0 > now - span }.count
        return Int((Double(n) / 5 / (span / 60)).rounded())
    }

    /// Today's stats as of `day` (a new day reads as empty before its first press).
    public func today(_ day: String) -> TypingStats { stats.day == day ? stats : TypingStats(day: day) }
}
