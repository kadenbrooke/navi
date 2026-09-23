import XCTest
@testable import PetCore

final class ParsingTests: XCTestCase {
    func testParsesRealSample() throws {
        let snap = try ThreadsParser.parse(fixtureData("threads-sample.json"))
        XCTAssertEqual(snap.threads.count, 16)
        XCTAssertEqual(snap.repo, "/work/example-app")
        XCTAssertEqual(snap.sources?["git"], "ok")

        let stale = try XCTUnwrap(snap.threads.first { $0.name == "demo-recording" })
        XCTAssertEqual(stale.state, .stale)
        XCTAssertEqual(stale.pr?.number, 13)
        XCTAssertEqual(stale.git?.behind, 47)
        XCTAssertEqual(stale.actions?.count, 3)

        let prOpen = try XCTUnwrap(snap.threads.first { $0.state == .prOpen })
        XCTAssertNotNil(prOpen.pr?.url)
        let active = snap.threads.filter { $0.state == .active }
        XCTAssertEqual(active.count, 1)
    }

    func testEmptyDataThrows() {
        XCTAssertThrowsError(try ThreadsParser.parse(Data())) { err in
            XCTAssertEqual(err as? ThreadsParseError, .empty)
        }
    }

    func testTruncatedWriteThrows() throws {
        // Simulates the collector mid-write: cut the real file in half.
        let full = try fixtureData("threads-sample.json")
        let half = full.prefix(full.count / 2)
        XCTAssertThrowsError(try ThreadsParser.parse(half))
    }

    func testGarbageThrows() {
        XCTAssertThrowsError(try ThreadsParser.parse(Data("not json at all".utf8)))
        XCTAssertThrowsError(try ThreadsParser.parse(Data("{\"threads\": \"nope\"}".utf8)))
    }

    func testMinimalThreadWithMissingOptionalFields() throws {
        let json = """
        {"threads":[{"id":"x","name":"x","state":"idle"}]}
        """
        let snap = try ThreadsParser.parse(Data(json.utf8))
        XCTAssertEqual(snap.threads.count, 1)
        XCTAssertNil(snap.threads[0].pr)
        XCTAssertNil(snap.threads[0].actions)
        XCTAssertNil(snap.generatedAt)
        XCTAssertNil(snap.threads[0].primaryAction)
    }

    func testUnknownStateDoesNotCrash() throws {
        let json = """
        {"threads":[{"id":"x","name":"x","state":"something-new","pr":null}]}
        """
        let snap = try ThreadsParser.parse(Data(json.utf8))
        XCTAssertEqual(snap.threads[0].state, .unknown)
        XCTAssertEqual(NaviStateMapper.state(for: snap.threads[0]), .idle)
    }

    /// A chat row: `omnigent:<id>`, no worktreePath, git null, one "open chat" action.
    func testChatRowWithoutWorktreeDecodesAndOpensOmnigent() throws {
        let json = """
        {"threads":[
          {"id":"omnigent:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa01","name":"Refactor the config loader","worktreePath":null,
           "workspacePath":"/repo","branch":"main","state":"active","stateLabel":"Agent working",
           "detail":"polly mid-turn, seen 9m ago","reason":null,"reviewReady":false,"pr":null,
           "omnigentUrl":"http://127.0.0.1:6767/c/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa01",
           "sessions":[{"harness":"omnigent","id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa01","title":"Refactor the config loader","status":"running","lastSeen":"2026-09-17T12:00:00.000Z"}],
           "git":null,
           "actions":[{"label":"Open chat in Omnigent","command":"open \\"http://127.0.0.1:6767/c/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa01\\""}]},
          {"id":"omnigent:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa06","name":"Profile the slow import","state":"blocked","detail":"Runner disconnected unexpectedly.","git":null,"actions":[]},
          {"id":"omnigent:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa07","name":"Which chart library should we use?","state":"needs-input","git":null,"actions":[]}
        ]}
        """
        let snap = try ThreadsParser.parse(Data(json.utf8))
        XCTAssertEqual(snap.threads.count, 3)
        let chat = snap.threads[0]
        XCTAssertNil(chat.worktreePath)
        XCTAssertNil(chat.git)
        XCTAssertNil(chat.pr)
        XCTAssertEqual(chat.state, .active)
        // older collector (no omnigentDeepLink field): the desktop link is derived from the http action
        XCTAssertEqual(chat.primaryAction?.command, "open \"omnigent://localhost:6767/c/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa01\"")
        XCTAssertEqual(chat.primaryAction(openChatsInBrowser: true)?.command, "open \"http://127.0.0.1:6767/c/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa01\"")
        XCTAssertEqual(snap.threads[1].state, .blocked)
        XCTAssertEqual(NaviStateMapper.state(for: snap.threads[1]), .blocked)
        XCTAssertEqual(snap.threads[2].state, .needsInput)
        XCTAssertEqual(NaviStateMapper.state(for: snap.threads[2]), .needsInput)
    }

    func testSessionChildFlagDecodesAndDefaultsToNil() throws {
        let json = """
        {"generatedAt":"2026-09-21T12:00:00Z","threads":[{"id":"omnigent:p1","name":"n","state":"idle",
          "sessions":[{"harness":"omnigent","id":"p1","status":"idle","lastSeen":"2026-09-21T12:00:00Z","child":false},
                      {"harness":"omnigent","id":"c1","status":"running","lastSeen":"2026-09-21T12:00:00Z","child":true},
                      {"harness":"claude","id":"old","status":"running"}]}]}
        """
        let snap = try ThreadsParser.parse(Data(json.utf8))
        let s = snap.threads[0].sessions!
        XCTAssertEqual(s.map(\.child), [false, true, nil])
        // an older collector (no `child` key) reads as parent: the running claude row counts
        XCTAssertEqual(NaviStateMapper.state(for: snap.threads[0], now: Date(timeIntervalSince1970: 1_790_000_000)), .working)
    }

    func testPrimaryActionPrefersPRThenTerminal() {
        let term = ThreadAction(label: "Open terminal here", command: "open -a Terminal \"/x\"")
        let pr = ThreadAction(label: "Open PR in browser", command: "open \"https://github.com/o/r/pull/1\"")
        let pull = ThreadAction(label: "Catch up with main", command: "git pull --rebase origin main")
        let rm = ThreadAction(label: "Remove worktree", command: "git worktree remove /x")

        let withPR = thread("a", .prOpen, pr: PullRequest(number: 1, url: "https://github.com/o/r/pull/1"), actions: [term, pr, pull])
        XCTAssertEqual(withPR.primaryAction, pr)

        let noPR = thread("b", .uncommitted, actions: [pull, term, rm])
        XCTAssertEqual(noPR.primaryAction, term)

        let onlyDestructive = thread("c", .stale, actions: [rm])
        XCTAssertNil(onlyDestructive.primaryAction, "never auto-pick a worktree remove")

        XCTAssertTrue(rm.isDestructive)
        XCTAssertFalse(pull.isDestructive)
    }
}
