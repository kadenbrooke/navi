// node --test collector/*.test.mjs
//
// Daemon tests: every socket, stream, fetch and fork is a fake handed to
// createDaemon. Nothing here touches the live Omnigent server, git, or gh.

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, readdirSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  createDaemon,
  makeCoalescer,
  nextBackoff,
  parseSseChunk,
  wantsParentStream,
} from "./collect-daemon.mjs";
import {
  applyParentStatus,
  buildThreads,
  collect,
  deriveLiveState,
  normalizeOmnigentStatus,
  writeSnapshot,
} from "./collect.mjs";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const until = async (pred, { timeout = 3000, step = 10 } = {}) => {
  const t0 = Date.now();
  while (!pred()) {
    if (Date.now() - t0 > timeout) throw new Error("timed out waiting");
    await sleep(step);
  }
};

const NOW = Date.now();
const secs = (msAgo) => Math.floor((NOW - msAgo) / 1000);

// ---------------------------------------------------------------------------
// Pure pieces
// ---------------------------------------------------------------------------
describe("coalescer", () => {
  test("a burst of schedules runs the job once, with every reason", async () => {
    const runs = [];
    const c = makeCoalescer(async (why) => runs.push(why), { delayMs: 20 });
    c.schedule("a");
    c.schedule("b");
    c.schedule("a");
    await sleep(60);
    assert.equal(runs.length, 1);
    assert.deepEqual(runs[0].sort(), ["a", "b"]);
  });

  test("a schedule during a run queues exactly one more run", async () => {
    const runs = [];
    let release;
    const c = makeCoalescer(
      async (why) => {
        runs.push(why);
        if (runs.length === 1) await new Promise((r) => (release = r));
      },
      { delayMs: 5 },
    );
    c.schedule("first");
    await sleep(20);
    assert.equal(runs.length, 1);
    c.schedule("x");
    c.schedule("y");
    c.schedule("z");
    release();
    await sleep(30);
    assert.equal(runs.length, 2);
    assert.deepEqual(runs[1].sort(), ["x", "y", "z"]);
  });

  test("flush during a run resolves only after the follow-up run carried its reason", async () => {
    const runs = [];
    let release;
    const c = makeCoalescer(
      async (why) => {
        runs.push(why);
        if (runs.length === 1) await new Promise((r) => (release = r));
      },
      { delayMs: 5 },
    );
    c.schedule("first");
    await sleep(20);
    const flushed = c.flush("tick");
    let done = false;
    flushed.then(() => (done = true));
    await sleep(20);
    assert.equal(done, false, "still waiting on the in-flight run");
    release();
    await flushed;
    assert.equal(runs.length, 2);
    assert.deepEqual(runs[1], ["tick"]);
  });

  test("flush runs now and cancels the pending debounce", async () => {
    const runs = [];
    const c = makeCoalescer(async (why) => runs.push(why), { delayMs: 500 });
    c.schedule("slow");
    await c.flush("tick");
    assert.equal(runs.length, 1);
    assert.deepEqual(runs[0].sort(), ["slow", "tick"]);
    await sleep(20);
    assert.equal(runs.length, 1, "the debounced run was folded into the flush");
  });
});

test("backoff doubles from min and caps at max", () => {
  const o = { min: 100, max: 1000 };
  const seq = [];
  let b = 0;
  for (let i = 0; i < 6; i++) seq.push((b = nextBackoff(b, o)));
  assert.deepEqual(seq, [100, 200, 400, 800, 1000, 1000]);
});

test("parseSseChunk handles split frames, event lines and [DONE]", () => {
  let r = parseSseChunk('event: session.status\ndata: {"type":"session.status","status":"idle"}\n\nevent: x\ndata: {"a"');
  assert.equal(r.events.length, 1);
  assert.equal(r.events[0].event, "session.status");
  assert.equal(r.events[0].json.status, "idle");
  assert.equal(r.rest, 'event: x\ndata: {"a"');
  r = parseSseChunk(r.rest + ':1}\n\n: comment\ndata: [DONE]\n\n');
  assert.equal(r.events.length, 2);
  assert.equal(r.events[0].event, "x");
  assert.deepEqual(r.events[0].json, { a: 1 });
  assert.equal(r.events[1].done, true);
  assert.equal(r.rest, "");
  // type falls back to the JSON's own `type`
  r = parseSseChunk('data: {"type":"session.heartbeat"}\n\n');
  assert.equal(r.events[0].event, "session.heartbeat");
});

test("wantsParentStream: running, live, un-archived parents only", () => {
  assert.equal(wantsParentStream({ id: "p", status: "running", runner_online: true }), true);
  assert.equal(wantsParentStream({ id: "p", status: "running" }), true, "runner_online unknown -> still wanted");
  assert.equal(wantsParentStream({ id: "p", status: "idle", runner_online: true }), false);
  assert.equal(wantsParentStream({ id: "c", status: "running", parent_session_id: "p" }), false);
  assert.equal(wantsParentStream({ id: "p", status: "running", runner_online: false }), false);
  assert.equal(wantsParentStream({ id: "p", status: "running", archived: true }), false);
  assert.equal(wantsParentStream(null), false);
});

// ---------------------------------------------------------------------------
// Parent-vs-child status mapping (collect.mjs)
// ---------------------------------------------------------------------------
describe("parent-only status", () => {
  const om = (over) => ({
    harness: "omnigent",
    id: "p1",
    title: "assistant chat",
    status: "running",
    listStatus: "running",
    lastSeen: new Date(NOW).toISOString(),
    cwd: "/repo",
    branch: "main",
    live: true,
    child: false,
    parentId: null,
    pendingInputs: 0,
    ...over,
  });

  test("normalizeOmnigentStatus folds waiting into running", () => {
    assert.equal(normalizeOmnigentStatus("waiting"), "running");
    assert.equal(normalizeOmnigentStatus("Idle"), "idle");
    assert.equal(normalizeOmnigentStatus(undefined), "unknown");
  });

  test("list running + parent idle -> idle with childActive", () => {
    const [s] = applyParentStatus([om()], new Map([["p1", "idle"]]));
    assert.equal(s.status, "idle");
    assert.equal(s.childActive, true);
  });

  test("list running + parent running -> running, no childActive", () => {
    const [s] = applyParentStatus([om()], new Map([["p1", "running"]]));
    assert.equal(s.status, "running");
    assert.equal(s.childActive, false);
  });

  test("a non-running roll-up is authoritative: a stale 'running' overlay cannot revive it", () => {
    const [s] = applyParentStatus([om({ status: "idle", listStatus: "idle" })], new Map([["p1", "running"]]));
    assert.equal(s.status, "idle");
    assert.equal(s.childActive, undefined);
  });

  test("child rows and other harnesses are never overlaid", () => {
    const rows = [om({ id: "c1", child: true, parentId: "p1" }), { ...om({ id: "cl" }), harness: "claude" }];
    applyParentStatus(rows, new Map([["c1", "idle"], ["cl", "idle"]]));
    assert.equal(rows[0].status, "running");
    assert.equal(rows[1].status, "running");
  });

  test("deriveLiveState: a running sub-agent never makes the row active", () => {
    const parent = om({ status: "idle", listStatus: "idle" });
    const child = om({ id: "c1", child: true, parentId: "p1", status: "running", agent: "explorer" });
    const d = deriveLiveState({ sessions: [parent, child] }, NOW);
    assert.equal(d.state, "idle");
    assert.match(d.detail, /sub-agents still running/);
  });

  test("deriveLiveState: childActive parent reads idle and says why", () => {
    const [parent] = applyParentStatus([om()], new Map([["p1", "idle"]]));
    const d = deriveLiveState({ sessions: [parent] }, NOW);
    assert.equal(d.state, "idle");
    assert.match(d.detail, /sub-agents still running/);
  });

  test("deriveLiveState: the parent mid-turn is active", () => {
    const d = deriveLiveState({ sessions: [om()] }, NOW);
    assert.equal(d.state, "active");
  });

  test("a child asking a question still surfaces as needs-input", () => {
    const parent = om({ status: "idle", listStatus: "idle" });
    const child = om({ id: "c1", child: true, parentId: "p1", status: "running", pendingInputs: 1 });
    assert.equal(deriveLiveState({ sessions: [parent, child] }, NOW).state, "needs-input");
  });

  test("buildThreads publishes child on each session so Navi can tell them apart", () => {
    const parent = om({ status: "idle", listStatus: "idle" });
    const child = om({ id: "c1", child: true, parentId: "p1", status: "running" });
    const threads = buildThreads({ worktrees: [], gitByPath: {}, prs: [], registry: null, sessions: [parent, child] }, NOW);
    assert.equal(threads.length, 1);
    assert.equal(threads[0].state, "idle");
    const byId = Object.fromEntries(threads[0].sessions.map((s) => [s.id, s]));
    assert.equal(byId.p1.child, false);
    assert.equal(byId.c1.child, true);
  });
});

// ---------------------------------------------------------------------------
// Atomic write
// ---------------------------------------------------------------------------
test("writeSnapshot leaves no temp file and the old snapshot as .prev", () => {
  const dir = mkdtempSync(join(tmpdir(), "bt-write-"));
  const out = join(dir, "threads.json");
  const prev = join(dir, "threads.prev.json");
  writeSnapshot({ generatedAt: "a", threads: [] }, { outFile: out, prevFile: prev });
  writeSnapshot({ generatedAt: "b", threads: [{ id: "x" }] }, { outFile: out, prevFile: prev });
  assert.deepEqual(readdirSync(dir).sort(), ["threads.json", "threads.prev.json"]);
  assert.equal(JSON.parse(readFileSync(out, "utf8")).generatedAt, "b");
  assert.equal(JSON.parse(readFileSync(prev, "utf8")).generatedAt, "a");
  assert.equal(existsSync(`${out}.tmp`), false);
});

// ---------------------------------------------------------------------------
// The daemon with fake WS / SSE / REST
// ---------------------------------------------------------------------------
function listItem(over) {
  return {
    id: "p1",
    agent_id: "ag",
    agent_name: "assistant",
    status: "running",
    created_at: secs(600_000),
    updated_at: secs(1000),
    title: "ship the thing",
    labels: {},
    runner_id: "r1",
    runner_online: true,
    pending_elicitations_count: 0,
    workspace: "/home/me/repo",
    git_branch: "main",
    archived: false,
    viewer_unread: false,
    parent_session_id: null,
    ...over,
  };
}

class FakeSocket {
  constructor(url) {
    this.url = url;
    this.sent = [];
    this.closed = false;
  }
  send(s) {
    this.sent.push(JSON.parse(s));
  }
  close() {
    this.closed = true;
    this.onclose?.({ code: 1000, reason: "test close" });
  }
}

function harness({ list = [listItem()], detail = {}, debounceMs = 20, graceMs = 60, ...over } = {}) {
  const home = mkdtempSync(join(tmpdir(), "bt-home-"));
  mkdirSync(join(home, ".claude", "sessions"), { recursive: true });
  mkdirSync(join(home, ".claude", "agent-state"), { recursive: true });
  const repo = mkdtempSync(join(tmpdir(), "bt-repo-"));
  const sockets = [];
  const streams = new Map(); // id -> { url, onEvent, onClose, closed }
  const streamHistory = [];
  const snapshots = [];
  const state = { list, detail, listCalls: 0, detailCalls: 0 };
  const d = createDaemon({
    repo,
    home,
    outFile: join(home, "threads.json"),
    debounceMs,
    graceMs,
    backoff: { min: 10, max: 40 },
    usage: false,
    watchFs: over.watchFs ?? false,
    log: () => {},
    fetchJson: async (url) => {
      if (url.includes("/v1/runners")) return { data: [{ runner_id: "r1", online: true }] };
      if (/\/v1\/sessions\/[^/?]+\?/.test(url)) {
        state.detailCalls++;
        const id = url.split("/v1/sessions/")[1].split("?")[0];
        if (!(id in state.detail)) throw new Error("no detail");
        return { id, status: state.detail[id] };
      }
      if (url.includes("/v1/sessions")) {
        state.listCalls++;
        return { object: "list", data: state.list, has_more: false, last_id: state.list.at(-1)?.id ?? null };
      }
      throw new Error(`unexpected fetch ${url}`);
    },
    wsFactory: (url) => {
      const s = new FakeSocket(url);
      sockets.push(s);
      return s;
    },
    openSse: (url, { onEvent, onClose }) => {
      const id = url.split("/v1/sessions/")[1].split("/")[0];
      const entry = { url, onEvent, onClose, closed: false };
      streams.set(id, entry);
      streamHistory.push(entry);
      return {
        close() {
          entry.closed = true;
          streams.delete(id);
          onClose?.("test close");
        },
      };
    },
    gitFn: () => ({
      mainWorktree: repo,
      worktrees: [{ path: repo, branch: "main", head: "x" }],
      gitByPath: {},
      prs: [],
      registry: null,
      sources: { git: "ok", gh: "ok", registry: "ok" },
      branchForCwd: () => null,
      collectedAt: Date.now(),
    }),
    procsFn: () => new Map(),
    codexFn: async () => [],
    writeFn: (snap) => snapshots.push(snap),
    notifyFn: () => {},
    ...over,
  });
  const openSocket = () => {
    const s = sockets.at(-1);
    s.onopen?.();
    return s;
  };
  return { d, home, repo, sockets, streams, streamHistory, snapshots, state, openSocket };
}

const omnigentRows = (snap) => (snap?.threads || []).filter((t) => t.id.startsWith("omnigent:"));

describe("daemon", () => {
  test("Omnigent parent: own status wins over the list roll-up, SSE edges flip the row", async () => {
    const h = harness({ detail: { p1: "idle" } });
    await h.d.start();
    const sock = h.openSocket();
    await until(() => sock.sent.length >= 1 && h.streams.has("p1"));
    assert.deepEqual(sock.sent[0], { type: "watch", session_ids: ["p1"] });

    // baseline from the detail endpoint: parent idle while the list says running
    await until(() => h.d.parentStatus.get("p1")?.status === "idle");
    await until(() => omnigentRows(h.snapshots.at(-1))[0]?.state === "idle");
    let row = omnigentRows(h.snapshots.at(-1))[0];
    assert.equal(row.state, "idle");
    assert.match(row.detail, /sub-agents still running/);
    assert.equal(row.sessions[0].status, "idle");

    // the parent starts a turn: SSE says running -> active
    const t0 = Date.now();
    const before = h.snapshots.length;
    h.streams.get("p1").onEvent({ event: "session.status", json: { type: "session.status", status: "running" } });
    await until(() => h.snapshots.length > before);
    assert.ok(Date.now() - t0 < 500, `event -> write took ${Date.now() - t0}ms`);
    assert.equal(omnigentRows(h.snapshots.at(-1))[0].state, "active");

    // ... and finishes: idle again, the "waiting on you" moment
    h.streams.get("p1").onEvent({ event: "session.status", json: { type: "session.status", status: "idle" } });
    await until(() => omnigentRows(h.snapshots.at(-1))[0].state === "idle");

    // the roll-up going idle (children done) closes the stream; list status rules
    h.d._handleFrame({ type: "changed", items: [listItem({ status: "idle" })] });
    await until(() => !h.streams.has("p1"));
    assert.equal(h.d.parentStatus.has("p1"), false);
    h.d.stop();
  });

  test("a child's activity never shows the parent as working; a child row is never its own thread", async () => {
    const child = listItem({ id: "c1", parent_session_id: "p1", status: "running", title: "explore" });
    const h = harness({ list: [listItem(), child], detail: { p1: "idle" } });
    await h.d.start();
    h.openSocket();
    await until(() => omnigentRows(h.snapshots.at(-1))[0]?.state === "idle");
    assert.equal(h.streams.has("c1"), false, "no stream for a sub-agent");
    const rows = omnigentRows(h.snapshots.at(-1));
    assert.equal(rows.length, 1);
    assert.equal(rows[0].id, "omnigent:p1");
    h.d.stop();
  });

  test("Omnigent down: rows survive the grace window, then drop; nothing fake stays live", async () => {
    const h = harness({ detail: { p1: "running" } });
    await h.d.start();
    const sock = h.openSocket();
    await until(() => omnigentRows(h.snapshots.at(-1)).length === 1);

    sock.close(); // server went away
    assert.equal(h.d.wsConnected, false);
    assert.equal(h.streams.size, 0, "parent streams are torn down with the socket");
    // inside the grace: the last-good row is still there
    h.d.schedule("test");
    const n = h.snapshots.length;
    await until(() => h.snapshots.length > n);
    assert.equal(omnigentRows(h.snapshots.at(-1)).length, 1);
    // past the grace: gone, and the source says so
    await until(() => omnigentRows(h.snapshots.at(-1)).length === 0, { timeout: 2000 });
    assert.match(h.snapshots.at(-1).sources.omnigent, /^unavailable/);
    // the daemon is still alive and reconnecting with backoff
    await until(() => h.sockets.length >= 2, { timeout: 1000 });
    h.openSocket();
    await until(() => omnigentRows(h.snapshots.at(-1)).length === 1, { timeout: 2000 });
    h.d.stop();
  });

  test("REST list unreachable at start: no Omnigent rows, no crash, still writes", async () => {
    const h = harness({
      fetchJson: async () => {
        throw new Error("ECONNREFUSED");
      },
    });
    await h.d.start();
    assert.ok(h.snapshots.length >= 1);
    assert.equal(omnigentRows(h.snapshots.at(-1)).length, 0);
    assert.match(h.snapshots.at(-1).sources.omnigent, /^unavailable/);
    h.d.stop();
  });

  test("a discovered session (changed frame for an unwatched id) is added to the watch-set", async () => {
    const h = harness({ detail: { p1: "running", p2: "running" } });
    await h.d.start();
    const sock = h.openSocket();
    await until(() => sock.sent.length >= 1);
    h.d._handleFrame({ type: "changed", items: [listItem({ id: "p2", title: "second" })] });
    await until(() => sock.sent.length >= 2 && sock.sent.at(-1).session_ids.includes("p2"), { timeout: 1000 });
    await until(() => omnigentRows(h.snapshots.at(-1)).length === 2);
    // archived on the wire -> gone
    h.d._handleFrame({ type: "changed", items: [listItem({ id: "p2", archived: true })] });
    await until(() => omnigentRows(h.snapshots.at(-1)).length === 1);
    h.d.stop();
  });

  test("an Omnigent-only edge never re-forks git or ps; the tick does", async (t) => {
    let gitCalls = 0;
    let psCalls = 0;
    const h = harness({
      detail: { p1: "running" },
      gitFn: () => {
        gitCalls++;
        return {
          mainWorktree: "/r",
          worktrees: [],
          gitByPath: {},
          prs: [],
          registry: null,
          sources: { git: "ok" },
          branchForCwd: () => null,
        };
      },
      procsFn: () => {
        psCalls++;
        return new Map();
      },
    });
    t.after(() => h.d.stop());
    await h.d.start();
    h.openSocket();
    await until(() => omnigentRows(h.snapshots.at(-1)).length === 1 && h.streams.has("p1"));
    const g0 = gitCalls;
    const p0 = psCalls;
    for (let i = 0; i < 3; i++) {
      const n = h.snapshots.length;
      h.streams.get("p1").onEvent({ event: "session.status", json: { status: i % 2 ? "running" : "idle" } });
      await until(() => h.snapshots.length > n);
    }
    assert.equal(gitCalls, g0, "git bundle reused across Omnigent edges");
    assert.equal(psCalls, p0, "process table reused across Omnigent edges");
    await h.d.tick();
    assert.equal(gitCalls, g0 + 1);
    assert.equal(psCalls, p0 + 1);
    h.d.stop();
  });

  test("a Claude Code hook write under ~/.claude/agent-state triggers a collect", async () => {
    const h = harness({ list: [], watchFs: true });
    await h.d.start();
    const n = h.snapshots.length;
    // macOS FSEvents can drop a write that lands right after the watch starts, so
    // keep rewriting (a hook rewrites the file every turn anyway) until one is seen.
    const write = () =>
      writeFileSync(
        join(h.home, ".claude", "agent-state", "abc.json"),
        JSON.stringify({ session_id: "abc", state: "waiting", cwd: h.repo, since: new Date().toISOString(), pid: 0 }),
      );
    write();
    const again = setInterval(write, 250);
    try {
      await until(() => h.snapshots.length > n, { timeout: 5000 });
      assert.ok(h.snapshots.at(-1).daemon.reasons.some((r) => r.startsWith("claude:")));
    } finally {
      clearInterval(again);
      h.d.stop();
    }
  });
});

// The one-shot library path still assembles from explicit sources.
test("collect() honours handed-in sources and the parent overlay without touching the network", async () => {
  const home = mkdtempSync(join(tmpdir(), "bt-home-"));
  const snap = await collect({
    repo: "/nowhere",
    home,
    usage: false,
    sources: {
      git: {
        mainWorktree: "/r",
        worktrees: [],
        gitByPath: {},
        prs: [],
        registry: null,
        sources: { git: "ok", gh: "ok", registry: "ok" },
        branchForCwd: () => "main",
      },
      procs: new Map(),
      omnigent: {
        sessions: [
          {
            harness: "omnigent",
            id: "p1",
            title: "t",
            status: "running",
            listStatus: "running",
            lastSeen: new Date().toISOString(),
            cwd: "/r",
            branch: null,
            live: true,
            child: false,
            parentId: null,
          },
        ],
        runners: "ok",
      },
      codex: [],
      usage: { usage: [{ harness: "x" }], usagePolledAt: "then", status: "ok" },
    },
    parentStatusById: new Map([["p1", "idle"]]),
    resolveParentStatus: false,
  });
  assert.equal(snap.threads.length, 1);
  assert.equal(snap.threads[0].state, "idle");
  assert.equal(snap.threads[0].branch, "main", "branchForCwd filled the missing branch");
  assert.equal(snap.sources.omnigent, "ok");
  assert.deepEqual(snap.usage, [{ harness: "x" }]);
  assert.equal(snap.usagePolledAt, "then");
});

// --- New tests for the fix round ---

describe("parent-status baseline races", () => {
  test("roll-up is NOT used while baseline is pending — parent shows unknown+childActive", async () => {
    // Detail endpoint is slow; list says running (roll-up from children)
    let detailResolve;
    const detailPromise = new Promise((r) => (detailResolve = r));
    const listData = [listItem({ status: "running" })];
    const h = harness({
      list: listData,
      detail: {},
      fetchJson: async (url) => {
        if (url.includes("/v1/sessions/p1")) {
          await detailPromise;
          return { id: "p1", status: "idle" };
        }
        if (url.includes("/v1/runners")) return { data: [{ runner_id: "r1", online: true }] };
        if (url.includes("/v1/sessions")) return { object: "list", data: listData, has_more: false, last_id: listData.at(-1)?.id ?? null };
        throw new Error(`unexpected fetch ${url}`);
      },
    });
    await h.d.start();
    const sock = h.openSocket();
    await until(() => h.streams.has("p1"));

    // Baseline is in flight (detailPromise not resolved yet).
    // Force a collect to capture the pending-baseline state.
    await h.d.coalescer.flush("test");

    // The row should NOT show "active" from the roll-up.
    // It should show "idle" with "sub-agents still running" (parent status unknown, children running).
    await until(() => {
      const rows = omnigentRows(h.snapshots.at(-1));
      return rows.length === 1 && rows[0].state === "idle" && rows[0].detail.includes("sub-agents still running");
    }, { timeout: 2000 });

    // Now resolve the baseline — parent is actually idle
    detailResolve({ id: "p1", status: "idle" });
    await until(() => {
      const rows = omnigentRows(h.snapshots.at(-1));
      return rows[0].state === "idle" && rows[0].detail.includes("sub-agents still running");
    });
    h.d.stop();
  });

  test("an SSE edge arriving during the initial baseline wins over its stale REST response", async (t) => {
    let baselineResolve;
    const baselinePromise = new Promise((r) => (baselineResolve = r));
    const listData = [listItem({ status: "running" })];
    const h = harness({
      list: listData,
      fetchJson: async (url) => {
        if (url.includes("/v1/sessions/p1")) {
          await baselinePromise;
          return { id: "p1", status: "idle" };
        }
        if (url.includes("/v1/runners")) return { data: [{ runner_id: "r1", online: true }] };
        if (url.includes("/v1/sessions")) return { object: "list", data: listData, has_more: false, last_id: listData.at(-1)?.id ?? null };
        throw new Error(`unexpected fetch ${url}`);
      },
    });
    t.after(() => h.d.stop());
    await h.d.start();
    h.openSocket();
    await until(() => h.d.streams.has("p1"));
    h.streams.get("p1").onEvent({ event: "session.status", json: { type: "session.status", status: "running" } });
    await until(() => h.d.parentStatus.get("p1")?.status === "running");
    baselineResolve();
    await sleep(30);
    assert.equal(h.d.parentStatus.get("p1")?.status, "running");
    h.d.stop();
  });

  test("a reconnect runs exactly one baseline for the new stream and applies it", async (t) => {
    let detailCalls = 0;
    const listData = [listItem({ status: "running" })];
    const h = harness({
      list: listData,
      fetchJson: async (url) => {
        if (url.includes("/v1/sessions/p1")) {
          detailCalls++;
          return { id: "p1", status: detailCalls === 1 ? "running" : "idle" };
        }
        if (url.includes("/v1/runners")) return { data: [{ runner_id: "r1", online: true }] };
        if (url.includes("/v1/sessions")) return { object: "list", data: listData, has_more: false, last_id: "p1" };
        throw new Error(`unexpected fetch ${url}`);
      },
    });
    t.after(() => h.d.stop());
    await h.d.start();
    h.openSocket();
    await until(() => h.d.parentStatus.get("p1")?.status === "running");
    assert.equal(detailCalls, 1);

    h.d.streams.get("p1").handle.close();
    await until(() => h.streamHistory.length === 2);
    await until(() => h.d.parentStatus.get("p1")?.status === "idle");
    assert.equal(detailCalls, 2, "one initial baseline plus exactly one reconnect baseline");
    h.d.stop();
  });

  test("a failed baseline retries and leaves a defined parent state", async (t) => {
    let detailCalls = 0;
    const h = harness({
      fetchJson: async (url) => {
        if (url.includes("/v1/sessions/p1")) {
          detailCalls++;
          if (detailCalls === 1) throw new Error("transient detail failure");
          return { id: "p1", status: "idle" };
        }
        if (url.includes("/v1/runners")) return { data: [{ runner_id: "r1", online: true }] };
        if (url.includes("/v1/sessions")) return { object: "list", data: [listItem()], has_more: false, last_id: "p1" };
        throw new Error(`unexpected fetch ${url}`);
      },
    });
    t.after(() => h.d.stop());
    await h.d.start();
    h.openSocket();
    await until(() => h.d.parentStatus.get("p1")?.status === "idle", { timeout: 1000 });
    assert.equal(detailCalls, 2);
    assert.equal(h.d.pendingBaseline.has("p1"), false);
    h.d.stop();
  });

  test("an old baseline cannot write into a removed and re-added session entry", async (t) => {
    let firstResolve;
    const firstDetail = new Promise((resolve) => (firstResolve = resolve));
    let detailCalls = 0;
    const h = harness({
      fetchJson: async (url) => {
        if (url.includes("/v1/sessions/p1")) {
          detailCalls++;
          if (detailCalls === 1) {
            await firstDetail;
            return { id: "p1", status: "idle" };
          }
          return { id: "p1", status: "running" };
        }
        if (url.includes("/v1/runners")) return { data: [{ runner_id: "r1", online: true }] };
        if (url.includes("/v1/sessions")) return { object: "list", data: [listItem()], has_more: false, last_id: "p1" };
        throw new Error(`unexpected fetch ${url}`);
      },
    });
    t.after(() => h.d.stop());
    await h.d.start();
    h.openSocket();
    await until(() => detailCalls === 1);
    h.d._handleFrame({ type: "removed", ids: ["p1"] });
    await until(() => !h.d.streams.has("p1"));
    h.d._handleFrame({ type: "changed", items: [listItem()] });
    await until(() => h.streamHistory.length === 2);
    firstResolve();
    await until(() => detailCalls === 2);
    await until(() => h.d.parentStatus.get("p1")?.status === "running");
    await sleep(30);
    assert.equal(h.d.parentStatus.get("p1")?.status, "running");
    h.d.stop();
  });
});

describe("tick resync", () => {
  test("tick resyncs the list via REST even while WS is disconnected", async () => {
    let listCallCount = 0;
    const detailData = { p1: "running", p2: "running" };
    let listData = [listItem({ id: "p1" })];
    const h = harness({
      detail: detailData,
      list: listData,
      fetchJson: async (url) => {
        if (url.includes("/v1/runners")) return { data: [{ runner_id: "r1", online: true }] };
        if (url.includes("/v1/sessions") && !url.includes("/v1/sessions/")) {
          listCallCount++;
          // First call returns p1; second call (on tick) returns p1 + p2
          const data = listCallCount === 1 ? [listItem({ id: "p1" })] : [listItem({ id: "p1" }), listItem({ id: "p2", title: "second" })];
          listData = data; // update for subsequent calls
          return { object: "list", data, has_more: false, last_id: data.at(-1)?.id ?? null };
        }
        if (url.includes("/v1/sessions/")) {
          const id = url.split("/v1/sessions/")[1].split("?")[0];
          return { id, status: detailData[id] };
        }
        throw new Error(`unexpected fetch ${url}`);
      },
    });
    await h.d.start();
    const sock = h.openSocket();
    await until(() => h.d.streams.has("p1"));
    // Force a collect after stream opens (baseline completes)
    await h.d.coalescer.flush("stream-opened");
    await until(() => omnigentRows(h.snapshots.at(-1)).length >= 1);
    // listCallCount is 2 here (startup resync + ws-open resync)
    assert.equal(listCallCount, 2);

    // Disconnect WS
    sock.close();
    await until(() => h.d.wsConnected === false);
    // Trigger a collect while WS is down (within grace period)
    await h.d.coalescer.flush("test");
    // Row should still be there (within grace)
    assert.ok(omnigentRows(h.snapshots.at(-1)).length >= 1);

    // Now run the tick — it should call resyncList via REST even though WS is down
    await h.d.tick("tick");
    // The tick's resyncList should have been called (third list call)
    assert.equal(listCallCount, 3, "tick should call resyncList via REST even when WS is down");
    // New session p2 should now be discovered
    assert.ok(omnigentRows(h.snapshots.at(-1)).length >= 2);
    h.d.stop();
  });

  test("WS outage serves fresh REST rows, then reports unavailable when REST also fails", async (t) => {
    let clock = 1_000;
    let failList = false;
    const listData = [listItem()];
    const h = harness({
      graceMs: 50,
      now: () => clock,
      fetchJson: async (url) => {
        if (url.includes("/v1/runners")) return { data: [{ runner_id: "r1", online: true }] };
        if (url.includes("/v1/sessions/p1")) return { id: "p1", status: "running" };
        if (url.includes("/v1/sessions")) {
          if (failList) throw new Error("REST list down");
          return { object: "list", data: listData, has_more: false, last_id: "p1" };
        }
        throw new Error(`unexpected fetch ${url}`);
      },
    });
    t.after(() => h.d.stop());
    await h.d.start();
    const sock = h.openSocket();
    await until(() => omnigentRows(h.snapshots.at(-1)).length === 1);
    sock.close();

    clock += 100;
    await h.d.tick("tick");
    assert.equal(h.d._omnigentSource().sessions.length, 1, "fresh REST rows remain available in degraded mode");

    failList = true;
    clock += 100;
    await h.d.tick("tick");
    assert.match(h.d._omnigentSource().error, /^unavailable:/);
    h.d.stop();
  });
});
