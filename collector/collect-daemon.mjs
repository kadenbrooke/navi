#!/usr/bin/env node
// Navi collector daemon — the long-lived, event-driven form of collect.mjs.
// launchd keeps it alive (com.navi.collector, KeepAlive, no StartInterval);
// it rewrites the snapshot (~/.navi/threads.json by default) within
// ~500 ms of anything that changes an agent's state, and idles at ~0 CPU in
// between.
//
//   node collect-daemon.mjs            run until SIGTERM / SIGINT
//   NAVI_DEBUG=1                       log every collect, not just ticks / edges
//
// Event sources (each one only schedules a debounced collect):
//   ws://127.0.0.1:6767/v1/sessions/updates   Omnigent's own sidebar feed. One
//                                             socket, a `watch` of every known
//                                             session id; `snapshot` / `changed`
//                                             / `removed` frames keep an
//                                             in-memory copy of the session list.
//   GET /v1/sessions/{id}/stream (SSE)        one per RUNNING Omnigent parent.
//                                             `session.status` here is the
//                                             parent's OWN status — the list
//                                             feed rolls children up, this does
//                                             not. Closed when the parent stops.
//   fs.watch ~/.claude/sessions               Claude Code registry rewrites
//   fs.watch ~/.claude/agent-state            hook writes at turn start / end
//   fs.watch <repo>/.git/worktrees            worktrees added / removed (NAVI_REPO only)
//   60 s tick                                 git / PR / registry / usage / codex
//                                             refresh, REST resync of the
//                                             Omnigent list, and a write so
//                                             generatedAt never goes stale
//
// Cost model: an Omnigent or Claude edge forks nothing but (for Claude) one
// `ps`; git, gh, lsof, sqlite and the quota fetchers run only on the tick or
// when a worktree appears. The git bundle from the last tick is reused
// verbatim in between.
//
// Omnigent down: the socket drops, reconnects with capped exponential
// backoff, and the last-good rows are kept for OMNIGENT_GRACE_MS so a server
// restart does not flash every chat row away. While WS is down, REST refreshes
// the list every 10 s; rows remain available in degraded mode while those
// refreshes succeed. They are dropped only when both feeds exceed the grace.
//
// No npm deps. Node >= 22.13 (global WebSocket, fetch, node:sqlite).

import { watch as fsWatch } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

import {
  processSignature,
  OMNIGENT_BASE,
  OMNIGENT_MAX_SESSIONS,
  OMNIGENT_PAGE_LIMIT,
  OUT_FILE,
  DEFAULT_REPO,
  ACTIVE_STATUSES,
  collect,
  collectCodex,
  collectGitSources,
  collectProcessesAsync,
  mapOmnigentSessions,
  normalizeOmnigentStatus,
  omnigentSessionDetailUrl,
  parseRunners,
  writeSnapshot,
} from "./collect.mjs";
import { collectUsageWithCache } from "./usage.mjs";
import { run as notifyRun } from "./notify.mjs";


export const DAEMON = {
  DEBOUNCE_MS: 300, // event -> collect; coalesces bursts (300-500 ms window; 300 keeps edge-to-file under 500)
  TICK_MS: 60_000, // slow fallback for git / PR / usage
  OMNIGENT_GRACE_MS: 20_000, // keep last-good rows this long after the socket drops
  BACKOFF_MIN_MS: 1000,
  BACKOFF_MAX_MS: 30_000,
  DETAIL_TIMEOUT_MS: 8000, // parent-status baseline fetch
  LIST_TIMEOUT_MS: 15_000,
  BASELINE_ATTEMPTS: 3,
};

// ---------------------------------------------------------------------------
// Small pieces (pure, tested)
// ---------------------------------------------------------------------------
export function nextBackoff(prev, { min = DAEMON.BACKOFF_MIN_MS, max = DAEMON.BACKOFF_MAX_MS } = {}) {
  if (!prev) return min;
  return Math.min(max, prev * 2);
}

// Add +/-20% jitter to a backoff value to prevent thundering herd on SSE reconnects.
export function jitterBackoff(ms, { factor = 0.2 } = {}) {
  const delta = ms * factor;
  return Math.floor(ms - delta + Math.random() * 2 * delta);
}

// Which Omnigent rows want a per-session SSE: a live, un-archived PARENT whose
// list status says running (a non-running roll-up means the parent is not
// running either, so there is nothing to watch).
export function wantsParentStream(row) {
  if (!row || row.archived) return false;
  if (row.parent_session_id) return false;
  if (row.runner_online === false) return false;
  return ACTIVE_STATUSES.has(String(row.status || "").toLowerCase());
}

// Parse SSE text frames ("event: x\ndata: {...}\n\n") out of a growing buffer.
// Returns the parsed events and the unconsumed tail.
export function parseSseChunk(buffer) {
  const events = [];
  let buf = buffer;
  let i;
  while ((i = buf.indexOf("\n\n")) >= 0) {
    const block = buf.slice(0, i);
    buf = buf.slice(i + 2);
    let event = null;
    const dataLines = [];
    for (const raw of block.split("\n")) {
      const line = raw.replace(/\r$/, "");
      if (line.startsWith(":")) continue;
      if (line.startsWith("event:")) event = line.slice(6).trim();
      else if (line.startsWith("data:")) dataLines.push(line.slice(5).replace(/^ /, ""));
    }
    if (!dataLines.length && !event) continue;
    const data = dataLines.join("\n");
    let json = null;
    if (data && data !== "[DONE]") {
      try {
        json = JSON.parse(data);
      } catch {}
    }
    events.push({ event: event || json?.type || null, data, json, done: data === "[DONE]" });
  }
  return { events, rest: buf };
}

// Debounced, coalescing trigger: many schedule() calls inside the window run
// one job; a call during a run queues exactly one more run.
export function makeCoalescer(job, { delayMs = DAEMON.DEBOUNCE_MS, setTimeoutFn = setTimeout, clearTimeoutFn = clearTimeout } = {}) {
  let timer = null;
  let running = null; // promise of the run in flight
  let queued = false;
  let reasons = new Set();
  let runs = 0;
  const fire = () => {
    timer = null;
    if (running) {
      queued = true;
      return running;
    }
    const why = [...reasons];
    reasons = new Set();
    runs++;
    running = (async () => {
      try {
        await job(why);
      } finally {
        running = null;
        if (queued) {
          queued = false;
          timer = setTimeoutFn(fire, 0);
        }
      }
    })();
    return running;
  };
  return {
    schedule(reason = "event") {
      reasons.add(reason);
      if (running) {
        queued = true;
        return;
      }
      if (timer) clearTimeoutFn(timer);
      timer = setTimeoutFn(fire, delayMs);
    },
    // Run now (used by the tick): cancels a pending debounce and executes. If
    // a run is in flight, waits for it AND for the follow-up run that carries
    // this reason, so the caller can rely on its reason having been collected.
    async flush(reason = "flush") {
      reasons.add(reason);
      if (timer) {
        clearTimeoutFn(timer);
        timer = null;
      }
      if (running) {
        queued = true;
        await running;
        // the finally above armed a 0 ms timer for the queued run; run it now
        if (timer) {
          clearTimeoutFn(timer);
          timer = null;
        }
        await fire();
        return;
      }
      await fire();
    },
    get runs() {
      return runs;
    },
    get pending() {
      return !!timer || queued;
    },
    cancel() {
      if (timer) clearTimeoutFn(timer);
      timer = null;
    },
  };
}

// ---------------------------------------------------------------------------
// Defaults for the injectable I/O (tests replace every one of these)
// ---------------------------------------------------------------------------
async function defaultFetchJson(url, timeoutMs) {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const res = await fetch(url, { signal: ctl.signal });
    if (!res.ok) throw new Error(`omnigent HTTP ${res.status}`);
    return await res.json();
  } finally {
    clearTimeout(t);
  }
}

function defaultWsFactory(url) {
  return new WebSocket(url);
}

// SSE via fetch. Returns { close() }. Calls onEvent per parsed frame and
// onClose(reason) exactly once when the stream ends for any reason.
function defaultOpenSse(url, { onEvent, onClose }) {
  const ctl = new AbortController();
  let closed = false;
  const finish = (reason) => {
    if (closed) return;
    closed = true;
    onClose(reason);
  };
  (async () => {
    try {
      const res = await fetch(url, { signal: ctl.signal, headers: { accept: "text/event-stream" } });
      if (!res.ok || !res.body) return finish(`HTTP ${res.status}`);
      const reader = res.body.getReader();
      const dec = new TextDecoder();
      let buf = "";
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buf += dec.decode(value, { stream: true });
        const parsed = parseSseChunk(buf);
        buf = parsed.rest;
        for (const ev of parsed.events) {
          if (ev.done) return finish("done");
          onEvent(ev);
        }
      }
      finish("eof");
    } catch (e) {
      finish(ctl.signal.aborted ? "closed" : String(e?.message || e));
    }
  })();
  return {
    close() {
      ctl.abort();
      finish("closed");
    },
  };
}

const defaultLog = (line) => process.stdout.write(`[${new Date().toISOString()}] ${line}\n`);

// ---------------------------------------------------------------------------
// The daemon
// ---------------------------------------------------------------------------
export function createDaemon({
  repo = DEFAULT_REPO,
  home = homedir(),
  omnigentBase = OMNIGENT_BASE,
  outFile = OUT_FILE,
  debounceMs = DAEMON.DEBOUNCE_MS,
  tickMs = DAEMON.TICK_MS,
  graceMs = DAEMON.OMNIGENT_GRACE_MS,
  outagePollMs = Math.min(10_000, Math.max(1_000, Math.floor(graceMs / 2))),
  backoff = { min: DAEMON.BACKOFF_MIN_MS, max: DAEMON.BACKOFF_MAX_MS },
  usage = process.env.NAVI_NO_USAGE !== "1",
  watchFs = true,
  // injectables
  fetchJson = defaultFetchJson,
  wsFactory = defaultWsFactory,
  openSse = defaultOpenSse,
  collectFn = collect,
  gitFn = collectGitSources,
  procsFn = collectProcessesAsync,
  codexFn = collectCodex,
  usageFn = collectUsageWithCache,
  writeFn = (snapshot) => writeSnapshot(snapshot, { outFile }),
  notifyFn = () => notifyRun({ snapshotFile: outFile }),
  log = defaultLog,
  debug = process.env.NAVI_DEBUG === "1",
  now = Date.now,
} = {}) {
  const wsUrl = omnigentBase.replace(/^http/, "ws") + "/v1/sessions/updates";
  const listUrl = `${omnigentBase}/v1/sessions`;
  const runnersUrl = `${omnigentBase}/v1/runners`;

  // --- cached slow sources -------------------------------------------------
  const cache = {
    git: null, // collectGitSources bundle
    procs: null,
    codex: null,
    usage: null, // { usage, usagePolledAt, status }
    runners: null, // Set of online runner ids (REST), fallback when a row lacks runner_online
    runnersStatus: "ok",
  };
  let procsDirty = true;
  let gitDirty = true;

  // --- Omnigent list state (fed by WS, resynced by REST on the tick) ---------
  const rows = new Map(); // id -> raw list item
  let ws = null;
  let wsConnected = false;
  let wsEverConnected = false;
  let wsDisconnectedAt = null;
  let wsBackoff = 0;
  let wsTimer = null;
  let watchTimer = null;
  let omnigentError = "not connected yet";
  let lastRestSuccessAt = null;
  let restPollTimer = null;

  // --- parent-only status ----------------------------------------------------
  const parentStatus = new Map(); // id -> { status, seq } (normalized status + monotonic sequence)
  const pendingBaseline = new Map(); // id -> baseline token for the active stream generation
  const streams = new Map(); // id -> { handle, backoff, timer, baselineWait, gen }

  let stopped = false;
  let tickTimer = null;
  let graceTimer = null;
  const watchers = [];
  const stats = { collects: 0, writes: 0, lastReasons: [], lastCollectMs: 0, lastWriteAt: null, errors: 0 };

  const dlog = (line) => debug && log(line);

  // ---- collect + write --------------------------------------------------------
  async function runCollect(reasons) {
    const t0 = now();
    // Cheap path: nothing but Omnigent / usage news -> no ps, no git.
    const omnigentOnly = reasons.length > 0 && reasons.every((r) => r.startsWith("omnigent") || r === "usage" || r === "procs");
    try {
      if (gitDirty || !cache.git) {
        try {
          cache.git = gitFn(repo);
        } catch (e) {
          if (!cache.git) throw e; // no spine at all: nothing to write
          log(`git refresh failed, reusing last bundle: ${e?.message || e}`);
        }
        gitDirty = false;
        watchWorktreesOnce();
      }
      // The process table: awaited only when there is none yet (first run) or
      // on the tick; a Claude edge collects with the cached table right away
      // and a background refresh re-collects if the harness processes changed.
      if (!cache.procs) await refreshProcs();
      else if (procsDirty && !omnigentOnly) {
        if (reasons.includes("tick") || reasons.includes("startup")) await refreshProcs();
        else refreshProcs().catch(() => {});
      }
      const omnigent = omnigentSource();
      const snapshot = await collectFn({
        repo,
        home,
        omnigentUrl: listUrl,
        usage: false,
        sources: {
          git: cache.git,
          procs: cache.procs || new Map(),
          omnigent,
          codex: cache.codex || [],
          usage: cache.usage || undefined,
        },
        parentStatusById: parentStatus,
        resolveParentStatus: false,
      });
      if (cache.codex === null) snapshot.sources.codex = "pending";
      snapshot.daemon = { reasons, ws: wsConnected ? "connected" : `down: ${omnigentError}`, streams: streams.size };
      writeFn(snapshot);
      stats.writes++;
      stats.lastWriteAt = snapshot.generatedAt;
      try {
        notifyFn();
      } catch (e) {
        log(`notify failed: ${e?.message || e}`);
      }
      reconcileStreams();
    } catch (e) {
      stats.errors++;
      log(`collect failed: ${e?.message || e}`);
    } finally {
      stats.collects++;
      stats.lastReasons = reasons;
      stats.lastCollectMs = now() - t0;
      const isTick = reasons.includes("tick") || reasons.includes("startup");
      if (isTick || debug) log(`collect [${reasons.join(",")}] ${stats.lastCollectMs}ms, ${streams.size} parent streams`);
    }
  }

  let procsInFlight = null;
  function refreshProcs() {
    if (procsInFlight) return procsInFlight;
    procsDirty = false;
    procsInFlight = (async () => {
      try {
        const next = await procsFn();
        const changed = cache.procs && processSignature(next) !== processSignature(cache.procs);
        cache.procs = next;
        if (changed) schedule("procs");
      } catch (e) {
        cache.procs = cache.procs || new Map();
        log(`ps failed: ${e?.message || e}`);
      } finally {
        procsInFlight = null;
      }
    })();
    return procsInFlight;
  }

  const coalescer = makeCoalescer(runCollect, { delayMs: debounceMs });
  const schedule = (reason) => {
    if (!stopped) coalescer.schedule(reason);
  };

  // What collect() sees for Omnigent. Either the WS or a recent successful
  // REST list keeps the rows available; only when both are stale is the source
  // considered down.
  function omnigentSource() {
    const wsFresh = wsConnected || (wsDisconnectedAt !== null && now() - wsDisconnectedAt <= graceMs);
    const restFresh = lastRestSuccessAt !== null && now() - lastRestSuccessAt <= graceMs;
    const down = !wsFresh && !restFresh;
    if (down) return { sessions: [], runners: cache.runnersStatus, error: `unavailable: ${omnigentError}` };
    const sessions = mapOmnigentSessions([...rows.values()], { onlineRunners: cache.runners });
    return { sessions, runners: cache.runnersStatus };
  }

  // ---- Omnigent WS ------------------------------------------------------------
  function connectWs() {
    if (stopped || ws) return;
    let sock;
    try {
      sock = wsFactory(wsUrl);
    } catch (e) {
      onWsClosed(`open failed: ${e?.message || e}`);
      return;
    }
    ws = sock;
    sock.onopen = () => {
      if (sock !== ws) return;
      wsConnected = true;
      wsEverConnected = true;
      wsBackoff = 0;
      wsDisconnectedAt = null;
      if (graceTimer) {
        clearTimeout(graceTimer);
        graceTimer = null;
      }
      if (restPollTimer) {
        clearTimeout(restPollTimer);
        restPollTimer = null;
      }
      omnigentError = null;
      log("omnigent ws connected");
      // Fresh list from REST so the watch-set is complete (sessions created
      // while we were down have no id we could otherwise know).
      resyncList("ws-open").then(() => sendWatch());
    };
    sock.onmessage = (ev) => {
      if (sock !== ws) return;
      let frame;
      try {
        frame = JSON.parse(String(ev.data));
      } catch {
        return;
      }
      handleFrame(frame);
    };
    sock.onerror = (ev) => {
      if (sock !== ws) return;
      omnigentError = ev?.message || "socket error";
    };
    sock.onclose = (ev) => {
      if (sock !== ws) return;
      onWsClosed(ev?.reason || `closed (${ev?.code ?? "?"})`);
    };
  }

  function onWsClosed(reason) {
    ws = null;
    const wasConnected = wsConnected;
    wsConnected = false;
    if (wasConnected || wsDisconnectedAt === null) wsDisconnectedAt = now();
    omnigentError = reason || "closed";
    if (wasConnected) log(`omnigent ws down: ${omnigentError}`);
    // Every parent stream is now unverifiable; drop them (they reopen on resync).
    for (const id of [...streams.keys()]) closeStream(id);
    parentStatus.clear();
    if (!stopped) {
      wsBackoff = nextBackoff(wsBackoff, backoff);
      wsTimer = setTimeout(() => {
        wsTimer = null;
        connectWs();
      }, wsBackoff);
      scheduleRestFallbackPoll();
      // Re-evaluate at the grace boundary: rows drop only if REST is stale too.
      if (!graceTimer) {
        graceTimer = setTimeout(() => {
          graceTimer = null;
          if (!wsConnected) {
            if (omnigentSource().error) log(`omnigent WS and REST still down after ${graceMs}ms grace — dropping its rows`);
            else dlog("omnigent WS down; serving fresh REST rows in degraded mode");
            schedule("omnigent:grace-expired");
          }
        }, graceMs + 50);
      }
    }
  }

  function scheduleRestFallbackPoll() {
    if (stopped || wsConnected || restPollTimer) return;
    restPollTimer = setTimeout(async () => {
      restPollTimer = null;
      if (stopped || wsConnected) return;
      await resyncList("ws-down");
      schedule("omnigent:rest-fallback");
      scheduleRestFallbackPoll();
    }, outagePollMs);
  }

  function handleFrame(frame) {
    if (!frame || typeof frame !== "object") return;
    let changed = false;
    if (frame.type === "snapshot" || frame.type === "changed") {
      for (const item of frame.items || []) {
        if (!item?.id) continue;
        if (item.archived) {
          if (rows.delete(item.id)) changed = true;
          continue;
        }
        const prev = rows.get(item.id);
        rows.set(item.id, item);
        if (!prev) {
          changed = true;
          sendWatchSoon(); // a discovered session: start watching it
        } else if (rowChanged(prev, item)) {
          changed = true;
        }
      }
    } else if (frame.type === "removed") {
      for (const id of frame.ids || []) if (rows.delete(id)) changed = true;
    }
    if (changed) {
      reconcileStreams();
      schedule("omnigent:list");
    }
  }

  // Fields the row -> thread mapping actually reads. Anything else changing
  // (context tokens, viewer_last_seen …) is not worth a collect.
  const ROW_FIELDS = [
    "status",
    "title",
    "updated_at",
    "runner_id",
    "runner_online",
    "workspace",
    "git_branch",
    "archived",
    "pending_elicitations_count",
    "viewer_unread",
    "parent_session_id",
    "agent_name",
    "kind",
    "sub_agent_name",
  ];
  function rowChanged(a, b) {
    for (const k of ROW_FIELDS) if (a?.[k] !== b?.[k]) return true;
    const la = a?.labels || {};
    const lb = b?.labels || {};
    for (const k of ["omnigent.last_task_error_code", "omnigent.last_task_error_title", "omnigent.last_task_error_message"]) {
      if (la[k] !== lb[k]) return true;
    }
    return false;
  }

  function sendWatch() {
    if (!ws || !wsConnected) return;
    try {
      ws.send(JSON.stringify({ type: "watch", session_ids: [...rows.keys()] }));
    } catch (e) {
      log(`watch send failed: ${e?.message || e}`);
    }
  }
  function sendWatchSoon() {
    if (watchTimer) return;
    watchTimer = setTimeout(() => {
      watchTimer = null;
      sendWatch();
    }, 250);
  }

  // REST list → rows (adds / updates / drops archived). Also refreshes the
  // runners set. Errors leave the rows alone.
  async function resyncList(reason) {
    try {
      const raw = await pageRawList();
      lastRestSuccessAt = now();
      const seen = new Set();
      let changed = false;
      for (const item of raw) {
        if (!item?.id || item.archived) continue;
        seen.add(item.id);
        const prev = rows.get(item.id);
        rows.set(item.id, item);
        if (!prev || rowChanged(prev, item)) changed = true;
      }
      for (const id of [...rows.keys()]) {
        if (!seen.has(id)) {
          rows.delete(id);
          changed = true;
        }
      }
      try {
        cache.runners = parseRunners(await fetchJson(runnersUrl, DAEMON.LIST_TIMEOUT_MS));
        cache.runnersStatus = "ok";
      } catch (e) {
        cache.runnersStatus = `unavailable: ${String(e?.message || e).split("\n")[0]}`;
      }
      reconcileStreams();
      if (changed) schedule(`omnigent:resync`);
      return true;
    } catch (e) {
      omnigentError = String(e?.message || e).split("\n")[0];
      dlog(`resync (${reason}) failed: ${omnigentError}`);
      return false;
    }
  }

  async function pageRawList() {
    const out = [];
    let after = null;
    for (let page = 0; page < Math.ceil(OMNIGENT_MAX_SESSIONS / OMNIGENT_PAGE_LIMIT) + 1; page++) {
      const u = new URL(listUrl);
      u.searchParams.set("limit", String(OMNIGENT_PAGE_LIMIT));
      if (after) u.searchParams.set("after", after);
      const payload = await fetchJson(u.toString(), DAEMON.LIST_TIMEOUT_MS);
      const items = Array.isArray(payload?.data) ? payload.data : [];
      out.push(...items);
      const lastId = payload?.last_id || items[items.length - 1]?.id || null;
      if (!payload?.has_more || !items.length || !lastId || lastId === after) break;
      after = lastId;
    }
    return out;
  }

  // ---- per-parent SSE -----------------------------------------------------------
  function reconcileStreams() {
    if (stopped) return;
    const wanted = new Set();
    if (wsConnected) {
      for (const row of rows.values()) if (wantsParentStream(row)) wanted.add(row.id);
    }
    for (const id of wanted) if (!streams.has(id)) openStream(id);
    for (const id of [...streams.keys()]) {
      if (!wanted.has(id)) {
        closeStream(id);
        // Not running per the roll-up ⇒ the parent is not running. The list
        // status is authoritative again.
        parentStatus.delete(id);
        pendingBaseline.delete(id);
      }
    }
  }

  function openStream(id) {
    const entry = { handle: null, backoff: 0, timer: null, baselineWait: null, gen: 0 };
    streams.set(id, entry);
    // Install the unknown placeholder before opening SSE so collection never
    // falls back to the list's child roll-up while the baseline is in flight.
    parentStatus.set(id, { status: null, seq: 0 });
    startStream(id, entry);
    // Opening a stream means we'll soon have parent status; schedule a collect so the
    // row updates from roll-up to "unknown+childActive" (or the real status) promptly.
    schedule("omnigent:stream-opened");
  }

  function startStream(id, entry, { forceBaseline = false } = {}) {
    if (stopped || streams.get(id) !== entry) return;
    const gen = ++entry.gen;
    const url = `${omnigentBase}/v1/sessions/${id}/stream`;
    entry.handle = openSse(url, {
      onEvent: (ev) => {
        if (streams.get(id) !== entry || entry.gen !== gen) return;
        entry.backoff = 0;
        if (ev.event === "session.status" && ev.json && typeof ev.json.status === "string") {
          const own = normalizeOmnigentStatus(ev.json.status);
          const prev = parentStatus.get(id);
          const newSeq = (prev?.seq ?? 0) + 1;
          parentStatus.set(id, { status: own, seq: newSeq });
          // An edge arrived: this id is no longer pending baseline
          pendingBaseline.delete(id);
          if (prev?.status !== own) {
            dlog(`parent ${id.slice(0, 8)} own status ${prev?.status ?? "?"} -> ${own} (seq ${newSeq})`);
            schedule("omnigent:parent-status");
          }
        }
      },
      onClose: (reason) => {
        if (streams.get(id) !== entry || entry.gen !== gen) return;
        entry.handle = null;
        entry.gen++;
        cancelBaselineWait(entry);
        pendingBaseline.delete(id);
        if (stopped) return;
        entry.backoff = nextBackoff(entry.backoff, backoff);
        const jittered = jitterBackoff(entry.backoff);
        dlog(`stream ${id.slice(0, 8)} closed (${reason}); retry in ${jittered}ms (base ${entry.backoff}ms)`);
        entry.timer = setTimeout(() => {
          entry.timer = null;
          if (streams.get(id) === entry && wantsParentStream(rows.get(id))) {
            // Bump/open the new generation first, then bind exactly one
            // re-baseline to that generation.
            startStream(id, entry, { forceBaseline: true });
          } else {
            closeStream(id);
          }
        }, jittered);
      },
    });
    baseline(id, { force: forceBaseline, entry, gen });
  }

  function closeStream(id) {
    const entry = streams.get(id);
    if (!entry) return;
    streams.delete(id);
    entry.gen++;
    if (entry.timer) clearTimeout(entry.timer);
    cancelBaselineWait(entry);
    try {
      entry.handle?.close();
    } catch {}
    pendingBaseline.delete(id);
  }

  // The stream only carries EDGES; the parent's current own status comes from
  // the detail endpoint once per (re)connect. A `session.status` that arrives
  // first wins — it is fresher than any REST read.
  // Each baseline belongs to one concrete stream entry and generation. This
  // prevents an old request from writing into a removed/re-added session whose
  // per-entry generation happens to have the same number.
  async function baseline(id, { force = false, entry, gen } = {}) {
    if (streams.get(id) !== entry || entry.gen !== gen) return;
    const token = { entry, gen };
    pendingBaseline.set(id, token);
    let retryBackoff = 0;
    try {
      for (let attempt = 1; attempt <= DAEMON.BASELINE_ATTEMPTS; attempt++) {
        if (streams.get(id) !== entry || entry.gen !== gen) return;
        const baselineStartSeq = parentStatus.get(id)?.seq ?? 0;
        let d;
        try {
          d = await fetchJson(omnigentSessionDetailUrl(id, omnigentBase), DAEMON.DETAIL_TIMEOUT_MS);
          if (!d || typeof d.status !== "string") throw new Error("detail response missing status");
        } catch (e) {
          if (streams.get(id) !== entry || entry.gen !== gen) return;
          if (attempt < DAEMON.BASELINE_ATTEMPTS) {
            retryBackoff = nextBackoff(retryBackoff, backoff);
            dlog(`baseline ${id.slice(0, 8)} attempt ${attempt} failed: ${e?.message || e}; retry in ${retryBackoff}ms`);
            await waitForBaselineRetry(entry, retryBackoff);
            continue;
          }
          const prev = parentStatus.get(id);
          if (!prev || prev.status === null) {
            parentStatus.set(id, { status: "unknown", seq: (prev?.seq ?? 0) + 1 });
            schedule("omnigent:parent-baseline-fallback");
          }
          log(`baseline ${id.slice(0, 8)} failed after ${DAEMON.BASELINE_ATTEMPTS} attempts; using ${parentStatus.get(id)?.status ?? "unknown"}`);
          return;
        }
        if (streams.get(id) !== entry || entry.gen !== gen) return;
        const own = normalizeOmnigentStatus(d.status);
        const prev = parentStatus.get(id);
        const currentSeq = prev?.seq ?? 0;
        const noRealStatusYet = !prev || prev.status === null;
        const noEdgeDuringFetch = currentSeq === baselineStartSeq;
        const shouldApply = force ? noEdgeDuringFetch : noRealStatusYet;
        if (shouldApply) {
          const newSeq = currentSeq + 1;
          parentStatus.set(id, { status: own, seq: newSeq });
          dlog(`parent ${id.slice(0, 8)} baseline ${own} (seq ${newSeq})${force ? " [forced]" : ""}`);
          schedule("omnigent:parent-baseline");
        } else {
          dlog(`parent ${id.slice(0, 8)} baseline skipped — newer edge/status exists (seq ${currentSeq}, start ${baselineStartSeq})`);
        }
        return;
      }
    } finally {
      if (pendingBaseline.get(id) === token) pendingBaseline.delete(id);
    }
  }

  function waitForBaselineRetry(entry, ms) {
    return new Promise((resolve) => {
      const wait = {
        timer: setTimeout(() => {
          if (entry.baselineWait === wait) entry.baselineWait = null;
          resolve();
        }, ms),
        resolve,
      };
      entry.baselineWait = wait;
    });
  }

  function cancelBaselineWait(entry) {
    const wait = entry.baselineWait;
    if (!wait) return;
    entry.baselineWait = null;
    clearTimeout(wait.timer);
    wait.resolve();
  }

  // ---- filesystem watchers ---------------------------------------------------------
  let worktreesWatched = false;
  // `git worktree add/remove` edits <main checkout>/.git/worktrees/, wherever
  // the worktree folders themselves live. Only the git bundle knows the main
  // checkout for sure. The dir does not exist until the first worktree is
  // added; until then the 60 s tick picks new worktrees up.
  function watchWorktreesOnce() {
    if (worktreesWatched || !watchFs || !cache.git?.mainWorktree) return;
    worktreesWatched = true;
    watchDir(join(cache.git.mainWorktree, ".git", "worktrees"), "git:worktrees", { git: true });
  }

  function watchDir(dir, reason, { git = false } = {}) {
    try {
      const w = fsWatch(dir, { persistent: true }, () => {
        if (git) gitDirty = true;
        else procsDirty = true;
        schedule(reason);
      });
      w.on("error", (e) => log(`watch ${dir} error: ${e?.message || e}`));
      watchers.push(w);
      dlog(`watching ${dir}`);
    } catch (e) {
      log(`cannot watch ${dir}: ${e?.message || e}`);
    }
  }

  // ---- slow tick --------------------------------------------------------------------
  async function tick(reason = "tick") {
    if (stopped) return;
    gitDirty = true;
    procsDirty = true;
    try {
      cache.codex = await codexFn(home, { procs: cache.procs || undefined });
    } catch (e) {
      cache.codex = cache.codex || [];
      dlog(`codex: ${e?.message || e}`);
    }
    // Always resync via REST regardless of WS state. During an extended WS outage,
    // the REST list is the only way to get fresh session data. On failure,
    // resyncList leaves rows alone and records omnigentError; the staleness/grace
    // logic will surface "collector/omnigent down" without a misleading snapshot.
    await resyncList(reason);
    await coalescer.flush(reason);
    // Quota usage last and off the critical path: its fetchers talk to five
    // providers and can take tens of seconds. It lands as its own cheap collect.
    if (usage) await refreshUsage();
  }

  let usageInFlight = false;
  async function refreshUsage() {
    if (usageInFlight) return;
    usageInFlight = true;
    try {
      const u = await usageFn({ now: now() });
      const errored = (u.usage || []).filter((r) => r.error).map((r) => r.harness);
      const next = { usage: u.usage, usagePolledAt: u.usagePolledAt, status: errored.length ? `partial: ${errored.join(", ")}` : "ok" };
      const changed = JSON.stringify(next) !== JSON.stringify(cache.usage);
      cache.usage = next;
      if (changed) schedule("usage");
    } catch (e) {
      cache.usage = cache.usage || { usage: [], usagePolledAt: null, status: `unavailable: ${e?.message || e}` };
    } finally {
      usageInFlight = false;
    }
  }

  // ---- lifecycle -------------------------------------------------------------------------
  async function start() {
    stopped = false;
    log(`daemon start (repo ${repo}, out ${outFile}, debounce ${debounceMs}ms, tick ${tickMs}ms)`);
    if (watchFs) {
      watchDir(join(home, ".claude", "sessions"), "claude:sessions");
      watchDir(join(home, ".claude", "agent-state"), "claude:agent-state");
    }
    connectWs();
    await tick("startup");
    tickTimer = setInterval(() => {
      tick().catch((e) => log(`tick failed: ${e?.message || e}`));
    }, tickMs);
  }

  function stop() {
    stopped = true;
    if (tickTimer) clearInterval(tickTimer);
    if (wsTimer) clearTimeout(wsTimer);
    if (graceTimer) clearTimeout(graceTimer);
    if (watchTimer) clearTimeout(watchTimer);
    if (restPollTimer) clearTimeout(restPollTimer);
    coalescer.cancel();
    for (const id of [...streams.keys()]) closeStream(id);
    for (const w of watchers) {
      try {
        w.close();
      } catch {}
    }
    watchers.length = 0;
    const sock = ws;
    ws = null;
    try {
      sock?.close();
    } catch {}
    wsConnected = false;
  }

  return {
    start,
    stop,
    tick,
    schedule,
    // introspection for tests / debugging
    get rows() {
      return rows;
    },
    get parentStatus() {
      return parentStatus;
    },
    get pendingBaseline() {
      return pendingBaseline;
    },
    get streams() {
      return streams;
    },
    get wsConnected() {
      return wsConnected;
    },
    get wsEverConnected() {
      return wsEverConnected;
    },
    get stats() {
      return stats;
    },
    get coalescer() {
      return coalescer;
    },
    _handleFrame: handleFrame,
    _omnigentSource: omnigentSource,
  };
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------
const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  const daemon = createDaemon();
  const bye = (sig) => {
    defaultLog(`daemon stopping (${sig})`);
    daemon.stop();
    process.exit(0);
  };
  process.on("SIGTERM", () => bye("SIGTERM"));
  process.on("SIGINT", () => bye("SIGINT"));
  process.on("uncaughtException", (e) => defaultLog(`uncaught: ${e?.stack || e}`));
  process.on("unhandledRejection", (e) => defaultLog(`unhandled rejection: ${e?.stack || e}`));
  daemon.start().catch((e) => {
    defaultLog(`daemon start failed: ${e?.stack || e}`);
    process.exit(1);
  });
}
