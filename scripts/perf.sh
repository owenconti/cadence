#!/usr/bin/env bash
# Measures animation lag on a throwaway release copy (demo library): opens the
# biggest playlist (80 songs) three times and prints the longest main-thread
# stall during the page transition. The first open of a session is slowest.
# 16 ms is one frame at 60 Hz.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/check/Cadence.app
OUT="$PWD/build/check/perf"
export BUNDLE_ID=com.owenconti.cadence.check

pkill -f "$APP/Contents/MacOS/Cadence" || true
rm -rf "$OUT"
APP="$APP" scripts/bundle.sh >/dev/null
open -g -n --env CADENCE_CHECK_DIR="$OUT" "$APP"
sleep 4
for i in 1 2 3; do
    notifyutil -p com.owenconti.cadence.check.open-largest
    sleep 3.2
    notifyutil -p com.owenconti.cadence.check.snapshot
    sleep 0.8
    python3 -c "import json; print('open playlist $i: stalled', json.load(open('$OUT/state.json'))['stallMs'], 'ms during the transition')"
done
pkill -f "$APP/Contents/MacOS/Cadence" || true
