// node --test collector/*.test.mjs
//
// Pure-function tests: no gh, no network, no real worktrees. Every external
// source is a fixture handed to buildThreads / deriveState / diffStates.

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  THRESHOLDS,
  STATE_LABELS,
  deriveState,
  stateKey,
  buildThreads,
  buildActions,
  parseWorktreeList,
  indexPrsByBranch,
  indexRegistryByBranch,
  mapOmnigentSessions,
  collectOmnigent,
  collectOmnigentFull,
  parseRunners,
  omnigentSessionUrl,
  omnigentDeepLink,
  liveness,
  isChannelListener,
  deriveLiveState,
  collectClaudeSessions,
  parseProcessTable,
  isOmnigentDescendant,
  codexLiveCwds,
  threadName,
  pickSessionTitle,
  isAutoBranch,
  deriveOmnigentState,
  mapCodexThreads,
  cwdMatches,
  renderTable,
  OMNIGENT_PAGE_LIMIT,
  CHAT_IDLE_LABEL,
  LIVE_IDLE_LABEL,
  collectGitSources,
} from "./collect.mjs";
import { diffStates, deliver, nextNotifiedMap, run as notifyRun } from "./notify.mjs";

const NOW = Date.parse("2026-09-17T12:00:00Z");
const HERE = dirname(fileURLToPath(import.meta.url));
const iso = (msAgo) => new Date(NOW - msAgo).toISOString();
const DAY = 86_400_000;
const MIN = 60_000;

// A clean, pushed, fresh branch — the baseline every state test perturbs.
function cleanGit(over = {}) {
  return {
    ahead: 1,
    behind: 0,
    dirtyFiles: 0,
    hasUpstream: true,
    unpushedCommits: 0,
    lastCommitAt: iso(1 * DAY),
    ...over,
  };
}

const openPr = { number: 42, url: "https://github.com/x/y/pull/42", title: "t", state: "OPEN" };
const mergedPr = { ...openPr, number: 41, state: "MERGED", mergedAt: iso(2 * DAY) };

// ---------------------------------------------------------------------------
describe("state machine — every state reachable", () => {
  test("stale: behind main by more than the threshold", () => {
    const r = deriveState(
      { git: cleanGit({ behind: THRESHOLDS.STALE_BEHIND_COMMITS + 1 }), pr: null, sessions: [] },
      NOW,
    );
    assert.equal(r.state, "stale");
    assert.equal(r.stateLabel, STATE_LABELS.stale);
    assert.match(r.detail, /behind main/);
  });

  test("stale: no commits in 7+ days (not merged)", () => {
    const r = deriveState(
      { git: cleanGit({ lastCommitAt: iso(THRESHOLDS.STALE_NO_COMMIT_DAYS * DAY + 1) }), pr: openPr, sessions: [] },
      NOW,
    );
    assert.equal(r.state, "stale");
    assert.match(r.detail, /last commit 7 days ago/);
  });

  test("exactly at the behind threshold is NOT stale", () => {
    const r = deriveState(
      { git: cleanGit({ behind: THRESHOLDS.STALE_BEHIND_COMMITS }), pr: null, sessions: [] },
      NOW,
    );
    assert.notEqual(r.state, "stale");
  });

  test("uncommitted: dirty files", () => {
    const r = deriveState({ git: cleanGit({ dirtyFiles: 3 }), pr: null, sessions: [] }, NOW);
    assert.equal(r.state, "uncommitted");
    assert.equal(r.stateLabel, STATE_LABELS.uncommitted);
    assert.equal(r.detail, "3 changed files not committed");
  });

  test("unpushed: commits ahead of upstream, clean tree", () => {
    const r = deriveState({ git: cleanGit({ unpushedCommits: 2 }), pr: null, sessions: [] }, NOW);
    assert.equal(r.state, "unpushed");
    assert.equal(r.stateLabel, STATE_LABELS.unpushed);
  });

  test("unpushed: no upstream but has commits past main", () => {
    const r = deriveState(
      { git: cleanGit({ hasUpstream: false, ahead: 3, unpushedCommits: 3 }), pr: null, sessions: [] },
      NOW,
    );
    assert.equal(r.state, "unpushed");
    assert.match(r.detail, /never been pushed/);
  });

  test("fresh worktree with no commits and no upstream is idle, not unpushed", () => {
    const r = deriveState(
      { git: cleanGit({ hasUpstream: false, ahead: 0, unpushedCommits: 0 }), pr: null, sessions: [] },
      NOW,
    );
    assert.equal(r.state, "idle");
    assert.match(r.detail, /no commits yet/);
  });

  test("pr-open: registry says ready -> 'PR waiting on you'", () => {
    const r = deriveState(
      { git: cleanGit(), pr: openPr, registryStatus: "ready-for-human-merge", sessions: [] },
      NOW,
    );
    assert.equal(r.state, "pr-open");
    assert.equal(r.reviewReady, true);
    assert.equal(r.stateLabel, STATE_LABELS["pr-open-ready"]);
    assert.equal(stateKey(r), "pr-open:ready");
  });

  test("pr-open: ready_for_merge (underscore variant) also counts", () => {
    const r = deriveState(
      { git: cleanGit(), pr: openPr, registryStatus: "ready_for_merge", sessions: [] },
      NOW,
    );
    assert.equal(r.reviewReady, true);
  });

  test("pr-open: no registry verdict -> 'PR open, review not done'", () => {
    const r = deriveState({ git: cleanGit(), pr: openPr, registryStatus: null, sessions: [] }, NOW);
    assert.equal(r.state, "pr-open");
    assert.equal(r.reviewReady, false);
    assert.equal(r.stateLabel, STATE_LABELS["pr-open"]);
    assert.equal(stateKey(r), "pr-open:unreviewed");
  });

  test("pr-open: registry fix-round status is not ready", () => {
    const r = deriveState(
      { git: cleanGit(), pr: openPr, registryStatus: "fix-round-2", sessions: [] },
      NOW,
    );
    assert.equal(r.reviewReady, false);
  });

  test("merged", () => {
    const r = deriveState({ git: cleanGit(), pr: mergedPr, sessions: [] }, NOW);
    assert.equal(r.state, "merged");
    assert.equal(r.stateLabel, STATE_LABELS.merged);
  });

  test("merged is never stale even when old", () => {
    const r = deriveState(
      { git: cleanGit({ lastCommitAt: iso(30 * DAY), behind: 100 }), pr: mergedPr, sessions: [] },
      NOW,
    );
    assert.equal(r.state, "merged");
  });

  test("active: session seen within the window", () => {
    const r = deriveState(
      {
        git: cleanGit(),
        pr: null,
        sessions: [{ harness: "claude", id: "s", title: "t", status: "idle", lastSeen: iso(2 * MIN) }],
      },
      NOW,
    );
    assert.equal(r.state, "active");
    assert.equal(r.stateLabel, STATE_LABELS.active);
  });

  test("active: status running counts even when lastSeen is old", () => {
    const r = deriveState(
      {
        git: cleanGit(),
        pr: null,
        sessions: [{ harness: "omnigent", id: "s", title: "t", status: "running", lastSeen: iso(45 * MIN) }],
      },
      NOW,
    );
    assert.equal(r.state, "active");
  });

  test("idle: session older than the window, nothing else", () => {
    const r = deriveState(
      {
        git: cleanGit(),
        pr: null,
        sessions: [
          { harness: "claude", id: "s", title: "t", status: "waiting", lastSeen: iso((THRESHOLDS.ACTIVE_SESSION_MINUTES + 1) * MIN) },
        ],
      },
      NOW,
    );
    assert.equal(r.state, "idle");
    assert.equal(r.stateLabel, STATE_LABELS.idle);
  });
});

describe("state machine — priority order, first match wins", () => {
  test("stale beats uncommitted, unpushed, pr-open, active", () => {
    const r = deriveState(
      {
        git: cleanGit({ behind: 99, dirtyFiles: 2, unpushedCommits: 1 }),
        pr: openPr,
        registryStatus: "ready-for-human-merge",
        sessions: [{ harness: "claude", id: "s", title: "t", status: "running", lastSeen: iso(0) }],
      },
      NOW,
    );
    assert.equal(r.state, "stale");
  });

  test("uncommitted beats unpushed, pr-open, merged, active", () => {
    const r = deriveState(
      {
        git: cleanGit({ dirtyFiles: 1, unpushedCommits: 1 }),
        pr: mergedPr,
        sessions: [{ harness: "claude", id: "s", title: "t", status: "running", lastSeen: iso(0) }],
      },
      NOW,
    );
    assert.equal(r.state, "uncommitted");
  });

  test("unpushed beats pr-open and active", () => {
    const r = deriveState(
      {
        git: cleanGit({ unpushedCommits: 1 }),
        pr: openPr,
        sessions: [{ harness: "claude", id: "s", title: "t", status: "running", lastSeen: iso(0) }],
      },
      NOW,
    );
    assert.equal(r.state, "unpushed");
  });

  test("pr-open beats active", () => {
    const r = deriveState(
      {
        git: cleanGit(),
        pr: openPr,
        sessions: [{ harness: "claude", id: "s", title: "t", status: "running", lastSeen: iso(0) }],
      },
      NOW,
    );
    assert.equal(r.state, "pr-open");
  });

  test("merged beats active", () => {
    const r = deriveState(
      {
        git: cleanGit(),
        pr: mergedPr,
        sessions: [{ harness: "claude", id: "s", title: "t", status: "running", lastSeen: iso(0) }],
      },
      NOW,
    );
    assert.equal(r.state, "merged");
  });
});

// ---------------------------------------------------------------------------
describe("actions", () => {
  const base = { worktreePath: "/wt/a", branch: "polly/a", pr: null };

  test("every thread gets 'open terminal'", () => {
    const a = buildActions({ ...base, state: "idle" });
    assert.equal(a.length, 1);
    assert.match(a[0].command, /open -a Terminal "\/wt\/a"/);
  });

  test("PR present -> open PR in browser", () => {
    const a = buildActions({ ...base, state: "pr-open", pr: openPr });
    assert.ok(a.some((x) => x.command === `open "${openPr.url}"`));
  });

  test("merged -> exact worktree remove + branch delete command, nothing else destructive", () => {
    const a = buildActions({ ...base, state: "merged", pr: mergedPr });
    const del = a.find((x) => /worktree remove/.test(x.command));
    assert.equal(del.command, 'git worktree remove "/wt/a" && git branch -d "polly/a"');
    assert.ok(!a.some((x) => /pull --rebase/.test(x.command)));
  });

  test("stale and unpushed -> rebase command; others do not get it", () => {
    for (const state of ["stale", "unpushed"]) {
      const a = buildActions({ ...base, state });
      assert.ok(a.some((x) => x.command === "git pull --rebase origin main"), state);
      assert.ok(!a.some((x) => /worktree remove/.test(x.command)), state);
    }
    for (const state of ["uncommitted", "pr-open", "active", "idle"]) {
      const a = buildActions({ ...base, state });
      assert.ok(!a.some((x) => /pull --rebase/.test(x.command)), state);
      assert.ok(!a.some((x) => /worktree remove/.test(x.command)), state);
    }
  });
});

// ---------------------------------------------------------------------------
describe("source parsing", () => {
  test("parseWorktreeList handles branch, detached, bare-ish entries", () => {
    const wts = parseWorktreeList(
      [
        "worktree /repo",
        "HEAD aaaa",
        "branch refs/heads/main",
        "",
        "worktree /repo-wt/x",
        "HEAD bbbb",
        "branch refs/heads/polly/x",
        "",
        "worktree /repo-wt/d",
        "HEAD cccc",
        "detached",
        "",
      ].join("\n"),
    );
    assert.equal(wts.length, 3);
    assert.equal(wts[0].branch, "main");
    assert.equal(wts[1].branch, "polly/x");
    assert.equal(wts[2].branch, null);
    assert.equal(wts[2].detached, true);
  });

  test("indexPrsByBranch prefers OPEN over MERGED over CLOSED, newest within a state", () => {
    const m = indexPrsByBranch([
      { number: 15, headRefName: "b", state: "MERGED" },
      { number: 16, headRefName: "b", state: "OPEN" },
      { number: 3, headRefName: "c", state: "CLOSED" },
      { number: 9, headRefName: "c", state: "MERGED" },
      { number: 7, headRefName: "d", state: "OPEN" },
      { number: 8, headRefName: "d", state: "OPEN" },
    ]);
    assert.equal(m.get("b").number, 16);
    assert.equal(m.get("c").number, 9);
    assert.equal(m.get("d").number, 8);
  });

  test("indexRegistryByBranch keys tasks by branch", () => {
    const m = indexRegistryByBranch({ tasks: [{ id: "t", branch: "polly/t", status: "ready-for-human-merge" }, { id: "nobranch" }] });
    assert.equal(m.get("polly/t").status, "ready-for-human-merge");
    assert.equal(m.size, 1);
  });

  test("mapOmnigentSessions drops archived and workspace-less rows", () => {
    const s = mapOmnigentSessions({
      data: [
        { id: "1", title: "a", status: "running", updated_at: 1700000000, workspace: "/wt/a", git_branch: "polly/a" },
        { id: "2", title: "b", status: "idle", updated_at: 1700000000, workspace: "/wt/b", archived: true },
        { id: "3", title: "c", status: "idle", updated_at: 1700000000 },
      ],
    });
    assert.equal(s.length, 1);
    assert.equal(s[0].harness, "omnigent");
    assert.equal(s[0].cwd, "/wt/a");
    assert.equal(s[0].lastSeen, new Date(1700000000 * 1000).toISOString());
  });

  test("mapCodexThreads uses updated_at_ms when present and truncates titles", () => {
    const s = mapCodexThreads([{ id: "c1", cwd: "/wt/a", title: "line1\nline2", updated_at: 1, updated_at_ms: 5000 }]);
    assert.equal(s[0].harness, "codex");
    assert.equal(s[0].title, "line1");
    assert.equal(s[0].lastSeen, new Date(5000).toISOString());
  });

  test("cwdMatches: equal or nested, never sibling prefix", () => {
    assert.ok(cwdMatches("/wt/a", "/wt/a"));
    assert.ok(cwdMatches("/wt/a/sub", "/wt/a/"));
    assert.ok(!cwdMatches("/wt/ab", "/wt/a"));
    assert.ok(!cwdMatches("", "/wt/a"));
  });
});

// ---------------------------------------------------------------------------
// The rule: a row exists ONLY when a live parent session backs it. Git / PR
// facts decorate rows, never create them; leftovers go to threads.dormant.
// ---------------------------------------------------------------------------
const liveSess = (over = {}) => ({
  harness: "claude",
  id: "s",
  title: "t",
  status: "idle",
  lastSeen: iso(0),
  cwd: "/repo-wt/a",
  branch: null,
  live: true,
  child: false,
  ...over,
});

describe("buildThreads — live parent sessions make rows, git only decorates", () => {
  const worktrees = [
    { path: "/repo", branch: "main" },
    { path: "/repo-wt/a", branch: "polly/a" },
    { path: "/repo-wt/b", branch: "polly/b" },
  ];
  const gitByPath = {
    "/repo": cleanGit(),
    "/repo-wt/a": cleanGit(),
    "/repo-wt/b": cleanGit({ dirtyFiles: 1 }),
  };

  test("no sessions at all -> zero rows; every worktree (not main) is dormant with git-only state", () => {
    const threads = buildThreads({ worktrees, gitByPath, prs: [], registry: null, sessions: [] }, NOW);
    assert.equal(threads.length, 0);
    assert.deepEqual(threads.dormant.map((t) => t.id).sort(), ["polly/a", "polly/b"]);
    const b = threads.dormant.find((t) => t.id === "polly/b");
    assert.equal(b.state, "uncommitted");
    assert.equal(b.git.dirtyFiles, 1);
    assert.equal(typeof b.name, "string");
  });

  test("open PR worktree with no live session -> dormant[], not threads[]", () => {
    const prs = [{ number: 5, headRefName: "polly/a", state: "OPEN", url: "u", title: "T" }];
    const registry = { tasks: [{ branch: "polly/a", status: "ready-for-human-merge" }] };
    const threads = buildThreads({ worktrees, gitByPath, prs, registry, sessions: [] }, NOW);
    assert.equal(threads.length, 0);
    const a = threads.dormant.find((t) => t.id === "polly/a");
    assert.deepEqual(a.pr, { number: 5, url: "u", title: "T", state: "OPEN" });
    assert.equal(a.state, "pr-open");
    assert.equal(a.reviewReady, true);
    assert.equal(a.name, "T");
  });

  test("gh + omnigent + codex + registry all undefined -> still no throw", () => {
    const threads = buildThreads({ worktrees, gitByPath, prs: undefined, registry: undefined, sessions: undefined }, NOW);
    assert.equal(threads.length, 0);
    assert.equal(threads.dormant.length, 2);
  });

  test("a live parent session in a worktree makes that worktree a row (by cwd, nested ok, or by branch)", () => {
    const sessions = [
      liveSess({ id: "nested", cwd: "/repo-wt/a/sub", lastSeen: iso(30 * MIN) }),
      liveSess({ harness: "omnigent", id: "bybranch", cwd: "/elsewhere", branch: "polly/a", status: "running", lastSeen: iso(1 * MIN) }),
    ];
    const threads = buildThreads({ worktrees, gitByPath, prs: [], registry: null, sessions }, NOW);
    assert.deepEqual(threads.map((t) => t.id), ["polly/a"]);
    assert.deepEqual(threads[0].sessions.map((s) => s.id), ["bybranch", "nested"]);
    assert.equal(threads[0].state, "active");
    assert.equal(threads[0].worktreePath, "/repo-wt/a");
    assert.equal(threads[0].git.ahead, 1);
    assert.ok(!("cwd" in threads[0].sessions[0]), "cwd not leaked into output");
    assert.deepEqual(threads.dormant.map((t) => t.id), ["polly/b"]);
  });

  test("dead session (live: false) in a worktree does not make a row", () => {
    const sessions = [liveSess({ live: false, status: "running" })];
    const threads = buildThreads({ worktrees, gitByPath, prs: [], registry: null, sessions }, NOW);
    assert.equal(threads.length, 0);
    assert.ok(threads.dormant.some((t) => t.id === "polly/a"));
  });

  test("child session (child: true or parentId) never makes a row on its own", () => {
    const orphanChild = [liveSess({ id: "kid", child: true })];
    assert.equal(buildThreads({ worktrees, gitByPath, prs: [], registry: null, sessions: orphanChild }, NOW).length, 0);
    const withParent = [liveSess({ id: "kid", parentId: "missing-parent" })];
    assert.equal(buildThreads({ worktrees, gitByPath, prs: [], registry: null, sessions: withParent }, NOW).length, 0);
  });

  test("git facts decorate a live row's detail but never flip its state", () => {
    const sessions = [liveSess({ id: "s", cwd: "/repo-wt/b", status: "idle", lastSeen: iso(30 * MIN) })];
    const threads = buildThreads({ worktrees, gitByPath, prs: [], registry: null, sessions }, NOW);
    const b = threads.find((t) => t.id === "polly/b");
    assert.equal(b.state, "idle");
    assert.equal(b.stateLabel, LIVE_IDLE_LABEL);
    assert.match(b.detail, /1 file not committed/);
  });

  test("a rotted branch under a live session is blocked with the rot as reason", () => {
    const g = { ...gitByPath, "/repo-wt/a": cleanGit({ behind: THRESHOLDS.STALE_BEHIND_COMMITS + 1 }) };
    const threads = buildThreads({ worktrees, gitByPath: g, prs: [], registry: null, sessions: [liveSess()] }, NOW);
    assert.equal(threads[0].state, "blocked");
    assert.match(threads[0].reason, /behind main/);
  });

  test("PR reviewed and ready under a live session -> needs-input", () => {
    const prs = [{ number: 5, headRefName: "polly/a", state: "OPEN", url: "u", title: "T" }];
    const registry = { tasks: [{ branch: "polly/a", status: "ready-for-human-merge" }] };
    const threads = buildThreads({ worktrees, gitByPath, prs, registry, sessions: [liveSess()] }, NOW);
    assert.equal(threads[0].state, "needs-input");
    assert.equal(threads[0].reviewReady, true);
    assert.match(threads[0].detail, /PR #5 reviewed/);
    assert.ok(threads[0].actions.some((x) => x.command === 'open "u"'));
  });

  test("codex sessions capped to newest one per row", () => {
    const sessions = Array.from({ length: 6 }, (_, i) =>
      liveSess({ harness: "codex", id: `c${i}`, lastSeen: iso(i * MIN), status: "running" }),
    );
    const threads = buildThreads({ worktrees, gitByPath, prs: [], registry: null, sessions }, NOW);
    assert.equal(threads[0].sessions.length, 1);
    assert.equal(threads[0].sessions[0].id, "c0");
  });

  test("live Claude Code TUI in the main checkout -> its own claude:<id> row", () => {
    const sessions = [liveSess({ id: "tui", title: "tui-74", cwd: "/repo", branch: "main", status: "busy" })];
    const threads = buildThreads({ worktrees, gitByPath, prs: [], registry: null, sessions }, NOW);
    assert.deepEqual(threads.map((t) => t.id), ["claude:tui"]);
    assert.equal(threads[0].name, "tui-74");
    assert.equal(threads[0].state, "active");
    assert.equal(threads[0].worktreePath, null);
    assert.equal(threads[0].omnigentUrl, null);
    assert.deepEqual(threads[0].actions, []);
  });

  test("renderTable counts live vs dormant and mentions unavailable sources", () => {
    const threads = buildThreads({ worktrees, gitByPath, prs: [], registry: null, sessions: [liveSess()] }, NOW);
    const out = renderTable({ threads, dormant: threads.dormant, sources: { git: "ok", gh: "unavailable: boom" } });
    assert.match(out, /sources unavailable: gh/);
    assert.match(out, /1 live, 0 need you · 1 dormant/);
    assert.match(renderTable({ threads: [], dormant: [{}, {}], sources: {} }), /No live sessions\. 2 dormant threads/);
  });
});

// ---------------------------------------------------------------------------
describe("thread naming — never a hash", () => {
  const sess = (title, msAgo = 0) => ({ harness: "omnigent", id: title, title, status: "idle", lastSeen: iso(msAgo) });

  test("isAutoBranch: omnigent worktree-<hex> and session/<id> are auto-names, polly/x is not", () => {
    assert.ok(isAutoBranch("worktree-b1468d65"));
    assert.ok(isAutoBranch("session/wr50vl"));
    assert.ok(isAutoBranch("session-wr50vl"));
    assert.ok(!isAutoBranch("polly/navi-rename"));
    assert.ok(!isAutoBranch("worktree-base-unify"));
    assert.ok(!isAutoBranch(null));
  });

  test("PR title beats everything", () => {
    assert.equal(
      threadName({ pr: { title: "Rename the pet to Navi" }, branch: "polly/navi-rename", sessions: [sess("x")], dir: "/wt/navi-rename" }),
      "Rename the pet to Navi",
    );
  });

  test("meaningful branch beats session titles; main/master and auto-names do not", () => {
    assert.equal(threadName({ pr: null, branch: "polly/navi-rename", sessions: [sess("chat")], dir: "/wt/a" }), "polly/navi-rename");
    assert.equal(threadName({ pr: null, branch: "main", sessions: [sess("chat")], dir: "/repo" }), "chat");
    assert.equal(threadName({ pr: null, branch: "worktree-b1468d65", sessions: [sess("Fix the menu")], dir: "/wt/worktree-b1468d65" }), "Fix the menu");
  });

  test("newest session title wins; Claude's dir-basename titles and slash commands are skipped", () => {
    const sessions = [
      { harness: "claude", id: "c", title: "worktree-b1468d65", status: "idle", lastSeen: iso(0) },
      sess("/model claude-opus-5", 1 * MIN),
      sess("Tidy up the menu labels", 2 * MIN),
    ];
    assert.equal(pickSessionTitle(sessions), "Tidy up the menu labels");
  });

  test("a slash-command title is still better than the hash when it is all there is", () => {
    assert.equal(pickSessionTitle([sess("/model claude-opus-5")]), "/model claude-opus-5");
    assert.equal(threadName({ pr: null, branch: "worktree-ead5cf1b", sessions: [sess("/model claude-opus-5")], dir: "/wt/worktree-ead5cf1b" }), "/model claude-opus-5");
  });

  test("dir basename is the last resort", () => {
    assert.equal(threadName({ pr: null, branch: "worktree-ead5cf1b", sessions: [], dir: "/wt/fixtures-dir" }), "fixtures-dir");
    assert.equal(threadName({ pr: null, branch: null, sessions: [], dir: null }), "untitled");
  });

  test("buildThreads: id stays the branch while the name changes with the PR title", () => {
    const worktrees = [{ path: "/repo-wt/worktree-b1468d65", branch: "worktree-b1468d65" }];
    const gitByPath = { "/repo-wt/worktree-b1468d65": cleanGit() };
    const sessions = [liveSess({ cwd: "/repo-wt/worktree-b1468d65", title: "worktree-b1468d65" })];
    const before = buildThreads({ worktrees, gitByPath, prs: [], registry: null, sessions }, NOW)[0];
    const after = buildThreads(
      { worktrees, gitByPath, prs: [{ number: 1, headRefName: "worktree-b1468d65", state: "OPEN", url: "u", title: "Real title" }], registry: null, sessions },
      NOW,
    )[0];
    assert.equal(before.id, after.id);
    assert.equal(before.name, "worktree-b1468d65");
    assert.equal(after.name, "Real title");
  });
});

// ---------------------------------------------------------------------------
describe("claude code sessions — pid liveness, omnigent workers hidden", () => {
  function fakeHome(rows, states = []) {
    const home = mkdtempSync(join(tmpdir(), "bt-home-"));
    mkdirSync(join(home, ".claude", "sessions"), { recursive: true });
    mkdirSync(join(home, ".claude", "agent-state"), { recursive: true });
    rows.forEach((r, i) => writeFileSync(join(home, ".claude", "sessions", `${r.pid || 0}.${r.sessionId || i}.json`), JSON.stringify(r)));
    states.forEach((r, i) => writeFileSync(join(home, ".claude", "agent-state", `${r.session_id || i}.json`), JSON.stringify(r)));
    return home;
  }
  const procs = parseProcessTable(
    [
      "  100     1 /bin/zsh",
      "  200   100 claude --permission-mode auto",
      "  300     1 tmux -S /tmp/omnigent-terminal-abc/tmux.sock",
      "  310   300 zsh",
      "  320   310 claude --permission-mode auto",
      "  400     1 /opt/x/.local/share/uv/tools/omnigent/bin/python3 -m omnigent",
      "  410   400 bun run --cwd /wt",
      "  420   410 claude",
      "  500     1 codex",
      "  510   400 codex",
      "  520     1 node /usr/local/bin/codex app-server",
    ].join("\n"),
  );
  const base = { cwd: "/repo", kind: "interactive", entrypoint: "cli", status: "idle", updatedAt: NOW, name: "tui-74" };

  test("registry entry with a dead pid -> excluded (liveness probe mocked)", () => {
    const home = fakeHome([{ ...base, pid: 200, sessionId: "alive" }, { ...base, pid: 999, sessionId: "dead" }]);
    const alive = (pid) => pid === 200;
    const out = collectClaudeSessions(home, { procs, alive });
    assert.deepEqual(out.map((s) => s.id), ["alive"]);
    assert.equal(out[0].live, true);
    assert.equal(out[0].child, false);
  });

  test("Omnigent-launched Claude Code (tmux omnigent-terminal or sdk-py entrypoint) is not listed twice", () => {
    const home = fakeHome([
      { ...base, pid: 200, sessionId: "person" },
      { ...base, pid: 320, sessionId: "via-omnigent-tmux" },
      { ...base, pid: 420, sessionId: "sdk-worker", entrypoint: "sdk-py" },
    ]);
    const out = collectClaudeSessions(home, { procs, alive: () => true });
    assert.deepEqual(out.map((s) => s.id), ["person"]);
  });

  test("a channel listener (`claude --channels ...`, e.g. a chat bridge) registers as entrypoint cli but is never a row", () => {
    const withListener = parseProcessTable(
      [
        "  100     1 /bin/zsh",
        "  200   100 claude --permission-mode auto",
        "  600     1 claude --channels plugin:chat@example-plugins --dangerously-skip-permissions",
        "  610     1 claude --channels=plugin:chat@example-plugins",
        "  620   100 claude --resume --channels-help", // not the flag: must stay a row
      ].join("\n"),
    );
    assert.equal(isChannelListener(600, withListener), true);
    assert.equal(isChannelListener(610, withListener), true);
    assert.equal(isChannelListener(620, withListener), false);
    assert.equal(isChannelListener(200, withListener), false);
    assert.equal(isChannelListener(999, withListener), false);
    const home = fakeHome(
      [
        { ...base, pid: 200, sessionId: "person" },
        { ...base, pid: 600, sessionId: "channel-listener", name: "tui-57" },
        { ...base, pid: 620, sessionId: "odd-flag" },
      ],
      // the hook-state path is guarded too
      [{ session_id: "listener-hook", state: "running", cwd: "/repo", pid: 610, since: iso(0) }],
    );
    const out = collectClaudeSessions(home, { procs: withListener, alive: () => true });
    assert.deepEqual(out.map((s) => s.id).sort(), ["odd-flag", "person"]);
    const threads = buildThreads({ worktrees: [{ path: "/repo", branch: "main" }], gitByPath: {}, prs: [], registry: null, sessions: out }, NOW);
    assert.ok(!threads.some((t) => t.id === "claude:channel-listener"));
  });

  test("a Task sub-agent (parentSessionId / isSidechain / kind != interactive) is a child, never a row", () => {
    const home = fakeHome([
      { ...base, pid: 200, sessionId: "parent" },
      { ...base, pid: 200, sessionId: "kid1", parentSessionId: "parent" },
      { ...base, pid: 200, sessionId: "kid2", isSidechain: true },
      { ...base, pid: 200, sessionId: "kid3", kind: "subagent" },
    ]);
    const out = collectClaudeSessions(home, { procs, alive: () => true });
    assert.deepEqual(out.filter((s) => !s.child).map((s) => s.id), ["parent"]);
    assert.equal(out.filter((s) => s.child).length, 3);
    const threads = buildThreads({ worktrees: [{ path: "/repo", branch: "main" }], gitByPath: {}, prs: [], registry: null, sessions: out }, NOW);
    assert.deepEqual(threads.map((t) => t.id), ["claude:parent"]);
  });

  test("agent-state hook row with pid 0 / no pid is dead (fails closed), even under the real probe", () => {
    const home = fakeHome([], [{ session_id: "nopid", state: "blocked", cwd: "/repo", pid: 0, since: iso(0) }]);
    assert.equal(collectClaudeSessions(home, { procs }).length, 0);
  });

  test("agent-state hook rows: dead pid dropped, registry-known ids not duplicated, status merged in", () => {
    const home = fakeHome(
      [{ ...base, pid: 200, sessionId: "reg" }],
      [
        { session_id: "reg", state: "waiting", cwd: "/repo", pid: 200, since: iso(0), branch: "main" },
        { session_id: "hook-only-alive", state: "running", cwd: "/repo", pid: 200, since: iso(0) },
        { session_id: "hook-only-dead", state: "running", cwd: "/repo", pid: 999, since: iso(0) },
      ],
    );
    const out = collectClaudeSessions(home, { procs, alive: (pid) => pid === 200 });
    assert.deepEqual(out.map((s) => s.id).sort(), ["hook-only-alive", "reg"]);
    assert.equal(out.find((s) => s.id === "reg").status, "waiting");
    assert.equal(out.find((s) => s.id === "reg").branch, "main");
  });

  test("isOmnigentDescendant walks ancestors; codexLiveCwds skips app-server and omnigent children", () => {
    assert.equal(isOmnigentDescendant(320, procs), true);
    assert.equal(isOmnigentDescendant(420, procs), true);
    assert.equal(isOmnigentDescendant(200, procs), false);
    const cwds = codexLiveCwds(procs, (pid) => `/cwd-of-${pid}`);
    assert.deepEqual(cwds, ["/cwd-of-500"]);
  });
});

// ---------------------------------------------------------------------------
describe("codex threads — live only with a matching TUI process", () => {
  const rows = [
    { id: "new", cwd: "/repo", title: "newest", updated_at_ms: 5000 },
    { id: "old", cwd: "/repo", title: "older", updated_at_ms: 4000 },
    { id: "else", cwd: "/other", title: "elsewhere", updated_at_ms: 6000 },
  ];

  test("no codex process -> every thread dead", () => {
    const s = mapCodexThreads(rows, { liveCwds: [] });
    assert.ok(s.every((r) => r.live === false && r.status === "unknown"));
  });

  test("one TUI in /repo -> only the newest /repo thread is live and reads as running", () => {
    const s = mapCodexThreads(rows, { liveCwds: ["/repo"] });
    const byId = Object.fromEntries(s.map((r) => [r.id, r]));
    assert.equal(byId.new.live, true);
    assert.equal(byId.new.status, "running");
    assert.equal(byId.old.live, false);
    assert.equal(byId.else.live, false);
  });

  test("a live codex thread outside any worktree gets its own codex:<id> row", () => {
    const s = mapCodexThreads(rows, { liveCwds: ["/other"] });
    const threads = buildThreads({ worktrees: [{ path: "/repo", branch: "main" }], gitByPath: {}, prs: [], registry: null, sessions: s }, NOW);
    assert.deepEqual(threads.map((t) => t.id), ["codex:else"]);
    assert.equal(threads[0].name, "elsewhere");
  });
});

// ---------------------------------------------------------------------------
describe("omnigent sessions — fixture-driven", () => {
  const fixture = JSON.parse(readFileSync(join(HERE, "fixtures", "omnigent-sessions.json"), "utf8"));
  // The fixture stores offsets so the tests never rot; turn them into epoch seconds.
  const pages = fixture.pages.map((p) => ({
    ...p,
    data: p.data.map(({ updated_at_offset_s, ...r }) => ({ ...r, updated_at: Math.floor(NOW / 1000) - updated_at_offset_s })),
  }));
  const ID = (n) => `aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa0${n}`;

  // Serves /v1/runners, page 1 bare, page 2 for ?after=<page1.last_id>; records every URL.
  function fakeFetch({ runnersDown = false } = {}) {
    const calls = [];
    const fj = async (url) => {
      calls.push(url);
      if (url.endsWith("/v1/runners")) {
        if (runnersDown) throw new Error("ECONNREFUSED");
        return fixture.runners;
      }
      const after = new URL(url).searchParams.get("after");
      if (!after) return pages[0];
      if (after === pages[0].last_id) return pages[1];
      throw new Error("unexpected cursor " + after);
    };
    return { fj, calls };
  }

  async function sessionsFromFixture(opts) {
    const { fj } = fakeFetch(opts);
    const out = await collectOmnigent("http://127.0.0.1:6767/v1/sessions", { fetchJson: fj });
    // collect() fills in the checkout branch for plain-checkout sessions.
    for (const s of out) if (!s.branch && s.cwd === "/repo") s.branch = "main";
    return out;
  }

  const worktrees = [
    { path: "/repo", branch: "main" },
    { path: "/repo-worktrees/worktree-b1468d65", branch: "worktree-b1468d65" },
  ];
  const gitByPath = { "/repo": cleanGit(), "/repo-worktrees/worktree-b1468d65": cleanGit({ hasUpstream: false, ahead: 0 }) };
  const build = async (opts) =>
    buildThreads({ worktrees, gitByPath, prs: [], registry: null, sessions: await sessionsFromFixture(opts) }, NOW);

  test("paged response: runners fetched once, both pages collected, cursor is ?after=<last_id>, archived dropped", async () => {
    const { fj, calls } = fakeFetch();
    const { sessions: out, runners } = await collectOmnigentFull("http://127.0.0.1:6767/v1/sessions", { fetchJson: fj });
    assert.equal(runners, "ok");
    assert.equal(calls.length, 3);
    assert.ok(calls[0].endsWith("/v1/runners"));
    assert.equal(new URL(calls[1]).searchParams.get("limit"), String(OMNIGENT_PAGE_LIMIT));
    assert.equal(new URL(calls[1]).searchParams.get("after"), null);
    assert.equal(new URL(calls[2]).searchParams.get("after"), pages[0].last_id);
    assert.deepEqual(out.map((s) => s.id), [ID(1), ID(2), ID(4), ID(5), ID(6), ID(7), ID(8), ID(9)]);
    assert.ok(!out.some((s) => s.id === ID(3)), "archived row never leaves the mapper");
  });

  test("liveness: runner_online on the row wins; else the /v1/runners set; else only status=running", () => {
    const on = parseRunners(fixture.runners);
    assert.deepEqual([...on], ["runner_token_fake_online_1"]);
    const byId = (rows, o) => Object.fromEntries(mapOmnigentSessions(rows, o).map((r) => [r.id, r]));
    const withRow = byId(pages[0].data.concat(pages[1].data));
    assert.equal(withRow[ID(1)].live, true);
    assert.equal(withRow[ID(2)].live, false, "status running + runner_online false = dead");
    assert.equal(withRow[ID(9)].live, false, "no runner_online field, no runner set -> idle is dead");
    const withSet = byId(pages[1].data, { onlineRunners: on });
    assert.equal(withSet[ID(9)].live, true, "runner set says its runner is online");
  });

  test("mapper carries parent / child / pending / unread / error signals", () => {
    const s = mapOmnigentSessions(pages[1].data.concat(pages[0].data));
    const byId = Object.fromEntries(s.map((r) => [r.id, r]));
    assert.equal(byId[ID(4)].parentId, ID(1));
    assert.equal(byId[ID(4)].child, true);
    assert.equal(byId[ID(4)].agent, "explorer");
    assert.equal(byId[ID(1)].child, false);
    assert.equal(byId[ID(6)].errorCode, "runner_disconnected");
    assert.equal(byId[ID(6)].errorTitle, "Runner disconnected unexpectedly.");
    assert.equal(byId[ID(7)].pendingInputs, 1);
    assert.equal(byId[ID(8)].unread, true);
    assert.equal(byId[ID(1)].errorCode, null);
  });

  test("running session on main with its runner online -> its own row, named by title, state active", async () => {
    const threads = await build();
    const row = threads.find((t) => t.id === `omnigent:${ID(1)}`);
    assert.ok(row, "row exists");
    assert.equal(row.name, "Refactor the config loader");
    assert.equal(row.branch, "main");
    assert.equal(row.state, "active");
    assert.equal(row.stateLabel, STATE_LABELS.active);
    assert.match(row.detail, /polly mid-turn/);
    assert.equal(row.worktreePath, null);
    assert.equal(row.git, null);
    assert.equal(row.pr, null);
    assert.equal(row.omnigentUrl, omnigentSessionUrl(ID(1)));
    assert.equal(row.omnigentUrl, `http://127.0.0.1:6767/c/${ID(1)}`);
    assert.equal(row.omnigentDeepLink, `omnigent://localhost:6767/c/${ID(1)}`);
    // the desktop deep link leads; the browser url stays for the context menu / prefs toggle
    assert.deepEqual(row.actions.map((a) => a.command), [`open "${row.omnigentDeepLink}"`, `open "${row.omnigentUrl}"`]);
    assert.deepEqual(row.actions.map((a) => a.label), ["Open chat in Omnigent", "Open chat in browser"]);
    assert.equal(row.idle, false, "a running row is never idle");
    assert.equal(typeof row.lastSeen, "string");
  });

  test("idle chat rows carry idle:true once activity is older than ACTIVE_SESSION_MINUTES, and sort after active", async () => {
    const threads = await build();
    const old = threads.find((t) => t.id === `omnigent:${ID(9)}`); // idle, 3 days old
    assert.equal(old.state, "idle");
    assert.equal(old.idle, true);
    assert.equal(Date.parse(old.lastSeen) > 0, true);
    const idleIdx = threads.findIndex((t) => t.idle);
    const lastActiveIdx = threads.map((t) => t.state === "active").lastIndexOf(true);
    assert.ok(idleIdx === -1 || idleIdx > lastActiveIdx, "idle rows come after active rows");
  });

  test("omnigentDeepLink: host/port come from the base url, 127.0.0.1 becomes localhost", () => {
    assert.equal(omnigentDeepLink("abc"), "omnigent://localhost:6767/c/abc");
    assert.equal(omnigentDeepLink("abc", "http://127.0.0.1:6767"), "omnigent://localhost:6767/c/abc");
    assert.equal(omnigentDeepLink("abc", "http://omni.tail.net:9000"), "omnigent://omni.tail.net:9000/c/abc");
    assert.equal(omnigentDeepLink("abc", "http://example.com"), "omnigent://example.com:80/c/abc");
    assert.equal(omnigentDeepLink(null), null);
  });

  test("liveness: idle only when state is idle AND newest activity is past the window", () => {
    const now = Date.parse("2026-09-17T12:00:00Z");
    const recent = { lastSeen: new Date(now - 2 * 60_000).toISOString() };
    const stale = { lastSeen: new Date(now - 30 * 60_000).toISOString() };
    assert.deepEqual(liveness([recent], "idle", now), { lastSeen: recent.lastSeen, idle: false });
    assert.deepEqual(liveness([stale], "idle", now), { lastSeen: stale.lastSeen, idle: true });
    assert.deepEqual(liveness([stale, recent], "idle", now), { lastSeen: recent.lastSeen, idle: false });
    assert.equal(liveness([stale], "active", now).idle, false, "an active row is never idle");
    assert.equal(liveness([stale], "needs-input", now).idle, false, "a question waiting on you is not idle");
    assert.deepEqual(liveness([], "idle", now), { lastSeen: null, idle: true });
    const edge = { lastSeen: new Date(now - THRESHOLDS.ACTIVE_SESSION_MINUTES * 60_000).toISOString() };
    assert.equal(liveness([edge], "idle", now).idle, false, "exactly the window is still fresh");
  });

  test("status running but runner_online false -> excluded (dead harness)", async () => {
    const threads = await build();
    assert.ok(!threads.some((t) => t.id === `omnigent:${ID(2)}`));
  });

  test("runner_online true (via /v1/runners) but status idle, 3 days old -> included as idle; recency is not a filter", async () => {
    const threads = await build();
    const row = threads.find((t) => t.id === `omnigent:${ID(9)}`);
    assert.ok(row, "row exists");
    assert.equal(row.state, "idle");
    assert.equal(row.stateLabel, CHAT_IDLE_LABEL);
    assert.match(row.detail, /idle, last activity 3d ago/);
  });

  test("archived -> excluded even with an online runner", async () => {
    const threads = await build();
    assert.ok(!threads.some((t) => t.id === `omnigent:${ID(3)}`));
  });

  test("child with a parent -> excluded as a row; rolls up under the parent's sessions", async () => {
    const threads = await build();
    assert.ok(!threads.some((t) => t.id === `omnigent:${ID(4)}`));
    const parent = threads.find((t) => t.id === `omnigent:${ID(1)}`);
    assert.deepEqual(parent.sessions.map((s) => s.id).sort(), [ID(1), ID(4)]);
    assert.equal(parent.sessions.find((s) => s.id === ID(4)).title, "explore the fixtures dir");
  });

  test("live session in a worktree-<hex> dir attaches to that worktree row, which takes the session's title", async () => {
    const threads = await build();
    assert.ok(!threads.some((t) => t.id === `omnigent:${ID(5)}`));
    const wt = threads.find((t) => t.id === "worktree-b1468d65");
    assert.ok(wt, "worktree row exists");
    assert.equal(wt.name, "Tidy up the menu labels");
    assert.equal(wt.worktreePath, "/repo-worktrees/worktree-b1468d65");
    assert.deepEqual(wt.sessions.map((s) => s.id), [ID(5)]);
    assert.equal(wt.omnigentUrl, omnigentSessionUrl(ID(5)));
  });

  test("last_task_error_code set -> blocked, reason = last_task_error_title", async () => {
    const threads = await build();
    const row = threads.find((t) => t.id === `omnigent:${ID(6)}`);
    assert.equal(row.state, "blocked");
    assert.equal(row.stateLabel, STATE_LABELS.blocked);
    assert.equal(row.reason, "Runner disconnected unexpectedly.");
    assert.equal(row.detail, "Runner disconnected unexpectedly.");
    assert.equal(row.name, "Profile the slow import");
  });

  test("pending elicitation or unread reply -> needs-input", async () => {
    const threads = await build();
    const asking = threads.find((t) => t.id === `omnigent:${ID(7)}`);
    assert.equal(asking.state, "needs-input");
    assert.match(asking.detail, /asked a question/);
    const unread = threads.find((t) => t.id === `omnigent:${ID(8)}`);
    assert.equal(unread.state, "needs-input");
    assert.match(unread.detail, /unread reply/);
  });

  test("whole fixture -> exactly the live parents, sorted needs-input > blocked > active > idle; no cwd leaks", async () => {
    const threads = await build();
    assert.deepEqual(
      threads.map((t) => t.id),
      [`omnigent:${ID(7)}`, `omnigent:${ID(8)}`, `omnigent:${ID(6)}`, `omnigent:${ID(1)}`, "worktree-b1468d65", `omnigent:${ID(9)}`],
    );
    for (const t of threads) for (const s of t.sessions) assert.ok(!("cwd" in s) && !("parentId" in s) && !("live" in s));
    assert.equal(threads.dormant.length, 0);
  });

  test("renderTable counts needs-input and blocked as 'need you'", async () => {
    const threads = await build();
    const out = renderTable({ threads, dormant: [], sources: { omnigent: "ok" } });
    assert.match(out, /6 live, 3 need you/);
  });

  test("/v1/runners down -> degraded: only status=running rows are live, and the source says so", async () => {
    const { fj } = fakeFetch({ runnersDown: true });
    const { sessions, runners } = await collectOmnigentFull("http://127.0.0.1:6767/v1/sessions", { fetchJson: fj });
    assert.match(runners, /unavailable/);
    const byId = Object.fromEntries(sessions.map((r) => [r.id, r]));
    assert.equal(byId[ID(1)].live, true, "row says runner_online: true");
    assert.equal(byId[ID(9)].live, false, "no runner_online field, no set -> idle is dead");
  });

  test("pagination stops on has_more=false and dedupes when the server repeats last_id", async () => {
    const fj = async (url) =>
      url.endsWith("/v1/runners") ? fixture.runners : { data: pages[0].data, has_more: true, last_id: pages[0].last_id };
    const out = await collectOmnigent("http://127.0.0.1:6767/v1/sessions", { fetchJson: fj });
    assert.equal(out.length, 4);
  });
});

describe("deriveLiveState — precedence", () => {
  const s = (over) => ({ harness: "omnigent", id: "s", title: "t", status: "idle", lastSeen: iso(0), agent: "polly", live: true, ...over });
  const st = (sessions, extra = {}) => deriveLiveState({ sessions, ...extra }, NOW).state;

  test("needs-input > blocked > active > idle", () => {
    assert.equal(st([s({ status: "running", pendingInputs: 1 })]), "needs-input");
    assert.equal(st([s({ status: "running", unread: true, errorCode: "x" })]), "needs-input");
    assert.equal(st([s({ status: "running", errorCode: "x", errorTitle: "boom" })]), "blocked");
    assert.equal(st([s({ status: "failed" })]), "blocked");
    assert.equal(st([s({ status: "running" })]), "active");
    assert.equal(st([s({ harness: "claude", status: "busy" })]), "active");
    assert.equal(st([s({ status: "idle" })]), "idle");
    assert.equal(st([]), "idle");
  });

  test("Claude Code hook 'blocked' (needs permission) is a question for you", () => {
    assert.equal(st([s({ harness: "claude", status: "blocked" })]), "needs-input");
  });

  test("PR reviewed-and-ready is needs-input; PR merely open is not", () => {
    const pr = { number: 9, state: "OPEN" };
    assert.equal(st([s({ status: "running" })], { pr, registryStatus: "ready-for-human-merge" }), "needs-input");
    assert.equal(st([s({ status: "running" })], { pr, registryStatus: "fix-round-2" }), "active");
  });

  test("a running sub-agent makes the parent row active", () => {
    const r = deriveLiveState({ sessions: [s({ id: "p", status: "idle" }), s({ id: "c", status: "running", agent: "explorer" })] }, NOW);
    assert.equal(r.state, "active");
    assert.match(r.detail, /explorer/);
  });

  test("deriveOmnigentState is the same machine", () => {
    assert.equal(deriveOmnigentState([s({ status: "failed" })], NOW).state, "blocked");
  });
});


// ---------------------------------------------------------------------------
describe("notifier diff", () => {
  const th = (id, state, extra = {}) => ({
    id,
    name: id,
    state,
    stateLabel: STATE_LABELS[state],
    detail: "",
    reviewReady: false,
    pr: null,
    ...extra,
  });

  test("no previous record -> only non-quiet threads reported", () => {
    const ch = diffStates(null, [th("a", "idle"), th("b", "active"), th("c", "uncommitted")]);
    assert.deepEqual(ch.map((c) => c.id), ["c"]);
  });

  test("unchanged -> nothing", () => {
    const ch = diffStates({ a: "uncommitted" }, [th("a", "uncommitted")]);
    assert.equal(ch.length, 0);
  });

  test("active <-> idle flapping never notifies", () => {
    assert.equal(diffStates({ a: "active" }, [th("a", "idle")]).length, 0);
    assert.equal(diffStates({ a: "idle" }, [th("a", "active")]).length, 0);
  });

  test("idle -> uncommitted notifies (mac only, not needs-you)", () => {
    const ch = diffStates({ a: "idle" }, [th("a", "uncommitted")]);
    assert.equal(ch.length, 1);
    assert.equal(ch[0].needsYou, false);
    assert.match(ch[0].line, /a: Work on your Mac only/);
  });

  test("a chat row entering blocked or needs-input pings the Mac but does not run the hook", () => {
    const ch = diffStates(null, [th("omnigent:1", "blocked", { detail: "Runner disconnected" }), th("omnigent:2", "needs-input")]);
    assert.deepEqual(ch.map((c) => c.id), ["omnigent:1", "omnigent:2"]);
    assert.ok(ch.every((c) => c.needsYou === false));
    assert.match(ch[0].line, /Agent hit an error — Runner disconnected/);
  });

  test("a row vanishing (harness quit) is silent, and its id is forgotten", () => {
    assert.equal(diffStates({ "omnigent:gone": "blocked", "claude:x": "needs-input" }, []).length, 0);
    assert.deepEqual(nextNotifiedMap([]), {});
  });

  test("live row: PR reviewed and waiting on the merge is needs-you; plain needs-input is not", () => {
    const ready = th("wt", "needs-input", { reviewReady: true, pr: { number: 9 } });
    assert.equal(stateKey(ready), "needs-input:pr-ready");
    const ch = diffStates({ wt: "active", ask: "active" }, [ready, th("ask", "needs-input")]);
    assert.deepEqual(ch.map((c) => [c.id, c.needsYou]), [["wt", true], ["ask", false]]);
  });

  test("entering stale is needs-you", () => {
    const ch = diffStates({ a: "pr-open:unreviewed" }, [th("a", "stale", { detail: "47 commits behind main" })]);
    assert.equal(ch[0].needsYou, true);
    assert.match(ch[0].line, /Behind main.*47 commits/);
  });

  test("pr-open unreviewed -> ready is a change and needs-you", () => {
    const ready = th("a", "pr-open", {
      reviewReady: true,
      stateLabel: STATE_LABELS["pr-open-ready"],
      pr: { number: 9 },
    });
    const ch = diffStates({ a: "pr-open:unreviewed" }, [ready]);
    assert.equal(ch.length, 1);
    assert.equal(ch[0].to, "pr-open:ready");
    assert.equal(ch[0].needsYou, true);
    assert.match(ch[0].line, /\(PR #9\): PR waiting on you/);
  });

  test("pr-open unreviewed (fresh) is a mac ping but does NOT run the hook", () => {
    const ch = diffStates({ a: "unpushed" }, [th("a", "pr-open", { pr: { number: 9 } })]);
    assert.equal(ch.length, 1);
    assert.equal(ch[0].needsYou, false);
  });

  test("deliver: every change hits mac notify; only needs-you hits the notify hook", () => {
    const macCalls = [];
    const hookCalls = [];
    const changes = diffStates({ a: "idle", b: "idle" }, [
      th("a", "stale"),
      th("b", "uncommitted"),
    ]);
    deliver(changes, { notify: (t, b) => macCalls.push(b), hook: (l) => hookCalls.push(l) });
    assert.equal(macCalls.length, 2);
    assert.equal(hookCalls.length, 1);
    assert.match(hookCalls[0], /^a: Behind main/);
  });

  test("nextNotifiedMap records the pr-open substate", () => {
    const m = nextNotifiedMap([th("a", "pr-open", { reviewReady: true }), th("b", "idle")]);
    assert.deepEqual(m, { a: "pr-open:ready", b: "idle" });
  });

  test("run(): first run records a baseline silently, second run delivers only changes", () => {
    const dir = mkdtempSync(join(tmpdir(), "bt-"));
    const snap = join(dir, "threads.json");
    const notified = join(dir, "notified.json");
    const macCalls = [];
    const hookCalls = [];
    const delivery = { notify: (t, b) => macCalls.push(b), hook: (l) => hookCalls.push(l) };

    writeFileSync(snap, JSON.stringify({ threads: [th("a", "uncommitted"), th("b", "idle")] }));
    let res = notifyRun({ snapshotFile: snap, notifiedFile: notified, delivery });
    assert.equal(res.reason, "baseline recorded");
    assert.equal(macCalls.length, 0);
    assert.ok(existsSync(notified));

    writeFileSync(snap, JSON.stringify({ threads: [th("a", "stale"), th("b", "active")] }));
    res = notifyRun({ snapshotFile: snap, notifiedFile: notified, delivery });
    assert.equal(res.changes.length, 1); // b idle->active is quiet
    assert.equal(macCalls.length, 1);
    assert.equal(hookCalls.length, 1);
    assert.deepEqual(JSON.parse(readFileSync(notified, "utf8")), { a: "stale", b: "active" });

    // Same snapshot again -> idempotent.
    res = notifyRun({ snapshotFile: snap, notifiedFile: notified, delivery });
    assert.equal(res.changes.length, 0);
    assert.equal(macCalls.length, 1);
  });
});

describe("no NAVI_REPO", () => {
  test("collectGitSources(null) -> empty git bundle, sessions still get rows", () => {
    const g = collectGitSources(null);
    assert.equal(g.mainWorktree, null);
    assert.deepEqual(g.worktrees, []);
    assert.match(g.sources.git, /not configured/);
    const s = { harness: "claude", id: "t1", title: "tui", status: "busy", lastSeen: new Date(NOW).toISOString(), cwd: "/elsewhere", branch: null, live: true, child: false };
    const threads = buildThreads({ worktrees: g.worktrees, gitByPath: g.gitByPath, prs: g.prs, registry: g.registry, sessions: [s] }, NOW);
    assert.deepEqual(threads.map((t) => t.id), ["claude:t1"]);
    assert.equal(threads[0].state, "active");
  });
});
