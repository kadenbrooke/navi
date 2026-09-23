# Navi collector

Technical reference for the collector. Install and settings: the [top-level README](../README.md).

One list of every piece of work in flight, in plain English. No worktree /
branch / PR vocabulary to decode — each row says what it is and whether it
needs you.

A **build thread** is one unit of work: a git worktree, its branch, whatever
agent sessions (Claude Code, Codex, Cursor, Omnigent/polly) are working in it,
and its PR if one exists.

**A row exists only while a live parent session backs it.** Live = the harness
process is running right now (Omnigent says its runner is online; a Claude Code
or Codex process is alive). Parent = not a sub-agent. Everything else is hidden:
a chat whose runner is gone, a sub-agent (it folds into its parent's row), an
archived chat, a worktree or open PR with nobody on it. Git and PR facts
decorate a row; they never create one. The leftovers — worktrees and PRs with
nobody live behind them — are kept in the snapshot's `dormant[]` for Raycast /
phone use; Navi ignores them.

A live session with no worktree of its own (most polly / assistant chats run in the
main checkout, or a Claude Code TUI in the main checkout) gets a row of its own,
id `omnigent:<id>` / `claude:<id>` / `codex:<id>`. An Omnigent-launched Claude
Code worker appears once, under its Omnigent row.

Rows are named for people, never by hash: PR title, else the branch name (unless
it is `main` or an auto-name like `worktree-b1468d65`), else the newest
session's title, else the folder name.

## Running it

`../install.sh` loads a launchd job (`com.navi.collector`, `KeepAlive`, no
`StartInterval`) that keeps `collect-daemon.mjs` running. The daemon rewrites
the list within ~half a second of an agent changing state and pings you only
when a thread's status changes.

launchd runs `run.sh` with a bare `PATH`, so it resolves `node` itself
(`$NAVI_NODE`, then `~/.local/bin`, Homebrew, `/usr/local/bin`, `~/.volta/bin`,
newest nvm, then `PATH`) and logs a FATAL line if none is found. If Navi says
the collector is stale, look at `~/Library/Logs/navi-collector.log` first.
`run.sh --once` is a one-shot (collect + notify, exit).

### The daemon (`collect-daemon.mjs`)

Event-driven; it idles at ~0 % CPU and forks nothing between events.

| Source | What it announces | Cost of the resulting collect |
|---|---|---|
| `ws://127.0.0.1:6767/v1/sessions/updates` (one socket, Omnigent's own sidebar feed; a `watch` of every known session id) | any Omnigent session row changing, new sessions, archives | no forks — git / PR / `ps` / codex / usage come from the last tick's cache |
| `GET /v1/sessions/{id}/stream` (SSE, one per **running** Omnigent parent, closed when it stops) | the parent's OWN `session.status` edges, sub-second | same |
| `fs.watch ~/.claude/sessions`, `~/.claude/agent-state` | Claude Code turn start / end (the hooks rewrite these files) | one `ps` |
| `fs.watch $NAVI_REPO/.git/worktrees` | a worktree added or removed | git + gh refresh |
| 60 s tick | git / PR / registry / codex / quota usage refresh, a REST resync of the Omnigent list, and a write so `generatedAt` never goes stale | the old full collect (~2–3 s) |

Every event goes through one 300 ms debounce, so a burst is one collect; a
collect is written with temp-file + rename, so Navi never reads a half-written
file. WS and SSE reconnect with capped exponential backoff (1 s → 30 s).

**Omnigent down.** The socket drops; the last-good chat rows stay for a 20 s
grace (a server restart does not flash every row away), then the `omnigent`
source is reported unavailable and its rows are **dropped** — never kept alive
from memory. They return on reconnect. Git / Claude / Codex rows are unaffected.

**Parent-only status.** Omnigent's list feed rolls
sub-agents up into the parent's status — a parent reads `running` while any
child runs, even after its own turn ended. That is exactly the moment you
want to know about, so the row's state comes from the parent's OWN
status instead: the per-session SSE carries it live, and the detail endpoint
(`GET /v1/sessions/{id}?include_items=false`) supplies the baseline when a
stream opens. The one-shot `collect.mjs` asks the detail endpoint for every
running parent. A parent that is idle while children run shows
`Agent idle, nothing waiting · … (sub-agents still running)`. Each row's
`sessions[]` carries `child: true` on sub-agents so Navi applies the same rule.

**Raycast:** in Raycast → Extensions → Script Commands, add
`collector/raycast` as a directory (it reads the default `~/.navi/threads.json`). The command is **Build Threads**.

## Reading the list

| Mark | What you see | What it means | What to do |
|---|---|---|---|
Live rows (what Navi shows), first match wins:

| Mark | What you see | What it means | What to do |
|---|---|---|---|
| `?` | Agent waiting on your reply | The agent asked you a question, has a reply you have not read, needs a permission, or its PR is reviewed and waiting on your merge | Open the chat / PR, answer |
| `!` | Agent hit an error | The session failed (detail is the error, e.g. "Runner disconnected"), or its branch rotted (20+ commits behind main, or no commit for a week) | Open the chat; restart, rebase, or archive |
| `●` | Agent working | The harness is mid-turn right now | Nothing |
| `○` | Agent idle, nothing waiting | Live but resting; detail notes uncommitted / unpushed work or an open PR | Nothing |

Every live row also carries `lastSeen` (newest session activity, ISO 8601) and
`idle` — true when the row is resting *and* that activity is older than
`THRESHOLDS.ACTIVE_SESSION_MINUTES` (10). Idle rows are never dropped; Navi dims
them and lists them after the active ones. Rows sort by state, then active
before idle, then most recent activity.

Omnigent-backed rows carry two links: `omnigentUrl` (web UI,
`http://127.0.0.1:6767/c/<id>`) and `omnigentDeepLink` (desktop app,
`omnigent://localhost:6767/c/<id>`, port required). Both derive from the one
`OMNIGENT_BASE` in `collect.mjs`; the deep link leads the row's actions as
"Open chat in Omnigent", the web url follows as "Open chat in browser".

Dormant rows (`dormant[]` in the JSON — worktrees and PRs with nobody live on them; Navi does not show these):

| Mark | What you see | What it means | What to do |
|---|---|---|---|
| `!` | Behind main — needs a rebase or should be deleted | It fell far behind (20+ commits) or nobody committed for a week | Decide: catch it up or delete it |
| `?` | PR waiting on you | A reviewer signed off; your merge is the last step | Open the PR, merge |
| `?` | PR open, review not done | A PR exists, nobody has reviewed it yet | Nothing — wait |
| `~` | Work on your Mac only, not saved to git yet | Edited files that were never committed | Commit it or delete it |
| `^` | Committed but not backed up to GitHub | Commits exist locally that GitHub doesn't have | Push it |
| `✓` | Merged — safe to delete this worktree | Its PR is merged; the folder is leftover | Run the delete command it offers |
| `○` | Pushed, nothing waiting | Backed up, no PR, no agent | Nothing |

A dormant thread that is both behind main and has uncommitted work shows as
"Behind main" because that is the bigger problem.

## Notifications

- Any status change → a macOS notification.
- A PR becoming **waiting on you**, or a thread going **stale** → also runs your
  `NAVI_NOTIFY_CMD`, if set (message in `"$1"`).
- An agent pausing and resuming (working ↔ nothing waiting) is never announced.
- A row disappearing because its harness quit is never announced; if it comes
  back it is a fresh first sighting.
- Dormant threads are never announced (they are not in `threads[]`).
- First run after install records a baseline silently; you are not pinged 16 times.

## By hand

```bash
node collector/collect.mjs --table   # the list, refreshed now
node collector/collect.mjs --json    # the raw snapshot
node collector/notify.mjs --dry-run  # what would be announced
```

Snapshot: `$NAVI_THREADS_PATH` (default `~/.navi/threads.json`). Log: `~/Library/Logs/navi-collector.log`.

## Where the facts come from

| Fact | Source |
|---|---|
| Threads, dirty files, pushed/unpushed, behind main, last commit | `git` in each worktree of `NAVI_REPO` (read-only; skipped when unset) |
| PR number / open / merged | one `gh pr list` call for the whole repo |
| "Reviewed, ready for you" | `.polly/registry.json` in `NAVI_REPO`, if you use Omnigent's polly orchestrator |
| Claude Code sessions | `~/.claude/sessions/` + optional `~/.claude/agent-state/`; live iff the pid is alive (pid 0 = dead) and it is not an Omnigent-launched worker |
| Omnigent / polly sessions | `http://127.0.0.1:6767/v1/sessions`, paged with `?limit=200&after=<last_id>` until `has_more` is false, capped at 500 (the daemon keeps the same rows fresh over `ws://…/v1/sessions/updates`); live iff `runner_online` (or its runner is in `/v1/runners`); skipped if down |
| Omnigent parent's own status | per-session SSE `session.status` (daemon) / `GET /v1/sessions/{id}?include_items=false` (one-shot + daemon baseline) — the list status is a child roll-up |
| Codex sessions | `~/.codex/state_*.sqlite`; live iff a `codex` TUI process has its cwd there (`ps` + `lsof`) |
| Which processes are alive / Omnigent-launched | one `ps -axo pid,ppid,command` per run |

Any source that is down is reported in the table footer; the list still renders
from git alone. Thresholds live in one `THRESHOLDS` block at the top of
`collect.mjs`.

## Troubleshooting

- PR link opens a GitHub 404 → sign into github.com in your default browser (a
  private repo needs it). The link is exactly what `gh pr list --json url` returned.
- No Omnigent chats in the list → the footer says `omnigent` is unavailable; is
  Omnigent running on port 6767?
- A chat you expect is missing → Omnigent says its runner is offline (open it in
  Omnigent; a restarted runner makes it reappear on the next refresh), it is a
  sub-agent (look under its parent's row), or it is archived.
- A worktree or open PR you expect is missing → nobody is live on it. It is in
  `dormant[]` in the snapshot; open a session in it
  and it becomes a row.
- `ps` unavailable in the footer → every Claude Code TUI is assumed a person's
  (no Omnigent dedupe), Codex threads all read as dead, and channel listeners
  cannot be told apart from people (see next).
- A channel listener (`claude --channels plugin:…@…`, e.g. a chat bridge) registers a
  Claude Code session like any TUI, but it is a daemon, not a build thread: any
  Claude process whose command line carries `--channels` is excluded
  (`isChannelListener`, both the session-registry and agent-state paths).
- Pressing Enter on an Omnigent-backed row opens the chat in the Omnigent desktop
  app (`omnigent://localhost:6767/c/<id>`); Navi's "Open chats in browser" pref
  switches that to the web url. Chat rows have no worktree, so there is no "open
  terminal" action; PR / terminal on a worktree row backed by an Omnigent session
  are in the right-click menu.

## Quota usage (`usage.mjs` → `snapshot.usage[]`)

Navi's last menu page shows how much of each harness's quota is used. The collector
polls every source on its own `pollEvery` (seconds) and reuses the last result in
between, so the 60 s tick never hammers a provider:

| Row | Where | Every |
|---|---|---|
| Claude Code | `api.anthropic.com/api/oauth/usage` — OAuth token from the Claude Code keychain item | 120 s |
| Codex | `chatgpt.com/backend-api/wham/usage` (token from `~/.codex/auth.json`); falls back to `codex app-server` JSON-RPC | 300 s |
| Cursor | `api2.cursor.sh` DashboardService — token from the `cursor-access-token` keychain item | 300 s |
| Antigravity | the IDE's loopback language server (`RetrieveUserQuotaSummary`); "Antigravity not running" when the IDE is closed | 120 s |
| OpenRouter (hermes + pi) | `openrouter.ai/api/v1/auth/key` — key from `~/.hermes/.env`, else `~/.pi/agent/auth.json` | 300 s |
| Nous (hermes) | `portal.nousresearch.com/api/billing/subscription` — token from `~/.hermes/auth.json` | 600 s |
| OpenCode | static "API keys, no quota" | — |
| Omnigent | `http://127.0.0.1:6767/v1/usage` → dollars today, no quota | 60 s |

Every fetcher is non-fatal: a failure becomes `error: "<short reason>"` on that row
(e.g. `token stale, open claude`) and the rest still render. The cache lives at
`usage-cache.json` next to the snapshot and holds normalized
rows only — never a token, keychain output, or CSRF value. `NAVI_NO_USAGE=1`
skips the whole block. `--table` prints the rows under a `quota usage` heading.

Row shape: `{ harness, label, plan?, sharedBy?, quota, windows: [{ name, usedPct,
resetsAt, severity?, active?, scope? }], credits?, blocked, blockedReason?, source,
fetchedAt, error, note?, costTodayUsd? }`. `usedPct` may exceed 100; windows are
sorted shortest → longest; `blocked` = provider says so OR any active window ≥ 100.

Tests: `node --test collector/*.test.mjs` (collector, daemon with fake WS / SSE /
REST, notifier, usage — nothing touches the live Omnigent server).
