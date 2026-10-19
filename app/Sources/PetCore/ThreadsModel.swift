import Foundation

/// Mirror of the `threads.json` shape written by `collector/collect.mjs`.
/// Decoding is lenient: every field the pet does not strictly need is optional so a
/// collector change never crashes the pet.

public enum ThreadState: String, Codable, Equatable, Sendable {
    case stale, uncommitted, unpushed, prOpen = "pr-open", merged, active, idle
    /// Chat rows (an Omnigent session with no worktree, id `omnigent:<id>`) add these two.
    case needsInput = "needs-input", blocked
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ThreadState(rawValue: raw) ?? .unknown
    }
}

public struct PullRequest: Codable, Equatable, Sendable {
    public var number: Int?
    public var url: String?
    public var title: String?
    public var state: String?

    public init(number: Int? = nil, url: String? = nil, title: String? = nil, state: String? = nil) {
        self.number = number; self.url = url; self.title = title; self.state = state
    }
}

public struct ThreadSession: Codable, Equatable, Sendable {
    public var harness: String?
    public var id: String?
    public var title: String?
    public var status: String?
    public var lastSeen: String?
    /// True for a sub-agent rolled up under this row. Its status never makes the row
    /// "working" — only the parent's does.
    public var child: Bool?

    public init(harness: String? = nil, id: String? = nil, title: String? = nil, status: String? = nil,
                lastSeen: String? = nil, child: Bool? = nil) {
        self.harness = harness; self.id = id; self.title = title; self.status = status; self.lastSeen = lastSeen
        self.child = child
    }
}

public struct GitInfo: Codable, Equatable, Sendable {
    public var ahead: Int?
    public var behind: Int?
    public var dirtyFiles: Int?
    public var hasUpstream: Bool?
    public var unpushedCommits: Int?
    public var lastCommitAt: String?
}

public struct ThreadAction: Codable, Equatable, Sendable {
    public var label: String
    /// What runs, as text: the collector's shell command, or (when `argv` is set) a
    /// shell-quoted rendering of `argv` for logs and the confirm dialog only.
    public var command: String
    /// Executable + arguments, run directly with no shell. Every open command Navi builds
    /// (`OpenTargets`) sets it, so a path or URL with quotes or `$(…)` is only ever an
    /// argument. nil = a collector shell command (`git pull …`), run via /bin/sh.
    public var argv: [String]?

    public init(label: String, command: String, argv: [String]? = nil) {
        self.label = label; self.command = command; self.argv = argv
    }

    /// The target of a plain `open <target>` (no -a / -b), or nil.
    public var openTarget: String? {
        guard let argv, argv.count == 2, argv[0] == OpenTargets.openTool else { return nil }
        return argv[1]
    }
}

public struct BuildThread: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var worktreePath: String?
    public var branch: String?
    public var state: ThreadState
    public var stateLabel: String?
    public var detail: String?
    public var reviewReady: Bool?
    public var pr: PullRequest?
    public var sessions: [ThreadSession]?
    public var git: GitInfo?
    public var actions: [ThreadAction]?
    /// Omnigent chat behind this row (chat rows, and worktree rows whose backing session is
    /// an Omnigent session). `omnigentUrl` is the web UI, `omnigentDeepLink` the desktop app
    /// (`omnigent://host:port/c/<id>`); both come from the collector's one OMNIGENT base url.
    public var omnigentUrl: String?
    public var omnigentDeepLink: String?
    /// Newest session activity on a live row (ISO 8601), and the collector's idle verdict:
    /// resting AND quiet for longer than its ACTIVE_SESSION_MINUTES. Idle rows stay listed.
    public var lastSeen: String?
    public var idle: Bool?

    public init(id: String, name: String, worktreePath: String? = nil, branch: String? = nil,
                state: ThreadState, stateLabel: String? = nil, detail: String? = nil,
                reviewReady: Bool? = nil, pr: PullRequest? = nil, sessions: [ThreadSession]? = nil,
                git: GitInfo? = nil, actions: [ThreadAction]? = nil,
                omnigentUrl: String? = nil, omnigentDeepLink: String? = nil,
                lastSeen: String? = nil, idle: Bool? = nil) {
        self.id = id; self.name = name; self.worktreePath = worktreePath; self.branch = branch
        self.state = state; self.stateLabel = stateLabel; self.detail = detail
        self.reviewReady = reviewReady; self.pr = pr; self.sessions = sessions
        self.git = git; self.actions = actions
        self.omnigentUrl = omnigentUrl; self.omnigentDeepLink = omnigentDeepLink
        self.lastSeen = lastSeen; self.idle = idle
    }

    /// True when an Omnigent chat backs this row (a chat row, or a worktree row whose live
    /// session is an Omnigent session).
    public var isOmnigentChat: Bool { chatLink(browser: false) != nil }

    /// The link a click should open for an Omnigent-backed row: the desktop deep link by
    /// default, the web url when `browser` is set. An older collector without
    /// `omnigentDeepLink` gets it derived from `omnigentUrl` (same host/port, `localhost`
    /// for 127.0.0.1) so the app still opens natively.
    public func chatLink(browser: Bool) -> String? {
        let web = omnigentUrl ?? actionURL(prefix: "open \"http", containing: "/c/")
        if browser { return web }
        if let deep = omnigentDeepLink { return deep }
        if let deep = actionURL(prefix: "open \"omnigent://", containing: "/c/") { return deep }
        return web.flatMap(BuildThread.deepLink(fromWebURL:))
    }

    /// `http://127.0.0.1:6767/c/<id>` → `omnigent://localhost:6767/c/<id>`.
    public static func deepLink(fromWebURL web: String) -> String? {
        guard let u = URLComponents(string: web), let host = u.host, u.path.contains("/c/") else { return nil }
        let h = host == "127.0.0.1" ? "localhost" : host
        let port = u.port ?? (u.scheme == "https" ? 443 : 80)
        return "omnigent://\(h):\(port)\(u.path)"
    }

    private func actionURL(prefix: String, containing: String) -> String? {
        guard let a = (actions ?? []).first(where: { $0.command.hasPrefix(prefix) && $0.command.contains(containing) }) else { return nil }
        var c = a.command.dropFirst("open ".count)
        if c.hasPrefix("\"") { c = c.dropFirst() }
        if c.hasSuffix("\"") { c = c.dropLast() }
        return String(c)
    }

    /// What a plain click / Enter on the row does, with the default prefs (desktop app, Terminal).
    public var primaryAction: ThreadAction? { primaryAction(OpenPrefs()) }

    public func primaryAction(openChatsInBrowser browser: Bool) -> ThreadAction? {
        primaryAction(OpenPrefs(chatsInBrowser: browser))
    }

    /// What a plain click / Enter on the row does (labels say where it opens):
    /// 1. an Omnigent-backed row opens its chat — in the Omnigent desktop app (`open -b`, so
    ///    the link never lands in another app) or, with the "Open chats in browser" pref, the
    ///    web UI. PR / terminal stay in the context menu.
    /// 2. otherwise (Claude CLI / Codex rows): the PR if there is one, else the worktree in
    ///    your terminal app, else the first action. Never a `git worktree remove`.
    public func primaryAction(_ prefs: OpenPrefs) -> ThreadAction? {
        if let link = chatLink(browser: prefs.chatsInBrowser) {
            return prefs.chatsInBrowser ? OpenTargets.open(link, label: "Open chat in browser") : OpenTargets.omnigent(link)
        }
        let list = actions(prefs).filter { !$0.isDestructive }
        if pr?.url != nil, let open = list.first(where: { $0.openTarget?.hasPrefix("http") == true }) {
            return open
        }
        if let term = list.first(where: { $0.argv?.prefix(3) == [OpenTargets.openTool, "-a", prefs.terminal.appName] }) {
            return term
        }
        return list.first
    }

    /// The collector's actions as the menus offer them: the terminal action opens the
    /// worktree in your terminal app, the Omnigent deep link opens in the Omnigent
    /// desktop app, each label says where it opens, and every `open "…"` becomes a no-shell
    /// argv. Other commands (`git pull …`, the confirmed worktree remove) are unchanged.
    public func actions(_ prefs: OpenPrefs) -> [ThreadAction] {
        (actions ?? []).map { a in
            if OpenTargets.isTerminal(a), let path = worktreePath ?? OpenTargets.quotedArgument(a.command) {
                return OpenTargets.terminal(path, app: prefs.terminal)
            }
            if a.command.hasPrefix("open \""), let target = OpenTargets.quotedArgument(a.command) {
                return target.hasPrefix("omnigent://") ? OpenTargets.omnigent(target) : OpenTargets.open(target, label: a.label)
            }
            return a
        }
    }

    /// Epoch seconds of `lastSeen`, for the menu's recency sort.
    public var lastSeenEpoch: Double? {
        lastSeen.flatMap { ISO8601DateFormatter.lenient($0) }?.timeIntervalSince1970
    }
}

/// Your terminal for opening a worktree. `auto` (the default) picks iTerm when it is
/// installed, else Terminal.
public enum TerminalApp: String, Equatable, Sendable, CaseIterable {
    case iTerm, terminal = "Terminal"

    public static let iTermBundleID = "com.googlecode.iterm2"

    /// The name `open -a` takes and the menus show.
    public var appName: String { rawValue }

    /// `pref`: the stored value (`auto` / unset, `iTerm`, `Terminal`, any case).
    public static func resolve(pref: String?, iTermInstalled: Bool) -> TerminalApp {
        switch pref?.lowercased() {
        case "iterm", "iterm2": return .iTerm
        case "terminal": return .terminal
        default: return iTermInstalled ? .iTerm : .terminal
        }
    }
}

/// Where a click opens things; built from Prefs on the app side.
public struct OpenPrefs: Equatable, Sendable {
    public var chatsInBrowser: Bool
    public var terminal: TerminalApp
    public init(chatsInBrowser: Bool = false, terminal: TerminalApp = .terminal) {
        self.chatsInBrowser = chatsInBrowser; self.terminal = terminal
    }
}

/// The one place the open commands and their labels are built. Each is an argv for
/// `/usr/bin/open`, never a shell string, so nothing in a path or URL can run.
public enum OpenTargets {
    public static let omnigentBundleID = "ai.omnigent.desktop"
    public static let openTool = "/usr/bin/open"

    public static func omnigent(_ deepLink: String) -> ThreadAction {
        argv("Open in Omnigent", ["-b", omnigentBundleID, deepLink])
    }

    public static func terminal(_ path: String, app: TerminalApp) -> ThreadAction {
        argv("Open in \(app.appName)", ["-a", app.appName, path])
    }

    /// `open <url>` in the default handler (browser for http).
    public static func open(_ target: String, label: String) -> ThreadAction {
        argv(label, [target])
    }

    static func argv(_ label: String, _ args: [String]) -> ThreadAction {
        ThreadAction(label: label, command: (["open"] + args.map(shellQuote)).joined(separator: " "), argv: [openTool] + args)
    }

    /// POSIX single-quoting for display (`/wt a` → `'/wt a'`, `it's` → `'it'\''s'`); plain
    /// path / URL characters stay bare.
    public static func shellQuote(_ s: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%+=:,./-_"))
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ plain.contains($0) && $0.isASCII }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func isTerminal(_ a: ThreadAction) -> Bool {
        a.command.hasPrefix("open -a Terminal ") || a.label.lowercased().contains("terminal")
    }

    /// `open -a Terminal "/x y"` → `/x y`.
    static func quotedArgument(_ command: String) -> String? {
        guard let start = command.firstIndex(of: "\""), let end = command.lastIndex(of: "\""), start < end else { return nil }
        return String(command[command.index(after: start)..<end])
    }
}

public extension ThreadAction {
    /// Destructive actions are only ever run from the explicit context menu, after confirmation.
    var isDestructive: Bool {
        let c = command.lowercased()
        return c.contains("worktree remove") || c.contains("rm -rf") || c.contains("branch -d")
    }
}

public struct ThreadsSnapshot: Codable, Equatable, Sendable {
    public var generatedAt: String?
    public var repo: String?
    public var sources: [String: String]?
    public var threads: [BuildThread]
    /// Per-harness quota rows for the menu's usage page. `nil` = collector predates usage.mjs.
    public var usage: [UsageRow]?
    public var usagePolledAt: String?
    /// Is the Omnigent feed behind the chat rows live? `nil` = collector predates it.
    public var omnigentFeed: OmnigentFeedInfo?

    public init(generatedAt: String? = nil, repo: String? = nil, sources: [String: String]? = nil, threads: [BuildThread],
                usage: [UsageRow]? = nil, usagePolledAt: String? = nil, omnigentFeed: OmnigentFeedInfo? = nil) {
        self.generatedAt = generatedAt; self.repo = repo; self.sources = sources; self.threads = threads
        self.usage = usage; self.usagePolledAt = usagePolledAt; self.omnigentFeed = omnigentFeed
    }
}

public enum ThreadsParseError: Error, Equatable {
    case empty
    case invalidJSON(String)
}

public enum ThreadsParser {
    /// Parses `threads.json` bytes. Throws on malformed input so the caller can keep its
    /// last good snapshot (partial writes from the collector are expected).
    public static func parse(_ data: Data) throws -> ThreadsSnapshot {
        guard !data.isEmpty else { throw ThreadsParseError.empty }
        do {
            return try JSONDecoder().decode(ThreadsSnapshot.self, from: data)
        } catch {
            throw ThreadsParseError.invalidJSON(String(describing: error))
        }
    }

    public static func parse(fileAt url: URL) throws -> ThreadsSnapshot {
        try parse(Data(contentsOf: url))
    }
}
