#!/usr/bin/env bash
# Cadence for iPhone, for Owen's own phone only.
#
#   scripts/phone.sh            build and install on the connected iPhone
#   scripts/phone.sh snapshots  screenshot every screen in the iPhone and iPad
#                               simulators (demo library) into
#                               build/phone/snapshots/{iphone,ipad}
#
# The Xcode project is generated from iOS/project.yml (XcodeGen) each time.
# Installing signs with Xcode's automatic signing for team HBLWB8LVKC, which
# needs that Apple ID added in Xcode › Settings › Accounts, and the iPhone
# plugged in (or paired over Wi-Fi) with Developer Mode on.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
command -v xcodegen >/dev/null || { echo "error: xcodegen is missing (brew install xcodegen)" >&2; exit 1; }
(cd iOS && xcodegen generate --quiet)
PROJECT=iOS/CadencePhone.xcodeproj

quiet_build() {
    local log="build/phone/xcodebuild.log"
    mkdir -p build/phone
    if ! xcodebuild -project "$PROJECT" -scheme Cadence "$@" >"$log" 2>&1; then
        grep -E 'error:' "$log" | sort -u | head -20 >&2 || true
        echo "error: build failed; full log in $log" >&2
        exit 1
    fi
}

case "${1:-install}" in
snapshots)
    sim_udid() {
        xcrun simctl list devices available -j | /usr/bin/python3 -c "
import json, sys
for runtime, devices in json.load(sys.stdin)['devices'].items():
    for d in devices:
        if d['name'] == sys.argv[1] and 'iOS' in runtime: print(d['udid']); sys.exit()
" "$1"
    }
    quiet_build -configuration Debug -destination "generic/platform=iOS Simulator" \
        -derivedDataPath build/phone/sim CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
    app="build/phone/sim/Build/Products/Debug-iphonesimulator/Cadence.app"
    rm -rf build/phone/snapshots
    # The tour on a phone and on an iPad (the Mac's layout).
    for pair in "iphone:${PHONE_SIM:-iPhone 17 Pro}" "ipad:${IPAD_SIM:-iPad Pro 11-inch (M5)}"; do
        name="${pair%%:*}"; sim="${pair#*:}"
        udid="$(sim_udid "$sim")"
        [[ -n "$udid" ]] || { echo "error: no simulator named $sim" >&2; exit 1; }
        xcrun simctl boot "$udid" 2>/dev/null || true
        xcrun simctl bootstatus "$udid" >/dev/null
        # A fixed status bar, so screenshots don't differ by the clock.
        xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 >/dev/null 2>&1 || true
        [[ "$name" == ipad ]] && xcrun simctl ui "$udid" appearance dark >/dev/null 2>&1 || true
        xcrun simctl install "$udid" "$app"
        out="$PWD/build/phone/snapshots/$name"
        SIMCTL_CHILD_CADENCE_SNAPSHOTS="$out" xcrun simctl launch --terminate-running-process "$udid" com.owenconti.cadence >/dev/null
        # The tour marks the end and quits.
        for _ in $(seq 1 90); do
            [[ -e "$out/.done" ]] && break
            sleep 1
        done
        [[ -e "$out/.done" ]] || { echo "error: the snapshot tour didn't finish on $sim" >&2; exit 1; }
        xcrun simctl shutdown "$udid" 2>/dev/null || true
        echo "$name: $(ls "$out" | tr '\n' ' ')"
    done
    ;;
install)
    device="$(xcrun devicectl list devices -j /dev/stdout 2>/dev/null | /usr/bin/python3 -c "
import json, sys
try: devices = json.load(sys.stdin)['result']['devices']
except Exception: sys.exit()
for d in devices:
    hw, conn = d.get('hardwareProperties', {}), d.get('connectionProperties', {})
    if hw.get('platform') == 'iOS' and conn.get('pairingState') == 'paired' and conn.get('tunnelState') != 'unavailable':
        print(hw.get('udid', '') + ' ' + d['identifier']); sys.exit()
" || true)"
    if [[ -z "$device" ]]; then
        echo "error: no iPhone connected. Plug it in, unlock it, tap Trust, and turn on Developer Mode (Settings › Privacy & Security)." >&2
        exit 1
    fi
    udid="${device%% *}"; id="${device##* }"
    quiet_build -configuration Release -destination "id=$udid" -derivedDataPath build/phone/device \
        -allowProvisioningUpdates build
    app="build/phone/device/Build/Products/Release-iphoneos/Cadence.app"
    xcrun devicectl device install app --device "$id" "$app" >/dev/null
    echo "Installed Cadence on the iPhone"
    ;;
*)
    echo "usage: scripts/phone.sh [install|snapshots]" >&2
    exit 1
    ;;
esac
