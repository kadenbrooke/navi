#!/bin/bash
# launchd entry point: exec the event-driven collector daemon (collect-daemon.mjs).
# It stays up under KeepAlive, rewrites threads.json on every agent-state edge,
# and announces status changes itself (notify.mjs runs in-process after each
# write). Logs go wherever launchd points stdout/stderr (install.sh: ~/Library/Logs/navi-collector.log).
#
#   run.sh            the daemon (what launchd runs)
#   run.sh --once     one collect + notify and exit (the pre-daemon behaviour)
#
# launchd runs this with a bare PATH (/usr/bin:/bin:/usr/sbin:/sbin) and no shell
# profile, so `node` is resolved here explicitly. Order: NAVI_NODE override,
# then the usual install locations, then whatever PATH already has.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

resolve_node() {
  local candidates=(
    "${NAVI_NODE:-}"
    "$HOME/.local/bin/node"
    "/opt/homebrew/bin/node"
    "/usr/local/bin/node"
    "$HOME/.volta/bin/node"
  )
  local c
  for c in "${candidates[@]}"; do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
  done
  # nvm: newest installed version
  local nvm_node
  # shellcheck disable=SC2012  # sort -V needs a list; version dirs have no odd characters
  nvm_node="$(ls -d "$HOME"/.nvm/versions/node/*/bin/node 2>/dev/null | sort -V | tail -1)"
  [ -n "$nvm_node" ] && [ -x "$nvm_node" ] && { echo "$nvm_node"; return 0; }
  command -v node 2>/dev/null && return 0
  return 1
}

NODE="$(resolve_node)" || {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] FATAL: no node binary found (looked in \$NAVI_NODE, ~/.local/bin, /opt/homebrew/bin, /usr/local/bin, ~/.volta/bin, ~/.nvm, PATH). Navi's threads.json will go stale."
  exit 127
}

if [ "${1:-}" = "--once" ]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] collect (node: $NODE)"
  "$NODE" "$HERE/collect.mjs" || echo "collect failed (exit $?)"
  "$NODE" "$HERE/notify.mjs" || echo "notify failed (exit $?)"
  exit 0
fi

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] daemon (node: $NODE)"
# exec so launchd tracks node itself: SIGTERM reaches the daemon, KeepAlive sees its exit.
exec "$NODE" "$HERE/collect-daemon.mjs"
