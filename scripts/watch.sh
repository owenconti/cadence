#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
(cd iOS && xcodegen generate --quiet)
mkdir -p build/watch
xcodebuild -project iOS/CadencePhone.xcodeproj -scheme CadenceWatch -configuration Debug -destination 'generic/platform=watchOS Simulator' -derivedDataPath build/watch CODE_SIGNING_ALLOWED=NO build > build/watch/build.log 2>&1 || { tail -35 build/watch/build.log; exit 1; }
if [[ "${1:-}" == snapshots ]]; then
    mkdir -p build/watch/snapshots
    for pair in small:Apple-Watch-Series-9-41mm large:Apple-Watch-Ultra-2-49mm; do
        size="${pair%%:*}"
        udid="$(xcrun simctl create "Cadence $size" "com.apple.CoreSimulator.SimDeviceType.${pair#*:}")"
        xcrun simctl boot "$udid"
        xcrun simctl bootstatus "$udid" -b >/dev/null
        xcrun simctl install "$udid" build/watch/Build/Products/Debug-watchsimulator/CadenceWatch.app
        xcrun simctl launch "$udid" com.owenconti.cadence.watchkitapp --snapshot
        sleep 3
        xcrun simctl io "$udid" screenshot "build/watch/snapshots/$size.png"
        xcrun simctl shutdown "$udid"
    done
fi
