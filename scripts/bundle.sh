#!/usr/bin/env bash
# Builds Cadence and wraps it in a signed .app bundle at build/Cadence.app.
#
# Signs with the first Apple Development or Developer ID identity in your
# keychain. MusicKit only issues tokens to apps whose bundle ID is registered
# with the MusicKit app service under the signing team.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="${BUNDLE_ID:-com.owenconti.cadence}"
CONFIG="${CONFIG:-release}"

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

APP=build/Cadence.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cadence"
cp Support/AppIcon/Cadence.icns "$APP/Contents/Resources/Cadence.icns"
sed "s/\$(BUNDLE_ID)/$BUNDLE_ID/" Support/Info.plist > "$APP/Contents/Info.plist"

codesign --force --sign "$SIGN_IDENTITY" --options runtime "$APP" >/dev/null
echo "Built $APP ($BUNDLE_ID, signed with '$SIGN_IDENTITY')"
