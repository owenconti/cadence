#!/usr/bin/env bash
# Automated check on a throwaway debug copy (build/check/Cadence.app, demo library):
# builds it, plays music, rebuilds it in place, confirms "Update ready", restarts
# it, confirms the new process resumed the same song from the same place, then
# quits and reopens it and confirms the song is back, paused.
# Never touches the user's own app. Screenshots land in build/check/out/.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/check/Cadence.app
# Its own bundle ID, so its settings, saved state and permissions stay apart
# from the user's app.
export BUNDLE_ID=com.owenconti.cadence.check
OUT="$PWD/build/check/out"
post() { notifyutil -p "com.owenconti.cadence.check.$1"; }
state() { post snapshot; sleep 1; python3 -c "import json,sys; print(json.load(open('$OUT/state.json'))['$1'])"; }
fail() { echo "FAIL: $*" >&2; pkill -f "$APP/Contents/MacOS/Cadence" || true; exit 1; }

pkill -f "$APP/Contents/MacOS/Cadence" || true
rm -rf "$OUT"
CONFIG=debug APP="$APP" scripts/bundle.sh >/dev/null
open -g -n --env CADENCE_CHECK_DIR="$OUT" "$APP"
sleep 4

post play; sleep 3
pid=$(state pid); track=$(state track); position=$(state position)
[[ "$(state playing)" == True ]] || fail "music didn't start"
cp "$OUT/window.png" "$OUT/1-playing.png"
echo "ok   playing '$track' at ${position%.*}s (pid $pid)"

CONFIG=debug APP="$APP" scripts/bundle.sh >/dev/null
sleep 4
[[ "$(state updateReady)" == True ]] || fail "rebuild wasn't noticed"
cp "$OUT/window.png" "$OUT/2-update-ready.png"
echo "ok   update ready after rebuild"

post restart; sleep 7
[[ "$(state pid)" != "$pid" ]] || fail "app didn't restart"
[[ "$(state track)" == "$track" ]] || fail "resumed a different song: $(state track)"
[[ "$(state playing)" == True ]] || fail "music didn't resume"
after=$(state position)
python3 -c "import sys; sys.exit(0 if $after >= $position else 1)" || fail "position went back: $position → $after"
[[ "$(state updateReady)" == False ]] || fail "new copy still says update ready"
cp "$OUT/window.png" "$OUT/3-restarted.png"
echo "ok   restarted (pid $(state pid)); '$track' resumed at ${after%.*}s"

inorder=$(state upNext)
post shuffle; sleep 1
[[ "$(state shuffled)" == True ]] || fail "shuffle didn't turn on"
[[ "$(state track)" == "$track" ]] || fail "turning shuffle on changed the current song"
[[ "$(state upNext)" != "$inorder" ]] || fail "shuffle didn't change what's up next"
cp "$OUT/window.png" "$OUT/4-shuffled.png"
echo "ok   shuffle on; '$track' still playing"

post quit; sleep 2
pgrep -f "$APP/Contents/MacOS/Cadence" >/dev/null && fail "app didn't quit"
open -g -n --env CADENCE_CHECK_DIR="$OUT" "$APP"; sleep 5
[[ "$(state track)" == "$track" ]] || fail "after quitting and reopening, got '$(state track)' instead of '$track'"
[[ "$(state playing)" == False ]] || fail "reopened app started playing by itself"
[[ "$(state shuffled)" == True ]] || fail "shuffle wasn't remembered"
cp "$OUT/window.png" "$OUT/5-reopened.png"
echo "ok   quit and reopened; '$track' is back, paused at $(state position | cut -d. -f1)s, still shuffled"

post shuffle; sleep 1
[[ "$(state shuffled)" == False ]] || fail "shuffle didn't turn off"
[[ "$(state track)" == "$track" ]] || fail "turning shuffle off changed the current song"
[[ "$(state upNext)" == "$inorder" ]] || fail "turning shuffle off didn't restore the order: $(state upNext)"
echo "ok   shuffle off; the original order is back"

pkill -f "$APP/Contents/MacOS/Cadence" || true
echo "PASS"
