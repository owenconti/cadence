# Cadence

A proof-of-concept native macOS music app built with SwiftUI and MusicKit, focused on playlists, artists, discovery and now playing.

## Run it

Tasks are in the `Makefile`; run `make` to list them.

```sh
make run      # build, install to /Applications and launch
make update   # rebuild and install; the running app offers Restart app
make check    # automated update + restart check on a throwaway copy
```

**Download:** [the latest release](https://github.com/owenconti/cadence/releases/latest) (the `.dmg`; drag Cadence to Applications). It's notarized, opens normally, and updates itself. Connect your Apple Music account (playback needs a subscription) or explore the demo library.

`make release BUMP=patch|minor|major NOTES=file` cuts a release, as Paseo Command does: checks, builds, signs with the Developer ID, notarizes (the `paseo-command-notary` keychain login) and staples the app and a disk image, writes the Sparkle appcast (signed with the keychain's EdDSA key), commits `Release v<version>`, pushes and publishes the GitHub release. `DRY_RUN=1` stops before committing.

The app installs to `/Applications/Cadence.app`, so it opens like any other app (Spotlight, Launchpad, the Dock). `make update` swaps a new build in underneath the running app without touching it. Within a few seconds the app shows **Update ready** in the sidebar. **Restart app** (in ⌘K, from the pill, or with ⌥⌘R) relaunches into the new build. The queue, current song, position and section carry across, so music resumes after a short pause.

The build signs with the first Apple Development or Developer ID identity in your keychain, as `com.owenconti.cadence`. The app always uses the Apple ID signed into macOS, and once access is granted it connects automatically.

**One-time setup:** in the Apple Developer portal, go to Identifiers, register the App ID `com.owenconti.cadence`, and enable **MusicKit** on the App Services tab. MusicKit only issues tokens to registered bundle IDs.

## iPhone

`iOS/` is Cadence for iPhone, for Owen's own phone only: it's installed through TestFlight's internal testing and never goes to the App Store. It compiles the Mac app's models, services and components directly (Mac-only code is behind `#if os(macOS)`), plus phone screens in `iOS/Sources`: Discover, Playlists, Artists and Search tabs, playlist, album and artist pages, a mini player and full-screen Now Playing. `iOS/project.yml` generates the Xcode project with XcodeGen (`brew install xcodegen`).

```sh
make testflight       # build and upload to TestFlight; the phone's TestFlight app installs it
make phone-snapshots  # screenshot every screen in the simulator (demo library) into build/phone/snapshots
make phone            # alternative: install directly on a plugged-in iPhone
```

**One-time setup for TestFlight:**

1. An App Store Connect API key (Users and Access › Integrations › App Store Connect API, App Manager access). Its `.p8` goes in `~/.appstoreconnect/private_keys/`, and its IDs in `~/.appstoreconnect/cadence.env` as `ASC_KEY_ID=…` and `ASC_ISSUER_ID=…`. With it, `scripts/asc.py signing` makes the App Store certificate (kept in its own keychain, `~/.appstoreconnect/cadence-signing.keychain-db`) and profile, and altool uploads. Signing also needs Apple's current WWDR G3 intermediate in the login keychain (Xcode normally installs it).
2. The app record in App Store Connect (Apps › + › New App: iOS, bundle ID `com.owenconti.cadence`). Apple's API can't create it.
3. An internal testing group with Owen in it (done: "Owen", with access to every build; `scripts/asc.py` talks to the App Store Connect API with the same key), and the TestFlight app on the phone.

Each upload's build number is the commit count, so every upload needs a new commit. TestFlight builds expire after 90 days. `make phone` instead needs the Apple ID in Xcode › Settings › Accounts, the phone plugged in and trusted, and Developer Mode on.

## Layout

| Area | What it does |
| --- | --- |
| Splash | Shown at launch while access is checked and the library loads, then fades into the app (Discover already filled in) or the connect screen |
| Sidebar | Discover / Playlists / Artists, pinned playlists, ⌘K launcher |
| Content | Discover (jump back in, recommendations, trending, new releases), playlist and album pages with in-list filtering, artist pages |
| Now panel | Artwork, scrubber, transport, and the Up Next queue. The artwork compacts on short windows so the queue keeps its space |
| Command palette | ⌘K searches songs, artists, albums and playlists, and runs every app action (navigation, playback, reload library, Restart app), all from the keyboard |

Shortcuts: Space play/pause · ⌘→ / ⌘← next/previous · ⌘1–3 sections · ⌘[ back · ⌘K search · ⌘B hide sidebar · ⇧⌘F Now Playing · ⌘W close the window (music keeps playing) · ⌘0 or the Dock icon bring it back · ⌥⌘R restart app · Esc close. Drag the inner edge of the sidebar or the Now panel to resize it; double-click to reset. In ⌘K, ⌘↩ plays the selected song next and ⌥↩ adds it to the queue.

## Code map

- `Services/MusicProvider.swift`: the protocol the UI depends on
- `Services/MusicKitProvider.swift`: live library and catalog (recently played, personal recommendations, charts, search)
- `Services/DemoProvider.swift`: offline catalog
- `Services/Player.swift`: the queue and what should play; commands reach the engine one at a time, in order
- `Services/LiveEngine.swift`: what plays it: Apple Music (`MusicKitEngine`) or `SimulatedEngine` for the demo library, which `make check` also slows down or makes refuse songs
- `App/AppUpdate.swift`: notices a newer build on disk, and Restart app with its playback handoff
- `App/RunMode.swift`, `App/CheckHooks.swift`: throwaway copies for `make check` and `make snapshots`
- `App/ArtworkAudit.swift`: `make artwork`, which draws every artwork source from the real library and fails on any blank
- `Components/ArtworkSnapshot.swift`: draws library artwork into an image (Control Center, the audit)
- `Views/`, `Components/`: SwiftUI

`make snapshots` captures every screen from a throwaway debug copy into `build/check/snapshots/`.
