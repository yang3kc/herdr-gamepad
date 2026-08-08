#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

STATE="${HERDR_PLUGIN_STATE_DIR:-$HOME/.config/herdr/plugins/state/gamepad}"
PIDFILE="$STATE/daemon.pid"

if [ ! -f "$PIDFILE" ]; then
  echo "not running (no pidfile)"
  exit 0
fi

pid="$(cat "$PIDFILE")"
if kill -0 "$pid" 2>/dev/null; then
  kill "$pid"
  echo "stopped (pid $pid)"
else
  echo "not running (stale pidfile)"
fi
rm -f "$PIDFILE"
