import XCTest
@testable import PetCore

/// The dropdown fix round: a feed blip never reads as "0 threads", the quota title
/// names what is full, a click says (and goes) where it opens, dev tools sit under Advanced.
final class DropdownFixesTests: XCTestCase {
    typealias Item = MenubarDropdown.Item
    let now = UsageFormat.parse("2026-10-17T12:10:00Z")!

    func notes(_ items: [Item]) -> [String] {
        items.compactMap { if case .note(let n) = $0 { return n } else { return nil } }
    }
    func threadLines(_ items: [Item]) -> [MenubarDropdown.ThreadLine] {
        items.compactMap { if case .thread(let l) = $0 { return l } else { return nil } }
    }

    // MARK: 1. Omnigent feed

    func testFeedReadsTheCollectorsFieldAndFallsBackToSources() throws {
        let held = try ThreadsParser.parse(Data("""
        {"generatedAt":"2026-10-17T12:09:00Z","sources":{"omnigent":"last-known: fetch failed"},
         "omnigentFeed":{"status":"last-known","since":"2026-10-17T12:08:00Z","error":"fetch failed"},
         "threads":[{"id":"omnigent:p1","name":"chat","state":"active"}]}
        """.utf8))
        XCTAssertEqual(OmnigentFeed.of(held), .lastKnown(since: UsageFormat.parse("2026-10-17T12:08:00Z")))
        XCTAssertEqual(held.threads.count, 1, "the held rows are still threads")
        XCTAssertEqual(OmnigentFeed.of(ThreadsSnapshot(threads: [], omnigentFeed: OmnigentFeedInfo(status: "unavailable"))), .unavailable)
        XCTAssertEqual(OmnigentFeed.of(ThreadsSnapshot(threads: [], omnigentFeed: OmnigentFeedInfo(status: "ok"))), .ok)
        XCTAssertEqual(OmnigentFeed.of(ThreadsSnapshot(sources: ["omnigent": "unavailable: fetch failed"], threads: [])), .unavailable,
                       "an older collector only says it in sources")
        XCTAssertEqual(OmnigentFeed.of(ThreadsSnapshot(sources: ["omnigent": "ok"], threads: [])), .ok)
        XCTAssertEqual(OmnigentFeed.of(nil), .ok)
    }

    func testFeedNotes() {
        XCTAssertNil(OmnigentFeed.ok.note(now: now))
        XCTAssertEqual(OmnigentFeed.lastKnown(since: now.addingTimeInterval(-120)).note(now: now),
                       "Omnigent feed unavailable — showing last known from 2m ago")
        XCTAssertEqual(OmnigentFeed.lastKnown(since: nil).note(now: now), "Omnigent feed unavailable — showing last known")
        XCTAssertEqual(OmnigentFeed.unavailable.note(now: now), "Omnigent feed unavailable — Omnigent chats not shown")
    }

    /// The bug: both feeds past the grace → threads=[] → "0 threads · none open".
    func testSummaryNeverSaysZeroThreadsForAFeedItCannotSee() {
        let fresh = CollectorHealth.fresh(age: 5)
        XCTAssertEqual(MenubarDropdown.summary(states: [], health: fresh, feed: .ok, sleeping: false), "0 threads · none open")
        XCTAssertEqual(MenubarDropdown.summary(states: [.working, .idle], health: fresh, feed: .ok, sleeping: false), "2 threads · 1 working · 1 idle")
        XCTAssertEqual(MenubarDropdown.summary(states: [.idle], health: fresh, feed: .ok, sleeping: true), "1 thread · 1 idle · sleeping")

        XCTAssertEqual(MenubarDropdown.summary(states: [], health: fresh, feed: .unavailable, sleeping: false), "Omnigent feed unavailable")
        XCTAssertEqual(MenubarDropdown.summary(states: [.working, .idle], health: fresh, feed: .unavailable, sleeping: false),
                       "Omnigent feed unavailable · 2 other threads · 1 working · 1 idle")
        XCTAssertEqual(MenubarDropdown.summary(states: [.idle], health: fresh, feed: .unavailable, sleeping: false),
                       "Omnigent feed unavailable · 1 other thread · 1 idle")
        XCTAssertEqual(MenubarDropdown.summary(states: [.working, .working], health: fresh, feed: .lastKnown(since: nil), sleeping: false),
                       "2 threads · 2 working · last known")
        XCTAssertEqual(MenubarDropdown.summary(states: [], health: .missing, feed: .unavailable, sleeping: false),
                       CollectorHealth.missing.summary, "a dead collector outranks the feed")
    }

    func testThreadSectionLeadsWithTheFeedNote() {
        var m = MenuModel(); m.setRows([row("chat", .working, ago: 1)])
        let held = MenubarDropdown.threadSection(m, workingColor: "#fff", feed: .lastKnown(since: now.addingTimeInterval(-60)), now: now)
        XCTAssertEqual(held[1], .note("Omnigent feed unavailable — showing last known from 60s ago"), "right under the header")
        XCTAssertEqual(threadLines(held).map(\.id), ["chat"])

        let gone = MenubarDropdown.threadSection(MenuModel(), workingColor: "#fff", feed: .unavailable, now: now)
        XCTAssertEqual(notes(gone), ["Omnigent feed unavailable — Omnigent chats not shown"], "no false 'no build threads'")
        XCTAssertEqual(notes(MenubarDropdown.threadSection(MenuModel(), workingColor: "#fff", feed: .ok, now: now)), ["no build threads"])
    }

    func testRowsComingBackAfterAnUnavailableFeedDoNotPopOrChime() {
        let chat = BuildThread(id: "omnigent:p1", name: "chat", state: .idle)
        let wt = BuildThread(id: "wt", name: "wt", state: .active)
        var td = TransitionDetector()
        var rec = FeedRecovery()
        func step(_ ts: [BuildThread], _ feed: OmnigentFeed, _ st: [String: NaviState]) -> [TransitionDetector.Change] {
            rec.filter(td.observe(ts.map { (id: $0.id, state: st[$0.id]!) }), feed: feed, threads: ts)
        }
        _ = step([chat, wt], .ok, ["omnigent:p1": .idle, "wt": .working])
        _ = step([wt], .unavailable, ["wt": .working])               // the chat row dropped
        let back = step([chat, wt], .ok, ["omnigent:p1": .idle, "wt": .idle])
        XCTAssertEqual(back.map(\.id), ["wt"], "the returning chat is not news; the real working → idle still is")
        XCTAssertEqual(IdleAlert.alerts(for: back, threads: []).map(\.id), ["wt"])
    }

    /// Codex review, fix round 1, issue 4: only Omnigent rows that were there before the
    /// outage return silently. A new Claude / Codex / git row, or a chat started during the
    /// outage, still pops on the recovery snapshot.
    func testRecoveryOnlySilencesOmnigentRowsThatExistedBeforeTheOutage() {
        let old = BuildThread(id: "omnigent:old", name: "old", state: .idle)
        let wtChat = BuildThread(id: "polly/x", name: "x", worktreePath: "/x", state: .active, omnigentUrl: "http://127.0.0.1:6767/c/x")
        let fresh = BuildThread(id: "omnigent:new", name: "new", state: .idle)
        let claude = BuildThread(id: "claude-wt", name: "claude", worktreePath: "/c", state: .active)
        var td = TransitionDetector()
        var rec = FeedRecovery()
        func step(_ ts: [BuildThread], _ feed: OmnigentFeed) -> [TransitionDetector.Change] {
            rec.filter(td.observe(ts.map { (id: $0.id, state: NaviStateMapper.state(for: $0)) }), feed: feed, threads: ts)
        }
        _ = step([old, wtChat], .ok)
        _ = step([], .unavailable)
        _ = step([], .unavailable)                                   // a second outage snapshot keeps the memory
        let back = step([old, wtChat, fresh, claude], .ok)
        XCTAssertEqual(Set(back.map(\.id)), ["omnigent:new", "claude-wt"], "pre-outage Omnigent rows silent, everything new pops")

        // not a recovery (the feed was fine): a new row is a new row, Omnigent or not
        var td2 = TransitionDetector(); var rec2 = FeedRecovery()
        _ = rec2.filter(td2.observe([]), feed: .ok, threads: [])
        XCTAssertEqual(rec2.filter(td2.observe([(id: "omnigent:old", state: .idle)]), feed: .ok, threads: [old]).map(\.id), ["omnigent:old"])
        XCTAssertTrue(wtChat.isOmnigentBacked); XCTAssertFalse(claude.isOmnigentBacked)
    }

    // MARK: 3. where a click opens

    func testTerminalAppResolve() {
        XCTAssertEqual(TerminalApp.resolve(pref: nil, iTermInstalled: true), .iTerm, "auto: iTerm when installed")
        XCTAssertEqual(TerminalApp.resolve(pref: "auto", iTermInstalled: false), .terminal)
        XCTAssertEqual(TerminalApp.resolve(pref: "Terminal", iTermInstalled: true), .terminal, "an explicit choice wins")
        XCTAssertEqual(TerminalApp.resolve(pref: "iterm2", iTermInstalled: false), .iTerm)
        XCTAssertEqual(TerminalApp.iTerm.appName, "iTerm")
    }

    func testActionsSayWhereTheyOpenAndOpenThere() {
        let deep = "omnigent://localhost:6767/c/abc"
        let web = "http://127.0.0.1:6767/c/abc"
        let raw = [ThreadAction(label: "Open terminal here", command: "open -a Terminal \"/wt a\""),
                   ThreadAction(label: "Open PR in browser", command: "open \"https://github.com/x/y/pull/7\""),
                   ThreadAction(label: "Open chat in Omnigent", command: "open \"\(deep)\""),
                   ThreadAction(label: "Open chat in browser", command: "open \"\(web)\""),
                   ThreadAction(label: "Delete this worktree (safe, already merged)", command: "git worktree remove \"/wt a\" && git branch -d \"b\"")]
        let t = BuildThread(id: "b", name: "b", worktreePath: "/wt a", state: .merged, actions: raw)
        let mapped = t.actions(OpenPrefs(terminal: .iTerm))
        XCTAssertEqual(mapped.map(\.label), ["Open in iTerm", "Open PR in browser", "Open in Omnigent", "Open chat in browser",
                                             "Delete this worktree (safe, already merged)"])
        XCTAssertEqual(mapped[0].argv, ["/usr/bin/open", "-a", "iTerm", "/wt a"])
        XCTAssertEqual(mapped[0].command, "open -a iTerm '/wt a'")
        XCTAssertEqual(mapped[1].argv, ["/usr/bin/open", "https://github.com/x/y/pull/7"])
        XCTAssertEqual(mapped[2].argv, ["/usr/bin/open", "-b", "ai.omnigent.desktop", deep])
        XCTAssertEqual(mapped[3].argv, ["/usr/bin/open", web])
        XCTAssertEqual(mapped[4], raw[4], "a collector shell command (the confirmed delete) is left alone")
        XCTAssertNil(mapped[4].argv); XCTAssertTrue(mapped[4].isDestructive)
        XCTAssertEqual(t.actions(OpenPrefs())[0].argv, ["/usr/bin/open", "-a", "Terminal", "/wt a"])
    }

    /// Codex review, fix round 1, issue 1: paths and URLs used to be pasted into a shell
    /// string run by /bin/sh -c. Now every open is an argv: hostile text is one argument.
    func testOpenCommandsAreArgvSoNothingInAPathOrURLCanRun() {
        let evil = "/tmp/x\"; touch /tmp/navi-injected; echo \"$(id)`id`'"
        let t = BuildThread(id: "e", name: "e", worktreePath: evil, state: .active,
                            actions: [ThreadAction(label: "Open terminal here", command: "open -a Terminal \"\(evil)\"")])
        let term = t.primaryAction(OpenPrefs(terminal: .iTerm))!
        XCTAssertEqual(term.argv, ["/usr/bin/open", "-a", "iTerm", evil], "the whole path, untouched, as one argument")
        XCTAssertEqual(term.label, "Open in iTerm")

        let evilURL = "omnigent://localhost:6767/c/a\"; touch /tmp/navi-injected; \""
        let chat = BuildThread(id: "omnigent:a", name: "a", state: .idle, omnigentDeepLink: evilURL)
        XCTAssertEqual(chat.primaryAction?.argv, ["/usr/bin/open", "-b", "ai.omnigent.desktop", evilURL])
        let web = BuildThread(id: "omnigent:b", name: "b", state: .idle, omnigentUrl: "http://127.0.0.1:6767/c/b$(id)")
        XCTAssertEqual(web.primaryAction(OpenPrefs(chatsInBrowser: true))?.argv, ["/usr/bin/open", "http://127.0.0.1:6767/c/b$(id)"])

        // a collector `open "…"` whose target carries a quote is also only an argument now
        let pr = BuildThread(id: "p", name: "p", state: .prOpen, pr: PullRequest(number: 1, url: "https://x"),
                             actions: [ThreadAction(label: "Open PR in browser", command: "open \"https://x/\"; touch /tmp/navi-injected; \"\"")])
        XCTAssertEqual(pr.primaryAction?.argv, ["/usr/bin/open", "https://x/\"; touch /tmp/navi-injected; \""])

        // the display string is safely quoted too (logs, confirm dialog)
        XCTAssertEqual(OpenTargets.shellQuote("/plain/path-1.2"), "/plain/path-1.2")
        XCTAssertEqual(OpenTargets.shellQuote("it's $(x)"), "'it'\\''s $(x)'")
        XCTAssertEqual(OpenTargets.shellQuote(""), "''")
    }

    func testDropdownRowsCarryTheirOpensInHint() {
        let wt = BuildThread(id: "wt", name: "wt", worktreePath: "/wt", state: .active,
                             actions: [ThreadAction(label: "Open terminal here", command: "open -a Terminal \"/wt\"")])
        let pr = BuildThread(id: "pr", name: "pr", worktreePath: "/p", state: .prOpen, pr: PullRequest(number: 1, url: "https://github.com/x/y/pull/1"),
                             actions: [ThreadAction(label: "Open PR in browser", command: "open \"https://github.com/x/y/pull/1\"")])
        let chat = BuildThread(id: "omnigent:c", name: "chat", state: .idle, omnigentUrl: "http://127.0.0.1:6767/c/c")
        var m = MenuModel(); m.setRows([row("wt", .working, ago: 1), row("pr", .working, ago: 2), row("omnigent:c", .idle, ago: 3), row("ghost", .idle, ago: 4)])
        let prefs = OpenPrefs(terminal: .iTerm)
        let hints = Dictionary(uniqueKeysWithValues: threadLines(MenubarDropdown.threadSection(m, workingColor: "#fff", threads: [wt, pr, chat], prefs: prefs))
            .map { ($0.id, $0.opensIn ?? "-") })
        XCTAssertEqual(hints, ["wt": "Open in iTerm", "pr": "Open PR in browser", "omnigent:c": "Open in Omnigent", "ghost": "-"])
        let browser = threadLines(MenubarDropdown.threadSection(m, workingColor: "#fff", threads: [chat], prefs: OpenPrefs(chatsInBrowser: true)))
        XCTAssertEqual(browser.first { $0.id == "omnigent:c" }?.opensIn, "Open chat in browser", "the browser pref still works")
    }

    // MARK: 2. quota title words

    func testPlainNames() {
        XCTAssertEqual(UsageRow(harness: "claude", label: "Claude Code · Max 5x").plainName, "Claude Code")
        XCTAssertEqual(UsageRow(harness: "x", label: "").plainName, "x")
        XCTAssertEqual(UsageFormat.plainWindow("5h"), "5-hour")
        XCTAssertEqual(UsageFormat.plainWindow("7d"), "weekly")
        XCTAssertEqual(UsageFormat.plainWindow("cycle total"), "cycle")
        XCTAssertEqual(UsageFormat.plainWindow("daily free reqs"), "daily free reqs")
    }

    // MARK: 4/5. Advanced

    func testAdvancedWording() {
        typealias A = MenubarDropdown.Advanced
        XCTAssertEqual([A.title, A.openDataFolder, A.copySettings, A.pasteSettings, A.resetSettings],
                       ["Advanced", "Open status data folder", "Copy look & behaviour settings", "Paste look & behaviour settings", "Reset look & behaviour…"])
        XCTAssertTrue(A.resetSettings.hasSuffix("…"), "it asks before resetting")
        for t in [A.openDataFolder, A.copySettings, A.pasteSettings, A.resetSettings, A.resetConfirmBody] {
            XCTAssertFalse(t.contains("json") || t.contains("config"), "plain words: \(t)")
        }
    }
}
