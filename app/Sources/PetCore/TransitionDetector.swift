import Foundation

/// Watches every thread's Navi state between observations and reports the ones that changed.
/// Any change on ANY thread is a symbol pop — even when the overall color set is unchanged
/// (two threads swapping into the same state still pops). The first observation after
/// launch is silent: nothing "changed", the pet just learned the world.
public struct TransitionDetector: Sendable {
    public struct Change: Equatable, Sendable {
        public var id: String
        public var from: NaviState?     // nil = thread is new
        public var to: NaviState
        public init(id: String, from: NaviState?, to: NaviState) { self.id = id; self.from = from; self.to = to }
    }

    public private(set) var last: [String: NaviState]? = nil

    public init() {}

    /// Feed every observation (including unchanged ones). Returns the changes, in the order
    /// the threads were given. Removed threads never pop.
    public mutating func observe(_ states: [(id: String, state: NaviState)]) -> [Change] {
        var next: [String: NaviState] = [:]
        for (id, s) in states { next[id] = s }
        defer { last = next }
        guard let prev = last else { return [] }
        var out: [Change] = []
        for (id, s) in states where prev[id] != s {
            out.append(Change(id: id, from: prev[id], to: s))
        }
        return out
    }

    /// Latest wins when several threads change in one observation.
    public static func popState(for changes: [Change]) -> NaviState? { changes.last?.to }
}

/// The "waiting on you" signal: a thread whose parent agent just finished a turn.
/// Fires only on working → idle (a fresh row that starts idle, or idle → idle, is nothing;
/// needs-input / blocked have their own louder treatment). The app posts one macOS user
/// notification per alert, gated by the "Notify when an agent goes idle" pref.
public struct IdleAlert: Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }

    /// Notification text. The thread name is what you call the work — never a hash.
    public var message: String { "\(name) is waiting on you" }

    public static func alerts(for changes: [TransitionDetector.Change], threads: [BuildThread]) -> [IdleAlert] {
        changes.compactMap { c in
            guard c.from == .working, c.to == .idle else { return nil }
            let name = threads.first { $0.id == c.id }?.name ?? c.id
            return IdleAlert(id: c.id, name: name)
        }
    }
}

/// Suppresses repeated idle notifications for the same thread while allowing
/// unrelated threads to notify independently.
public struct IdleAlertCooldown: Sendable {
    public var interval: TimeInterval
    private var lastPostedAt: [String: TimeInterval] = [:]

    public init(interval: TimeInterval = 60) {
        self.interval = interval
    }

    public mutating func shouldPost(threadID: String, now: TimeInterval) -> Bool {
        if let last = lastPostedAt[threadID], now - last < interval { return false }
        lastPostedAt[threadID] = now
        return true
    }
}

/// Nap logic: no state change on any thread for `threshold` → sleep. Any change (or a click,
/// via `wake`) wakes her. A manual nap holds until woken the same way.
public struct SleepTimer: Sendable {
    public var threshold: TimeInterval
    public private(set) var lastChangeAt: Double
    public private(set) var sleeping = false

    public init(threshold: TimeInterval, now: Double) {
        self.threshold = threshold
        self.lastChangeAt = now
    }

    /// Call on every thread state change. Wakes if asleep. Returns true if she woke.
    @discardableResult
    public mutating func noteChange(now: Double) -> Bool {
        lastChangeAt = now
        return wake(now: now)
    }

    /// Call each tick. Returns true the tick she falls asleep.
    @discardableResult
    public mutating func tick(now: Double) -> Bool {
        guard !sleeping, threshold > 0, now - lastChangeAt >= threshold else { return false }
        sleeping = true
        return true
    }

    public mutating func sleep(now: Double) {
        sleeping = true
        lastChangeAt = now
    }

    @discardableResult
    public mutating func wake(now: Double) -> Bool {
        guard sleeping else { return false }
        sleeping = false
        lastChangeAt = now
        return true
    }
}
