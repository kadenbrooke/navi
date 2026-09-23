// Where the collector reads its config and writes its output. Everything is
// overridable by environment variable; install.sh bakes the values you had at
// install time into the launchd agents (collector and app) so both agree.
//
//   NAVI_THREADS_PATH   snapshot Navi reads            default ~/.navi/threads.json
//                       (threads.prev.json, notified.json and usage-cache.json
//                       live next to it)
//   NAVI_REPO           git repo whose worktrees / PRs to track (optional;
//                       without it, rows come from live agent sessions only)

import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";

const expand = (p) => (p.startsWith("~/") ? join(homedir(), p.slice(2)) : p);

export const OUT_FILE = resolve(expand(process.env.NAVI_THREADS_PATH || join(homedir(), ".navi", "threads.json")));
export const OUT_DIR = dirname(OUT_FILE);
export const PREV_FILE = join(OUT_DIR, "threads.prev.json");
export const NOTIFIED_FILE = join(OUT_DIR, "notified.json");
export const USAGE_CACHE_FILE = join(OUT_DIR, "usage-cache.json");

export const DEFAULT_REPO = process.env.NAVI_REPO ? resolve(expand(process.env.NAVI_REPO)) : null;
