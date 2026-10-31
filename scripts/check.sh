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
# Posts a hook until a state key has the value (notifications can be dropped).
until_state() { for _ in 1 2 3; do post "$1"; sleep 0.6; [[ "$(state "$2")" == "$3" ]] && return 0; done; return 1; }
fail() { echo "FAIL: $*" >&2; pkill -f "$APP/Contents/MacOS/Cadence" || true; exit 1; }

pkill -f "$APP/Contents/MacOS/Cadence" || true
rm -rf "$OUT"
CONFIG=debug APP="$APP" scripts/bundle.sh >/dev/null
open -g -n --env CADENCE_CHECK_DIR="$OUT" "$APP"
sleep 4

post play; sleep 3
pid=$(state pid); track=$(state track); position=$(state position); source=$(state source)
[[ "$source" == Playlist:* ]] || fail "no 'playing from' source: $source"
[[ "$(state playing)" == True ]] || fail "music didn't start"
cp "$OUT/window.png" "$OUT/1-playing.png"
echo "ok   playing '$track' at ${position%.*}s (pid $pid), from $source"

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
[[ "$(state source)" == "$source" ]] || fail "lost where it was playing from: $(state source)"
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
[[ "$(state source)" == "$source" ]] || fail "lost where it was playing from after reopening: $(state source)"
cp "$OUT/window.png" "$OUT/5-reopened.png"
echo "ok   quit and reopened; '$track' is back, paused at $(state position | cut -d. -f1)s, still shuffled"

post open-album; sleep 1.5
[[ "$(state page)" == album ]] || fail "clicking the album didn't open it: $(state page)"
echo "ok   opened the album '$(state pageTitle)' from Now Playing"

post shuffle; sleep 1
[[ "$(state shuffled)" == False ]] || fail "shuffle didn't turn off"
[[ "$(state track)" == "$track" ]] || fail "turning shuffle off changed the current song"
[[ "$(state upNext)" == "$inorder" ]] || fail "turning shuffle off didn't restore the order: $(state upNext)"
echo "ok   shuffle off; the original order is back"

post snapshot; sleep 1
python3 - "$OUT/state.json" <<'PY' || fail "playlist sorting is wrong"
import json, sys
s = json.load(open(sys.argv[1]))
names, sizes = s["playlistsName"], [int(x.rsplit(":", 1)[1]) for x in s["playlistsSize"]]
assert names == sorted(names, key=str.casefold), ("A–Z", names)
assert sizes == sorted(sizes, reverse=True) and min(sizes) >= 0, ("Largest", s["playlistsSize"])
PY
post play-last-playlist; sleep 1.5
last=$(state source | sed 's/^Playlist: //')
recent=$(python3 -c "import json; print(json.load(open('$OUT/state.json'))['playlistsRecent'][0])")
[[ "$recent" == "$last" ]] || fail "Recent doesn't put the playlist just played ('$last') first: '$recent'"
echo "ok   playlists sort A–Z, by size, and by recent ('$last' first after playing it)"

post focus-filter; sleep 1
post palette; sleep 0.6
post type-glass; sleep 0.6
[[ "$(state paletteQuery)" == glass && -z "$(state filterText)" ]] || fail "typing after opening ⌘K didn't reach its search field (query '$(state paletteQuery)', page filter '$(state filterText)')"
post palette-close; sleep 0.3
echo "ok   ⌘K opens with its search field focused: typing lands in it, even from a filter field"

until_state sidebar-hide sidebarHidden True || fail "⌘B didn't hide the sidebar"
cp "$OUT/window.png" "$OUT/6-sidebar-hidden.png"
until_state sidebar-show sidebarHidden False || fail "⌘B didn't bring the sidebar back"
echo "ok   ⌘B hides and shows the sidebar"

until_state now-playing-on nowPlayingMode True || fail "⇧⌘F didn't open Now Playing"
cp "$OUT/window.png" "$OUT/7-now-playing.png"
until_state now-playing-off nowPlayingMode False || fail "⇧⌘F didn't leave Now Playing"
echo "ok   ⇧⌘F opens and leaves Now Playing"

pkill -f "$APP/Contents/MacOS/Cadence" || true

# Artwork from the real library: every source must draw.
scripts/artwork.sh | sed 's/^/     artwork: /' || fail "artwork didn't draw; see build/audit/out/report.txt"
echo "PASS"
