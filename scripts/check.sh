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
# Writes a fresh state.json: numbered, so a late snapshot can't pass for this one.
snapshot() {
    local id="$RANDOM$RANDOM$RANDOM"; echo "$id" > "$OUT/snapshot.txt"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        post snapshot; sleep 0.3
        [[ "$(python3 -c "import json; print(json.load(open('$OUT/state.json')).get('snapshot'))" 2>/dev/null)" == "$id" ]] && return 0
    done
    echo "warning: no fresh snapshot" >&2
}
state() { snapshot; python3 -c "import json,sys; print(json.load(open('$OUT/state.json'))['$1'])"; }
# Posts a hook until a state key has the value (notifications can be dropped).
until_state() { for _ in 1 2 3; do post "$1"; sleep 0.6; [[ "$(state "$2")" == "$3" ]] && return 0; done; return 1; }
# Presses a key once (see CheckHooks `press`), resending until the app says it ran.
presses=0
press() {
    presses=$((presses + 1)); echo "$presses $1" > "$OUT/press.txt"
    for _ in 1 2 3 4 5; do post press; sleep 0.4; [[ "$(state pressed)" == "$presses" ]] && return 0; done
    return 1
}
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

until_state select-artists section artists || fail "couldn't go to Artists"
queue=$(state queueIDs); index=$(state index); position=$(state position); restarted_at=$(date +%s)
post restart; sleep 7
[[ "$(state pid)" != "$pid" ]] || fail "app didn't restart"
[[ "$(state track)" == "$track" ]] || fail "resumed a different song: $(state track)"
[[ "$(state queueIDs)" == "$queue" ]] || fail "the queue changed across the restart"
[[ "$(state index)" == "$index" ]] || fail "resumed at queue position $(state index) instead of $index"
[[ "$(state section)" == artists ]] || fail "came back to $(state section) instead of Artists"
[[ "$(state playing)" == True ]] || fail "music didn't resume"
after=$(state position); elapsed=$(( $(date +%s) - restarted_at ))
python3 -c "import sys; sys.exit(0 if $position <= $after <= $position + $elapsed + 3 else 1)" \
    || fail "resumed at ${after}s; expected ${position}s plus the ${elapsed}s the restart took"
[[ "$(state updateReady)" == False ]] || fail "new copy still says update ready"
[[ "$(state source)" == "$source" ]] || fail "lost where it was playing from: $(state source)"
cp "$OUT/window.png" "$OUT/3-restarted.png"
echo "ok   restarted (pid $(state pid)); '$track' resumed at ${after%.*}s"

inorder=$(state upNextAll)
post shuffle; sleep 1
[[ "$(state shuffled)" == True ]] || fail "shuffle didn't turn on"
[[ "$(state track)" == "$track" ]] || fail "turning shuffle on changed the current song"
[[ "$(state upNextAll)" != "$inorder" ]] || fail "shuffle didn't change what's up next"
cp "$OUT/window.png" "$OUT/4-shuffled.png"
echo "ok   shuffle on; '$track' still playing"

queue=$(state queueIDs); index=$(state index); quit_position=$(state position)
post quit; sleep 2
pgrep -f "$APP/Contents/MacOS/Cadence" >/dev/null && fail "app didn't quit"
open -g -n --env CADENCE_CHECK_DIR="$OUT" "$APP"; sleep 5
[[ "$(state track)" == "$track" ]] || fail "after quitting and reopening, got '$(state track)' instead of '$track'"
[[ "$(state playing)" == False ]] || fail "reopened app started playing by itself"
[[ "$(state queueIDs)" == "$queue" && "$(state index)" == "$index" ]] || fail "the queue or its position changed across quitting"
reopened=$(state position)
python3 -c "import sys; sys.exit(0 if abs($reopened - $quit_position) <= 3 else 1)" || fail "reopened at ${reopened}s instead of about ${quit_position}s"
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
[[ "$(state upNextAll)" == "$inorder" ]] || fail "turning shuffle off didn't restore the order"
echo "ok   shuffle off; the original order is back"

snapshot
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
press cmd-k && [[ "$(state paletteOpen)" == True ]] || fail "⌘K didn't open the palette"
post type-glass; sleep 0.6
[[ "$(state paletteQuery)" == glass && -z "$(state filterText)" ]] || fail "typing after opening ⌘K didn't reach its search field (query '$(state paletteQuery)', page filter '$(state filterText)')"
press esc && [[ "$(state paletteOpen)" == False ]] || fail "Esc didn't close ⌘K"
echo "ok   ⌘K opens with its search field focused: typing lands in it, even from a filter field; Esc closes it"

press cmd-b && [[ "$(state sidebarHidden)" == True ]] || fail "⌘B didn't hide the sidebar"
cp "$OUT/window.png" "$OUT/6-sidebar-hidden.png"
press cmd-b && [[ "$(state sidebarHidden)" == False ]] || fail "⌘B didn't bring the sidebar back"
echo "ok   ⌘B hides and shows the sidebar"

press shift-cmd-f && [[ "$(state nowPlayingMode)" == True ]] || fail "⇧⌘F didn't open Now Playing"
cp "$OUT/window.png" "$OUT/7-now-playing.png"
press esc && [[ "$(state nowPlayingMode)" == False ]] || fail "Esc didn't leave Now Playing"
press shift-cmd-f && [[ "$(state nowPlayingMode)" == True ]] || fail "⇧⌘F didn't open Now Playing again"
press shift-cmd-f && [[ "$(state nowPlayingMode)" == False ]] || fail "⇧⌘F didn't leave Now Playing"
echo "ok   ⇧⌘F opens and leaves Now Playing, as does Esc"

# The same song twice in the queue: quitting and reopening comes back to the
# copy that was playing, not the first.
until_state play-duplicates index 2 || fail "couldn't play a queue with a song in it twice"
sleep 2.5
post quit; sleep 2
open -g -n --env CADENCE_CHECK_DIR="$OUT" "$APP"; sleep 5
[[ "$(state index)" == 2 ]] || fail "reopened at queue position $(state index) instead of 2, the second copy of the song"
echo "ok   a song queued twice comes back as the copy that was playing"

pkill -f "$APP/Contents/MacOS/Cadence" || true

# Artwork from the real library: every source must draw.
scripts/artwork.sh | sed 's/^/     artwork: /' || fail "artwork didn't draw; see build/audit/out/report.txt"
echo "PASS"
