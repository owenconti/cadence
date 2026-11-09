#!/usr/bin/env bash
# Builds Cadence for iPhone and uploads it to TestFlight, for Owen's own phone.
# The TestFlight app on the phone installs it (and each later upload) over the
# air; nothing is plugged in.
#
# Uses an App Store Connect API key: the .p8 at
# ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8, and its IDs in
# ~/.appstoreconnect/cadence.env (ASC_KEY_ID=..., ASC_ISSUER_ID=...).
#
# Xcode's own export can't sign with the key (App Store Connect rejects its
# token for "store configuration"), so this does what it would: builds the app
# unsigned, gets an App Store certificate and profile through the API
# (scripts/asc.py signing; the certificate lives in its own keychain), signs,
# packs the .ipa and uploads it with altool. The app record
# (com.owenconti.cadence) must exist in App Store Connect.
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
[[ -f "$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8" ]] || die "the API key file isn't in ~/.appstoreconnect/private_keys"

[[ -z "$(git status --porcelain)" ]] || die "commit first: the build number is the commit count, and the upload should match a commit"
BUILD="$(git rev-list --count HEAD)"

(cd iOS && xcodegen generate --quiet)
OUT="$PWD/build/phone/testflight"
rm -rf "$OUT"
mkdir -p "$OUT"
LOG="$OUT/build.log"

echo "Building ${BUILD}…"
if ! xcodebuild -project iOS/CadencePhone.xcodeproj -scheme Cadence -configuration Release \
    -destination generic/platform=iOS -archivePath "$OUT/Cadence.xcarchive" \
    CURRENT_PROJECT_VERSION="$BUILD" CODE_SIGNING_ALLOWED=NO archive >"$LOG" 2>&1; then
    grep -E 'error:' "$LOG" | sort -u | head -20 >&2 || true
    die "build failed; full log in $LOG"
fi

echo "Signing…"
eval "$(python3 -I scripts/asc.py signing)"   # KEYCHAIN, IDENTITY, PROFILE
security cms -D -i "$PROFILE" | grep -q com.apple.developer.carplay-audio \
    || die "the App Store profile doesn't grant CarPlay: in the Apple Developer portal, open Identifiers › com.owenconti.cadence › Additional Capabilities, tick CarPlay Audio and save"

PAYLOAD="$OUT/ipa/Payload"
APP="$PAYLOAD/Cadence.app"
mkdir -p "$PAYLOAD"
ditto "$OUT/Cadence.xcarchive/Products/Applications/Cadence.app" "$APP"
cp "$PROFILE" "$APP/embedded.mobileprovision"
TEAM=HBLWB8LVKC

# iCloud (CloudStore.swift) once the container is on the App ID (README); the
# Info.plist key tells the app it may touch CloudKit.
CLOUD_CONTAINER=iCloud.com.owenconti.cadence
CLOUD_ENTITLEMENTS=""
if security cms -D -i "$PROFILE" | grep -q "$CLOUD_CONTAINER"; then
    /usr/libexec/PlistBuddy -c "Add :CadenceCloudContainer string $CLOUD_CONTAINER" "$APP/Info.plist"
    CLOUD_ENTITLEMENTS="<key>com.apple.developer.icloud-container-identifiers</key><array><string>$CLOUD_CONTAINER</string></array>
    <key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array>
    <key>com.apple.developer.icloud-container-environment</key><string>Production</string>"
else
    echo "note: the profile has no $CLOUD_CONTAINER yet, so this build has no iCloud (see README)" >&2
fi
cat >"$OUT/entitlements.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>application-identifier</key><string>$TEAM.com.owenconti.cadence</string>
    <key>com.apple.developer.team-identifier</key><string>$TEAM</string>
    <key>get-task-allow</key><false/>
    <key>beta-reports-active</key><true/>
    <key>com.apple.developer.carplay-audio</key><true/>
    $CLOUD_ENTITLEMENTS
</dict>
</plist>
EOF

# The signing keychain goes on the search list (codesign builds the chain from
# it) and is unlocked only while signing; both are undone on any exit.
LOGIN="$HOME/Library/Keychains/login.keychain-db"
ORIGINAL=()
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line//\"/}"
    [[ -n "$line" ]] && ORIGINAL+=("$line")
done < <(security list-keychains -d user)
[[ ${#ORIGINAL[@]} -gt 0 ]] || ORIGINAL=("$LOGIN")
restore() {
    security list-keychains -d user -s "${ORIGINAL[@]}"
    security lock-keychain "$KEYCHAIN" 2>/dev/null || true
}
trap restore EXIT
security unlock-keychain -p "$(cat "$HOME/.appstoreconnect/cadence-keychain-password")" "$KEYCHAIN"
security list-keychains -d user -s "${ORIGINAL[@]}" "$KEYCHAIN"

sign() { codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" "$@" >>"$LOG" 2>&1 || die "couldn't sign ${*: -1}; see $LOG"; }
if [[ -d "$APP/Frameworks" ]]; then
    for nested in "$APP"/Frameworks/*; do sign "$nested"; done
fi
WATCH_APP="$APP/Watch/CadenceWatch.app"
[[ -d "$WATCH_APP" ]] || die "archive is missing the embedded watch companion"
PHONE_PROFILE="$PROFILE"
eval "$(CADENCE_SIGN_BUNDLE=com.owenconti.cadence.watchkitapp python3 -I scripts/asc.py signing)"
cp "$PROFILE" "$WATCH_APP/embedded.mobileprovision"
security cms -D -i "$PROFILE" > "$OUT/watch-profile.plist"
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$OUT/watch-profile.plist" > "$OUT/watch-entitlements.plist"
if [[ -d "$WATCH_APP/Frameworks" ]]; then
    for nested in "$WATCH_APP"/Frameworks/*; do sign "$nested"; done
fi
sign --entitlements "$OUT/watch-entitlements.plist" --generate-entitlement-der "$WATCH_APP"
sign --entitlements "$OUT/entitlements.plist" --generate-entitlement-der "$APP"
restore
trap - EXIT
codesign --verify --strict "$APP" || die "the signed app doesn't verify"

(cd "$OUT/ipa" && zip -qry ../Cadence.ipa Payload)

echo "Uploading to TestFlight…"
if ! xcrun altool --upload-app -f "$OUT/Cadence.ipa" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" >>"$LOG" 2>&1; then
    grep -iE 'error|ITMS-' "$LOG" | sort -u | head -20 >&2 || true
    die "upload failed; full log in $LOG"
fi
echo "Uploaded build $BUILD. TestFlight offers it on the phone once Apple has processed it (usually 5–15 minutes)."
