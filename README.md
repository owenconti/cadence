# Cadence

A proof-of-concept native macOS music app built with SwiftUI and MusicKit, focused on playlists, artists, discovery and now playing.

## Run it

Tasks are in the `Makefile`; run `make` to list them.

```sh
make dev   # hot-reload debug app plus a supervisor that rebuilds when needed
make run   # signed release build, launched
```

`make dev` launches `build/Cadence-Dev.app`. When a Swift file is saved, the change is swapped into the running app via [InjectionIII](https://github.com/johnno1962/InjectionIII/releases) (installed in `/Applications`), and playback keeps going. When an edit can't be swapped in (files added or removed, project changes, or a failed swap), the supervisor rebuilds and relaunches by itself. Logs are in `build/dev-watch.log` and `build/dev.log`.

Both builds sign with the first Apple Development or Developer ID identity in your keychain, as `com.owenconti.cadence`. The app always uses the Apple ID signed into macOS, and once access is granted it connects automatically.

**One-time setup:** in the Apple Developer portal, go to Identifiers, register the App ID `com.owenconti.cadence`, and enable **MusicKit** on the App Services tab. MusicKit only issues tokens to registered bundle IDs.

## Layout

| Area | What it does |
| --- | --- |
| Sidebar | Discover / Playlists / Artists, pinned playlists, ⌘K launcher |
| Content | Discover (jump back in, recommendations, trending, new releases), playlist and album pages with in-list filtering, artist pages |
| Now panel | Artwork, scrubber, transport, and the Up Next queue. The artwork compacts on short windows so the queue keeps its space |
| Command palette | ⌘K searches songs, artists, albums and playlists, and runs commands, all from the keyboard |

Shortcuts: Space play/pause · ⌘→ / ⌘← next/previous · ⌘1–3 sections · ⌘[ back · ⌘K search · Esc close.

## Code map

- `Services/MusicProvider.swift`: the protocol the UI depends on
- `Services/MusicKitProvider.swift`: live library and catalog (recently played, personal recommendations, charts, search)
- `Services/DemoProvider.swift`: offline catalog
- `Services/Player.swift`: queue, plus `ApplicationMusicPlayer` (live) or a simulated clock (demo)
- `Views/`, `Components/`: SwiftUI

Debug builds can capture screenshots of every screen: `open --env CADENCE_SNAPSHOTS=/tmp/shots build/Cadence-Dev.app`.
