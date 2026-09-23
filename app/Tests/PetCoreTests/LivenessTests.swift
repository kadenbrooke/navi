import XCTest
@testable import PetCore

/// Click behaviour, idle rows, and the collector staleness guard.
final class LivenessTests: XCTestCase {
    private let id = "84e81756307b49139557f733749eb3b7"
    private var web: String { "http://127.0.0.1:6767/c/\(id)" }
    private var deep: String { "omnigent://localhost:6767/c/\(id)" }

    // MARK: primaryAction ordering (acceptance 4)

    func testChatRowPrimaryIsTheOmnigentDeepLink() {
        let t = BuildThread(id: "omnigent:\(id)", name: "chat", state: .active,
                            actions: [ThreadAction(label: "Open chat in Omnigent", command: "open \"\(deep)\""),
                                      ThreadAction(label: "Open chat in browser", command: "open \"\(web)\"")],
                            omnigentUrl: web, omnigentDeepLink: deep)
        XCTAssertTrue(t.isOmnigentChat)
        XCTAssertEqual(t.primaryAction?.command, "open \"\(deep)\"")
        XCTAssertEqual(t.primaryAction?.label, "Open chat in Omnigent")
        XCTAssertEqual(t.primaryAction(openChatsInBrowser: false)?.command, "open \"\(deep)\"")
    }

    func testOpenChatsInBrowserPrefSwitchesToTheWebURL() {
        let t = BuildThread(id: "omnigent:\(id)", name: "chat", state: .idle, omnigentUrl: web, omnigentDeepLink: deep)
        XCTAssertEqual(t.primaryAction(openChatsInBrowser: true)?.command, "open \"\(web)\"")
        XCTAssertEqual(t.primaryAction(openChatsInBrowser: true)?.label, "Open chat in browser")
    }

    func testWorktreeRowBackedByAnOmnigentSessionOpensTheChatNotThePROrTerminal() {
        let pr = ThreadAction(label: "Open PR in browser", command: "open \"https://github.com/x/y/pull/7\"")
        let term = ThreadAction(label: "Open terminal here", command: "open -a Terminal \"/wt\"")
        let t = BuildThread(id: "polly/x", name: "x", worktreePath: "/wt", state: .prOpen,
                            pr: PullRequest(number: 7, url: "https://github.com/x/y/pull/7"),
                            actions: [term, pr, ThreadAction(label: "Open chat in Omnigent", command: "open \"\(deep)\"")],
                            omnigentUrl: web, omnigentDeepLink: deep)
        XCTAssertEqual(t.primaryAction?.command, "open \"\(deep)\"", "chat wins; PR and terminal stay in the context menu")
        XCTAssertTrue((t.actions ?? []).contains(pr) && (t.actions ?? []).contains(term), "context menu keeps them")
    }

    func testClaudeAndCodexRowsKeepPRThenTerminalThenFirst() {
        let pr = ThreadAction(label: "Open PR in browser", command: "open \"https://github.com/x/y/pull/7\"")
        let term = ThreadAction(label: "Open terminal here", command: "open -a Terminal \"/wt\"")
        let withPR = BuildThread(id: "a", name: "a", worktreePath: "/wt", state: .prOpen,
                                 pr: PullRequest(number: 7, url: "https://github.com/x/y/pull/7"), actions: [term, pr])
        XCTAssertFalse(withPR.isOmnigentChat)
        XCTAssertEqual(withPR.primaryAction, pr)
        let noPR = BuildThread(id: "b", name: "b", worktreePath: "/wt", state: .active, actions: [term])
        XCTAssertEqual(noPR.primaryAction, term)
        XCTAssertEqual(noPR.primaryAction(openChatsInBrowser: true), term, "the pref only affects Omnigent rows")
        let codex = BuildThread(id: "codex:1", name: "c", state: .idle, actions: [ThreadAction(label: "Catch up with main", command: "git pull --rebase origin main")])
        XCTAssertEqual(codex.primaryAction?.command, "git pull --rebase origin main")
        XCTAssertNil(BuildThread(id: "d", name: "d", state: .idle).primaryAction)
    }

    func testDeepLinkDerivationFromWebURL() {
        XCTAssertEqual(BuildThread.deepLink(fromWebURL: web), deep)
        XCTAssertEqual(BuildThread.deepLink(fromWebURL: "http://omni.tail.net:9000/c/abc"), "omnigent://omni.tail.net:9000/c/abc")
        XCTAssertEqual(BuildThread.deepLink(fromWebURL: "https://omni.example.com/c/abc"), "omnigent://omni.example.com:443/c/abc")
        XCTAssertNil(BuildThread.deepLink(fromWebURL: "https://github.com/x/y/pull/7"), "not a chat url")
        // no omnigentDeepLink, no http action either → derived from omnigentUrl alone
        let t = BuildThread(id: "omnigent:\(id)", name: "chat", state: .idle, omnigentUrl: web)
        XCTAssertEqual(t.primaryAction?.command, "open \"\(deep)\"")
    }

    // MARK: idle rows (task d)

    func testIdleFlagAndLastSeenDecode() throws {
        let json = """
        {"threads":[{"id":"omnigent:1","name":"quiet","state":"idle","idle":true,"lastSeen":"2026-09-19T15:52:54.000Z"},
                    {"id":"omnigent:2","name":"busy","state":"active","idle":false,"lastSeen":"2026-09-19T16:00:00Z"},
                    {"id":"claude:3","name":"old collector","state":"idle"}]}
        """
        let snap = try ThreadsParser.parse(Data(json.utf8))
        XCTAssertEqual(snap.threads[0].idle, true)
        XCTAssertEqual(snap.threads[0].lastSeenEpoch, ISO8601DateFormatter.lenient("2026-09-19T15:52:54.000Z")?.timeIntervalSince1970)
        XCTAssertEqual(snap.threads[1].idle, false)
        XCTAssertNotNil(snap.threads[1].lastSeenEpoch, "seconds-precision ISO parses too")
        XCTAssertNil(snap.threads[2].idle, "older collector: absent, treated as not idle")
        XCTAssertNil(snap.threads[2].lastSeenEpoch)
    }

    func testIdleDoesNotChangeNaviState() {
        // the collector's idle flag is a menu decoration; the state mapper still reads sessions
        var t = BuildThread(id: "omnigent:1", name: "quiet", state: .idle, idle: true)
        XCTAssertEqual(NaviStateMapper.state(for: t), .idle)
        t.state = .needsInput
        XCTAssertEqual(NaviStateMapper.state(for: t), .needsInput, "a question stays a question even if the row is quiet")
        t.state = .active; t.idle = false
        XCTAssertEqual(NaviStateMapper.state(for: t), .working)
    }

    func testMenuSortsIdleRowsAfterActiveRowsInBothSorts() {
        var rows = [
            row("active-old", .working, ago: 30),
            row("idle-new", .idle, ago: 1),
            row("blocked-idle", .blocked, ago: 2),
            row("needs-input", .needsInput, ago: 10),
        ]
        rows[1].idle = true
        rows[2].idle = true
        var m = MenuModel(sort: .recent)
        m.setRows(rows)
        XCTAssertEqual(m.sortedRows.map(\.name), ["needs-input", "active-old", "idle-new", "blocked-idle"],
                       "recent: active rows newest-first, then idle rows newest-first")
        m.sort = .status
        XCTAssertEqual(m.sortedRows.map(\.name), ["needs-input", "active-old", "blocked-idle", "idle-new"],
                       "status: active rows by rank, then idle rows by rank")
        XCTAssertTrue(m.sortedRows.filter(\.idle).allSatisfy { $0.idle }, "idle rows are still listed, never dropped")
        XCTAssertEqual(m.sortedRows.count, 4)
    }

    func testMenuRowIdleDefaultsFalse() {
        XCTAssertFalse(MenuRow(id: "a", name: "a", state: .idle, changedAt: 0, status: "").idle)
    }

    // MARK: collector staleness guard (task b)

    private func snap(generatedAt: String?) -> ThreadsSnapshot {
        ThreadsSnapshot(generatedAt: generatedAt, threads: [BuildThread(id: "omnigent:1", name: "x", state: .active)])
    }

    func testFreshWithinThreeMinutes() {
        let now = ISO8601DateFormatter.lenient("2026-09-19T16:10:00Z")!
        let h = CollectorHealth.check(snapshot: snap(generatedAt: "2026-09-19T16:08:30.000Z"), fileExists: true, now: now)
        XCTAssertEqual(h, .fresh(age: 90))
        XCTAssertTrue(h.isLive)
        XCTAssertNil(h.menuRow)
        XCTAssertNil(h.summary)
        XCTAssertEqual(CollectorHealth.check(snapshot: snap(generatedAt: "2026-09-19T16:07:00Z"), fileExists: true, now: now), .fresh(age: 180), "exactly the threshold is still fresh")
    }

    func testStaleAfterThreeMinutesShowsOneCollectorRowAndNoLiveThreads() {
        let now = ISO8601DateFormatter.lenient("2026-09-19T16:10:00Z")!
        // generatedAt touched back 10 minutes (acceptance 3)
        let h = CollectorHealth.check(snapshot: snap(generatedAt: "2026-09-19T16:00:00.000Z"), fileExists: true, now: now)
        XCTAssertEqual(h, .stale(age: 600))
        XCTAssertFalse(h.isLive, "stale sessions are never live")
        let r = try! XCTUnwrap(h.menuRow)
        XCTAssertEqual(r.id, CollectorHealth.rowId)
        XCTAssertEqual(r.name, "collector not running")
        XCTAssertEqual(r.state, .blocked)
        XCTAssertEqual(r.status, "threads.json is 10m old · run ./install.sh")
        XCTAssertEqual(h.summary, "collector stale (last snapshot 10m ago) — run ./install.sh")
        XCTAssertEqual(CollectorHealth.staleAfter, 180)
    }

    func testMissingFileAndUnparseableGeneratedAt() {
        XCTAssertEqual(CollectorHealth.check(snapshot: nil, fileExists: false), .missing)
        XCTAssertEqual(CollectorHealth.check(snapshot: snap(generatedAt: nil), fileExists: false), .missing)
        XCTAssertEqual(CollectorHealth.missing.menuRow?.status, CollectorHealth.installHint)
        XCTAssertEqual(CollectorHealth.check(snapshot: snap(generatedAt: nil), fileExists: true), .stale(age: nil))
        XCTAssertEqual(CollectorHealth.check(snapshot: snap(generatedAt: "garbage"), fileExists: true), .stale(age: nil))
        XCTAssertEqual(CollectorHealth.stale(age: nil).menuRow?.status, "threads.json has no generatedAt · run ./install.sh")
    }

    func testAgeText() {
        XCTAssertEqual(CollectorHealth.ageText(45), "45s")
        XCTAssertEqual(CollectorHealth.ageText(600), "10m")
        XCTAssertEqual(CollectorHealth.ageText(7200), "2h")
        XCTAssertEqual(CollectorHealth.ageText(3 * 86_400), "3d")
    }
}
