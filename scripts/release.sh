#!/usr/bin/env bash
# A copy of Cadence to give to someone: built, signed with the Developer ID,
# notarized by Apple and stapled, so it opens on any Mac without warnings.
# Writes build/release/Cadence.zip. Uses the notarytool login Paseo Command
# saved in the keychain ("paseo-command-notary"). Never touches
# /Applications/Cadence.app.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/release
APP="$OUT/Cadence.app"
ZIP="$OUT/Cadence.zip"
PROFILE="${NOTARY_PROFILE:-paseo-command-notary}"

IDENTITY="$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')"
[[ -n "$IDENTITY" ]] || { echo "error: no Developer ID Application identity in the keychain" >&2; exit 1; }
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null \
    || { echo "error: no working notarytool login \"$PROFILE\" in the keychain" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"
APP="$APP" BUNDLE_ID=com.owenconti.cadence CONFIG=release SIGN_IDENTITY="$IDENTITY" scripts/bundle.sh >/dev/null
# Notarization needs a secure timestamp on the signature.
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
codesign --verify --strict --deep "$APP"

echo "Notarizing (Apple usually answers within a few minutes)…"
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
result="$(xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$PROFILE" --wait --output-format json)"
status="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['status'])" "$result")"
id="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['id'])" "$result")"
if [[ "$status" != Accepted ]]; then
    xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
    echo "error: Apple didn't notarize it ($status, submission $id)" >&2
    exit 1
fi
rm "$OUT/notarize.zip"
xcrun stapler staple "$APP" >/dev/null
spctl --assess --type execute -vv "$APP" 2>&1 | grep -q "source=Notarized Developer ID" \
    || { echo "error: Gatekeeper doesn't accept the stapled app as notarized" >&2; exit 1; }

ditto -c -k --keepParent "$APP" "$ZIP"
version="$(git rev-parse --short HEAD)"
echo "Notarized (submission $id). $ZIP ($(du -h "$ZIP" | cut -f1 | tr -d ' '), build $version)"
