// node --test collector/*.test.mjs
//
// Fixture-driven normalizer tests for every usage source + scheduler/cache tests.
// No network, no keychain: fetchers are replaced with stubs.

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import {
  SOURCES,
  normalizeClaude,
  claudePlanLabel,
  normalizeCodex,
  parseCodexAppServerOutput,
  codexAppServerRequests,
  normalizeCursor,
  normalizeAgy,
  normalizeOpenRouter,
  nextUtcMidnight,
  normalizeNous,
  normalizeOmnigent,
  runSource,
  collectUsage,
  isDue,
  loadUsageCache,
  saveUsageCache,
  sortWindows,
  windowSeconds,
  windowLabel,
  computeBlocked,
  humanizeUntil,
  renderUsage,
  shortReason,
} from "./usage.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const fixture = (name) => JSON.parse(readFileSync(join(HERE, "fixtures", "usage", name), "utf8"));
const NOW = Date.parse("2026-09-18T20:00:00Z");

// ---------------------------------------------------------------------------
describe("window helpers", () => {
  test("windowSeconds orders 5h < 1d < 7d < cycle < unknown", () => {
    assert.ok(windowSeconds("5h") < windowSeconds("daily free reqs"));
    assert.ok(windowSeconds("daily free reqs") < windowSeconds("7d Fable"));
    assert.ok(windowSeconds("7d") < windowSeconds("cycle total"));
    assert.equal(windowSeconds("whatever"), Infinity);
  });

  test("windowLabel from seconds", () => {
    assert.equal(windowLabel(18000), "5h");
    assert.equal(windowLabel(604800), "7d");
    assert.equal(windowLabel(86400), "1d");
    assert.equal(windowLabel(1800), "30m");
    assert.equal(windowLabel(undefined), "window");
  });

  test("sortWindows is shortest→longest and stable", () => {
    const sorted = sortWindows([{ name: "7d" }, { name: "cycle a" }, { name: "5h" }, { name: "7d Fable" }]);
    assert.deepEqual(
      sorted.map((w) => w.name),
      ["5h", "7d", "7d Fable", "cycle a"],
    );
  });

  test("computeBlocked: provider flag, or any active window ≥100", () => {
    assert.equal(computeBlocked([{ name: "5h", usedPct: 40 }]), false);
    assert.equal(computeBlocked([{ name: "5h", usedPct: 40 }], true), true);
    assert.equal(computeBlocked([{ name: "7d", usedPct: 100 }]), true);
    assert.equal(computeBlocked([{ name: "7d", usedPct: 108 }]), true, "usedPct may exceed 100");
    assert.equal(computeBlocked([{ name: "7d", usedPct: 120, active: false }]), false, "inactive windows do not block");
  });
});

// ---------------------------------------------------------------------------
describe("claude", () => {
  test("normalizes limits[] into 5h / 7d / 7d <model> with severity + active", () => {
    const row = normalizeClaude(fixture("claude.json"), { meta: { subscriptionType: "max", rateLimitTier: "default_claude_max_5x" } });
    assert.equal(row.label, "Claude Code · Max 5x");
    assert.equal(row.plan, "Max 5x");
    assert.deepEqual(
      row.windows.map((w) => [w.name, w.usedPct]),
      [
        ["5h", 38],
        ["7d", 12],
        ["7d Fable", 12],
      ],
    );
    assert.equal(row.windows[0].severity, "normal");
    assert.equal(row.windows[0].active, true);
    assert.equal(row.windows[1].active, false);
    assert.equal(row.windows[0].resetsAt, "2026-09-18T23:30:00.828Z");
    assert.deepEqual(row.windows[2].scope, { model: "Fable" });
    assert.equal(row.blocked, false);
  });

  test("falls back to five_hour / seven_day when limits[] is missing", () => {
    const row = normalizeClaude({ five_hour: { utilization: 91.4, resets_at: "2026-09-18T23:30:00Z" }, seven_day: { utilization: 100, resets_at: "2026-09-25T08:00:00Z" } });
    assert.deepEqual(
      row.windows.map((w) => [w.name, w.usedPct]),
      [
        ["5h", 91.4],
        ["7d", 100],
      ],
    );
    assert.equal(row.blocked, true, "a 100% window blocks");
    assert.equal(row.label, "Claude Code");
  });

  test("locked_reason marks blocked with the provider reason", () => {
    const row = normalizeClaude({ five_hour: { utilization: 50, resets_at: null, locked_reason: "org_paused" } });
    assert.equal(row.blocked, true);
    assert.equal(row.blockedReason, "org_paused");
  });

  test("plan label variants", () => {
    assert.equal(claudePlanLabel({ subscriptionType: "max", rateLimitTier: "default_claude_max_20x" }), "Max 20x");
    assert.equal(claudePlanLabel({ subscriptionType: "pro" }), "Pro");
    assert.equal(claudePlanLabel({}), null);
  });
});

// ---------------------------------------------------------------------------
describe("codex", () => {
  test("HTTP shape: primary/secondary + additional gpt-reserve, blocked via rate_limit_reached_type", () => {
    const row = normalizeCodex(fixture("codex-http.json"));
    assert.equal(row.label, "Codex · Plus");
    assert.deepEqual(
      row.windows.map((w) => [w.name, w.usedPct]),
      [
        ["5h", 0],
        ["7d", 100],
        ["7d gpt-reserve", 100],
      ],
    );
    assert.equal(row.windows[1].resetsAt, new Date(1789835640 * 1000).toISOString());
    assert.deepEqual(row.windows[2].scope, { model: "gpt-5.6-luna" });
    assert.equal(row.blocked, true);
    assert.equal(row.blockedReason, "You're out of Codex messages");
    assert.deepEqual(row.credits, { balance: 0, unit: "credits" });
  });

  test("app-server shape: rateLimits + rateLimitsByLimitId", () => {
    const row = normalizeCodex(fixture("codex-app-server.json"));
    assert.deepEqual(
      row.windows.map((w) => [w.name, w.usedPct]),
      [
        ["5h", 12],
        ["7d", 64],
        ["7d gpt-reserve", 100],
      ],
    );
    assert.equal(row.blocked, true, "the reserve window at 100% blocks");
    assert.equal(row.credits.balance, 3.5);
    assert.equal(row.plan, "Plus", "planType is nested inside rateLimits");
    assert.deepEqual(row.windows[2].scope, { model: "gpt-5.6-luna" });
    assert.equal(row.windows.length, 3, "the duplicate 'codex' entry in rateLimitsByLimitId is skipped");
  });

  test("app-server shape: nested rateLimitReachedType + rateLimitUpsell drive blocked", () => {
    const fx = fixture("codex-app-server.json");
    fx.rateLimits.rateLimitReachedType = "rate_limit_reached";
    fx.rateLimitUpsell = { title: "You're out of Codex messages" };
    const row = normalizeCodex(fx);
    assert.equal(row.blocked, true);
    assert.equal(row.blockedReason, "You're out of Codex messages");
  });

  test("not blocked when nothing is reached", () => {
    const row = normalizeCodex({ plan_type: "pro", rate_limit: { allowed: true, limit_reached: false, primary_window: { used_percent: 3, limit_window_seconds: 18000, reset_at: 1789781743 } } });
    assert.equal(row.blocked, false);
    assert.equal(row.blockedReason, undefined);
    assert.equal(row.windows.length, 1);
  });

  test("app-server output parsing picks the id:2 result and ignores noise", () => {
    const out = ['{"id":1,"result":{"userAgent":"x"}}', "not json", '{"method":"thread/started","params":{}}', '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":5}}}}'].join("\n");
    assert.deepEqual(parseCodexAppServerOutput(out), { rateLimits: { primary: { usedPercent: 5 } } });
    assert.throws(() => parseCodexAppServerOutput('{"id":1,"result":{}}'), /no rate limits/);
    assert.throws(() => parseCodexAppServerOutput('{"id":2,"error":{"message":"nope"}}'), /nope/);
    assert.deepEqual(
      codexAppServerRequests().map((m) => m.method),
      ["initialize", "account/rateLimits/read"],
    );
  });
});

// ---------------------------------------------------------------------------
describe("cursor", () => {
  test("three cycle windows sharing the billing-cycle reset", () => {
    const row = normalizeCursor(fixture("cursor.json"));
    assert.equal(row.label, "Cursor");
    assert.deepEqual(
      row.windows.map((w) => [w.name, w.usedPct]),
      [
        ["cycle total", 69.5],
        ["cycle auto", 100],
        ["cycle api", 39],
      ],
    );
    assert.equal(row.windows[0].resetsAt, new Date(1790992000000).toISOString());
    assert.equal(row.blocked, false, "only the total gates the account; auto at 100 is informational");
  });

  test("total ≥100 blocks", () => {
    const row = normalizeCursor({ planUsage: { totalPercentUsed: 100, autoPercentUsed: 100, apiPercentUsed: 100 }, billingCycleEnd: "1790992000000", membershipType: "pro" });
    assert.equal(row.blocked, true);
    assert.equal(row.label, "Cursor · pro");
  });
});

// ---------------------------------------------------------------------------
describe("antigravity", () => {
  test("groups/buckets → 7d <group> with usedPct = (1 - remaining) * 100", () => {
    const row = normalizeAgy(fixture("agy.json"));
    assert.equal(row.label, "Antigravity · Pro");
    assert.deepEqual(
      row.windows.map((w) => [w.name, w.usedPct]),
      [
        ["7d Gemini Models", 1.8],
        ["7d Claude and GPT models", 0],
      ],
    );
    assert.equal(row.windows[0].resetsAt, "2026-09-25T07:04:38.000Z");
    assert.deepEqual(row.credits, { balance: 500, limit: 50000, unit: "prompt credits" });
    assert.equal(row.blocked, false);
  });

  test("quota only (no status) still works; exhausted bucket blocks", () => {
    const row = normalizeAgy({ quota: { response: { groups: [{ displayName: "Gemini", buckets: [{ window: "weekly", remainingFraction: 0, resetTime: "2026-09-25T07:04:38Z" }] }] } } });
    assert.equal(row.label, "Antigravity");
    assert.equal(row.windows[0].usedPct, 100);
    assert.equal(row.blocked, true);
    assert.equal(row.credits, undefined);
  });
});

// ---------------------------------------------------------------------------
describe("openrouter", () => {
  test("daily free requests → one window that may exceed 100%, resets next UTC midnight", () => {
    const row = normalizeOpenRouter(fixture("openrouter.json"), { now: NOW });
    assert.equal(row.label, "OpenRouter · free");
    assert.equal(row.windows.length, 1);
    assert.equal(row.windows[0].name, "daily free reqs");
    assert.equal(row.windows[0].usedPct, 108);
    assert.equal(row.windows[0].resetsAt, "2026-09-19T00:00:00.000Z");
    assert.equal(row.blocked, true);
    assert.match(row.blockedReason, /54\/50/);
  });

  test("nextUtcMidnight rolls the date", () => {
    assert.equal(nextUtcMidnight(Date.parse("2026-12-31T23:59:59Z")), "2027-01-01T00:00:00.000Z");
  });

  test("paid key with no free bucket → no windows, not blocked", () => {
    const row = normalizeOpenRouter({ data: { is_free_tier: false } });
    assert.equal(row.label, "OpenRouter · paid");
    assert.deepEqual(row.windows, []);
    assert.equal(row.blocked, false);
  });
});

// ---------------------------------------------------------------------------
describe("nous", () => {
  test("credits row, no windows", () => {
    const row = normalizeNous(fixture("nous.json"));
    assert.equal(row.label, "Nous · Free");
    assert.deepEqual(row.windows, []);
    assert.deepEqual(row.credits, { balance: 0, limit: 0, unit: "credits", resetsAt: "2026-10-02T21:03:53.000Z" });
    assert.equal(row.blocked, false, "0 of 0 on the free tier is not 'spent'");
  });

  test("spent credits on a paid tier block", () => {
    const row = normalizeNous({ current: { tierName: "Plus", monthlyCredits: "22", creditsRemaining: "0", cycleEndsAt: "2026-10-02T21:03:53.000Z" } });
    assert.equal(row.blocked, true);
    assert.equal(row.blockedReason, "credits spent");
  });
});

// ---------------------------------------------------------------------------
describe("omnigent / opencode", () => {
  test("omnigent carries dollars today, no quota", () => {
    const row = normalizeOmnigent(fixture("omnigent.json"));
    assert.equal(row.costTodayUsd, 12.35);
    assert.equal(row.note, "$12 today");
    assert.equal(row.blocked, false);
  });

  test("opencode is a static no-quota row", async () => {
    const src = SOURCES.find((s) => s.harness === "opencode");
    const row = await runSource(src, { now: NOW });
    assert.equal(row.quota, false);
    assert.equal(row.note, "API keys, no quota");
    assert.equal(row.error, null);
  });
});

// ---------------------------------------------------------------------------
describe("runSource — never rejects", () => {
  const good = { harness: "x", label: "X", quota: true, pollEvery: 60, source: "test", fetch: async () => ({ data: { five_hour: { utilization: 10, resets_at: "2026-09-18T23:30:00Z" } }, meta: {} }), normalize: normalizeClaude };

  test("a throwing fetcher yields an error row", async () => {
    const src = { ...good, fetch: async () => { throw new Error("token stale, open claude\nstack line"); } };
    const row = await runSource(src, { now: NOW });
    assert.equal(row.error, "token stale, open claude");
    assert.equal(row.harness, "x");
    assert.equal(row.quota, true);
    assert.deepEqual(row.windows, []);
    assert.equal(row.blocked, false);
    assert.equal(row.fetchedAt, new Date(NOW).toISOString());
  });

  test("a synchronously throwing fetcher yields an error row", async () => {
    const src = { ...good, fetch: () => { throw new Error("boom"); } };
    const row = await runSource(src, { now: NOW });
    assert.equal(row.error, "boom");
  });

  test("a throwing normalizer yields an error row", async () => {
    const src = { ...good, normalize: () => { throw new TypeError("bad shape"); } };
    const row = await runSource(src, { now: NOW });
    assert.equal(row.error, "bad shape");
  });

  test("a hanging fetcher is cut off by the per-source timeout", async () => {
    const src = { ...good, fetch: () => new Promise(() => {}) };
    const row = await runSource(src, { now: NOW, timeoutMs: 20 });
    assert.match(row.error, /timed out/);
  });

  test("a good fetcher fills the row and clears error", async () => {
    const row = await runSource(good, { now: NOW });
    assert.equal(row.error, null);
    assert.equal(row.windows[0].usedPct, 10);
    assert.equal(row.source, "test");
  });

  test("meta.via overrides source (codex fallback path)", async () => {
    const src = { ...good, fetch: async () => ({ data: {}, meta: { via: "codex app-server" } }), normalize: () => ({ windows: [] }) };
    const row = await runSource(src, { now: NOW });
    assert.equal(row.source, "codex app-server");
  });

  test("shortReason trims and truncates", () => {
    assert.equal(shortReason(new Error("a\nb")), "a");
    assert.equal(shortReason("x".repeat(100)).length, 80);
    assert.equal(shortReason(null), "unknown error");
  });
});

// ---------------------------------------------------------------------------
describe("collectUsage — pollEvery + cache", () => {
  function counting(harness, pollEvery, calls) {
    return {
      harness,
      label: harness,
      quota: true,
      pollEvery,
      source: "t",
      fetch: async () => {
        calls[harness] = (calls[harness] || 0) + 1;
        return { data: { five_hour: { utilization: calls[harness], resets_at: null } }, meta: {} };
      },
      normalize: normalizeClaude,
    };
  }

  test("isDue", () => {
    assert.equal(isDue(undefined, 60, NOW), true);
    assert.equal(isDue({ fetchedAt: NOW - 59_000 }, 60, NOW), false);
    assert.equal(isDue({ fetchedAt: NOW - 60_000 }, 60, NOW), true);
    assert.equal(isDue({ fetchedAt: "garbage" }, 60, NOW), true);
  });

  test("rows not yet due reuse the cached row; due rows refetch", async () => {
    const calls = {};
    const sources = [counting("fast", 60, calls), counting("slow", 300, calls)];
    const first = await collectUsage({ now: NOW, sources });
    assert.deepEqual(calls, { fast: 1, slow: 1 });
    assert.equal(first.usagePolledAt, new Date(NOW).toISOString());
    assert.equal(first.usage.length, 2);

    const second = await collectUsage({ now: NOW + 61_000, sources, cache: first.cache });
    assert.deepEqual(calls, { fast: 2, slow: 1 }, "only the 60s source is due after 61s");
    assert.equal(second.usage[0].windows[0].usedPct, 2);
    assert.equal(second.usage[1].windows[0].usedPct, 1, "cached row is reused verbatim");
    assert.equal(second.usage[1].cached, true);
    assert.equal(second.usage[1].fetchedAt, new Date(NOW).toISOString(), "cached rows keep their original fetchedAt");

    const third = await collectUsage({ now: NOW + 301_000, sources, cache: second.cache });
    assert.deepEqual(calls, { fast: 3, slow: 2 });
    assert.equal(third.usage.map((r) => r.harness).join(","), "fast,slow", "output keeps SOURCES order");
  });

  test("an erroring source is cached too (no hammering) and never rejects the batch", async () => {
    const calls = {};
    const bad = { harness: "bad", label: "bad", quota: true, pollEvery: 120, source: "t", fetch: async () => { calls.bad = (calls.bad || 0) + 1; throw new Error("down"); }, normalize: normalizeClaude };
    const a = await collectUsage({ now: NOW, sources: [bad] });
    assert.equal(a.usage[0].error, "down");
    const b = await collectUsage({ now: NOW + 30_000, sources: [bad], cache: a.cache });
    assert.equal(calls.bad, 1);
    assert.equal(b.usage[0].error, "down");
  });

  test("cache round-trips through disk and holds normalized rows only", async () => {
    const dir = mkdtempSync(join(tmpdir(), "usage-cache-"));
    const file = join(dir, "nested", "usage-cache.json");
    const calls = {};
    const out = await collectUsage({ now: NOW, sources: [counting("c", 60, calls)] });
    assert.equal(saveUsageCache(out.cache, file), true);
    assert.ok(existsSync(file));
    const text = readFileSync(file, "utf8");
    assert.doesNotMatch(text, /Bearer|token|csrf/i);
    const loaded = loadUsageCache(file);
    assert.deepEqual(loaded.entries.c.row, out.usage[0]);
    assert.deepEqual(loadUsageCache(join(dir, "missing.json")), { entries: {} });
  });

  test("stale cache entries for removed sources are dropped", async () => {
    const out = await collectUsage({ now: NOW, sources: [], cache: { entries: { ghost: { fetchedAt: NOW, row: {} } } } });
    assert.deepEqual(out.cache.entries, {});
    assert.deepEqual(out.usage, []);
  });
});

// ---------------------------------------------------------------------------
describe("rendering", () => {
  test("humanizeUntil", () => {
    assert.equal(humanizeUntil(new Date(NOW + 30_000).toISOString(), NOW), "30s");
    assert.equal(humanizeUntil(new Date(NOW + 14 * 60_000).toISOString(), NOW), "14m");
    assert.equal(humanizeUntil(new Date(NOW + (2 * 3600 + 14 * 60) * 1000).toISOString(), NOW), "2h 14m");
    assert.equal(humanizeUntil(new Date(NOW + 3 * 86400_000).toISOString(), NOW), "3d");
    assert.equal(humanizeUntil(new Date(NOW + (3 * 86400 + 5 * 3600) * 1000).toISOString(), NOW), "3d 5h");
    assert.equal(humanizeUntil(new Date(NOW - 5000).toISOString(), NOW), "0s");
    assert.equal(humanizeUntil(null, NOW), "");
  });

  test("renderUsage lists quota rows and folds no-quota rows into one line", () => {
    const usage = [
      { harness: "claude", label: "Claude Code · Max 5x", quota: true, blocked: false, windows: [{ name: "5h", usedPct: 38, resetsAt: new Date(NOW + 3600_000).toISOString() }], error: null },
      { harness: "codex", label: "Codex", quota: true, blocked: true, windows: [{ name: "7d", usedPct: 100, resetsAt: null }], error: null },
      { harness: "agy", label: "Antigravity", quota: true, blocked: false, windows: [], error: "Antigravity not running" },
      { harness: "opencode", label: "OpenCode", quota: false, windows: [], note: "API keys, no quota", error: null },
      { harness: "omnigent", label: "Omnigent", quota: false, windows: [], note: "$12 today", error: null },
    ];
    const text = renderUsage(usage, NOW);
    assert.match(text, /Claude Code · Max 5x: 5h 38% \(resets 1h 0m\)/);
    assert.match(text, /^! Codex: 7d 100%/m);
    assert.match(text, /Antigravity: Antigravity not running/);
    assert.match(text, /no quota: opencode \(API keys, no quota\), omnigent \(\$12 today\)/);
    assert.equal(renderUsage([]), "");
  });
});
