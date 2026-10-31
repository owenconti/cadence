#!/usr/bin/env bash
# Hot-reload development loop for Cadence.
#
#   scripts/dev.sh start    build, launch, and supervise in the background
#   scripts/dev.sh stop     stop the supervisor and the dev app
#   scripts/dev.sh restart  rebuild and relaunch once
#   scripts/dev.sh status   show whether the supervisor and app are running
#
# Saved edits to Swift files are swapped into the running app by InjectionIII.
# The supervisor rebuilds and relaunches by itself when that can't work: files
# added or removed, project/plist/icon changes, or an edit that fails to inject.
#
# Logs: build/dev.log (app + injection), build/dev-watch.log (supervisor).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
BUNDLE_ID="${BUNDLE_ID:-com.owenconti.cadence}"
INJECTION=/Applications/InjectionIII.app
# InjectionIII also looks in <project>/build/DerivedData, which keeps paths fixed.
DERIVED="$ROOT/build/DerivedData"
LOGS="$DERIVED/Logs/Build"
APP="$ROOT/build/Cadence-Dev.app"
APP_LOG="$ROOT/build/dev.log"
WATCH_LOG="$ROOT/build/dev-watch.log"
PIDFILE="$ROOT/build/dev-watch.pid"
INJECT_TIMEOUT=10

note() { echo "[$(date +%H:%M:%S)] $*"; }

build() {
    [[ -d "$INJECTION" ]] || { note "error: $INJECTION not found"; return 1; }
    mkdir -p "$LOGS"
    local log action=build
    log="$(mktemp)"
    # The first build must compile every file so the log has a command for
    # each one; later incremental logs only add what changed.
    ls "$LOGS"/cadence-*.xcactivitylog >/dev/null 2>&1 || action="clean build"

    # InjectionIII finds recompile commands in Xcode build logs, so keep
    # xcodebuild's output there. Xcode separates log records with \r.
    if ! xcodebuild -scheme Cadence -destination 'platform=macOS' -configuration Debug \
        -derivedDataPath "$DERIVED" $action EMIT_FRONTEND_COMMAND_LINES=YES >"$log" 2>&1; then
        grep -E "error:" "$log" | sort -u | head -20 || tail -30 "$log"
        rm -f "$log"
        return 1
    fi
    tr '\n' '\r' <"$log" | gzip -c >"$LOGS/cadence-$(date +%s).xcactivitylog"
    rm -f "$log"

    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp "$DERIVED/Build/Products/Debug/Cadence" "$APP/Contents/MacOS/Cadence"
    cp Support/AppIcon/Cadence.icns "$APP/Contents/Resources/Cadence.icns"
    sed "s/\$(BUNDLE_ID)/$BUNDLE_ID/" Support/Info.plist >"$APP/Contents/Info.plist"

    # No hardened runtime: library validation would block InjectionIII's code.
    local identity
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"\(Apple Development\|Developer ID Application\): [^"]*"' | head -1 | tr -d '"' || true)"
    codesign --force --sign "${identity:--}" "$APP" >/dev/null 2>&1
}

quit_app() {
    if pkill -x Cadence 2>/dev/null; then
        while pgrep -x Cadence >/dev/null; do sleep 0.2; done
    fi
}

launch() {
    quit_app
    echo "=== launch $(date +%H:%M:%S) ===" >>"$APP_LOG"
    open --env CADENCE_HOT_RELOAD=1 --stdout "$APP_LOG" --stderr "$APP_LOG" "$APP"
}

restart() {
    note "building…"
    if build; then
        launch
        note "launched $APP"
    else
        note "build failed; the previous app (if any) is still running"
        return 1
    fi
}

# Signature of things that need a full rebuild: the set of Swift files plus
# project-level inputs.
structure() {
    { find Sources -name '*.swift' | sort
      stat -f '%m %N' Package.swift Support/Info.plist Support/AppIcon/Cadence.icns 2>/dev/null; } | shasum
}

# Signature of Swift file contents (via modification times).
contents() {
    find Sources -name '*.swift' -exec stat -f '%m %N' {} + | sort | shasum
}

# Successful hot reloads since the most recent launch.
reloads() { awk '/^=== launch/ {n = 0} /hot reload #/ {n++} END {print n + 0}' "$APP_LOG" 2>/dev/null || echo 0; }

watch() {
    restart || true
    local last_structure last_contents
    last_structure="$(structure)"
    last_contents="$(contents)"
    note "watching Sources/ for changes"
    while true; do
        sleep 1
        local now_structure now_contents
        now_structure="$(structure)"
        now_contents="$(contents)"
        if [[ "$now_structure" != "$last_structure" ]]; then
            note "files or project settings changed → rebuild"
            restart || true
        elif [[ "$now_contents" != "$last_contents" ]] && pgrep -x Cadence >/dev/null; then
            local before after waited=0
            before="$(reloads)"
            after="$before"
            while (( waited < INJECT_TIMEOUT )) && [[ "$after" == "$before" ]]; do
                sleep 1; waited=$((waited + 1)); after="$(reloads)"
            done
            if [[ "$after" != "$before" ]]; then
                note "hot reloaded"
            else
                note "edit didn't hot reload → rebuild"
                restart || true
            fi
        elif [[ "$now_contents" != "$last_contents" ]]; then
            note "app isn't running; changes will apply on next launch"
        fi
        # Compare against what was seen before acting, so edits made while
        # waiting or building are picked up on the next pass.
        last_structure="$now_structure"
        last_contents="$now_contents"
    done
}

watcher_pid() {
    [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null && cat "$PIDFILE"
}

stop_watcher() {
    local pid
    if pid="$(watcher_pid)"; then
        pkill -P "$pid" 2>/dev/null || true
        kill "$pid" 2>/dev/null || true
    fi
    rm -f "$PIDFILE"
}

case "${1:-start}" in
    start)
        stop_watcher
        mkdir -p build
        nohup "$0" watch >"$WATCH_LOG" 2>&1 &
        echo $! >"$PIDFILE"
        disown
        # Report the first build's outcome before returning.
        for _ in $(seq 1 300); do
            grep -q -E "launched|build failed" "$WATCH_LOG" 2>/dev/null && break
            sleep 1
        done
        cat "$WATCH_LOG"
        ;;
    watch) watch ;;
    restart) restart ;;
    stop) stop_watcher; quit_app; note "stopped" ;;
    status)
        if pid="$(watcher_pid)"; then echo "supervisor: running (pid $pid)"; else echo "supervisor: stopped"; fi
        if pgrep -x Cadence >/dev/null; then echo "app: running"; else echo "app: not running"; fi
        tail -5 "$WATCH_LOG" 2>/dev/null || true
        ;;
    *) echo "usage: $0 [start|stop|restart|status]" >&2; exit 2 ;;
esac
