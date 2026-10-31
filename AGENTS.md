# Cadence

Native macOS music app (SwiftUI + MusicKit). See README.md for the layout and code map.

## Claude runs the builds; the user chooses when to reload

The user describes what to build and never runs commands. Claude builds, checks, commits and rebuilds the app, and never tells the user to run a command. Tasks live in the Makefile (`make` lists them). Run them with the sandbox disabled, because they launch apps and read the signing keychain.

When a change is done:

1. **Check it.** Run `make check`. It plays music on a throwaway debug copy (`build/check/Cadence.app`, demo library), rebuilds that copy in place, confirms "Update ready", restarts it and confirms playback resumed. For visual work, also run `make snapshots` and look at the screenshots in `build/check/snapshots/`. For changes to lists, pages or animations, run `make perf` (a demo playlist of 80 songs opened 3 times). It reports the longest main-thread stall during the page transition. It measured about 115 ms before the track list was made lazy, and about 25–55 ms after. Screen recording isn't available.
2. **Commit to `main`.** Make one commit per change. There is no remote, so don't push.
3. **Rebuild the user's app.** Run `make update`. It rebuilds and installs `/Applications/Cadence.app` in place, under the running copy. Within about 3 seconds that copy shows "Update ready" in the sidebar, and **Restart app** (⌘K or ⌥⌘R) loads the new build. Before quitting, it saves the queue, current song, position and section; the new copy resumes them after a pause of a second or two.
4. **Tell the user** what changed and that Restart app (⌘K) is ready.

Never quit, relaunch or open the user's app (`/Applications/Cadence.app`), and don't run `make run`; restarting is the user's choice. Check runs use only the throwaway copy under `build/check/`. It has its own bundle ID (`com.owenconti.cadence.check`), so its settings, saved window state and permissions never touch the user's app. It listens for `notifyutil -p com.owenconti.cadence.check.<snapshot|play|restart>`, and writes `state.json` and `window.png` to its check folder.

## Command palette

The command palette (⌘K) lists everything the app can do. Its entries are `commands` in `Sources/Cadence/Views/CommandPalette.swift`. Whenever you add, rename, remove or change a user-facing action (a button, a menu item, a keyboard shortcut), update its palette entry in the same change: title, `hint` (its shortcut), `keywords`, and the condition it shows under (only when it would work). Keep the menus in `CadenceApp.swift` consistent with it.

## No animations

The user doesn't want animations or transitions anywhere: pages, overlays, hover and press states, and status changes all appear instantly. Don't add `withAnimation`, `.animation`, `.transition`, `.contentTransition`, symbol effects, repeating or `TimelineView` motion, or scale/offset effects. `RootView` also switches off every animation in its `.transaction`; keep that. The only motion allowed is the system's progress spinner while something loads.
