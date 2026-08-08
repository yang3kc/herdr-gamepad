#!/usr/bin/env bash
# Starts the daemon detached, so it outlives the shell (or plugin action)
# that launched it.
set -euo pipefail

cd "$(dirname "$0")"

STATE="${HERDR_PLUGIN_STATE_DIR:-$HOME/.config/herdr/plugins/state/gamepad}"
mkdir -p "$STATE"
PIDFILE="$STATE/daemon.pid"
LOGFILE="$STATE/daemon.log"

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "already running (pid $(cat "$PIDFILE"))"
  exit 0
fi

if [ ! -x bin/herdr-gamepad ]; then
  echo "binary missing — run ./build.sh first" >&2
  exit 1
fi

nohup ./bin/herdr-gamepad daemon >>"$LOGFILE" 2>&1 &
pid=$!
echo "$pid" >"$PIDFILE"
echo "started (pid $pid), logging to $LOGFILE"
