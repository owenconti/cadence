#!/usr/bin/env bash
# Cuts a Cadence release, like Paseo Command's:
#   make release [BUMP=patch|minor|major | VERSION=x.y.z] [NOTES=file] [DRY_RUN=1]
# Without a version it takes the next patch after the latest published release
# (or VERSION's own, if that's newer). Runs make check, builds the release copy
# (it updates itself with Sparkle from this repository's releases), signs it with
# the Developer ID, has Apple notarize it and staples the ticket, zips it (what
# Sparkle downloads), makes a drag-to-Applications disk image (signed and
# notarized too), and writes the Sparkle appcast, signed with the EdDSA key in
# the keychain. Then, unless DRY_RUN, commits "Release v<version>", pushes main
# and publishes the GitHub release with the zip, disk image and appcast.
# Notarizes with the notarytool login Paseo Command saved ("paseo-command-notary").
# Never touches /Applications/Cadence.app.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/release
PROFILE="${NOTARY_PROFILE:-paseo-command-notary}"
SPARKLE=.build/artifacts/sparkle/Sparkle/bin
REPO=owenconti/cadence
step() { printf '\n== %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

# Checks first: nothing is built until a release could go through.
[[ "$(git branch --show-current)" == main ]] || die "releases are cut from main"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || die "the working tree has uncommitted changes"
[[ -z "${DRY_RUN:-}" ]] && { gh auth status >/dev/null 2>&1 || die "gh isn't signed in (gh auth login)"; }
IDENTITY="$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')"
[[ -n "$IDENTITY" ]] || die "no Developer ID Application identity in the keychain"
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || die "no working notarytool login \"$PROFILE\" in the keychain"

# The version: an explicit one, a bump of the latest release, or VERSION's.
current="$(tr -d '[:space:]' < VERSION)"
latest="$(gh release list --repo "$REPO" --limit 100 --json tagName --jq '.[].tagName' 2>/dev/null | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 || true)"
version="$(python3 - "$current" "${latest:-}" "${VERSION_OVERRIDE:-}" "${BUMP:-}" <<'PY'
import re, sys
current, latest, explicit, bump = sys.argv[1:5]
parse = lambda v: tuple(map(int, v.split('.')))
ok = lambda v: re.fullmatch(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', v)
if explicit:
    assert ok(explicit), f"VERSION must look like 1.2.3, not {explicit}"
    v = explicit
elif not latest:
    v = current
else:
    base = max(parse(latest), parse(current)) if not bump else parse(latest)
    if not bump and parse(current) > parse(latest):
        v = current
    else:
        ma, mi, pa = base
        kind = bump or 'patch'
        v = {'major': f'{ma+1}.0.0', 'minor': f'{ma}.{mi+1}.0', 'patch': f'{ma}.{mi}.{pa+1}'}[kind]
if latest:
    assert parse(v) > parse(latest), f"version {v} must be newer than the latest release {latest}"
print(v)
PY
)" || die "couldn't choose a version"
echo "Releasing Cadence $version${latest:+ (latest published: $latest)}${DRY_RUN:+ — dry run}"

# Notes: the given file, or the commit subjects since the last release.
notes="$OUT-notes.md"
mkdir -p build
if [[ -n "${NOTES:-}" ]]; then
    cp "$NOTES" "$notes"
else
    since="$( [[ -n "$latest" ]] && git rev-list -n1 "v$latest" 2>/dev/null || true)"
    git log --no-merges --format='- %s' ${since:+$since..HEAD} | grep -v '^- Release v' > "$notes" || true
fi

# A dry run or a failure leaves VERSION as it was.
restore() { if [[ -n "${DRY_RUN:-}" || -z "${released:-}" ]]; then echo "$current" > VERSION; fi; }
trap restore EXIT

step "Checking (make check)"
make check

step "Building $version"
echo "$version" > VERSION
rm -rf "$OUT"
mkdir -p "$OUT"
APP="$OUT/Cadence.app"
RELEASE=1 APP="$APP" BUNDLE_ID=com.owenconti.cadence CONFIG=release SIGN_IDENTITY="$IDENTITY" scripts/bundle.sh >/dev/null
codesign --verify --strict --deep "$APP"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"

notarize() { # file, what
    local result status id
    result="$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json)"
    status="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['status'])" "$result")"
    id="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['id'])" "$result")"
    if [[ "$status" != Accepted ]]; then
        xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
        die "Apple didn't notarize $2 ($status, submission $id)"
    fi
    echo "Notarized $2 (submission $id)."
}

step "Notarizing the app (Apple usually answers within a few minutes)"
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
notarize "$OUT/notarize.zip" "the app"
rm "$OUT/notarize.zip"
xcrun stapler staple "$APP" >/dev/null
spctl --assess --type execute -vv "$APP" 2>&1 | grep -q "source=Notarized Developer ID" || die "Gatekeeper doesn't accept the app as notarized"

ZIP="$OUT/Cadence-$version.zip"
DMG="$OUT/Cadence-$version.dmg"
ditto -c -k --keepParent "$APP" "$ZIP"

step "Making the disk image"
stage="$(mktemp -d)"
ditto "$APP" "$stage/Cadence.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname Cadence -srcfolder "$stage" -format UDZO -ov "$DMG" >/dev/null
rm -rf "$stage"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
notarize "$DMG" "the disk image"
xcrun stapler staple "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null

step "Writing the appcast"
signature="$("$SPARKLE/sign_update" "$ZIP")"
python3 - "$version" "$build" "$ZIP" "$signature" "$notes" "$OUT/appcast.xml" <<'PY'
import html, os, re, sys
from email.utils import formatdate
version, build, zipfile, signed, notes, out = sys.argv[1:7]
ed = re.search(r'sparkle:edSignature="([^"]+)"', signed).group(1)
length = re.search(r'length="(\d+)"', signed).group(1)
items = [l[2:] for l in open(notes).read().splitlines() if l.startswith('- ')]
body = open(notes).read() if not items else '<ul>' + ''.join(f'<li>{html.escape(i)}</li>' for i in items) + '</ul>'
url = f"https://github.com/owenconti/cadence/releases/download/v{version}/{os.path.basename(zipfile)}"
open(out, 'w').write(f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Cadence</title>
    <item>
      <title>Cadence {version}</title>
      <pubDate>{formatdate()}</pubDate>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <description><![CDATA[{body.replace("]]>", "]]]]><![CDATA[>")}]]></description>
      <enclosure url="{html.escape(url)}" length="{length}" type="application/octet-stream" sparkle:version="{build}" sparkle:shortVersionString="{version}" sparkle:edSignature="{ed}"/>
    </item>
  </channel>
</rss>
''')
PY
echo "Cadence $version (build $build): $ZIP, $DMG, $OUT/appcast.xml"

if [[ -n "${DRY_RUN:-}" ]]; then
    echo "Dry run: nothing committed, pushed or published."
    exit 0
fi

step "Publishing"
git add VERSION
git commit -q -m "Release v$version" || true
released=1
git push origin main
gh release create "v$version" --repo "$REPO" --target "$(git rev-parse HEAD)" --title "Cadence $version" \
    --notes-file "$notes" "$ZIP" "$DMG" "$OUT/appcast.xml"
echo "Published https://github.com/$REPO/releases/tag/v$version"
