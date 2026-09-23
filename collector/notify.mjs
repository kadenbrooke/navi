#!/usr/bin/env node
// Navi notifier — tells you ONLY when a thread's status changes.
//
//   node notify.mjs            diff threads.json against what was last announced, deliver
//   node notify.mjs --dry-run  print the lines, deliver nothing, don't record
//
// Delivery:
//   every change    -> macOS notification (osascript display notification)
//   needs-you only  -> ALSO your own hook, if NAVI_NOTIFY_CMD is set (a PR that
//                      passed review, or a thread gone stale). It runs as
//                      `/bin/sh -c "$NAVI_NOTIFY_CMD" navi-notify "<line>"`, so the
//                      line is "$1" — e.g. NAVI_NOTIFY_CMD='my-pager "$1"'.
//
// Never notifies on active <-> idle flapping — an agent pausing and resuming
// is not news. A row that vanishes (its harness quit) is silent too: diffStates
// only walks the rows in the current snapshot, and notified.json forgets the
// id, so "session ended" is never a ping and a later restart reads as a fresh
// first sighting. The "last announced" state lives in notified.json next to
// the snapshot, so running notify twice (or collect twice between notifies)
// never double-sends.

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { pathToFileURL } from "node:url";
import { stateKey } from "./collect.mjs";
import { NOTIFIED_FILE, OUT_FILE } from "./paths.mjs";

export { NOTIFIED_FILE };

// Transitions between these two are noise, never announced.
export const QUIET_STATES = new Set(["active", "idle"]);

// Entering one of these means you have to do something -> NAVI_NOTIFY_CMD too.
// Live rows use needs-input:pr-ready (a reviewed PR waiting on the merge);
// pr-open:ready / stale are the dormant-era keys, kept so an old notified.json
// still diffs cleanly.
export const NEEDS_YOU_KEYS = new Set(["needs-input:pr-ready", "pr-open:ready", "stale"]);

// ---------------------------------------------------------------------------
// Pure diff — tested directly.
// ---------------------------------------------------------------------------
// prev: { [threadId]: stateKey } as last announced; next: snapshot.threads
export function diffStates(prev, threads) {
  const out = [];
  for (const t of threads || []) {
    const key = stateKey(t);
    const before = prev?.[t.id] ?? null;
    if (before === key) continue;

    // First sighting of a thread that is merely working or resting: silent.
    if (before === null && QUIET_STATES.has(t.state)) continue;
    // Flap guard: active <-> idle in either direction.
    if (before !== null && QUIET_STATES.has(before) && QUIET_STATES.has(t.state)) continue;

    out.push({
      id: t.id,
      name: t.name,
      from: before,
      to: key,
      needsYou: NEEDS_YOU_KEYS.has(key),
      line: formatLine(t),
    });
  }
  return out;
}

export function formatLine(t) {
  const pr = t.pr ? ` (PR #${t.pr.number})` : "";
  return `${t.name}${pr}: ${t.stateLabel}${t.detail ? ` — ${t.detail}` : ""}`;
}

// The state map to persist after announcing: every current thread's key.
export function nextNotifiedMap(threads) {
  const map = {};
  for (const t of threads || []) map[t.id] = stateKey(t);
  return map;
}

// ---------------------------------------------------------------------------
// Delivery (injectable for tests)
// ---------------------------------------------------------------------------
export function macNotify(title, body) {
  try {
    execFileSync(
      "osascript",
      ["-e", `display notification ${JSON.stringify(body)} with title ${JSON.stringify(title)}`],
      { stdio: "ignore", timeout: 5000 },
    );
  } catch {}
}

export function runHook(line, cmd = process.env.NAVI_NOTIFY_CMD) {
  if (!cmd) return false;
  try {
    execFileSync("/bin/sh", ["-c", cmd, "navi-notify", line], { stdio: "ignore", timeout: 20000 });
    return true;
  } catch {
    return false;
  }
}

export function deliver(changes, { notify = macNotify, hook = runHook } = {}) {
  const sent = [];
  for (const ch of changes) {
    notify("Navi", ch.line);
    if (ch.needsYou) hook(ch.line);
    sent.push(ch.line);
  }
  return sent;
}

// ---------------------------------------------------------------------------
// Runner
// ---------------------------------------------------------------------------
function readJson(path, fallback) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return fallback;
  }
}

export function run({
  snapshotFile = OUT_FILE,
  notifiedFile = NOTIFIED_FILE,
  dryRun = false,
  delivery = {},
} = {}) {
  const snapshot = readJson(snapshotFile, null);
  if (!snapshot?.threads) return { changes: [], reason: "no snapshot" };

  const prev = readJson(notifiedFile, null);
  const changes = diffStates(prev, snapshot.threads);

  if (!dryRun) {
    // First ever run: record the baseline silently so install day isn't 16 pings.
    if (prev === null) {
      writeNotified(notifiedFile, nextNotifiedMap(snapshot.threads));
      return { changes: [], reason: "baseline recorded" };
    }
    deliver(changes, delivery);
    writeNotified(notifiedFile, nextNotifiedMap(snapshot.threads));
  }
  return { changes, reason: dryRun ? "dry-run" : "delivered" };
}

function writeNotified(path, map) {
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(map, null, 2) + "\n");
  renameSync(tmp, path);
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  const args = new Set(process.argv.slice(2));
  const res = run({ dryRun: args.has("--dry-run") });
  if (!existsSync(OUT_FILE)) process.stderr.write("navi notify: no threads.json yet\n");
  for (const ch of res.changes) process.stdout.write(`${ch.needsYou ? "!! " : "   "}${ch.line}\n`);
  if (!res.changes.length) process.stdout.write(`no status changes (${res.reason})\n`);
}
