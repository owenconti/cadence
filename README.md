# Cadence

A proof-of-concept native macOS music app built with SwiftUI and MusicKit, focused on playlists, artists, discovery and now playing.

## Run it

Tasks are in the `Makefile`; run `make` to list them.

```sh
make run      # build, install to /Applications and launch
make update   # rebuild and install; the running app offers Restart app
make check    # automated update + restart check on a throwaway copy
```

The app installs to `/Applications/Cadence.app`, so it opens like any other app (Spotlight, Launchpad, the Dock). `make update` swaps a new build in underneath the running app without touching it. Within a few seconds the app shows **Update ready** in the sidebar. **Restart app** (in ⌘K, from the pill, or with ⌥⌘R) relaunches into the new build. The queue, current song, position and section carry across, so music resumes after a short pause.

The build signs with the first Apple Development or Developer ID identity in your keychain, as `com.owenconti.cadence`. The app always uses the Apple ID signed into macOS, and once access is granted it connects automatically.

**One-time setup:** in the Apple Developer portal, go to Identifiers, register the App ID `com.owenconti.cadence`, and enable **MusicKit** on the App Services tab. MusicKit only issues tokens to registered bundle IDs.

## Layout

| Area | What it does |
| --- | --- |
| Sidebar | Discover / Playlists / Artists, pinned playlists, ⌘K launcher |
| Content | Discover (jump back in, recommendations, trending, new releases), playlist and album pages with in-list filtering, artist pages |
| Now panel | Artwork, scrubber, transport, and the Up Next queue. The artwork compacts on short windows so the queue keeps its space |
| Command palette | ⌘K searches songs, artists, albums and playlists, and runs every app action (navigation, playback, reload library, Restart app), all from the keyboard |

Shortcuts: Space play/pause · ⌘→ / ⌘← next/previous · ⌘1–3 sections · ⌘[ back · ⌘K search · ⌥⌘R restart app · Esc close.

## Code map

- `Services/MusicProvider.swift`: the protocol the UI depends on
- `Services/MusicKitProvider.swift`: live library and catalog (recently played, personal recommendations, charts, search)
- `Services/DemoProvider.swift`: offline catalog
- `Services/Player.swift`: queue, plus `ApplicationMusicPlayer` (live) or a simulated clock (demo)
- `App/AppUpdate.swift`: notices a newer build on disk, and Restart app with its playback handoff
- `App/RunMode.swift`, `App/CheckHooks.swift`: throwaway copies for `make check` and `make snapshots`
- `Views/`, `Components/`: SwiftUI

`make snapshots` captures every screen from a throwaway debug copy into `build/check/snapshots/`.
