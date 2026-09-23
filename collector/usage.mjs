// Per-harness quota usage for the Navi menu's last page.
//
// One row per harness that has a quota (Claude Code, Codex, Cursor, Antigravity,
// OpenRouter shared by hermes+pi, Nous shared by hermes) plus two `quota:false`
// rows (opencode = API keys, omnigent = dollars today). Every fetcher is
// non-fatal: any failure becomes `{ error: '<short human reason>' }` on the row and
// the collector keeps going.
//
// Tokens are read from the keychain / dotfiles at fetch time and never written
// anywhere. The cache (usage-cache.json) holds NORMALIZED rows only.
//
// Row schema:
//   { harness, label, plan?, sharedBy?, quota: true|false,
//     windows: [{ name, usedPct, resetsAt, severity?, active?, scope? }],   // shortest -> longest
//     credits?: { balance, limit?, unit, resetsAt? },
//     blocked, blockedReason?, source, fetchedAt, error: null|string, note?, costTodayUsd? }

import { execFile, execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { USAGE_CACHE_FILE } from "./paths.mjs";

export { USAGE_CACHE_FILE };

export const USAGE_HTTP_TIMEOUT_MS = 8000;
export const USAGE_SOURCE_TIMEOUT_MS = 20000; // hard cap per source, whatever it does inside
export const CODEX_APP_SERVER_TIMEOUT_MS = 15000;
export const OMNIGENT_USAGE_URL = "http://127.0.0.1:6767/v1/usage";

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------
export function shortReason(err, max = 80) {
  const msg = String(err?.message ?? err ?? "unknown error").split("\n")[0].trim();
  return msg.length > max ? msg.slice(0, max - 1) + "…" : msg || "unknown error";
}

function toIso(v) {
  if (v == null || v === "") return null;
  if (typeof v === "number") return new Date(v < 1e12 ? v * 1000 : v).toISOString(); // epoch s or ms
  if (/^\d+$/.test(String(v))) return toIso(Number(v));
  const t = Date.parse(v);
  return Number.isFinite(t) ? new Date(t).toISOString() : null;
}

function num(v, fallback = null) {
  const n = typeof v === "string" ? parseFloat(v) : v;
  return Number.isFinite(n) ? n : fallback;
}

function round1(n) {
  return Math.round(n * 10) / 10;
}

/// Window name -> seconds, for shortest->longest sorting. Unknown names sort last.
export function windowSeconds(name) {
  const m = /^(\d+)\s*([mhd])\b/.exec(String(name || "").trim());
  if (m) {
    const n = parseInt(m[1], 10);
    return n * { m: 60, h: 3600, d: 86400 }[m[2]];
  }
  if (/^daily\b/.test(name)) return 86400;
  if (/^cycle\b/.test(name)) return 30 * 86400;
  if (/^monthly\b/.test(name)) return 30 * 86400;
  return Infinity;
}

/// Seconds -> the short window label used everywhere ("5h", "7d", "30d").
export function windowLabel(seconds) {
  const s = num(seconds);
  if (!s) return "window";
  if (s % 86400 === 0) return `${s / 86400}d`;
  if (s % 3600 === 0) return `${s / 3600}h`;
  return `${Math.round(s / 60)}m`;
}

export function sortWindows(windows) {
  return [...windows]
    .map((w, i) => ({ w, i }))
    .sort((a, b) => windowSeconds(a.w.name) - windowSeconds(b.w.name) || a.i - b.i)
    .map(({ w }) => w);
}

/// blocked = provider said so OR any active window is at/over 100 %.
export function computeBlocked(windows, providerBlocked = false) {
  if (providerBlocked) return true;
  return (windows || []).some((w) => (w.active ?? true) && num(w.usedPct, 0) >= 100);
}

function makeWindow({ name, usedPct, resetsAt, severity, active, scope }) {
  const w = { name, usedPct: round1(num(usedPct, 0)), resetsAt: toIso(resetsAt) };
  if (severity != null) w.severity = severity;
  if (active != null) w.active = !!active;
  if (scope != null) w.scope = scope;
  return w;
}

async function httpJson(url, { method = "GET", headers = {}, body, timeoutMs = USAGE_HTTP_TIMEOUT_MS, fetchImpl = fetch } = {}) {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const res = await fetchImpl(url, { method, headers, body, signal: ctl.signal });
    const text = await res.text();
    let json = null;
    try {
      json = JSON.parse(text);
    } catch {}
    return { status: res.status, ok: res.ok, json, text };
  } finally {
    clearTimeout(t);
  }
}

function readJsonFile(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function keychain(service, account) {
  return execFileSync("security", ["find-generic-password", "-s", service, "-a", account, "-w"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
    timeout: 5000,
  }).trim();
}

function httpError(status, hint) {
  const e = new Error(hint || `HTTP ${status}`);
  e.status = status;
  return e;
}

// ---------------------------------------------------------------------------
// claude — Anthropic OAuth usage (token from the Claude Code keychain item)
// ---------------------------------------------------------------------------
export function claudePlanLabel(meta = {}) {
  const sub = String(meta.subscriptionType || "").trim();
  const tier = String(meta.rateLimitTier || "");
  const mult = /_(\d+)x\b/.exec(tier)?.[1];
  const base = sub ? sub[0].toUpperCase() + sub.slice(1) : null;
  if (!base) return null;
  return mult ? `${base} ${mult}x` : base;
}

export function normalizeClaude(raw, { meta = {} } = {}) {
  const windows = [];
  const limits = Array.isArray(raw?.limits) ? raw.limits : [];
  if (limits.length) {
    for (const l of limits) {
      let name;
      if (l.kind === "session") name = "5h";
      else if (l.kind === "weekly_all") name = "7d";
      else if (l.kind === "weekly_scoped") name = `7d ${l.scope?.model?.display_name || l.scope?.surface || "scoped"}`;
      else name = l.kind || "window";
      windows.push(
        makeWindow({
          name,
          usedPct: l.percent,
          resetsAt: l.resets_at,
          severity: l.severity ?? undefined,
          active: l.is_active ?? undefined,
          scope: l.scope?.model?.display_name ? { model: l.scope.model.display_name } : undefined,
        }),
      );
    }
  } else {
    if (raw?.five_hour) windows.push(makeWindow({ name: "5h", usedPct: raw.five_hour.utilization, resetsAt: raw.five_hour.resets_at }));
    if (raw?.seven_day) windows.push(makeWindow({ name: "7d", usedPct: raw.seven_day.utilization, resetsAt: raw.seven_day.resets_at }));
  }
  const providerBlocked =
    !!raw?.five_hour?.locked_reason ||
    !!raw?.seven_day?.locked_reason ||
    limits.some((l) => /block|reject|exceed|locked/i.test(String(l.severity || "")));
  const blockedReason = raw?.five_hour?.locked_reason || raw?.seven_day?.locked_reason || (providerBlocked ? "limit reached" : undefined);
  const plan = claudePlanLabel(meta);
  return {
    label: plan ? `Claude Code · ${plan}` : "Claude Code",
    plan: plan ?? undefined,
    windows: sortWindows(windows),
    blocked: computeBlocked(windows, providerBlocked),
    blockedReason,
  };
}

export async function fetchClaude({ fetchImpl } = {}) {
  let creds;
  try {
    creds = JSON.parse(keychain("Claude Code-credentials", process.env.USER || ""));
  } catch {
    throw new Error("no Claude Code login in keychain");
  }
  const oauth = creds?.claudeAiOauth || {};
  if (!oauth.accessToken) throw new Error("no Claude Code login in keychain");
  const r = await httpJson("https://api.anthropic.com/api/oauth/usage", {
    headers: { Authorization: `Bearer ${oauth.accessToken}`, "anthropic-beta": "oauth-2025-04-20" },
    fetchImpl,
  });
  if (r.status === 401 || r.status === 403) throw httpError(r.status, "token stale, open claude");
  if (!r.ok || !r.json) throw httpError(r.status);
  return { data: r.json, meta: { subscriptionType: oauth.subscriptionType, rateLimitTier: oauth.rateLimitTier } };
}

// ---------------------------------------------------------------------------
// codex — chatgpt.com wham/usage (snake_case) with `codex app-server` fallback (camelCase)
// ---------------------------------------------------------------------------
function codexWindow(w, suffix = "", scope) {
  if (!w) return null;
  const seconds = num(w.limit_window_seconds) ?? (num(w.windowDurationMins) != null ? num(w.windowDurationMins) * 60 : null);
  const usedPct = w.used_percent ?? w.usedPercent ?? 0;
  const resetsAt = w.reset_at ?? w.resetsAt ?? null;
  const name = `${windowLabel(seconds)}${suffix ? ` ${suffix}` : ""}`;
  return makeWindow({ name, usedPct, resetsAt, scope });
}

export function normalizeCodex(raw) {
  const windows = [];
  let providerBlocked = false;
  let blockedReason;

  // HTTP shape
  if (raw?.rate_limit) {
    const rl = raw.rate_limit;
    for (const w of [rl.primary_window, rl.secondary_window]) {
      const cw = codexWindow(w);
      if (cw) windows.push(cw);
    }
    if (rl.limit_reached) providerBlocked = true;
    for (const extra of raw.additional_rate_limits || []) {
      const suffix = extra.limit_name || extra.metered_feature || "extra";
      const scope = extra.normal_model_slug ? { model: extra.normal_model_slug } : undefined;
      for (const w of [extra.rate_limit?.primary_window, extra.rate_limit?.secondary_window]) {
        const cw = codexWindow(w, suffix, scope);
        if (cw) windows.push(cw);
      }
    }
  }
  // app-server shape (`account/rateLimits/read`): plan / credits / reached live INSIDE
  // rateLimits, and rateLimitsByLimitId repeats the main limit under its own id.
  const main = raw?.rateLimits;
  if (main) {
    for (const w of [main.primary, main.secondary]) {
      const cw = codexWindow(w);
      if (cw) windows.push(cw);
    }
    for (const [id, rl] of Object.entries(raw.rateLimitsByLimitId || {})) {
      if (!rl || id === (main.limitId ?? "codex")) continue; // duplicate of the main limit
      const suffix = rl.limitName || (id === "base_model_inference" ? "gpt-reserve" : id);
      const scope = rl.modelSlug || rl.normalModelSlug ? { model: rl.modelSlug || rl.normalModelSlug } : undefined;
      for (const w of [rl.primary, rl.secondary]) {
        const cw = codexWindow(w, suffix, scope);
        if (cw) windows.push(cw);
      }
    }
  }

  const upsellTitle = raw?.rate_limit_upsell?.title ?? raw?.rateLimitUpsell?.title;
  const reached = raw?.rate_limit_reached_type ?? raw?.rateLimitReachedType ?? main?.rateLimitReachedType;
  if (reached && (typeof reached === "string" || reached.type)) {
    providerBlocked = true;
    blockedReason = upsellTitle || `rate limit reached (${typeof reached === "string" ? reached : reached.type})`;
  } else if (providerBlocked) {
    blockedReason = upsellTitle || "rate limit reached";
  }

  const planRaw = raw?.plan_type ?? raw?.planType ?? main?.planType;
  const plan = planRaw ? String(planRaw)[0].toUpperCase() + String(planRaw).slice(1) : undefined;
  const out = {
    label: plan ? `Codex · ${plan}` : "Codex",
    plan,
    windows: sortWindows(windows),
    blocked: computeBlocked(windows, providerBlocked),
    blockedReason,
  };
  const credits = raw?.credits ?? main?.credits;
  if (credits && credits.balance != null) {
    out.credits = { balance: num(credits.balance, 0), unit: "credits" };
  }
  return out;
}

export function codexAppServerRequests() {
  return [
    { id: 1, method: "initialize", params: { clientInfo: { name: "build-threads", version: "1" } } },
    { id: 2, method: "account/rateLimits/read", params: {} },
  ];
}

/// Pull the rateLimits result out of whatever the app-server printed (one JSON per line).
export function parseCodexAppServerOutput(stdout) {
  for (const line of String(stdout || "").split("\n")) {
    const s = line.trim();
    if (!s.startsWith("{")) continue;
    let msg;
    try {
      msg = JSON.parse(s);
    } catch {
      continue;
    }
    if (msg.id === 2 && msg.result) return msg.result;
    if (msg.id === 2 && msg.error) throw new Error(msg.error.message || "app-server error");
  }
  throw new Error("codex app-server gave no rate limits");
}

function codexAppServer({ timeoutMs = CODEX_APP_SERVER_TIMEOUT_MS } = {}) {
  return new Promise((resolve, reject) => {
    let child;
    try {
      child = execFile(
        "codex",
        ["app-server"],
        { encoding: "utf8", timeout: timeoutMs, maxBuffer: 4 * 1024 * 1024, env: process.env },
        (err, stdout) => {
          // The server never exits on its own, so a timeout kill is the normal path;
          // whatever it printed before that is what we parse.
          try {
            resolve(parseCodexAppServerOutput(stdout));
          } catch (e) {
            reject(err?.code === "ENOENT" ? new Error("codex CLI not installed") : e);
          }
        },
      );
    } catch (e) {
      reject(e);
      return;
    }
    const lines = codexAppServerRequests().map((m) => JSON.stringify(m)).join("\n") + "\n";
    child.stdin.on("error", () => {});
    child.stdin.write(lines);
    // Give it a few seconds to answer, then close — resolve happens on exit.
    let buf = "";
    child.stdout.on("data", (d) => {
      buf += d;
      if (/"id":\s*2\b/.test(buf)) setTimeout(() => child.kill(), 200);
    });
  });
}

export async function fetchCodex({ fetchImpl, home = homedir() } = {}) {
  let auth;
  try {
    auth = readJsonFile(join(home, ".codex", "auth.json"));
  } catch {
    throw new Error("no codex login (~/.codex/auth.json)");
  }
  const token = auth?.tokens?.access_token;
  const account = auth?.tokens?.account_id;
  let httpErr = null;
  if (token) {
    try {
      const headers = { Authorization: `Bearer ${token}` };
      if (account) headers["ChatGPT-Account-Id"] = account;
      const r = await httpJson("https://chatgpt.com/backend-api/wham/usage", { headers, fetchImpl });
      if (r.ok && r.json) return { data: r.json, meta: { via: "chatgpt.com/backend-api/wham/usage" } };
      httpErr = httpError(r.status, r.status === 401 ? "token stale, open codex" : `HTTP ${r.status}`);
    } catch (e) {
      httpErr = e;
    }
  } else {
    httpErr = new Error("no codex access token");
  }
  try {
    const data = await codexAppServer();
    return { data, meta: { via: "codex app-server" } };
  } catch (e) {
    throw httpErr?.status === 401 ? httpErr : new Error(`${shortReason(httpErr)}; ${shortReason(e)}`);
  }
}

// ---------------------------------------------------------------------------
// cursor — DashboardService.GetCurrentPeriodUsage (Connect JSON)
// ---------------------------------------------------------------------------
export function normalizeCursor(raw) {
  const pu = raw?.planUsage || {};
  const resetsAt = raw?.billingCycleEnd ?? null;
  const windows = [
    makeWindow({ name: "cycle total", usedPct: pu.totalPercentUsed, resetsAt }),
    makeWindow({ name: "cycle auto", usedPct: pu.autoPercentUsed, resetsAt }),
    makeWindow({ name: "cycle api", usedPct: pu.apiPercentUsed, resetsAt }),
  ];
  const plan = raw?.membershipType || raw?.planName || undefined;
  // "total" is the one that gates the account; the two sub-buckets are informational.
  const blocked = computeBlocked([windows[0]]);
  return {
    label: plan ? `Cursor · ${plan}` : "Cursor",
    plan,
    windows,
    blocked,
    blockedReason: blocked ? "included usage spent" : undefined,
  };
}

export async function fetchCursor({ fetchImpl } = {}) {
  let token;
  try {
    token = keychain("cursor-access-token", "cursor-user");
  } catch {
    throw new Error("no Cursor login in keychain");
  }
  if (!token) throw new Error("no Cursor login in keychain");
  const r = await httpJson("https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: "{}",
    fetchImpl,
  });
  if (r.status === 401 || r.status === 403) throw httpError(r.status, "token stale, open cursor");
  if (!r.ok || !r.json) throw httpError(r.status);
  return { data: r.json, meta: {} };
}

// ---------------------------------------------------------------------------
// agy (Antigravity) — loopback language server, CSRF token from its own argv
// ---------------------------------------------------------------------------
function agyWindowLabel(window) {
  const w = String(window || "").toLowerCase();
  if (w.includes("week")) return "7d";
  if (w.includes("day") || w.includes("daily")) return "1d";
  if (w.includes("month")) return "30d";
  if (w.includes("hour")) return "1h";
  return w || "window";
}

export function normalizeAgy(raw) {
  const groups = raw?.quota?.response?.groups ?? raw?.quota?.groups ?? [];
  const windows = [];
  for (const g of groups) {
    for (const b of g.buckets || []) {
      const remaining = num(b.remainingFraction, 1);
      windows.push(
        makeWindow({
          name: `${agyWindowLabel(b.window)} ${g.displayName || b.displayName || "quota"}`,
          usedPct: (1 - remaining) * 100,
          resetsAt: b.resetTime,
        }),
      );
    }
  }
  const status = raw?.status?.userStatus || {};
  const plan = status.planStatus?.planInfo?.planName || status.userTier?.name || undefined;
  const out = {
    label: plan ? `Antigravity · ${plan}` : "Antigravity",
    plan,
    windows: sortWindows(windows),
    blocked: computeBlocked(windows),
  };
  const prompt = num(status.planStatus?.availablePromptCredits);
  const promptLimit = num(status.planStatus?.planInfo?.monthlyPromptCredits);
  if (prompt != null) out.credits = { balance: prompt, limit: promptLimit ?? undefined, unit: "prompt credits" };
  return out;
}

export function discoverAgy({ exec = execFileSync } = {}) {
  let pidsOut;
  try {
    pidsOut = exec("lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-c", "language_", "-t"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 5000,
    });
  } catch {
    pidsOut = "";
  }
  const pids = String(pidsOut).split("\n").map((s) => s.trim()).filter(Boolean);
  if (!pids.length) throw new Error("Antigravity not running");
  const pid = pids[0];
  const argv = exec("ps", ["-o", "command=", "-p", pid], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 5000 })
    .trim()
    .split(/\s+/);
  const i = argv.indexOf("--csrf_token");
  const csrf = i >= 0 ? argv[i + 1] : null;
  if (!csrf) throw new Error("Antigravity csrf token not found");
  const portsOut = exec("lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", pid], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
    timeout: 5000,
  });
  const ports = [...new Set([...String(portsOut).matchAll(/127\.0\.0\.1:(\d+)\s+\(LISTEN\)/g)].map((m) => parseInt(m[1], 10)))].sort(
    (a, b) => b - a, // the HTTP port has been the higher of the pair on this Mac; probe order only
  );
  if (!ports.length) throw new Error("Antigravity has no listening port");
  return { pid, csrf, ports };
}

export async function fetchAgy({ fetchImpl, exec } = {}) {
  const { csrf, ports } = discoverAgy({ exec });
  const base = "/exa.language_server_pb.LanguageServerService/";
  const headers = { "x-codeium-csrf-token": csrf, "Content-Type": "application/json" };
  let quota = null;
  let port = null;
  for (const p of ports) {
    try {
      const r = await httpJson(`http://127.0.0.1:${p}${base}RetrieveUserQuotaSummary`, { method: "POST", headers, body: "{}", fetchImpl, timeoutMs: 4000 });
      if (r.ok && r.json) {
        quota = r.json;
        port = p;
        break;
      }
    } catch {}
  }
  if (!quota) throw new Error("Antigravity quota endpoint unreachable");
  let status = null;
  try {
    const r = await httpJson(`http://127.0.0.1:${port}${base}GetUserStatus`, { method: "POST", headers, body: "{}", fetchImpl, timeoutMs: 4000 });
    if (r.ok && r.json) status = r.json;
  } catch {}
  return { data: { quota, status }, meta: {} };
}

// ---------------------------------------------------------------------------
// openrouter — shared by hermes + pi (key from ~/.hermes/.env, else ~/.pi/agent/auth.json)
// ---------------------------------------------------------------------------
export function nextUtcMidnight(now = Date.now()) {
  const d = new Date(now);
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + 1)).toISOString();
}

export function normalizeOpenRouter(raw, { now = Date.now() } = {}) {
  const d = raw?.data || raw || {};
  const free = d.free_model_daily_requests || {};
  const used = num(free.used, 0);
  const limit = num(free.limit, 0);
  const windows = [];
  if (limit > 0 || used > 0) {
    windows.push(makeWindow({ name: "daily free reqs", usedPct: limit > 0 ? (used / limit) * 100 : 0, resetsAt: nextUtcMidnight(now) }));
  }
  const plan = d.is_free_tier === true ? "free" : d.is_free_tier === false ? "paid" : undefined;
  const providerBlocked = limit > 0 && num(free.remaining, 1) <= 0;
  return {
    label: plan ? `OpenRouter · ${plan}` : "OpenRouter",
    plan,
    windows,
    blocked: computeBlocked(windows, providerBlocked),
    blockedReason: providerBlocked ? `${used}/${limit} free requests today` : undefined,
    note: `${used}/${limit} free reqs`,
  };
}

export function readOpenRouterKey(home = homedir()) {
  try {
    const env = readFileSync(join(home, ".hermes", ".env"), "utf8");
    const m = /^\s*(?:export\s+)?OPENROUTER_API_KEY\s*=\s*(.+?)\s*$/m.exec(env);
    if (m) {
      const v = m[1].replace(/^["']|["']$/g, "");
      if (v) return v;
    }
  } catch {}
  try {
    const pi = readJsonFile(join(home, ".pi", "agent", "auth.json"));
    if (pi?.openrouter?.access) return pi.openrouter.access;
  } catch {}
  throw new Error("no OpenRouter key (~/.hermes/.env or ~/.pi)");
}

export async function fetchOpenRouter({ fetchImpl, home } = {}) {
  const key = readOpenRouterKey(home);
  const r = await httpJson("https://openrouter.ai/api/v1/auth/key", { headers: { Authorization: `Bearer ${key}` }, fetchImpl });
  if (r.status === 401 || r.status === 403) throw httpError(r.status, "OpenRouter key rejected");
  if (!r.ok || !r.json) throw httpError(r.status);
  return { data: r.json, meta: {} };
}

// ---------------------------------------------------------------------------
// nous — portal subscription credits (hermes)
// ---------------------------------------------------------------------------
export function normalizeNous(raw) {
  const c = raw?.current || {};
  const balance = num(c.creditsRemaining, 0);
  const limit = num(c.monthlyCredits, 0);
  const plan = c.tierName || undefined;
  const blocked = limit > 0 && balance <= 0;
  return {
    label: plan ? `Nous · ${plan}` : "Nous",
    plan,
    windows: [],
    credits: { balance, limit, unit: "credits", resetsAt: toIso(c.cycleEndsAt) },
    blocked,
    blockedReason: blocked ? "credits spent" : undefined,
    note: `${balance}/${limit} credits`,
  };
}

export async function fetchNous({ fetchImpl, home = homedir() } = {}) {
  let token;
  try {
    token = readJsonFile(join(home, ".hermes", "auth.json"))?.providers?.nous?.access_token;
  } catch {}
  if (!token) throw new Error("no Nous login (~/.hermes/auth.json)");
  const r = await httpJson("https://portal.nousresearch.com/api/billing/subscription", { headers: { Authorization: `Bearer ${token}` }, fetchImpl });
  if (r.status === 401 || r.status === 403) throw httpError(r.status, "token stale, open hermes");
  if (!r.ok || !r.json) throw httpError(r.status);
  return { data: r.json, meta: {} };
}

// ---------------------------------------------------------------------------
// omnigent — dollars today from the loopback usage report (no quota)
// ---------------------------------------------------------------------------
export function normalizeOmnigent(raw) {
  const today = num(raw?.cost_today);
  return {
    label: "Omnigent",
    windows: [],
    blocked: false,
    costTodayUsd: today == null ? undefined : Math.round(today * 100) / 100,
    note: today == null ? "no cost data" : `$${today.toFixed(0)} today`,
  };
}

export async function fetchOmnigent({ fetchImpl, url = OMNIGENT_USAGE_URL } = {}) {
  let r;
  try {
    r = await httpJson(url, { fetchImpl, timeoutMs: 2000 });
  } catch {
    throw new Error("Omnigent not running");
  }
  if (!r.ok || !r.json) throw httpError(r.status);
  return { data: r.json, meta: {} };
}

// ---------------------------------------------------------------------------
// Source table
// ---------------------------------------------------------------------------
export const SOURCES = [
  { harness: "claude", label: "Claude Code", quota: true, pollEvery: 120, source: "api.anthropic.com/api/oauth/usage", fetch: fetchClaude, normalize: normalizeClaude },
  { harness: "codex", label: "Codex", quota: true, pollEvery: 300, source: "chatgpt.com/backend-api/wham/usage", fetch: fetchCodex, normalize: normalizeCodex },
  { harness: "cursor", label: "Cursor", quota: true, pollEvery: 300, source: "api2.cursor.sh DashboardService", fetch: fetchCursor, normalize: normalizeCursor },
  { harness: "agy", label: "Antigravity", quota: true, pollEvery: 120, source: "antigravity language server (loopback)", fetch: fetchAgy, normalize: normalizeAgy },
  { harness: "openrouter", label: "OpenRouter", quota: true, sharedBy: ["hermes", "pi"], pollEvery: 300, source: "openrouter.ai/api/v1/auth/key", fetch: fetchOpenRouter, normalize: normalizeOpenRouter },
  { harness: "nous", label: "Nous", quota: true, sharedBy: ["hermes"], pollEvery: 600, source: "portal.nousresearch.com billing", fetch: fetchNous, normalize: normalizeNous },
  { harness: "opencode", label: "OpenCode", quota: false, pollEvery: 3600, source: "static", fetch: null, normalize: () => ({ note: "API keys, no quota", windows: [], blocked: false }) },
  { harness: "omnigent", label: "Omnigent", quota: false, pollEvery: 60, source: OMNIGENT_USAGE_URL, fetch: fetchOmnigent, normalize: normalizeOmnigent },
];

export function baseRow(src, now = Date.now()) {
  const row = {
    harness: src.harness,
    label: src.label,
    quota: !!src.quota,
    windows: [],
    blocked: false,
    source: src.source || src.harness,
    fetchedAt: new Date(now).toISOString(),
    error: null,
  };
  if (src.sharedBy) row.sharedBy = [...src.sharedBy];
  return row;
}

function withTimeout(promise, ms, label) {
  let t;
  const timeout = new Promise((_, reject) => {
    t = setTimeout(() => reject(new Error(`${label} timed out`)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(t));
}

/// Run one source end to end. NEVER rejects: any throw becomes `row.error`.
export async function runSource(src, { now = Date.now(), ctx = {}, timeoutMs = USAGE_SOURCE_TIMEOUT_MS } = {}) {
  const row = baseRow(src, now);
  try {
    let raw = { data: null, meta: {} };
    if (typeof src.fetch === "function") raw = await withTimeout(Promise.resolve().then(() => src.fetch(ctx)), timeoutMs, src.label);
    const fields = src.normalize ? src.normalize(raw?.data, { now, meta: raw?.meta || {} }) : {};
    for (const [k, v] of Object.entries(fields || {})) if (v !== undefined) row[k] = v;
    if (raw?.meta?.via) row.source = raw.meta.via;
    row.windows = Array.isArray(row.windows) ? row.windows : [];
    row.blocked = !!row.blocked;
    return row;
  } catch (e) {
    row.error = shortReason(e);
    return row;
  }
}

// ---------------------------------------------------------------------------
// Cache (normalized rows only — never a token) + due scheduling
// ---------------------------------------------------------------------------
export function loadUsageCache(file = USAGE_CACHE_FILE) {
  try {
    const j = JSON.parse(readFileSync(file, "utf8"));
    return j && typeof j.entries === "object" && j.entries ? j : { entries: {} };
  } catch {
    return { entries: {} };
  }
}

export function saveUsageCache(cache, file = USAGE_CACHE_FILE) {
  try {
    mkdirSync(dirname(file), { recursive: true });
    const tmp = `${file}.tmp`;
    writeFileSync(tmp, JSON.stringify(cache, null, 2) + "\n");
    renameSync(tmp, file);
    return true;
  } catch {
    return false;
  }
}

export function isDue(entry, pollEvery, nowMs) {
  if (!entry || !Number.isFinite(entry.fetchedAt)) return true;
  return nowMs - entry.fetchedAt >= pollEvery * 1000;
}

/// Collect every source: due ones are fetched (in parallel), the rest reuse the cached row.
/// Returns the rows in SOURCES order plus the updated cache.
export async function collectUsage({ now = Date.now(), sources = SOURCES, cache = { entries: {} }, ctx = {}, timeoutMs } = {}) {
  const entries = { ...(cache?.entries || {}) };
  const rows = await Promise.all(
    sources.map(async (src) => {
      const prev = entries[src.harness];
      if (!isDue(prev, src.pollEvery, now) && prev?.row) return { ...prev.row, cached: true };
      const row = await runSource(src, { now, ctx, timeoutMs });
      entries[src.harness] = { fetchedAt: now, row };
      return row;
    }),
  );
  // Drop cache entries for sources that no longer exist.
  for (const k of Object.keys(entries)) if (!sources.some((s) => s.harness === k)) delete entries[k];
  return { usage: rows, usagePolledAt: new Date(now).toISOString(), cache: { entries } };
}

/// Convenience for collect.mjs: load cache, poll what is due, save cache.
export async function collectUsageWithCache({ now = Date.now(), file = USAGE_CACHE_FILE, ...rest } = {}) {
  const cache = loadUsageCache(file);
  const out = await collectUsage({ now, cache, ...rest });
  saveUsageCache(out.cache, file);
  return out;
}

// ---------------------------------------------------------------------------
// Terminal rendering (for `collect.mjs --table` and the PR body)
// ---------------------------------------------------------------------------
export function humanizeUntil(iso, now = Date.now()) {
  const t = Date.parse(iso);
  if (!Number.isFinite(t)) return "";
  const secs = Math.max(0, Math.round((t - now) / 1000));
  if (secs < 60) return `${secs}s`;
  const mins = Math.round(secs / 60);
  if (mins < 60) return `${mins}m`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ${mins % 60}m`;
  const days = Math.floor(hours / 24);
  return hours % 24 ? `${days}d ${hours % 24}h` : `${days}d`;
}

export function renderUsage(usage, now = Date.now()) {
  if (!Array.isArray(usage) || !usage.length) return "";
  const lines = [];
  for (const r of usage) {
    if (!r.quota) continue;
    if (r.error) {
      lines.push(`  ${r.label}: ${r.error}`);
      continue;
    }
    const parts = r.windows.map((w) => `${w.name} ${Math.round(w.usedPct)}%${w.resetsAt ? ` (resets ${humanizeUntil(w.resetsAt, now)})` : ""}`);
    if (r.credits) parts.push(`${r.credits.balance}${r.credits.limit != null ? `/${r.credits.limit}` : ""} ${r.credits.unit}`);
    lines.push(`${r.blocked ? "!" : " "} ${r.label}: ${parts.join(" · ") || r.note || "-"}`);
  }
  const none = usage
    .filter((r) => !r.quota)
    .map((r) => (r.error ? `${r.harness} (${r.error})` : r.note ? `${r.harness} (${r.note})` : r.harness));
  if (none.length) lines.push(`  no quota: ${none.join(", ")}`);
  return lines.join("\n") + "\n";
}
