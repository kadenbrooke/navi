#!/usr/bin/env bash
# OPTIONAL Claude Code hook: records whether a session is working, waiting on you,
# or blocked on a permission prompt, in ~/.claude/agent-state/<session_id>.json.
# Navi works without it (Claude Code's own ~/.claude/sessions registry says busy /
# idle); with it, "asking for permission" shows up as needs-input and turn edges
# land faster. Wiring: README → Optional: Claude Code hook.
#
#   agent-state.sh running|waiting|blocked|gone     (hook JSON on stdin)
#
# Fail-open: every path exits 0 and prints nothing, so it never blocks a prompt.

{
  STATE="${1:-}"
  [ -n "$STATE" ] || exit 0

  STATE_DIR="$HOME/.claude/agent-state"
  mkdir -p "$STATE_DIR" || exit 0

  input=$(cat)

  # Flat string field extraction (no jq / python dependency).
  field() {
    printf '%s' "$input" \
      | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
      | head -1
  }

  sid=$(field session_id)
  [ -n "$sid" ] || exit 0
  case "$sid" in */*|*..*) exit 0 ;; esac   # never escape the state dir

  f="$STATE_DIR/$sid.json"
  if [ "$STATE" = "gone" ]; then rm -f "$f"; exit 0; fi

  cwd=$(field cwd)
  [ -n "$cwd" ] || cwd="$PWD"
  branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=""
  label=$(basename "$cwd")
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Liveness is anchored to the owning `claude` process, not $PPID (hooks run under
  # a short-lived `sh -c`). Reuse the pid from a previous event when we have one.
  claude_pid=0
  if [ -f "$f" ]; then
    cached=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$f" | head -1)
    [ -n "$cached" ] && [ "$cached" -gt 1 ] 2>/dev/null && claude_pid=$cached
  fi
  probe=$PPID
  i=0
  [ "$claude_pid" -gt 1 ] && i=99
  while [ "$i" -lt 8 ]; do
    [ -n "$probe" ] && [ "$probe" -gt 1 ] 2>/dev/null || break
    line=$(ps -p "$probe" -o ppid=,comm= 2>/dev/null) || break
    [ -n "$line" ] || break
    line=$(printf '%s' "$line" | sed 's/^ *//')
    parent=${line%% *}
    comm=${line#* }
    if [ "$(basename "$comm")" = "claude" ]; then claude_pid=$probe; break; fi
    probe=$parent
    i=$((i + 1))
  done

  # `since` = when this state began, so a repeated event keeps the original time.
  if [ -f "$f" ]; then
    prev_state=$(sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -1)
    prev_since=$(sed -n 's/.*"since"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -1)
    [ "$prev_state" = "$STATE" ] && [ -n "$prev_since" ] && now="$prev_since"
  fi

  # Write-then-rename so a reader never sees a half-written file.
  printf '{"session_id":"%s","state":"%s","label":"%s","branch":"%s","cwd":"%s","since":"%s","pid":%d}\n' \
    "$sid" "$STATE" "$label" "$branch" "$cwd" "$now" "$claude_pid" \
    > "$f.tmp" && mv -f "$f.tmp" "$f"
} >/dev/null 2>&1

exit 0
