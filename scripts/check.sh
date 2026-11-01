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
    return 1
}
# Reading state that isn't fresh would test the wrong thing: stop the check.
state() {
    snapshot || { echo "FAIL: the app didn't answer for its state" >&2; pkill -f "$APP/Contents/MacOS/Cadence"; kill "$$"; exit 1; }
    python3 -c "import json,sys; print(json.load(open('$OUT/state.json'))['$1'])"; }
# Posts a hook until a state key has the value (notifications can be dropped).
until_state() { for _ in 1 2 3; do post "$1"; sleep 0.6; [[ "$(state "$2")" == "$3" ]] && return 0; done; return 1; }
# Presses a key once (see CheckHooks `press`), resending until the app says it ran.
presses=0
press() {
    presses=$((presses + 1)); echo "$presses $1" > "$OUT/press.txt"
    for _ in 1 2 3 4 5; do post press; sleep 0.4; [[ "$(state pressed)" == "$presses" ]] && return 0; done
    return 1
}
# Runs steps inside the app, in order (see CheckHooks `run`), and waits for them.
steps() {
    local id="$RANDOM$RANDOM$RANDOM"
    { echo "$id"; printf '%s\n' "$@"; } > "$OUT/run.txt"
    for _ in $(seq 1 40); do post run; sleep 0.5; [[ "$(state ran)" == "$id" ]] && return 0; done
    return 1
}
# Cadence's queue and the engine's must match: same songs, same order.
in_step() {
    [[ "$(state queueIDs)" == "$(state engineQueueIDs)" ]] || fail "$1: Cadence's queue and the player's differ"
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

queue=$(state queueIDs); index=$(state index); quit_position=$(state position); pid=$(state pid)
post quit; sleep 2
pgrep -f "$APP/Contents/MacOS/Cadence" >/dev/null && fail "app didn't quit"
open -g -n --env CADENCE_CHECK_DIR="$OUT" "$APP"; sleep 5
[[ "$(state pid)" != "$pid" ]] || fail "still talking to the copy that was asked to quit"
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

snapshot || fail "the app didn't answer for its state"
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
[[ "$(state mosaics)" -ge 1 ]] || fail "no playlist got a cover made of its songs' covers"
echo "ok   playlists get covers made of their songs' covers ($(state mosaics))"

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
pid=$(state pid)
post quit; sleep 2
pgrep -f "$APP/Contents/MacOS/Cadence" >/dev/null && fail "app didn't quit"
open -g -n --env CADENCE_CHECK_DIR="$OUT" "$APP"; sleep 5
[[ "$(state pid)" != "$pid" ]] || fail "still talking to the copy that was asked to quit"
[[ "$(state index)" == 2 ]] || fail "reopened at queue position $(state index) instead of 2, the second copy of the song"
echo "ok   a song queued twice comes back as the copy that was playing"

until_state play-duplicates-first index 0 || fail "couldn't play a queue with a song in it twice, from the first copy"
inorder=$(state upNextAll)
press cmd-s && [[ "$(state shuffled)" == True ]] || fail "⌘S didn't turn shuffle on"
press cmd-s && [[ "$(state shuffled)" == False ]] || fail "⌘S didn't turn shuffle off"
[[ "$(state upNextAll)" == "$inorder" ]] || fail "shuffle on then off changed the order of a queue with a song in it twice"
echo "ok   ⌘S on and off puts a queue with a song in it twice back in order"

# The player's timing paths, with the simulated engine slowed down or
# refusing, as Apple Music can be.
steps "sim prepare=2" "play-playlist 0" "toggle" "wait 3" "sim prepare=0" || fail "steps didn't run"
[[ "$(state playingNow)" == False && "$(state enginePlaying)" == False ]] || fail "a pause while the queue was still starting didn't hold"
in_step "pause while starting"
echo "ok   a pause while a slow queue is still starting holds"

steps "sim prepare=2" "toggle" "play-playlist 1" "wait 3" "sim prepare=0" || fail "steps didn't run"
[[ "$(state playingNow)" == True && "$(state enginePlaying)" == True ]] || fail "a queue that took a while to start never started playing"
in_step "slow start"
echo "ok   a queue that takes a while to start still plays"

steps "sim insert=2" "play-playlist 0" "wait 0.5" "add-to-queue 1 -1" "wait 0.3" "play-playlist 2" "wait 3" "sim insert=0" || fail "steps didn't run"
in_step "adding a song while another queue started"
echo "ok   adding a song while a new queue starts leaves the two queues matching"

queue=$(state queueIDs)
steps "sim refuse=1" "add-to-queue 1 -1" "wait 0.5" "sim refuse=0" || fail "steps didn't run"
[[ "$(state queueIDs)" == "$queue" ]] || fail "a song the player refused still went into the queue"
[[ "$(state notice)" == Couldn* ]] || fail "a refused song didn't say so: '$(state notice)'"
in_step "refused song"
echo "ok   a song the player refuses stays out of the queue, and the Now panel says why"

steps "sim play=1.5" "toggle" "toggle" "toggle" "wait 2.5" "sim play=0" || fail "steps didn't run"
[[ "$(state playingNow)" == False && "$(state enginePlaying)" == False ]] || fail "a slow play queued before a pause won over it"
echo "ok   a pause given after a slow play still wins"

steps "toggle" "sim insert=6" "add-to-queue 1 0" "wait 0.3" || fail "steps didn't run"
t1=$(state engineTime); p1=$(state position); sleep 1.5; p2=$(state position)
python3 -c "import sys; sys.exit(0 if $p2 - $p1 >= 1 else 1)" || fail "the position stood still while a song was being added ($p1 → $p2)"
steps "wait 5" "sim insert=0" || fail "steps didn't run"
in_step "slow add"
echo "ok   the position keeps moving while a slow add is under way"

until_state play-duplicates index 2 || fail "couldn't play a queue with a song in it twice"
sleep 1
[[ "$(state engineIndex)" == 2 ]] || fail "the player started at its entry $(state engineIndex), not the second copy (2)"
in_step "song queued twice"
echo "ok   the player starts at the very copy of a song queued twice"

# Shuffled, from the second copy; restart; shuffle off: the copies must
# come back in their own order.
steps "play-duplicates 2 shuffled" "wait 0.5" || fail "steps didn't run"
expected=$(python3 -c "ids='$(state unshuffledIDs)'.split(','); del ids[2]; print(','.join(ids))")
pid=$(state pid)
post quit; sleep 2
open -g -n --env CADENCE_CHECK_DIR="$OUT" "$APP"; sleep 5
[[ "$(state pid)" != "$pid" ]] || fail "still talking to the copy that was asked to quit"
press cmd-s && [[ "$(state shuffled)" == False ]] || fail "⌘S didn't turn shuffle off after reopening"
[[ "$(state upNextAll)" == "$expected" ]] || fail "after reopening, shuffle off put a song queued twice out of order: $(state upNextAll) instead of $expected"
echo "ok   shuffled with a song queued twice, reopened, shuffle off: back in order"

# ⌘W closes the window but the app keeps running, and playing; ⌘0 and
# reopening the app (as a Dock click does) bring the window back.
steps "play-playlist 0" "wait 1" || fail "steps didn't run"
pid=$(state pid)
press cmd-w && [[ "$(state windowOpen)" == False ]] || fail "⌘W didn't close the window"
[[ "$(state pid)" == "$pid" ]] || fail "closing the window quit the app"
p1=$(state position); sleep 2
[[ "$(state playingNow)" == True && "$(state enginePlaying)" == True ]] || fail "the music stopped when the window closed"
python3 -c "import sys; sys.exit(0 if $(state position) > $p1 + 1 else 1)" || fail "the music didn't carry on with the window closed"
press cmd-0 && [[ "$(state windowOpen)" == True ]] || fail "⌘0 didn't bring the window back"
press cmd-w && [[ "$(state windowOpen)" == False ]] || fail "⌘W didn't close the window again"
open -g "$APP"; sleep 1.5
[[ "$(state windowOpen)" == True && "$(state pid)" == "$pid" ]] || fail "reopening the app (a Dock click) didn't bring the window back"
echo "ok   ⌘W closes the window and the music plays on; ⌘0 and the Dock bring it back"

pkill -f "$APP/Contents/MacOS/Cadence" || true

# Artwork from the real library: every source must draw.
scripts/artwork.sh | sed 's/^/     artwork: /' || fail "artwork didn't draw; see build/audit/out/report.txt"
echo "PASS"
