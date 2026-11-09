#!/usr/bin/env bash
# Artwork audit against the real Apple Music library: builds a copy at
# build/audit/Cadence.app under the app's own bundle ID (MusicKit only serves
# registered IDs), which walks every place the app gets artwork from, draws
# each one, writes build/audit/out/report.txt and quits. Read-only: it starts
# no playback and saves nothing, and it never touches /Applications/Cadence.app.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/audit/Cadence.app
OUT="$PWD/build/audit/out"

pkill -f "$APP/Contents/MacOS/Cadence" || true
rm -rf "$OUT"
APP="$APP" BUNDLE_ID=com.owenconti.cadence CONFIG=release scripts/bundle.sh >/dev/null
open -g -n --env CADENCE_ARTWORK_AUDIT="$OUT" "$APP"
for _ in $(seq 1 300); do [[ -f "$OUT/report.txt" ]] && break; sleep 1; done
[[ -f "$OUT/report.txt" ]] || { pkill -f "$APP/Contents/MacOS/Cadence" || true; echo "FAIL: the audit didn't finish in 5 minutes" >&2; exit 1; }
grep -v '^note ' "$OUT/report.txt"
cat "$OUT/cloud.txt" 2>/dev/null && echo
notes=$(grep -c '^note ' "$OUT/report.txt" || true)
[[ "$notes" -gt 0 ]] && echo "($notes items have no artwork in Apple Music and show the placeholder; see $OUT/report.txt)"
! grep -q '^FAIL' "$OUT/cloud.txt" 2>/dev/null && [[ "$(head -1 "$OUT/report.txt")" == PASS ]]
