#!/usr/bin/env bash
# Build and launch Cadence.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/bundle.sh
if pkill -x Cadence 2>/dev/null; then
    while pgrep -x Cadence >/dev/null; do sleep 0.2; done
fi
open build/Cadence.app
