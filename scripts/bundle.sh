#!/usr/bin/env bash
# Builds Cadence into a signed .app bundle and installs it at
# /Applications/Cadence.app (or $APP).
#
# Safe while that app is running: the new bundle is assembled and signed in a
# staging folder under build/, then swapped in by rename. The running copy
# keeps its files and shows "Update ready"; Restart app (⌘K) switches to the
# new build.
#
# RELEASE=1 makes the copy people download (scripts/release.sh): it points
# Sparkle at the GitHub feed so it updates itself, and timestamps signatures
# for notarization. Other copies never check for updates.
#
# Signs with the first Developer ID (else Apple Development) identity in your
# keychain. MusicKit only issues tokens to apps whose bundle ID is registered
# with the MusicKit app service under the signing team.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="${BUNDLE_ID:-com.owenconti.cadence}"
CONFIG="${CONFIG:-release}"
APP="${APP:-/Applications/Cadence.app}"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    # Developer ID first: macOS ties Apple Music access to the signature, so
    # switching identity would make the app ask again (or fail the artwork audit).
    SIGN_IDENTITY="$(grep -o '"Developer ID Application: [^"]*"' <<<"$identities" | head -1 | tr -d '"' || true)"
    [[ -z "$SIGN_IDENTITY" ]] && SIGN_IDENTITY="$(grep -o '"Apple Development: [^"]*"' <<<"$identities" | head -1 | tr -d '"' || true)"
    if [[ -z "$SIGN_IDENTITY" ]]; then
        SIGN_IDENTITY="-"
        echo "warning: no signing identity found; ad-hoc signing (Apple Music won't connect, demo library still works)" >&2
    fi
fi

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c "$CONFIG"
BINDIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BINDIR/Cadence"
# Sparkle installs an update only if it's newer by build number: the commit count.
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
FEED="https://github.com/owenconti/cadence/releases/latest/download/appcast.xml"

mkdir -p build
STAGE="$PWD/build/.staging-$$/Cadence.app"
OLD="$(dirname "$STAGE")/old.app"
# On any exit: if the swap below was cut short, put the previous app back
# before the staging folder (which holds it) is removed.
cleanup() {
    local status=$?
    if [[ ! -d "$APP" && -d "$OLD" ]]; then
        if mv "$OLD" "$APP"; then
            echo "warning: install didn't finish; kept the previous $APP" >&2
        else
            # Never delete the only copy left.
            echo "error: install failed and the previous app couldn't be put back; it's at $OLD" >&2
            exit 1
        fi
    fi
    rm -rf "$(dirname "$STAGE")"
    exit $status
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/Cadence"
cp Support/AppIcon/Cadence.icns "$STAGE/Contents/Resources/Cadence.icns"
sed -e "s/\$(BUNDLE_ID)/$BUNDLE_ID/" -e "s/\$(VERSION)/$VERSION/" -e "s/\$(BUILD)/$BUILD/" Support/Info.plist > "$STAGE/Contents/Info.plist"
if [[ -n "${RELEASE:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $FEED" "$STAGE/Contents/Info.plist"
fi

# Sparkle's framework, its symlinks kept (ditto), where the executable's rpath
# looks. Signed inside out, without --deep, as Sparkle's docs sign it outside
# Xcode; then the app.
mkdir -p "$STAGE/Contents/Frameworks"
ditto "$BINDIR/Sparkle.framework" "$STAGE/Contents/Frameworks/Sparkle.framework"
sign() { codesign --force --sign "$SIGN_IDENTITY" --options runtime ${RELEASE:+--timestamp} "$@" >/dev/null 2>&1 \
    || { echo "error: couldn't sign ${*: -1}" >&2; exit 1; }; }
sparkle="$STAGE/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$sparkle/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
sign "$sparkle/Autoupdate"
sign "$sparkle/Updater.app"
sign "$STAGE/Contents/Frameworks/Sparkle.framework"
sign "$STAGE"

# Swap by rename, never by overwriting files a running copy may have mapped.
# If the second rename fails or is interrupted, cleanup puts the previous
# app back.
mkdir -p "$(dirname "$APP")"
if [[ -d "$APP" ]]; then mv "$APP" "$OLD"; fi
mv "$STAGE" "$APP"
echo "Built $APP ($BUNDLE_ID, signed with '$SIGN_IDENTITY')"
