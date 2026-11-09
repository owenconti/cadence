#!/usr/bin/env bash
# Puts Support/CloudKit/schema.ckdb (My Playlists' record types) into the
# iCloud container's Development schema with cktool. Release builds use the
# Production schema, so afterwards it must be deployed once in CloudKit
# Console (Schema › Deploy Schema Changes…); `make artwork` says whether it is.
#
# Needs a CloudKit management token, saved once with
# `xcrun cktool save-token --type management` (CloudKit Console › Settings ›
# Tokens & Keys).
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcrun cktool validate-schema --team-id HBLWB8LVKC --container-id iCloud.com.owenconti.cadence \
    --environment development --file Support/CloudKit/schema.ckdb
xcrun cktool import-schema --team-id HBLWB8LVKC --container-id iCloud.com.owenconti.cadence \
    --environment development --file Support/CloudKit/schema.ckdb
echo "Imported into Development. Deploy it to Production in CloudKit Console: Schema › Deploy Schema Changes…"
