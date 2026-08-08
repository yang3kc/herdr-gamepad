#!/usr/bin/env bash
# Builds the daemon. Invoked by herdr on `plugin install` / `plugin link`
# via the [[build]] step in herdr-plugin.toml.
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found." >&2
  echo "Install Xcode command line tools:  xcode-select --install" >&2
  exit 1
fi

mkdir -p bin
swiftc -O src/*.swift -o bin/herdr-gamepad
echo "built bin/herdr-gamepad"
