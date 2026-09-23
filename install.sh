#!/bin/bash
# Install Navi: builds the app, wraps it as ~/Applications/Navi.app (no Dock icon), and
# starts two per-user launchd agents:
#
#   com.navi.collector  collector/run.sh -> collect-daemon.mjs, keeps the snapshot fresh
#   com.navi.app        the floating fairy itself
#
# Every path is derived from where this clone lives, so move the clone -> re-run this.
#
#   ./install.sh              build + install + (re)start both agents
#   ./install.sh --dry-run    print what would happen (plists included); touches nothing
#   ./install.sh --stop       stop both agents until next login or ./install.sh
#   ./install.sh --uninstall  stop, remove both agents and Navi.app (data dir is kept)
#
# Settings are read from your environment NOW and baked into both agents (launchd
# does not see your shell profile). Re-run after changing any of them:
#
#   NAVI_REPO           git repo whose worktrees / PRs to track (optional)
#   NAVI_THREADS_PATH   snapshot file (default ~/.navi/threads.json)
#   NAVI_SFX_DIR        where Navi looks for sound files (default ~/Library/Application Support/Navi/sfx)
#   NAVI_NODE           node binary for the collector (default: auto-detect, needs Node >= 22.13)
#   NAVI_NOTIFY_CMD     optional shell command run for "needs you" changes, line in "$1"
#   NAVI_NO_USAGE=1     skip the quota-usage page's provider polling
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Navi"
BUNDLE_ID="dev.navi.pet"
DEST="$HOME/Applications/$APP_NAME.app"
AGENTS="$HOME/Library/LaunchAgents"
APP_LABEL="com.navi.app"
COLLECTOR_LABEL="com.navi.collector"
APP_LOG="$HOME/Library/Logs/navi.log"
COLLECTOR_LOG="$HOME/Library/Logs/navi-collector.log"
DOMAIN="gui/$(id -u)"

MODE="install"
case "${1:-}" in
  "") ;;
  --dry-run) MODE="dry-run" ;;
  --stop) MODE="stop" ;;
  --uninstall) MODE="uninstall" ;;
  -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
  *) echo "unknown option: $1 (try --help)"; exit 2 ;;
esac

xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; s="${s//\"/&quot;}"
  printf '%s' "$s"
}

# <key>EnvironmentVariables</key> block for every NAVI_* setting that is set.
env_block() {
  local keys=(NAVI_REPO NAVI_THREADS_PATH NAVI_SFX_DIR NAVI_NODE NAVI_NOTIFY_CMD NAVI_NO_USAGE)
  local k any=""
  for k in "${keys[@]}"; do [ -n "${!k:-}" ] && any=1; done
  [ -z "$any" ] && return 0
  echo "  <key>EnvironmentVariables</key>"
  echo "  <dict>"
  for k in "${keys[@]}"; do
    [ -n "${!k:-}" ] && echo "    <key>$k</key><string>$(xml_escape "${!k}")</string>"
  done
  echo "  </dict>"
}

collector_plist() {
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$COLLECTOR_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$(xml_escape "$ROOT/collector/run.sh")</string></array>
  <key>RunAtLoad</key><true/>
  <!-- long-lived event daemon: relaunch whenever it exits, never poll -->
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
$(env_block)
  <key>StandardOutPath</key><string>$(xml_escape "$COLLECTOR_LOG")</string>
  <key>StandardErrorPath</key><string>$(xml_escape "$COLLECTOR_LOG")</string>
</dict>
</plist>
PLIST
}

app_plist() {
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$APP_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$(xml_escape "$DEST/Contents/MacOS/$APP_NAME")</string></array>
  <key>RunAtLoad</key><true/>
  <!-- relaunch after a crash or a kill (non-zero exit); a clean Quit from her menu (exit 0) stays quit -->
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
$(env_block)
  <key>StandardOutPath</key><string>$(xml_escape "$APP_LOG")</string>
  <key>StandardErrorPath</key><string>$(xml_escape "$APP_LOG")</string>
</dict>
</plist>
PLIST
}

info_plist() {
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST
}

bootout() {
  launchctl bootout "$DOMAIN/$1" 2>/dev/null || true
  # bootout is asynchronous; bootstrapping over a lingering label fails with "Input/output error".
  for _ in $(seq 1 20); do
    launchctl print "$DOMAIN/$1" >/dev/null 2>&1 || break
    sleep 0.25
  done
}

stop_all() {
  bootout "$APP_LABEL"
  pkill -x "$APP_NAME" 2>/dev/null || true
  bootout "$COLLECTOR_LABEL"
}

node_ok() {
  # Node >= 22.13: global WebSocket + unflagged node:sqlite (Codex session index).
  "$1" -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>22||(a===22&&b>=13)?0:1)' 2>/dev/null
}

case "$MODE" in
  stop)
    stop_all
    echo "Navi stopped (both agents unloaded until next login or ./install.sh)."
    exit 0 ;;
  uninstall)
    stop_all
    rm -f "$AGENTS/$APP_LABEL.plist" "$AGENTS/$COLLECTOR_LABEL.plist"
    rm -rf "$DEST"
    echo "Navi removed. Data, sounds and prefs are still on disk — see README → Uninstall."
    exit 0 ;;
  dry-run)
    echo "clone:      $ROOT"
    echo "app:        swift build -c release in $ROOT/app -> $DEST (bundle id $BUNDLE_ID)"
    echo "agents:     $AGENTS/$COLLECTOR_LABEL.plist, $AGENTS/$APP_LABEL.plist"
    echo "snapshot:   ${NAVI_THREADS_PATH:-$HOME/.navi/threads.json}"
    echo "repo:       ${NAVI_REPO:-(none — live sessions only)}"
    NODE="${NAVI_NODE:-$(command -v node || true)}"
    if [ -n "$NODE" ] && node_ok "$NODE"; then echo "node:       $NODE ($("$NODE" --version))"; else echo "node:       WARNING — no Node >= 22.13 found (set NAVI_NODE)"; fi
    command -v swift >/dev/null && echo "swift:      $(swift --version 2>&1 | head -1)" || echo "swift:      WARNING — not found (install Xcode or the Command Line Tools)"
    echo; echo "---- $COLLECTOR_LABEL.plist"; collector_plist
    echo; echo "---- $APP_LABEL.plist"; app_plist
    echo; echo "(dry run: nothing built, written, or loaded)"
    exit 0 ;;
esac

command -v swift >/dev/null || { echo "swift not found — install Xcode or the Command Line Tools (xcode-select --install)"; exit 1; }
NODE="${NAVI_NODE:-$(command -v node || true)}"
if [ -z "$NODE" ] || ! node_ok "$NODE"; then
  echo "warning: no Node >= 22.13 on PATH — the collector will not run until one is installed (or NAVI_NODE is set)"
fi

echo "→ swift build -c release"
(cd "$ROOT/app" && swift build -c release 2>&1 | tail -3)
BIN="$ROOT/app/.build/release/BuildThreadsPet"
[ -x "$BIN" ] || { echo "build failed: $BIN missing"; exit 1; }

echo "→ assembling $DEST"
stop_all                                       # bootout first, or KeepAlive relaunches the old binary mid-copy
rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp "$BIN" "$DEST/Contents/MacOS/$APP_NAME"
info_plist > "$DEST/Contents/Info.plist"
# Ad-hoc sign so launch-at-login (SMAppService) and Gatekeeper are happy locally.
codesign --force --sign - "$DEST" >/dev/null 2>&1 || echo "  (codesign skipped)"

mkdir -p "$AGENTS" "$HOME/Library/Logs" "$(dirname "${NAVI_THREADS_PATH:-$HOME/.navi/threads.json}")"
chmod +x "$ROOT/collector/run.sh"

echo "→ installing $COLLECTOR_LABEL"
collector_plist > "$AGENTS/$COLLECTOR_LABEL.plist"
launchctl bootstrap "$DOMAIN" "$AGENTS/$COLLECTOR_LABEL.plist"

echo "→ installing $APP_LABEL"
app_plist > "$AGENTS/$APP_LABEL.plist"
launchctl bootstrap "$DOMAIN" "$AGENTS/$APP_LABEL.plist"

sleep 1
if pgrep -x "$APP_NAME" >/dev/null; then
  echo "done. Navi is up (pid $(pgrep -x "$APP_NAME" | head -1)); logs: $APP_LOG, $COLLECTOR_LOG"
else
  echo "agents loaded but Navi is not running yet — check $APP_LOG"; exit 1
fi
echo "She appears bottom-right and follows your cursor. ⌥⌘P sleep/wake · ⌥⌘N hide/show · menubar Triforce has the rest."
echo "Stop her for good: ./install.sh --stop   (a plain kill just brings her back)"
