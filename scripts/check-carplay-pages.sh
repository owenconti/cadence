#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/carplay
swiftc iOS/Sources/CarPlaySongPage.swift scripts/check-carplay-pages.swift -o build/carplay/check-pages
build/carplay/check-pages
