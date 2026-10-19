import Foundation

/// `threads.json`'s `omnigentFeed`, as `collect.mjs` writes it.
public struct OmnigentFeedInfo: Codable, Equatable, Sendable {
    public var status: String?
    public var since: String?
    public var error: String?
    public init(status: String? = nil, since: String? = nil, error: String? = nil) {
        self.status = status; self.since = since; self.error = error
    }
}

/// Can Navi see the Omnigent chats right now? The collector keeps the last rows Omnigent
/// reported for a few minutes when its feed blips (`lastKnown`), then drops them
/// (`unavailable`). Either way you are told, instead of reading a false "0 threads".
public enum OmnigentFeed: Equatable, Sendable {
    case ok
    /// The chat rows are the last ones Omnigent reported; `since` = when the feed was last good.
    case lastKnown(since: Date?)
    /// No Omnigent rows in this snapshot at all.
    case unavailable

    public static func of(_ snapshot: ThreadsSnapshot?) -> OmnigentFeed {
        guard let snapshot else { return .ok }
        if let info = snapshot.omnigentFeed {
            switch info.status {
            case "last-known": return .lastKnown(since: info.since.flatMap { ISO8601DateFormatter.lenient($0) })
            case "unavailable": return .unavailable
            default: return .ok
            }
        }
        // Older collector: only `sources.omnigent` says it.
        if snapshot.sources?["omnigent"]?.hasPrefix("unavailable") == true { return .unavailable }
        return .ok
    }

    public var isOK: Bool { self == .ok }

    /// The line both menus show above the threads; nil when the feed is fine.
    public func note(now: Date) -> String? {
        switch self {
        case .ok: return nil
        case .lastKnown(let since):
            let ago = since.map { " from \(CollectorHealth.ageText(max(0, now.timeIntervalSince($0)))) ago" } ?? ""
            return "Omnigent feed unavailable — showing last known\(ago)"
        case .unavailable: return "Omnigent feed unavailable — Omnigent chats not shown"
        }
    }

}

/// Omnigent rows coming back when the feed recovers from unavailable are not news: they
/// were there before the outage. Remembers which Omnigent rows were on screen before it, and
/// on recovery drops only their "new thread" changes, so Navi neither pops nor chimes for
/// them. Any other new row (a fresh Claude / Codex / git thread, a chat started during the
/// outage) still pops.
public struct FeedRecovery: Sendable {
    private var beforeOutage: Set<String> = []
    private var previous: OmnigentFeed = .ok

    public init() {}

    public mutating func filter(_ changes: [TransitionDetector.Change], feed: OmnigentFeed, threads: [BuildThread]) -> [TransitionDetector.Change] {
        defer {
            // While unavailable the snapshot has no Omnigent rows: keep the pre-outage set.
            if feed != .unavailable { beforeOutage = Set(threads.filter(\.isOmnigentBacked).map(\.id)) }
            previous = feed
        }
        guard previous == .unavailable, feed != .unavailable else { return changes }
        return changes.filter { !($0.from == nil && beforeOutage.contains($0.id)) }
    }
}

extension BuildThread {
    /// A chat row (`omnigent:<id>`) or a worktree row backed by an Omnigent session.
    public var isOmnigentBacked: Bool { id.hasPrefix("omnigent:") || isOmnigentChat }
}
