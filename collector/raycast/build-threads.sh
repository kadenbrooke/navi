#!/bin/bash
#
# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Build Threads
# @raycast.mode fullOutput
#
# Optional parameters:
# @raycast.icon 🧵
# @raycast.packageName Navi
# @raycast.description One list of every build thread (worktree + branch + PR) in plain English

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export NO_COLOR=1
# --cached renders the last snapshot instantly; the launchd watcher refreshes it
# on every change. Falls back to a live collect when no snapshot exists yet.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$HERE/../collect.mjs" --table --cached
