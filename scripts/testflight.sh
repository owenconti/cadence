#!/usr/bin/env bash
# Builds Cadence for iPhone and uploads it to TestFlight, for Owen's own phone.
# The TestFlight app on the phone installs it (and each later upload) over the
# air; nothing is plugged in.
#
# Signs and uploads with an App Store Connect API key: the .p8 at
# ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8, and its IDs in
# ~/.appstoreconnect/cadence.env (ASC_KEY_ID=..., ASC_ISSUER_ID=...).
# Xcode's automatic signing makes the distribution certificate and profile
# with that key. The app record (com.owenconti.cadence) must exist in App
# Store Connect; Apple's API can't create one.
#
# The build number is the commit count, so each upload needs a new commit.
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "error: $*" >&2; exit 1; }

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
command -v xcodegen >/dev/null || die "xcodegen is missing (brew install xcodegen)"

CONFIG_FILE="$HOME/.appstoreconnect/cadence.env"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
[[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]] || die "no App Store Connect API key IDs in $CONFIG_FILE (ASC_KEY_ID, ASC_ISSUER_ID)"
KEY="$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"
[[ -f "$KEY" ]] || die "the API key file isn't at $KEY"
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

[[ -z "$(git status --porcelain)" ]] || die "commit first: the build number is the commit count, and the upload should match a commit"
BUILD="$(git rev-list --count HEAD)"

(cd iOS && xcodegen generate --quiet)
OUT=build/phone/testflight
rm -rf "$OUT"
mkdir -p "$OUT"
LOG="$OUT/xcodebuild.log"

run() {
    if ! xcodebuild "$@" >>"$LOG" 2>&1; then
        grep -E 'error:|Error Domain|ITMS-' "$LOG" | sort -u | head -20 >&2 || true
        die "xcodebuild failed; full log in $LOG"
    fi
}

echo "Archiving build $BUILD…"
run -project iOS/CadencePhone.xcodeproj -scheme Cadence -configuration Release \
    -destination generic/platform=iOS -archivePath "$OUT/Cadence.xcarchive" \
    CURRENT_PROJECT_VERSION="$BUILD" "${AUTH[@]}" archive

cat >"$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>upload</string>
    <key>teamID</key><string>HBLWB8LVKC</string>
    <key>signingStyle</key><string>automatic</string>
    <key>manageAppVersionAndBuildNumber</key><false/>
    <key>testFlightInternalTestingOnly</key><true/>
</dict>
</plist>
EOF

echo "Uploading to TestFlight…"
run -exportArchive -archivePath "$OUT/Cadence.xcarchive" -exportOptionsPlist "$OUT/ExportOptions.plist" \
    -exportPath "$OUT/export" "${AUTH[@]}"
echo "Uploaded build $BUILD. TestFlight offers it on the phone once Apple has processed it (usually 5–15 minutes)."
