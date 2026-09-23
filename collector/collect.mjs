#!/usr/bin/env node
// Navi collector — ONE list of active build threads with plain-English git
// status, so you never have to decode worktree / branch / PR / merge vocabulary
// across Claude Code, Codex, Cursor, and Omnigent/polly chats.
//
// A BUILD THREAD = one git worktree + its branch + the agent session(s) working
// in it + its PR (if any). One row per thread, never per chat.
//
// A row exists ONLY when a LIVE PARENT SESSION backs it: the harness process must be running right now, and the session
// must not be a sub-agent. Git / PR facts decorate a row; they never create
// one. Worktrees, branches and open PRs with nobody live behind them go to
// snapshot.dormant[] (Raycast / phone later); Navi reads only threads[].
//
//   node collect.mjs            collect, write the snapshot (paths.mjs: ~/.navi/threads.json), print summary
//   node collect.mjs --json     collect, write, print the JSON
//   node collect.mjs --table    collect, write, print a readable table
//   node collect.mjs --cached   skip collection, read the last snapshot (Raycast uses this)
//   node collect.mjs --no-write collect but leave threads.json alone
//
// This file is the one-shot path AND the library: collect-daemon.mjs (the
// launchd KeepAlive daemon) imports collect() and feeds it cached sources
// (git / PRs / process table / Omnigent rows it already holds from the push
// feeds) so an Omnigent or Claude Code turn edge never forks git or gh.
//
// Sources (all read-only; every one degrades to "unavailable" instead of throwing):
//   git worktree list           worktrees of NAVI_REPO (optional; skipped when unset)
//   gh pr list (ONE call)       PR number / state / url per branch (optional)
//   .polly/registry.json        review verdicts from an Omnigent/polly registry (optional)
//   ~/.claude/sessions/*.json   Claude Code's own per-pid session registry
//   ~/.claude/agent-state/      optional hook output (running / waiting / blocked), see README
//   http://127.0.0.1:6767       Omnigent loopback sessions API (paged; a session with no
//                               worktree of its own becomes its own "omnigent:<id>" row;
//                               /v1/runners says which sessions' runners are online)
//   ps -axo pid,ppid,command    process table: pid liveness, and which Claude / Codex
//                               processes were launched BY Omnigent (never double-listed)
//   ~/.codex/state_*.sqlite     Codex thread index (node:sqlite, read-only)
//   usage.mjs                   per-harness quota usage (Claude, Codex, Cursor, Antigravity, …)
//                               -> snapshot.usage[] + usagePolledAt; NAVI_NO_USAGE=1 skips it
//
// No npm deps. Never touches a worktree: no checkout, no fetch, no remove.

import { execFile, execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import { collectUsageWithCache, renderUsage } from "./usage.mjs";
import { DEFAULT_REPO, OUT_DIR, OUT_FILE, PREV_FILE } from "./paths.mjs";

export { DEFAULT_REPO, OUT_DIR, OUT_FILE, PREV_FILE };

// ---------------------------------------------------------------------------
// Thresholds — the whole state machine is tuned from this one block.
// ---------------------------------------------------------------------------
export const THRESHOLDS = {
  STALE_BEHIND_COMMITS: 20, // behind origin/main by MORE than this -> stale
  STALE_NO_COMMIT_DAYS: 7, // no commit in this many days (and not merged) -> stale
  ACTIVE_SESSION_MINUTES: 10, // a session seen within this window -> "Agent working"
  OMNIGENT_TIMEOUT_MS: 15000, // per request; a busy server takes seconds, and a miss hides every chat
  GH_TIMEOUT_MS: 15000,
  GIT_TIMEOUT_MS: 5000,
};

// Registry statuses that mean "a reviewer signed off, your merge is the only
// thing left". Repos whose GitHub reviewDecision is blank (no required
// reviews) rely on this for "PR waiting on you".
export const REGISTRY_READY_PATTERN = /ready/i;

// Session statuses that mean "an agent is mid-turn right now". agent-state's
// `since` is the time of the last state CHANGE, not a heartbeat, so a long
// build reads as 10+ minutes old while still very much running.
export const ACTIVE_STATUSES = new Set(["running", "busy"]);

// Codex writes one thread row per `codex exec` call, so a polly-driven
// worktree can carry dozens. Keep only the newest per harness where noted.
export const MAX_SESSIONS_PER_HARNESS = { codex: 1, default: 5 };

// Branches that are never a build thread (the main checkout is home base).
export const HOME_BRANCHES = new Set(["main", "master"]);

// Auto-generated branch names carry no meaning to a person (Omnigent's
// `worktree-<8hex>`, session tools' `session/<id>` / `session-<id>`). A thread
// on one of these is named by its PR or its newest session title instead.
export const AUTO_BRANCH_PATTERN = /^(worktree-[0-9a-f]{6,}|session[\/-][a-z0-9]+)$/i;

// Omnigent's list endpoint pages with `has_more` + `last_id`; follow it with
// `?after=<last_id>` until done, never past OMNIGENT_MAX_SESSIONS rows.
export const OMNIGENT_PAGE_LIMIT = 200;
export const OMNIGENT_MAX_SESSIONS = 500;

// A Claude Code / Codex process with one of these in an ancestor's command line
// was launched by Omnigent (its python runner, or its `omnigent-terminal-*` tmux
// server). Omnigent's own session row already represents it.
export const OMNIGENT_PROCESS_PATTERN = /omnigent/i;

// Claude Code registry entrypoints that are a person at a terminal. `sdk-py`
// (Omnigent's claude-sdk harness) and anything else are workers.
export const CLAUDE_INTERACTIVE_ENTRYPOINTS = new Set(["cli"]);

// A Claude Code process started as a channel listener / daemon (e.g. a chat
// bridge: `claude --channels plugin:<channel>@...`). It registers a session
// row with entrypoint `cli`, but nobody is building in it — never a thread.
export const CHANNEL_LISTENER_PATTERN = /(^|\s)--channels(\s|=|$)/;

// A Codex TUI process: the `codex` binary itself, not `codex app-server` (a
// background service) and not its `*-host` helpers.
export const CODEX_TUI_PATTERN = /(^|\/)codex(\s|$)(?!.*\bapp-server\b)/;

// Plain-language labels — the only status vocabulary you see.
export const STATE_LABELS = {
  stale: "Behind main — needs a rebase or should be deleted",
  uncommitted: "Work on your Mac only, not saved to git yet",
  unpushed: "Committed but not backed up to GitHub",
  "pr-open": "PR open, review not done",
  "pr-open-ready": "PR waiting on you",
  merged: "Merged — safe to delete this worktree",
  active: "Agent working",
  idle: "Pushed, nothing waiting",
  "needs-input": "Agent waiting on your reply",
  blocked: "Agent hit an error",
};
// A live row that is resting: the agent is there, nothing is asked of you.
// Git facts (dirty / unpushed) go in the detail, not the label.
export const LIVE_IDLE_LABEL = "Agent idle, nothing waiting";
export const CHAT_IDLE_LABEL = LIVE_IDLE_LABEL;

export const OMNIGENT_BASE = "http://127.0.0.1:6767";
export const OMNIGENT_URL = `${OMNIGENT_BASE}/v1/sessions`;
export const OMNIGENT_RUNNERS_URL = `${OMNIGENT_BASE}/v1/runners`;

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------
function sh(cmd, args, opts = {}) {
  return execFileSync(cmd, args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
    timeout: opts.timeout ?? THRESHOLDS.GIT_TIMEOUT_MS,
    ...opts,
  });
}

function git(cwd, args) {
  return sh("git", ["-C", cwd, ...args]).trim();
}

function tryGit(cwd, args, fallback = null) {
  try {
    return git(cwd, args);
  } catch {
    return fallback;
  }
}

function readJson(path, fallback = null) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return fallback;
  }
}

// No pid = no proof the harness is running = dead (liveness fails closed).
function pidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 1) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err?.code === "EPERM";
  }
}

// ---------------------------------------------------------------------------
// Process table — the liveness oracle. One `ps` call per collect.
// ---------------------------------------------------------------------------
export function parseProcessTable(text) {
  const byPid = new Map();
  for (const line of String(text || "").split("\n")) {
    const m = /^\s*(\d+)\s+(\d+)\s+(.*)$/.exec(line);
    if (!m) continue;
    byPid.set(parseInt(m[1], 10), { pid: parseInt(m[1], 10), ppid: parseInt(m[2], 10), command: m[3].trim() });
  }
  return byPid;
}

export function collectProcesses() {
  return parseProcessTable(sh("ps", ["-axo", "pid=,ppid=,command="]));
}

// Same table without blocking the event loop (the daemon refreshes it in the
// background so a Claude Code edge is not held up by the fork).
export function collectProcessesAsync() {
  return new Promise((resolve, reject) => {
    execFile(
      "ps",
      ["-axo", "pid=,ppid=,command="],
      { encoding: "utf8", maxBuffer: 64 * 1024 * 1024, timeout: THRESHOLDS.GIT_TIMEOUT_MS },
      (err, stdout) => (err ? reject(err) : resolve(parseProcessTable(stdout))),
    );
  });
}

// The part of the process table the collector actually reads: harness
// processes and their ancestry. Two tables with the same signature classify
// every session the same way.
export function processSignature(byPid) {
  const keep = [];
  for (const p of byPid?.values() || []) {
    if (/claude|codex|omnigent/i.test(p.command)) keep.push(`${p.pid}:${p.ppid}`);
  }
  return keep.sort().join(",");
}

// True when the process itself is a channel listener (see CHANNEL_LISTENER_PATTERN).
export function isChannelListener(pid, byPid) {
  const p = byPid?.get(pid);
  return !!p && CHANNEL_LISTENER_PATTERN.test(p.command);
}

// True when any ancestor (or the process itself) was started by Omnigent.
export function isOmnigentDescendant(pid, byPid) {
  let cur = byPid?.get(pid);
  for (let hops = 0; cur && hops < 64; hops++) {
    if (OMNIGENT_PROCESS_PATTERN.test(cur.command)) return true;
    if (cur.ppid <= 1) return false;
    cur = byPid.get(cur.ppid);
  }
  return false;
}

export function processCwd(pid) {
  try {
    const out = sh("lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]);
    const line = out.split("\n").find((l) => l.startsWith("n"));
    return line ? line.slice(1).trim() : null;
  } catch {
    return null;
  }
}

export function ago(iso, now = Date.now()) {
  const then = typeof iso === "number" ? iso : Date.parse(iso);
  if (!Number.isFinite(then)) return "unknown";
  const secs = Math.max(0, Math.round((now - then) / 1000));
  if (secs < 60) return `${secs}s ago`;
  const mins = Math.round(secs / 60);
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 48) return `${hours}h ago`;
  return `${Math.floor(hours / 24)}d ago`;
}

function normPath(p) {
  return String(p || "").replace(/\/+$/, "");
}

// A session belongs to a thread when its cwd is the worktree or inside it.
export function cwdMatches(cwd, worktreePath) {
  const a = normPath(cwd);
  const b = normPath(worktreePath);
  return !!a && !!b && (a === b || a.startsWith(b + "/"));
}

// ---------------------------------------------------------------------------
// Source: git worktrees (the spine)
// ---------------------------------------------------------------------------
export function parseWorktreeList(porcelain) {
  const out = [];
  let cur = null;
  for (const line of String(porcelain).split("\n")) {
    if (line.startsWith("worktree ")) {
      cur = { path: line.slice(9).trim(), head: null, branch: null, detached: false };
      out.push(cur);
    } else if (!cur) {
      continue;
    } else if (line.startsWith("HEAD ")) {
      cur.head = line.slice(5).trim();
    } else if (line.startsWith("branch ")) {
      cur.branch = line.slice(7).trim().replace(/^refs\/heads\//, "");
    } else if (line.trim() === "detached") {
      cur.detached = true;
    }
  }
  return out;
}

export function collectWorktrees(repo) {
  const porcelain = git(repo, ["worktree", "list", "--porcelain"]);
  const list = parseWorktreeList(porcelain);
  const mainWorktree = list[0]?.path || repo;
  return { mainWorktree, worktrees: list };
}

export function gitFacts(wt) {
  const cwd = wt.path;
  const status = tryGit(cwd, ["status", "--porcelain", "--untracked-files=normal"], "");
  const dirtyFiles = status ? status.split("\n").filter(Boolean).length : 0;

  const upstream = tryGit(cwd, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]);
  const hasUpstream = !!upstream;

  let ahead = 0;
  let behind = 0;
  const lr = tryGit(cwd, ["rev-list", "--left-right", "--count", "origin/main...HEAD"]);
  if (lr) {
    const [b, a] = lr.split(/\s+/).map((n) => parseInt(n, 10));
    behind = Number.isFinite(b) ? b : 0;
    ahead = Number.isFinite(a) ? a : 0;
  }

  // Commits on this branch that its own upstream does not have yet.
  let unpushedCommits = ahead; // no upstream -> everything past main is unpushed
  if (hasUpstream) {
    const n = parseInt(tryGit(cwd, ["rev-list", "--count", "@{u}..HEAD"], "0"), 10);
    unpushedCommits = Number.isFinite(n) ? n : 0;
  }

  const lastCommitAt = tryGit(cwd, ["log", "-1", "--format=%cI"]) || null;

  return { ahead, behind, dirtyFiles, hasUpstream, unpushedCommits, lastCommitAt };
}

// ---------------------------------------------------------------------------
// Source: GitHub PRs — ONE gh call for the whole repo
// ---------------------------------------------------------------------------
const PR_RANK = { OPEN: 0, MERGED: 1, CLOSED: 2 };

// Newest OPEN PR wins, then newest MERGED, then newest CLOSED.
export function indexPrsByBranch(prs) {
  const byBranch = new Map();
  for (const pr of prs || []) {
    if (!pr?.headRefName) continue;
    const cur = byBranch.get(pr.headRefName);
    if (!cur) {
      byBranch.set(pr.headRefName, pr);
      continue;
    }
    const rc = (PR_RANK[pr.state] ?? 9) - (PR_RANK[cur.state] ?? 9);
    if (rc < 0 || (rc === 0 && pr.number > cur.number)) byBranch.set(pr.headRefName, pr);
  }
  return byBranch;
}

export function collectPrs(repo) {
  const raw = sh(
    "gh",
    [
      "pr",
      "list",
      "--state",
      "all",
      "--limit",
      "100",
      "--json",
      "number,headRefName,state,url,title,mergedAt,reviewDecision,isDraft",
    ],
    { cwd: repo, timeout: THRESHOLDS.GH_TIMEOUT_MS },
  );
  return JSON.parse(raw);
}

// ---------------------------------------------------------------------------
// Source: polly registry — review verdicts
// ---------------------------------------------------------------------------
export function indexRegistryByBranch(registry) {
  const byBranch = new Map();
  for (const task of registry?.tasks || []) {
    if (task?.branch) byBranch.set(task.branch, task);
  }
  return byBranch;
}

export function collectRegistry(mainWorktree) {
  const path = join(mainWorktree, ".polly", "registry.json");
  if (!existsSync(path)) throw new Error(`no registry at ${path}`);
  return JSON.parse(readFileSync(path, "utf8"));
}

// ---------------------------------------------------------------------------
// Source: Claude Code sessions (~/.claude/sessions + ~/.claude/agent-state)
// ---------------------------------------------------------------------------
// Every row carries `live` (its process is running now, and it is not an
// Omnigent-launched worker) and `child` (a sub-agent, never row-backing).
// Omnigent-launched Claude Code processes are dropped outright: the Omnigent
// session row is the same thing, and it should be listed once.
export function collectClaudeSessions(home = homedir(), { procs = null, alive = pidAlive } = {}) {
  const out = [];
  const seen = new Set();
  const byPid = procs ?? (() => { try { return collectProcesses(); } catch { return new Map(); } })();
  const omnigentLaunched = (row) =>
    (row.entrypoint && !CLAUDE_INTERACTIVE_ENTRYPOINTS.has(row.entrypoint)) || isOmnigentDescendant(row.pid, byPid);
  const isChild = (row) =>
    !!(row.parentSessionId || row.parent_session_id || row.isSidechain) || (row.kind && row.kind !== "interactive");

  const sessDir = join(home, ".claude", "sessions");
  let names = [];
  try {
    names = readdirSync(sessDir).filter((n) => n.endsWith(".json"));
  } catch {}
  for (const name of names) {
    const row = readJson(join(sessDir, name));
    if (!row?.cwd) continue;
    const id = row.sessionId || name.replace(/\.json$/, "");
    seen.add(id);
    if (!alive(row.pid)) continue; // harness quit: dead, and dead is invisible
    if (omnigentLaunched(row)) continue; // listed once, under its Omnigent row
    if (isChannelListener(row.pid, byPid)) continue; // a channel daemon, not a build thread
    out.push({
      harness: "claude",
      id,
      title: row.name || basename(row.cwd),
      status: row.status || "unknown",
      lastSeen: new Date(row.updatedAt || row.startedAt || 0).toISOString(),
      cwd: row.cwd,
      branch: null,
      live: true,
      child: isChild(row),
    });
  }

  // agent-state carries running/waiting/blocked from the hook; merge it in.
  const stateDir = join(home, ".claude", "agent-state");
  let stateNames = [];
  try {
    stateNames = readdirSync(stateDir).filter((n) => n.endsWith(".json"));
  } catch {}
  for (const name of stateNames) {
    const row = readJson(join(stateDir, name));
    if (!row?.cwd) continue;
    const existing = out.find((s) => s.id === row.session_id);
    if (existing) {
      if (row.state) existing.status = row.state;
      existing.branch = row.branch || existing.branch;
      continue;
    }
    if (seen.has(row.session_id)) continue; // registry knew it and rejected it
    if (!alive(row.pid)) continue;
    if (isOmnigentDescendant(row.pid, byPid)) continue;
    if (isChannelListener(row.pid, byPid)) continue;
    out.push({
      harness: "claude",
      id: row.session_id || name.replace(/\.json$/, ""),
      title: row.label || basename(row.cwd),
      status: row.state || "unknown",
      lastSeen: row.since || new Date(0).toISOString(),
      cwd: row.cwd,
      branch: row.branch || null,
      live: true,
      child: false, // the hook does not say; undeterminable -> keep
    });
  }
  return out;
}

// ---------------------------------------------------------------------------
// Source: Omnigent loopback API (optional)
// ---------------------------------------------------------------------------
// Accepts one page envelope ({ data: [...] }) or a bare row array. Archived
// rows are dropped here so nothing downstream ever sees them. Sub-agent rows
// (the list endpoint hides them today, but the detail shape has
// `parent_session_id` / `kind` / `sub_agent_name`) keep their parent id so
// buildThreads can roll them up under the parent instead of giving them a row.
// `live` comes from the row's own `runner_online` when the server sends it,
// else from the /v1/runners online set. With neither (runners endpoint down)
// only `status: running` counts as alive — a degraded guess, flagged in sources.
export function mapOmnigentSessions(payload, { onlineRunners = null } = {}) {
  const rows = Array.isArray(payload) ? payload : Array.isArray(payload?.data) ? payload.data : [];
  return rows
    .filter((r) => r && !r.archived && r.workspace)
    .map((r) => {
      const labels = r.labels && typeof r.labels === "object" ? r.labels : {};
      const err = r.last_task_error && typeof r.last_task_error === "object" ? r.last_task_error : {};
      const errorCode = String(labels["omnigent.last_task_error_code"] || err.code || "").trim();
      const errorTitle = String(
        labels["omnigent.last_task_error_title"] || err.title || labels["omnigent.last_task_error_message"] || err.message || "",
      ).trim();
      const parentId = r.parent_session_id || labels["omnigent.parent_session_id"] || null;
      const live =
        typeof r.runner_online === "boolean"
          ? r.runner_online
          : onlineRunners
            ? onlineRunners.has(r.runner_id)
            : String(r.status || "").toLowerCase() === "running";
      return {
        harness: "omnigent",
        id: r.id,
        title: r.title || r.agent_name || "omnigent",
        status: r.status || "unknown",
        // The list endpoint's status is a ROLL-UP: a parent reads "running"
        // while any sub-agent child is running, even if the parent's own turn
        // ended. Kept verbatim here; applyParentStatus overlays the parent's own
        // status when the caller knows it (SSE / detail endpoint).
        listStatus: r.status || "unknown",
        lastSeen: new Date((r.updated_at || r.created_at || 0) * 1000).toISOString(),
        cwd: r.workspace,
        branch: r.git_branch || null,
        agent: r.sub_agent_name || r.agent_name || null,
        parentId: parentId && parentId !== r.id ? parentId : null,
        child: !!(parentId && parentId !== r.id) || (r.kind && r.kind !== "default") || !!r.sub_agent_name,
        live,
        pendingInputs: Number(r.pending_elicitations_count) || 0,
        unread: r.viewer_unread === true,
        errorCode: errorCode || null,
        errorTitle: errorTitle || null,
      };
    });
}

async function fetchJson(url, timeoutMs) {
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

// Pages through every session. The envelope is { data, has_more, last_id };
// `?after=<last_id>` is the only cursor the server honours (page/offset/
// starting_after are ignored and return page one again).
export function parseRunners(payload) {
  const rows = Array.isArray(payload?.data) ? payload.data : Array.isArray(payload) ? payload : [];
  return new Set(rows.filter((r) => r && r.online === true && r.runner_id).map((r) => r.runner_id));
}

export async function collectOmnigentFull(url = OMNIGENT_URL, { fetchJson: fj = fetchJson, runnersUrl = null } = {}) {
  const base = new URL(url);
  const rUrl = runnersUrl ?? `${base.origin}/v1/runners`;
  let onlineRunners = null;
  let runners = "ok";
  try {
    onlineRunners = parseRunners(await fj(rUrl, THRESHOLDS.OMNIGENT_TIMEOUT_MS));
  } catch (e) {
    runners = `unavailable: ${String(e.message || e).split("\n")[0]}`;
  }
  const out = [];
  const seen = new Set();
  let after = null;
  for (let page = 0; page < Math.ceil(OMNIGENT_MAX_SESSIONS / OMNIGENT_PAGE_LIMIT) + 1; page++) {
    const u = new URL(url);
    u.searchParams.set("limit", String(OMNIGENT_PAGE_LIMIT));
    if (after) u.searchParams.set("after", after);
    const payload = await fj(u.toString(), THRESHOLDS.OMNIGENT_TIMEOUT_MS);
    const rows = Array.isArray(payload?.data) ? payload.data : [];
    for (const m of mapOmnigentSessions(rows, { onlineRunners })) {
      if (seen.has(m.id)) continue;
      seen.add(m.id);
      out.push(m);
    }
    const lastId = payload?.last_id || rows[rows.length - 1]?.id || null;
    if (!payload?.has_more || !rows.length || !lastId || lastId === after) break;
    if (out.length >= OMNIGENT_MAX_SESSIONS) break;
    after = lastId;
  }
  return { sessions: out.slice(0, OMNIGENT_MAX_SESSIONS), runners };
}

export async function collectOmnigent(url = OMNIGENT_URL, opts = {}) {
  return (await collectOmnigentFull(url, opts)).sessions;
}

// ---------------------------------------------------------------------------
// Parent-only status: an Omnigent chat row is
// "working" only while the PARENT agent is mid-turn. Sub-agent activity never
// keeps the parent shown as working — the parent going idle while children
// run is exactly the "waiting on you" moment worth surfacing.
//
// Omnigent's list feed (REST + WS) rolls children up into the parent's
// status, so the parent's own status has to come from elsewhere:
//   - GET /v1/sessions/{id}?include_items=false&include_liveness=false
//     (the detail endpoint reads the session's own cache entry, no roll-up)
//   - per-session SSE `session.status` events (the daemon's live edge source)
// Either way the caller ends up with a Map id -> own status and hands it to
// applyParentStatus. A roll-up that is NOT running is authoritative (own
// status cannot be running if the roll-up isn't), so the overlay only ever
// matters for rows whose list status is running.
// ---------------------------------------------------------------------------
// Omnigent's fine-grained statuses. `waiting` = the runner is inside a turn
// waiting on a tool / approval — still the agent's turn, so still working
// (Omnigent's own list collapses it the same way). Distinct from the Claude
// Code hook's `waiting`, which means the turn ended.
export function normalizeOmnigentStatus(status) {
  const s = String(status || "").toLowerCase();
  return s === "waiting" ? "running" : s || "unknown";
}

export function omnigentSessionDetailUrl(id, base = OMNIGENT_BASE) {
  return `${base}/v1/sessions/${id}?include_items=false&include_liveness=false`;
}

// Overlay the parent's own status onto rows whose list status is a roll-up.
  // `childActive` marks a parent that is idle while its sub-agents still run
  // (the list said running, the parent itself did not) so the row's detail can
  // say so. Rows the map does not know keep their list status.
  // parentStatusById values can be either a plain string (legacy) or { status, seq }.
  // A status of null/undefined means "baseline in flight, parent status unknown" —
  // we don't use the roll-up; instead we mark the row as unknown with childActive.
  export function applyParentStatus(sessions, parentStatusById) {
    if (!parentStatusById || typeof parentStatusById.get !== "function") return sessions;
    for (const s of sessions || []) {
      if (s.harness !== "omnigent" || s.child || s.parentId) continue;
      const ownEntry = parentStatusById.get(s.id);
      if (!ownEntry) continue;
      const own = typeof ownEntry === "string" ? ownEntry : ownEntry.status;
      const listRunning = ACTIVE_STATUSES.has(String(s.listStatus ?? s.status).toLowerCase());
      // The roll-up can only over-report "running"; a non-running roll-up wins.
      if (!listRunning) continue;
      // If parent status is unknown (baseline pending), don't use roll-up; mark unknown + childActive
      if (own === null || own === undefined) {
        s.status = "unknown";
        s.childActive = true;
        continue;
      }
      s.status = normalizeOmnigentStatus(own);
      s.childActive = !ACTIVE_STATUSES.has(s.status);
    }
    return sessions;
  }

// One-shot path: ask the detail endpoint for every running parent's own
// status, a few at a time. Each miss is silent (the row keeps its roll-up).
export async function resolveOmnigentParentStatus(
  sessions,
  { fetchJson: fj = fetchJson, base = OMNIGENT_BASE, concurrency = 6, timeoutMs = THRESHOLDS.OMNIGENT_TIMEOUT_MS } = {},
) {
  const out = new Map();
  const targets = (sessions || []).filter(
    (s) => s.harness === "omnigent" && s.live && !s.child && !s.parentId && ACTIVE_STATUSES.has(String(s.status).toLowerCase()),
  );
  let i = 0;
  const worker = async () => {
    while (i < targets.length) {
      const s = targets[i++];
      try {
        const d = await fj(omnigentSessionDetailUrl(s.id, base), timeoutMs);
        if (d && typeof d.status === "string") out.set(s.id, d.status);
      } catch {}
    }
  };
  await Promise.all(Array.from({ length: Math.min(concurrency, targets.length) }, worker));
  return out;
}

// The Omnigent web UI addresses a chat at /c/<session id>.
export function omnigentSessionUrl(id, base = OMNIGENT_BASE) {
  return id ? `${base}/c/${id}` : null;
}

// The Omnigent desktop app (/Applications/Omnigent.app, bundle ai.omnigent.desktop)
// registers the `omnigent://` URL scheme; the same chat is
// `omnigent://<host>:<port>/c/<session id>` (port required). Host and port come
// from OMNIGENT_BASE so they are configured once; the app wants `localhost`
// where the HTTP base says 127.0.0.1.
export const OMNIGENT_SCHEME = "omnigent";
export function omnigentDeepLink(id, base = OMNIGENT_BASE) {
  if (!id) return null;
  const u = new URL(base);
  const host = u.hostname === "127.0.0.1" ? "localhost" : u.hostname;
  const port = u.port || (u.protocol === "https:" ? "443" : "80");
  return `${OMNIGENT_SCHEME}://${host}:${port}/c/${id}`;
}

// ---------------------------------------------------------------------------
// Source: Codex thread index (optional, node:sqlite read-only)
// ---------------------------------------------------------------------------
// Codex stores no pid. A thread is live iff a `codex` TUI process (not
// Omnigent-launched) has its cwd in the thread's cwd; the newest such thread
// per cwd is the one that process is showing, the rest are history.
export function mapCodexThreads(rows, { liveCwds = [] } = {}) {
  const claimed = new Set();
  return (rows || [])
    .filter((r) => r && r.cwd)
    .sort((a, b) => (b.updated_at_ms || (b.updated_at || 0) * 1000) - (a.updated_at_ms || (a.updated_at || 0) * 1000))
    .map((r) => {
      const cwd = liveCwds.find((c) => cwdMatches(c, r.cwd) || cwdMatches(r.cwd, c));
      const live = !!cwd && !claimed.has(cwd);
      if (live) claimed.add(cwd);
      return {
        harness: "codex",
        id: r.id,
        title: (r.name || r.title || r.first_user_message || "codex").split("\n")[0].slice(0, 80),
        status: live ? "running" : "unknown", // codex keeps no turn status; a live TUI is "on it"
        lastSeen: new Date(r.updated_at_ms || (r.updated_at || 0) * 1000).toISOString(),
        cwd: r.cwd,
        branch: r.git_branch || null,
        live,
        child: false,
      };
    });
}

export function codexLiveCwds(byPid, cwdOf = processCwd) {
  const out = [];
  for (const p of byPid?.values() || []) {
    if (!CODEX_TUI_PATTERN.test(p.command)) continue;
    if (isOmnigentDescendant(p.pid, byPid)) continue;
    const cwd = cwdOf(p.pid);
    if (cwd) out.push(cwd);
  }
  return out;
}

export async function collectCodex(home = homedir(), { procs = null } = {}) {
  const byPid = procs ?? (() => { try { return collectProcesses(); } catch { return new Map(); } })();
  const liveCwds = codexLiveCwds(byPid);
  const dir = join(home, ".codex");
  const dbs = readdirSync(dir)
    .filter((n) => /^state_\d+\.sqlite$/.test(n))
    .sort((a, b) => parseInt(b.match(/\d+/)[0], 10) - parseInt(a.match(/\d+/)[0], 10));
  if (!dbs.length) throw new Error("no codex state db");
  const { DatabaseSync } = await import("node:sqlite");
  const db = new DatabaseSync(join(dir, dbs[0]), { readOnly: true });
  try {
    const rows = db
      .prepare(
        `SELECT id, cwd, git_branch, title, name, first_user_message, updated_at, updated_at_ms
           FROM threads WHERE archived = 0 ORDER BY updated_at DESC LIMIT 300`,
      )
      .all();
    return mapCodexThreads(rows, { liveCwds });
  } finally {
    db.close();
  }
}

// ---------------------------------------------------------------------------
// State machine — first match wins, in this order.
// ---------------------------------------------------------------------------
export function deriveState({ git: g, pr, registryStatus, sessions }, now = Date.now()) {
  const merged = pr?.state === "MERGED";
  const reviewReady = !!(registryStatus && REGISTRY_READY_PATTERN.test(registryStatus));

  const lastCommitMs = g?.lastCommitAt ? Date.parse(g.lastCommitAt) : NaN;
  const daysSinceCommit = Number.isFinite(lastCommitMs)
    ? (now - lastCommitMs) / 86_400_000
    : Infinity;

  const activeCutoff = now - THRESHOLDS.ACTIVE_SESSION_MINUTES * 60_000;
  const isActive = (s) => {
    if (ACTIVE_STATUSES.has(String(s.status || "").toLowerCase())) return true;
    const t = Date.parse(s.lastSeen);
    return Number.isFinite(t) && t >= activeCutoff;
  };
  const hasActiveSession = (sessions || []).some(isActive);

  let state;
  let detail;
  if (
    !merged &&
    ((g?.behind ?? 0) > THRESHOLDS.STALE_BEHIND_COMMITS ||
      daysSinceCommit >= THRESHOLDS.STALE_NO_COMMIT_DAYS)
  ) {
    state = "stale";
    const parts = [];
    if ((g?.behind ?? 0) > THRESHOLDS.STALE_BEHIND_COMMITS) parts.push(`${g.behind} commits behind main`);
    if (daysSinceCommit >= THRESHOLDS.STALE_NO_COMMIT_DAYS)
      parts.push(
        Number.isFinite(daysSinceCommit)
          ? `last commit ${Math.floor(daysSinceCommit)} days ago`
          : "no commits found",
      );
    detail = parts.join(", ");
  } else if ((g?.dirtyFiles ?? 0) > 0) {
    state = "uncommitted";
    detail = `${g.dirtyFiles} changed file${g.dirtyFiles === 1 ? "" : "s"} not committed`;
  } else if ((g?.unpushedCommits ?? 0) > 0) {
    state = "unpushed";
    detail = !g?.hasUpstream
      ? `branch has never been pushed (${g?.ahead ?? 0} commit${g?.ahead === 1 ? "" : "s"} past main)`
      : `${g.unpushedCommits} commit${g.unpushedCommits === 1 ? "" : "s"} not on GitHub yet`;
  } else if (pr?.state === "OPEN") {
    state = "pr-open";
    detail = reviewReady
      ? `PR #${pr.number} reviewed and ready — your merge is the last step`
      : `PR #${pr.number} open, no reviewer has signed off yet`;
  } else if (merged) {
    state = "merged";
    detail = `PR #${pr.number} merged ${ago(pr.mergedAt, now)}`;
  } else if (hasActiveSession) {
    state = "active";
    const s = sessions.find(isActive);
    detail = `${s.harness} session ${s.status}, seen ${ago(s.lastSeen, now)}`;
  } else {
    state = "idle";
    detail = pr
      ? `PR #${pr.number} ${pr.state.toLowerCase()}`
      : !g?.hasUpstream
        ? "fresh worktree, no commits yet"
        : "pushed, no PR yet";
  }

  const stateLabel =
    state === "pr-open" && reviewReady ? STATE_LABELS["pr-open-ready"] : STATE_LABELS[state];

  return { state, stateLabel, detail, reviewReady };
}

// ---------------------------------------------------------------------------
// Thread display name — a person reads this, so a hash is never acceptable.
//   PR title > branch (unless main/master or an auto-name) > newest session
//   title (Claude Code sessions default their title to the dir basename, so
//   auto-names are skipped; a slash-command "title" like "/model x" is used
//   only when nothing better exists) > dir basename.
// The thread id stays the branch / path so notifications never re-fire on a
// rename.
// ---------------------------------------------------------------------------
const SLASH_COMMAND_TITLE = /^\/[a-z]/i;
const AUTO_TITLE_PATTERN = /^(worktree-[0-9a-f]{6,}|session[\/-][a-z0-9]+)/i;

export function isAutoBranch(branch) {
  return !!branch && AUTO_BRANCH_PATTERN.test(branch);
}

// Root sessions (no parent) outrank sub-agents: a chat is named by what you
// asked, not by the newest helper the agent spawned.
export function pickSessionTitle(sessions) {
  const sorted = [...(sessions || [])].sort(
    (a, b) => (a.parentId ? 1 : 0) - (b.parentId ? 1 : 0) || Date.parse(b.lastSeen) - Date.parse(a.lastSeen),
  );
  let fallback = null;
  for (const s of sorted) {
    const t = String(s?.title || "").trim();
    if (!t || AUTO_TITLE_PATTERN.test(t)) continue;
    if (!SLASH_COMMAND_TITLE.test(t)) return t;
    fallback ??= t;
  }
  return fallback;
}

export function threadName({ pr, branch, sessions, dir }) {
  const prTitle = String(pr?.title || "").trim();
  if (prTitle) return prTitle;
  if (branch && !HOME_BRANCHES.has(branch) && !isAutoBranch(branch)) return branch;
  return pickSessionTitle(sessions) || (dir ? basename(dir) : null) || branch || "untitled";
}

// State for a live row. First match wins:
//   needs-input  a pending question, an unread reply, or a PR reviewed and
//                waiting on your merge
//   blocked      last_task_error_code / failed session, or a rotted branch
//   active       the PARENT harness is mid-turn (running / busy). A sub-agent
//                running while its parent rests never makes the row active —
//                the parent resting is the "waiting on you" signal.
//   idle         live but resting
// Git facts (dirty / unpushed) only decorate the detail — they never change
// the state of a live row, because a live agent is expected to be mid-work.
export function isParentSession(s) {
  return !!s && !s.child && !s.parentId;
}

export function deriveLiveState({ sessions, git: g, pr, registryStatus }, now = Date.now()) {
  const list = [...(sessions || [])].sort((a, b) => Date.parse(b.lastSeen) - Date.parse(a.lastSeen));
  const lower = (s) => String(s.status || "").toLowerCase();
  const reviewReady = !!(pr?.state === "OPEN" && registryStatus && REGISTRY_READY_PATTERN.test(registryStatus));
  const who = (s) => s.agent || s.harness || "agent";

  const asking = list.find((s) => (s.pendingInputs ?? 0) > 0 || lower(s) === "blocked");
  if (asking) {
    return { state: "needs-input", reviewReady, detail: `${who(asking)} asked a question ${ago(asking.lastSeen, now)}` };
  }
  const unread = list.find((s) => s.unread);
  if (unread) {
    return { state: "needs-input", reviewReady, detail: `unread reply from ${who(unread)}, ${ago(unread.lastSeen, now)}` };
  }
  if (reviewReady) {
    return { state: "needs-input", reviewReady, detail: `PR #${pr.number} reviewed and ready — your merge is the last step` };
  }
  const failed = list.find((s) => s.errorCode || lower(s) === "failed");
  if (failed) {
    const reason = failed.errorTitle || failed.errorCode || "session failed";
    return { state: "blocked", reviewReady, detail: reason, reason };
  }
  const lastCommitMs = g?.lastCommitAt ? Date.parse(g.lastCommitAt) : NaN;
  const daysSinceCommit = Number.isFinite(lastCommitMs) ? (now - lastCommitMs) / 86_400_000 : NaN;
  if (pr?.state !== "MERGED" && (g?.behind ?? 0) > THRESHOLDS.STALE_BEHIND_COMMITS) {
    const reason = `branch is ${g.behind} commits behind main`;
    return { state: "blocked", reviewReady, detail: reason, reason };
  }
  if (pr?.state !== "MERGED" && daysSinceCommit >= THRESHOLDS.STALE_NO_COMMIT_DAYS) {
    const reason = `last commit ${Math.floor(daysSinceCommit)} days ago`;
    return { state: "blocked", reviewReady, detail: reason, reason };
  }
  const running = list.find((s) => isParentSession(s) && ACTIVE_STATUSES.has(lower(s)));
  if (running) {
    return { state: "active", reviewReady, detail: `${who(running)} mid-turn, seen ${ago(running.lastSeen, now)}` };
  }
  const newest = list[0];
  const childBusy = list.find((s) => s.childActive || (!isParentSession(s) && ACTIVE_STATUSES.has(lower(s))));
  const childNote = childBusy ? " (sub-agents still running)" : "";
  const gitNote =
    (g?.dirtyFiles ?? 0) > 0
      ? `, ${g.dirtyFiles} file${g.dirtyFiles === 1 ? "" : "s"} not committed`
      : (g?.unpushedCommits ?? 0) > 0
        ? `, ${g.unpushedCommits} commit${g.unpushedCommits === 1 ? "" : "s"} not pushed`
        : pr?.state === "OPEN"
          ? `, PR #${pr.number} open`
          : "";
  return {
    state: "idle",
    reviewReady,
    detail: (newest ? `${who(newest)} idle, last activity ${ago(newest.lastSeen, now)}` : "idle") + childNote + gitNote,
  };
}

// Kept for callers that only have Omnigent sessions in hand.
export function deriveOmnigentState(sessions, now = Date.now()) {
  return deriveLiveState({ sessions }, now);
}

// Key the notifier diffs on — pr-open splits by review readiness because
// "review just passed" is the moment that matters.
export function stateKey(thread) {
  if (thread.state === "pr-open") return `pr-open:${thread.reviewReady ? "ready" : "unreviewed"}`;
  if (thread.state === "needs-input" && thread.reviewReady) return "needs-input:pr-ready";
  return thread.state;
}

export function buildActions(thread) {
  const actions = [];
  if (thread.worktreePath) {
    actions.push({ label: "Open terminal here", command: `open -a Terminal "${thread.worktreePath}"` });
  }
  if (thread.pr?.url) actions.push({ label: "Open PR in browser", command: `open "${thread.pr.url}"` });
  if (thread.omnigentDeepLink) actions.push({ label: "Open chat in Omnigent", command: `open "${thread.omnigentDeepLink}"` });
  if (thread.omnigentUrl) actions.push({ label: "Open chat in browser", command: `open "${thread.omnigentUrl}"` });
  if (thread.state === "merged" && thread.branch) {
    actions.push({
      label: "Delete this worktree (safe, already merged)",
      command: `git worktree remove "${thread.worktreePath}" && git branch -d "${thread.branch}"`,
    });
  }
  if (thread.state === "stale" || thread.state === "unpushed") {
    actions.push({ label: "Catch up with main", command: "git pull --rebase origin main" });
  }
  return actions;
}

// ---------------------------------------------------------------------------
// Assembly — pure: takes already-collected source data, returns threads.
// ---------------------------------------------------------------------------
function capPerHarness(sorted) {
  const perHarness = {};
  return sorted.filter((s) => {
    const cap = MAX_SESSIONS_PER_HARNESS[s.harness] ?? MAX_SESSIONS_PER_HARNESS.default;
    perHarness[s.harness] = (perHarness[s.harness] || 0) + 1;
    return perHarness[s.harness] <= cap;
  });
}

// `child` rides along so Navi can tell a sub-agent's status from the parent's
// without re-deriving the tree.
const publicSession = ({ harness, id, title, status, lastSeen, child, parentId }) => ({
  harness,
  id,
  title,
  status,
  lastSeen,
  child: !!(child || parentId),
});

// Idle decoration for a live row. `lastSeen` is the newest session activity;
// `idle` is true when the row is resting AND that activity is older than
// ACTIVE_SESSION_MINUTES. Idle rows stay listed (a resting chat is still a
// chat) — Navi dims them and sorts them after active rows.
export function liveness(sessions, state, now = Date.now()) {
  const times = (sessions || []).map((s) => Date.parse(s.lastSeen)).filter(Number.isFinite);
  const newest = times.length ? Math.max(...times) : null;
  const lastSeen = newest === null ? null : new Date(newest).toISOString();
  const idle = state === "idle" && (newest === null || now - newest > THRESHOLDS.ACTIVE_SESSION_MINUTES * 60_000);
  return { lastSeen, idle };
}

// A session backs a row when its harness process is running now and it is
// a parent (not a sub-agent). Everything else is history.
export function isLiveParent(s) {
  return !!s && s.live === true && !s.child && !s.parentId;
}

export function buildThreads({ worktrees, gitByPath, prs, registry, sessions }, now = Date.now()) {
  const prByBranch = indexPrsByBranch(prs);
  const regByBranch = indexRegistryByBranch(registry);
  const threads = [];
  const dormant = [];
  const all = (sessions || []).filter((s) => s && s.id);

  // A sub-agent lives wherever its parent lives: match on the root of the
  // parent chain so a child never lands in a different thread (or its own row).
  const byId = new Map(all.map((s) => [s.id, s]));
  const rootOf = (s) => {
    let cur = s;
    const seen = new Set();
    while (cur?.parentId && byId.has(cur.parentId) && !seen.has(cur.id)) {
      seen.add(cur.id);
      cur = byId.get(cur.parentId);
    }
    return cur;
  };
  const attached = new Set();
  const prRow = (pr) => (pr ? { number: pr.number, url: pr.url, title: pr.title, state: pr.state } : null);

  for (const wt of worktrees || []) {
    if (wt.branch && HOME_BRANCHES.has(wt.branch)) continue;
    const g = gitByPath[wt.path] || {};
    const pr = wt.branch ? prByBranch.get(wt.branch) || null : null;
    const reg = wt.branch ? regByBranch.get(wt.branch) : null;

    const mine = all.filter((s) => {
      const r = rootOf(s);
      return cwdMatches(r.cwd, wt.path) || (wt.branch && r.branch && r.branch === wt.branch);
    });
    for (const s of mine) attached.add(s.id);
    mine.sort((a, b) => Date.parse(b.lastSeen) - Date.parse(a.lastSeen));
    const live = mine.filter((s) => isLiveParent(rootOf(s)));
    const name = threadName({ pr, branch: wt.branch, sessions: mine, dir: wt.path });
    const git = {
      ahead: g.ahead ?? 0,
      behind: g.behind ?? 0,
      dirtyFiles: g.dirtyFiles ?? 0,
      hasUpstream: !!g.hasUpstream,
      unpushedCommits: g.unpushedCommits ?? 0,
      lastCommitAt: g.lastCommitAt ?? null,
    };

    if (!live.length) {
      // Nobody live here: git-only facts for Raycast / phone, invisible to Navi.
      const derived = deriveState({ git: g, pr, registryStatus: reg?.status || null, sessions: [] }, now);
      dormant.push({
        id: wt.branch || wt.path,
        name,
        worktreePath: wt.path,
        branch: wt.branch,
        state: derived.state,
        stateLabel: derived.stateLabel,
        detail: derived.detail,
        reviewReady: derived.reviewReady,
        pr: prRow(pr),
        git,
      });
      continue;
    }

    const kept = capPerHarness(live);
    const derived = deriveLiveState({ sessions: kept, git: g, pr, registryStatus: reg?.status || null }, now);
    const thread = {
      id: wt.branch || wt.path,
      name,
      worktreePath: wt.path,
      branch: wt.branch,
      state: derived.state,
      stateLabel: derived.state === "idle" ? LIVE_IDLE_LABEL : STATE_LABELS[derived.state],
      detail: derived.detail,
      reason: derived.reason ?? null,
      reviewReady: derived.reviewReady,
      pr: prRow(pr),
      omnigentUrl: (() => {
        const om = kept.find((s) => s.harness === "omnigent");
        return om ? omnigentSessionUrl(om.id) : null;
      })(),
      omnigentDeepLink: (() => {
        const om = kept.find((s) => s.harness === "omnigent");
        return om ? omnigentDeepLink(om.id) : null;
      })(),
      ...liveness(kept, derived.state, now),
      sessions: kept.map(publicSession),
      git,
      actions: [],
    };
    thread.actions = buildActions(thread);
    threads.push(thread);
  }

  // Live parent sessions with no worktree of their own (most polly / assistant
  // chats run in the main checkout, a Claude Code TUI in the main checkout,
  // a Codex TUI in another repo): one row per root session.
  const groups = new Map();
  for (const s of all) {
    if (attached.has(s.id)) continue;
    const root = rootOf(s);
    if (attached.has(root.id) || !isLiveParent(root)) continue;
    if (!groups.has(root.id)) groups.set(root.id, { root, members: [] });
    groups.get(root.id).members.push(s);
  }
  for (const { root, members } of groups.values()) {
    members.sort((a, b) => Date.parse(b.lastSeen) - Date.parse(a.lastSeen));
    const branch = root.branch || null;
    const pr = branch && !HOME_BRANCHES.has(branch) ? prByBranch.get(branch) || null : null;
    const reg = branch ? regByBranch.get(branch) : null;
    const derived = deriveLiveState({ sessions: members, pr, registryStatus: reg?.status || null }, now);
    const thread = {
      id: `${root.harness}:${root.id}`,
      name: threadName({ pr, branch: null, sessions: [root, ...members], dir: root.cwd }),
      worktreePath: null,
      workspacePath: root.cwd || null,
      branch,
      state: derived.state,
      stateLabel: derived.state === "idle" ? CHAT_IDLE_LABEL : STATE_LABELS[derived.state],
      detail: derived.detail,
      reason: derived.reason ?? null,
      reviewReady: derived.reviewReady,
      pr: prRow(pr),
      omnigentUrl: root.harness === "omnigent" ? omnigentSessionUrl(root.id) : null,
      omnigentDeepLink: root.harness === "omnigent" ? omnigentDeepLink(root.id) : null,
      ...liveness(members, derived.state, now),
      sessions: capPerHarness(members).map(publicSession),
      git: null,
      actions: [],
    };
    thread.actions = buildActions(thread);
    threads.push(thread);
  }

  const ORDER = { "needs-input": 0, blocked: 1, active: 2, idle: 3 };
  // state, then active before idle, then most recent activity, then name
  const seenMs = (t) => (t.lastSeen ? Date.parse(t.lastSeen) : 0) || 0;
  threads.sort(
    (a, b) =>
      (ORDER[a.state] ?? 9) - (ORDER[b.state] ?? 9) ||
      Number(!!a.idle) - Number(!!b.idle) ||
      seenMs(b) - seenMs(a) ||
      a.name.localeCompare(b.name),
  );

  const DORMANT_ORDER = { stale: 0, "pr-open": 1, uncommitted: 2, unpushed: 3, merged: 4, active: 5, idle: 6 };
  dormant.sort((a, b) => {
    if (a.state === "pr-open" && b.state === "pr-open" && a.reviewReady !== b.reviewReady) return a.reviewReady ? -1 : 1;
    return (DORMANT_ORDER[a.state] ?? 9) - (DORMANT_ORDER[b.state] ?? 9) || a.name.localeCompare(b.name);
  });
  threads.dormant = dormant;
  return threads;
}

// ---------------------------------------------------------------------------
// Collect everything (each source independently fallible)
// ---------------------------------------------------------------------------
const unavailable = (e) => `unavailable: ${String(e?.message || e).split("\n")[0]}`;

// The git / PR / registry portion: every fork of git and gh happens here and
// nowhere else, so the daemon can cache the result and refresh it on its own
// slow cadence. `branchForCwd` answers "what branch is this plain checkout
// on" for sessions that report no git_branch (memoized — one git fork per
// unknown cwd per bundle).
export function collectGitSources(repo = DEFAULT_REPO) {
  const sources = {};
  if (!repo) {
    // No NAVI_REPO: no worktree / PR rows, but every live agent session still
    // gets a row of its own (and its branch is still read from its checkout).
    const branchByCwd = new Map();
    const branchForCwd = (cwd) => {
      if (!cwd) return null;
      const key = normPath(cwd);
      if (!branchByCwd.has(key)) branchByCwd.set(key, tryGit(cwd, ["rev-parse", "--abbrev-ref", "HEAD"]) || null);
      return branchByCwd.get(key) || null;
    };
    sources.git = "not configured (set NAVI_REPO)";
    return { mainWorktree: null, worktrees: [], gitByPath: {}, prs: [], registry: null, sources, branchForCwd, collectedAt: Date.now() };
  }
  const { mainWorktree, worktrees } = collectWorktrees(repo); // git is the spine when configured; this one may throw
  sources.git = "ok";

  const gitByPath = {};
  for (const wt of worktrees) gitByPath[wt.path] = gitFacts(wt);

  let prs = [];
  try {
    prs = collectPrs(mainWorktree);
    sources.gh = "ok";
  } catch (e) {
    sources.gh = unavailable(e);
  }

  let registry = null;
  try {
    registry = collectRegistry(mainWorktree);
    sources.registry = "ok";
  } catch (e) {
    sources.registry = unavailable(e);
  }

  const branchByCwd = new Map(worktrees.map((wt) => [normPath(wt.path), wt.branch]));
  const branchForCwd = (cwd) => {
    if (!cwd) return null;
    const key = normPath(cwd);
    if (!branchByCwd.has(key)) {
      branchByCwd.set(key, tryGit(cwd, ["rev-parse", "--abbrev-ref", "HEAD"]) || null);
    }
    return branchByCwd.get(key) || null;
  };

  return { mainWorktree, worktrees, gitByPath, prs, registry, sources, branchForCwd, collectedAt: Date.now() };
}

// A session in a plain checkout (main, another repo) reports no git_branch;
// read it from the checkout so the row can still find its PR.
function fillBranches(sessions, branchForCwd) {
  for (const s of sessions) {
    if (s.branch || !s.cwd) continue;
    s.branch = branchForCwd(s.cwd);
  }
}

// `sources` lets a long-lived caller hand in what it already holds; anything
// omitted is collected fresh, exactly as the one-shot path does:
//   git       a collectGitSources() bundle
//   procs     a process table (collectProcesses())
//   omnigent  { sessions, runners } as collectOmnigentFull() returns
//   codex     mapped codex threads
//   usage     { usage, usagePolledAt, status } from an earlier snapshot
// `parentStatusById` overlays Omnigent parents' own status (see
// applyParentStatus); `resolveParentStatus` (one-shot default) asks the detail
// endpoint for any running parent the map does not cover.
export async function collect({
  repo = DEFAULT_REPO,
  home = homedir(),
  omnigentUrl = OMNIGENT_URL,
  usage = process.env.NAVI_NO_USAGE !== "1",
  sources: given = {},
  parentStatusById = null,
  resolveParentStatus = true,
} = {}) {
  const now = Date.now();

  const g = given.git ?? collectGitSources(repo);
  const { mainWorktree, worktrees, gitByPath, prs, registry, branchForCwd } = g;
  const sources = { ...g.sources };

  let procs = given.procs ?? null;
  if (procs) {
    sources.ps = "ok";
  } else {
    try {
      procs = collectProcesses();
      sources.ps = "ok";
    } catch (e) {
      procs = new Map();
      sources.ps = unavailable(e);
    }
  }

  let sessions = [];
  try {
    sessions.push(...collectClaudeSessions(home, { procs }));
    sources.claude = "ok";
  } catch (e) {
    sources.claude = unavailable(e);
  }
  try {
    if (given.omnigent?.error) throw new Error(given.omnigent.error.replace(/^unavailable:\s*/, ""));
    const { sessions: om, runners } = given.omnigent ?? (await collectOmnigentFull(omnigentUrl));
    if (runners !== "ok") sources.omnigentRunners = runners;
    // Never mutate a caller's cached rows: the overlay below is per-collect.
    const rows = om.map((s) => ({ ...s }));
    fillBranches(rows, branchForCwd);
    const overlay = new Map(parentStatusById ? [...parentStatusById] : []);
    if (resolveParentStatus) {
      const base = new URL(omnigentUrl).origin;
      const pending = rows.filter((s) => !overlay.has(s.id));
      for (const [id, st] of await resolveOmnigentParentStatus(pending, { base })) overlay.set(id, st);
    }
    applyParentStatus(rows, overlay);
    sessions.push(...rows);
    sources.omnigent = "ok";
  } catch (e) {
    sources.omnigent = unavailable(e);
  }
  try {
    sessions.push(...(given.codex ?? (await collectCodex(home, { procs }))));
    sources.codex = "ok";
  } catch (e) {
    sources.codex = unavailable(e);
  }

  const threads = buildThreads({ worktrees, gitByPath, prs, registry, sessions }, now);
  const dormant = threads.dormant || [];
  delete threads.dormant;
  const snapshot = { generatedAt: new Date(now).toISOString(), repo: mainWorktree, sources, threads, dormant };

  // Quota usage for Navi's last menu page. Each source is non-fatal inside
  // usage.mjs; this guard only covers the cache file itself.
  if (given.usage) {
    snapshot.usage = given.usage.usage;
    snapshot.usagePolledAt = given.usage.usagePolledAt;
    if (given.usage.status) sources.usage = given.usage.status;
  } else if (usage) {
    try {
      const u = await collectUsageWithCache({ now });
      snapshot.usage = u.usage;
      snapshot.usagePolledAt = u.usagePolledAt;
      const errored = u.usage.filter((r) => r.error).map((r) => r.harness);
      sources.usage = errored.length ? `partial: ${errored.join(", ")}` : "ok";
    } catch (e) {
      sources.usage = unavailable(e);
    }
  }
  return snapshot;
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------
export function writeSnapshot(snapshot, { outFile = OUT_FILE, prevFile = PREV_FILE } = {}) {
  mkdirSync(dirname(outFile), { recursive: true });
  if (existsSync(outFile)) {
    try {
      renameSync(outFile, prevFile);
    } catch {}
  }
  const tmp = `${outFile}.tmp`;
  writeFileSync(tmp, JSON.stringify(snapshot, null, 2) + "\n");
  renameSync(tmp, outFile);
}

const GLYPH = {
  stale: "!",
  uncommitted: "~",
  unpushed: "^",
  "pr-open": "?",
  merged: "✓",
  active: "●",
  idle: "○",
  "needs-input": "?",
  blocked: "!",
};

function pad(s, n) {
  s = String(s ?? "");
  return s.length >= n ? s.slice(0, n) : s + " ".repeat(n - s.length);
}

export function renderTable(snapshot) {
  const useColor = process.stdout.isTTY && !process.env.NO_COLOR;
  const c = (code) => (useColor ? code : "");
  const COLOR = {
    stale: c("\x1b[31m"),
    "pr-open": c("\x1b[33m"),
    uncommitted: c("\x1b[35m"),
    unpushed: c("\x1b[35m"),
    merged: c("\x1b[32m"),
    active: c("\x1b[36m"),
    idle: c("\x1b[90m"),
    "needs-input": c("\x1b[33m"),
    blocked: c("\x1b[31m"),
  };
  const DIM = c("\x1b[2m");
  const RESET = c("\x1b[0m");

  if (!snapshot.threads.length) {
    const d = snapshot.dormant?.length || 0;
    return `No live sessions.${d ? ` ${d} dormant thread${d === 1 ? "" : "s"} (worktrees / PRs with nobody on them) in the JSON.` : ""}\n`;
  }

  const nameW = Math.min(28, Math.max(10, ...snapshot.threads.map((t) => t.name.length)));
  const labelW = Math.max(...snapshot.threads.map((t) => t.stateLabel.length));
  const lines = snapshot.threads.map((t) => {
    const hue = COLOR[t.state] ?? "";
    const prCol = t.pr ? `#${t.pr.number}` : "-";
    return (
      `${hue}${GLYPH[t.state] ?? "?"}${RESET} ${pad(t.name, nameW)} ` +
      `${hue}${pad(t.stateLabel, labelW)}${RESET} ${pad(prCol, 5)} ${DIM}${t.detail}${RESET}`
    );
  });

  const needsYou = snapshot.threads.filter(
    (t) =>
      t.state === "stale" ||
      (t.state === "pr-open" && t.reviewReady) ||
      t.state === "merged" ||
      t.state === "needs-input" ||
      t.state === "blocked",
  ).length;
  const down = Object.entries(snapshot.sources)
    .filter(([, v]) => v !== "ok")
    .map(([k]) => k);
  const dormantN = snapshot.dormant?.length || 0;
  const footer =
    `${DIM}${snapshot.threads.length} live, ${needsYou} need you` +
    (dormantN ? ` · ${dormantN} dormant` : "") +
    (down.length ? ` · sources unavailable: ${down.join(", ")}` : "") +
    `${RESET}`;
  const usageBlock = snapshot.usage?.length ? `\n${DIM}quota usage${RESET}\n${renderUsage(snapshot.usage)}` : "";
  return `${lines.join("\n")}\n${footer}\n${usageBlock}`;
}

async function main() {
  const args = new Set(process.argv.slice(2));
  let snapshot;
  if (args.has("--cached") && existsSync(OUT_FILE)) {
    snapshot = readJson(OUT_FILE);
  }
  if (!snapshot) {
    snapshot = await collect();
    if (!args.has("--no-write")) writeSnapshot(snapshot);
  }

  if (args.has("--json")) {
    process.stdout.write(JSON.stringify(snapshot, null, 2) + "\n");
  } else if (args.has("--table")) {
    process.stdout.write(renderTable(snapshot));
  } else {
    process.stdout.write(
      `${snapshot.threads.length} build threads written to ${OUT_FILE}\n`,
    );
  }
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  main().catch((err) => {
    process.stderr.write(`navi collect failed: ${err?.message || err}\n`);
    process.exit(1);
  });
}
