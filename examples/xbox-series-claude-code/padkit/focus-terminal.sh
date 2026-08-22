#!/usr/bin/env bash
# Bring the terminal running herdr to the front.
#
# Activates twice with a pause. The gamepad binding for this lives on the Xbox
# button, which macOS used to answer by opening its Game Overlay — and that
# window won the focus race against a single activation. The overlay is now
# switched off in System Settings -> Game Controllers, so one activation would
# do; the retry stays because that setting is easy to lose across machines and
# OS updates, and a second `open` on an already-frontmost app costs nothing.
set -euo pipefail

APP="${PADKIT_TERMINAL_APP:-Warp}"

open -a "$APP"
sleep 0.6
open -a "$APP"
