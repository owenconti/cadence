#!/usr/bin/env bash
# Builds Cadence into a signed .app bundle at build/Cadence.app.
#
# Safe while that app is running: the new bundle is assembled and signed in a
# staging folder, then swapped in by rename. The running copy keeps its files
# and shows "Update ready"; Restart app (⌘K) switches to the new build.
#
# Signs with the first Apple Development or Developer ID identity in your
# keychain. MusicKit only issues tokens to apps whose bundle ID is registered
# with the MusicKit app service under the signing team.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="${BUNDLE_ID:-com.owenconti.cadence}"
CONFIG="${CONFIG:-release}"
APP="${APP:-build/Cadence.app}"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    SIGN_IDENTITY="$(grep -o '"Apple Development: [^"]*"' <<<"$identities" | head -1 | tr -d '"' || true)"
    [[ -z "$SIGN_IDENTITY" ]] && SIGN_IDENTITY="$(grep -o '"Developer ID Application: [^"]*"' <<<"$identities" | head -1 | tr -d '"' || true)"
    if [[ -z "$SIGN_IDENTITY" ]]; then
        SIGN_IDENTITY="-"
        echo "warning: no signing identity found; ad-hoc signing (Apple Music won't connect, demo library still works)" >&2
    fi
fi

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Cadence"

STAGE="$(dirname "$APP")/.staging-$$/Cadence.app"
trap 'rm -rf "$(dirname "$STAGE")"' EXIT
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/Cadence"
cp Support/AppIcon/Cadence.icns "$STAGE/Contents/Resources/Cadence.icns"
sed "s/\$(BUNDLE_ID)/$BUNDLE_ID/" Support/Info.plist > "$STAGE/Contents/Info.plist"
codesign --force --sign "$SIGN_IDENTITY" --options runtime "$STAGE" >/dev/null

# Swap by rename, never by overwriting files a running copy may have mapped.
OLD="$(dirname "$STAGE")/old.app"
[[ -d "$APP" ]] && mv "$APP" "$OLD"
mv "$STAGE" "$APP"
echo "Built $APP ($BUNDLE_ID, signed with '$SIGN_IDENTITY')"
