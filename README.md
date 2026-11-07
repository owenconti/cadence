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

The build signs with the first Developer ID (else Apple Development) identity in your keychain, as `com.owenconti.cadence`. The app always uses the Apple ID signed into macOS, and once access is granted it connects automatically.

**One-time setup:** in the Apple Developer portal, go to Identifiers, register the App ID `com.owenconti.cadence`, and enable **MusicKit** on the App Services tab. MusicKit only issues tokens to registered bundle IDs.

## iPhone and iPad

`iOS/` is Cadence for iPhone and iPad, for Owen's own devices only: it's installed through TestFlight's internal testing and never goes to the App Store. It compiles the Mac app's models, services and components directly (Mac-only code is behind `#if os(macOS)`), plus phone screens in `iOS/Sources`: Discover, Playlists, Artists and Search tabs, playlist, album and artist pages, a mini player and full-screen Now Playing (swipe the artwork to change song). A full-width iPad gets the Mac's layout instead (`TabletShell`): in landscape the three columns, in portrait the sidebar and pages with the mini player; Search fills the page column in place of ⌘K. Narrow Split View sizes get the phone's. `iOS/project.yml` generates the Xcode project with XcodeGen (`brew install xcodegen`).

```sh
make testflight       # build and upload to TestFlight; the phone's TestFlight app installs it
make phone-snapshots  # screenshot every screen on the iPhone and iPad simulators (demo library) into build/phone/snapshots/{iphone,ipad}
make phone            # alternative: install directly on a plugged-in iPhone
```

**One-time setup for TestFlight:**

1. An App Store Connect API key (Users and Access › Integrations › App Store Connect API, App Manager access). Its `.p8` goes in `~/.appstoreconnect/private_keys/`, and its IDs in `~/.appstoreconnect/cadence.env` as `ASC_KEY_ID=…` and `ASC_ISSUER_ID=…`. With it, `scripts/asc.py signing` makes the App Store certificate (kept in its own keychain, `~/.appstoreconnect/cadence-signing.keychain-db`) and profile, and altool uploads. Signing also needs Apple's current WWDR G3 intermediate in the login keychain (Xcode normally installs it).
2. The app record in App Store Connect (Apps › + › New App: iOS, bundle ID `com.owenconti.cadence`). Apple's API can't create it.
3. An internal testing group with Owen in it (done: "Owen", with access to every build; `scripts/asc.py` talks to the App Store Connect API with the same key), and the TestFlight app on the phone.

**CarPlay:** `iOS/Sources/CarPlay.swift` gives the car Listen Now (Jump back in, Discover's shelves, Trending) and Playlists tabs, each opening songs with Play and Shuffle, and the system's Now Playing screen. Cars only show apps with the CarPlay audio entitlement (`iOS/CarPlay.entitlements`), which Apple has granted. Every build carries it, and `make testflight` signs with it; it needs CarPlay Audio ticked on the App ID (Identifiers › com.owenconti.cadence › Additional Capabilities), which the API can't do, and fails saying so if it isn't. The simulator's CarPlay window is I/O › External Displays › CarPlay.

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

CarPlay collection lists use one native scrolling song section with Play and
Shuffle in the navigation bar, leaving the complete item budget for songs.
There are no paging controls. The connected vehicle determines
`CPListTemplate.maximumItemCount` (across all sections) and
`maximumSectionCount`; Apple documents no universal fixed number:
[maximumItemCount](https://developer.apple.com/documentation/carplay/cplisttemplate/maximumitemcount),
[maximumSectionCount](https://developer.apple.com/documentation/carplay/cplisttemplate/maximumsectioncount).
Apple's [CarPlay Developer Guide](https://developer.apple.com/download/files/CarPlay-Developer-Guide.pdf),
“List template”, additionally documents a dynamic 12-item restriction in some
cars. Cadence observes `CPSessionConfiguration` list restrictions, uses all 12
rows for songs when restricted, and restores the larger budget when lifted.
The iOS 26.5 simulator reports 500 items and 200 sections before connection;
these values do not establish a particular car's limit. Songs beyond
that system cap cannot be browsed in the list, but Play and Shuffle still use
the complete collection. A section heading reports when the list is capped.
The CarPlay log records loaded, submitted, and retained item counts and runtime
limits to distinguish provider truncation from template truncation.

For simulator verification, launch a debug build with
`CADENCE_CHECK_DIR=/tmp/cadence-carplay` to use the offline demo library, enable
I/O › External Displays › CarPlay, open Cadence › Playlists › All Songs (more
than 50 songs), and scroll to the final song. Compare Listen Now's collection
route and verify selection on a later row starts at that song. Retest on a real
head unit for vehicle-specific limits and restrictions while driving.

## Apple Watch

The embedded `CadenceWatch` target (watchOS 10+) mirrors the phone's shared
`Player` through WatchConnectivity. Controls reach the same serialized queue;
there is no second player, artwork, or watch MusicKit authorization. Keep Cadence
running on the paired iPhone. Offline controls are disabled and the last state
remains visible. Crown volume is omitted: public iOS APIs do not offer arbitrary
remote system volume control.

`make watch` builds the simulator target and `make check` includes it (and thus
macOS release checks do too). TestFlight archives embed the watch app and sign it
before the phone. Explicit App ID `com.owenconti.cadence.watchkitapp` is registered
under team HBLWB8LVKC in Apple Developer Identifiers, with no extra capabilities.
Existing phone identifiers and entitlements are unchanged. Xcode needs the watchOS
platform and simulator runtime installed.

`scripts/watch.sh snapshots` captures the Now Playing fixture (`--snapshot`)
on 41mm and 49mm simulators into `build/watch/snapshots/{small,large}.png`.
These show the disconnected state with the last received track; pairing and
transport should also be verified on Owen's physical watch before distribution.
