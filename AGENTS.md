# Cadence

Native macOS music app (SwiftUI + MusicKit). See README.md for the layout and code map.

## Claude runs the builds; the user chooses when to reload

The user describes what to build and never runs commands. Claude builds, checks, commits and rebuilds the app, and never tells the user to run a command. Tasks live in the Makefile (`make` lists them). Run them with the sandbox disabled, because they launch apps and read the signing keychain.

When a change is done:

1. **Check it.** Run `make check`. It plays music on a throwaway debug copy (`build/check/Cadence.app`, demo library), rebuilds that copy in place, confirms "Update ready", restarts it and confirms playback resumed. It also drives the player's timing paths through the simulated engine (slow starts, slow or refused songs, a pause racing a play, a song queued twice) and requires Cadence's queue and the engine's to match after each. It then runs `make artwork`, which draws every artwork source (Discover, playlists and their songs, album pages, artists, artist pages, search, the restored queue, Control Center) from the real library and fails on any blank; two known-dead handles must stay blank, proving it can tell. It also syncs the empty iCloud zone from that copy (its sync state kept in the audit folder) and fails if iCloud can't be reached. Any artwork change must pass it. For visual work, also run `make snapshots` and look at the screenshots in `build/check/snapshots/`. For changes to lists, pages or animations, run `make perf` (a demo playlist of 80 songs opened 3 times). It reports the longest main-thread stall during the page transition. It measured about 115 ms before the track list was made lazy, and about 25–55 ms after. Screen recording isn't available.
2. **Commit to `main` and push.** Make one commit per change, then `git push origin main` (github.com/owenconti/cadence, public).
3. **Rebuild the user's app.** Run `make update`. It rebuilds and installs `/Applications/Cadence.app` in place, under the running copy. Within about 3 seconds that copy shows "Update ready" in the sidebar, and **Restart app** (⌘K or ⌥⌘R) loads the new build. Before quitting, it saves the queue, current song, position and section; the new copy resumes them after a pause of a second or two.
4. **Tell the user** what changed and that Restart app (⌘K) is ready.

Never quit, relaunch or open the user's app (`/Applications/Cadence.app`), and don't run `make run`; restarting is the user's choice. Check runs use only the throwaway copy under `build/check/`, plus the read-only artwork audit copy under `build/audit/` (the app's own bundle ID, since MusicKit only serves registered IDs; it starts no playback, saves nothing and quits). The check copy has its own bundle ID (`com.owenconti.cadence.check`), so its settings, saved window state and permissions never touch the user's app. It listens for `notifyutil -p com.owenconti.cadence.check.<snapshot|play|restart>`, and writes `state.json` and `window.png` to its check folder.

## iPhone

`iOS/` builds Cadence for the user's own iPhone (see README.md). After changing shared code (Models, Services, Components, `AppModel`), also build the phone app: `make phone-snapshots` builds it, runs a screenshot tour on the iPhone and iPad simulators on the demo library and writes `build/phone/snapshots/{iphone,ipad}` (the iPad's landscape shots are drawn in a landscape-sized window, since iPadOS won't let an app rotate itself); look at them for phone or iPad UI changes. The iPad reuses the Mac's views (Sidebar, RootView's MainShell, the pages), so Mac view changes show up there too. When a phone change is done, commit and push, then run `make testflight`: it uploads a build to TestFlight, and the phone's TestFlight app offers it within about 15 minutes (tell the user to update there). It fails with what's missing if the one-time setup in README.md isn't done. `make phone` installs on a plugged-in iPhone instead; use it only if the user asks. There's no Update ready on the phone. The command palette doesn't exist on the phone; Search is its tab.

## Releases

Copies people download update themselves with Sparkle from this repository's GitHub releases; the user's own copy and check copies have no feed and update only by rebuilding. Run `make release` only when the user explicitly asks to cut or publish a release; finishing a feature or changing the release tooling doesn't authorize one. Then don't ask for a version: review the commits since the latest release and choose the bump (patch for fixes, minor for new features; minor for incompatible changes while at 0.x), write user-facing notes to a file, and run `make release BUMP=<kind> NOTES=<file>`. It runs `make check`, builds, signs with the Developer ID, notarizes (the `paseo-command-notary` keychain login Paseo Command uses) and staples the app and a disk image, signs the Sparkle appcast with the keychain's EdDSA key (the same as Paseo Command's), commits `Release v<version>`, pushes `main` and publishes the GitHub release. `DRY_RUN=1` does all but commit, push and publish. Report the published version and link. After pushing other changes, mention that a release is pending if they're user-visible.

## Command palette

The command palette (⌘K) lists everything the app can do. Its entries are `commands` in `Sources/Cadence/Views/CommandPalette.swift`. Whenever you add, rename, remove or change a user-facing action (a button, a menu item, a keyboard shortcut), update its palette entry in the same change: title, `hint` (its shortcut), `keywords`, and the condition it shows under (only when it would work). Keep the menus in `CadenceApp.swift` consistent with it.

## No screen transitions

The user doesn't want transitions between screens: switching between the splash, the connect screen and the app, moving between pages, and opening or closing the command palette all happen instantly, with no cross-fades or slides. Animation within a screen is welcome: loading states, hover and press effects, interactive controls, and status changes such as the Update ready pill.
