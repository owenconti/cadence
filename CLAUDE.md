# Cadence

Native macOS music app (SwiftUI + MusicKit). See README.md for layout and code map.

## Claude runs the app; the user doesn't

The user describes what to build and never runs commands. Claude builds, launches, restarts and verifies everything, and never tells the user to run a command.

Tasks live in the Makefile (`make` lists them). Run them with the sandbox disabled, because they launch GUI apps and read the signing keychain.

- **Start of a session:** run `make status`. If the supervisor isn't running, run `make dev`. It builds, launches `build/Cadence-Dev.app` with hot reload, and keeps a supervisor running in the background.
- **After editing Swift files:** saved edits hot reload into the running app, and playback keeps going. After each batch of edits, wait a few seconds and read `tail build/dev-watch.log`:
  - `hot reloaded` means it's live.
  - `build failed` lists compiler errors. Fix them before reporting back. The previous app keeps running meanwhile.
  - The supervisor rebuilds and relaunches by itself when files are added or removed, when `Package.swift`, `Support/Info.plist` or the icon changes, or when an edit fails to inject.
- **Changes the supervisor can't detect.** Run `make restart` after:
  - adding or removing stored properties (`@State`, model fields, new cases),
  - changing launch or setup code (`CadenceApp`, `AppDelegate`, `AppModel.init`).

  A restart stops playback, so batch these together and mention it to the user.
- **Debugging injection:** `build/dev.log` has the app's stdout and InjectionIII's 💉 messages.
- **Visual checks:** take a screenshot with the debug snapshot tour (see README). Screen recording isn't available.
- **Release build:** `make run` builds the signed `build/Cadence.app` and launches it.

Hot reload uses InjectionIII (in /Applications) in standalone mode. `scripts/dev.sh` saves `xcodebuild` output as a `\r`-separated `.xcactivitylog`, because that's where InjectionIII looks up compile commands. Every view body starts with `HotReload.observe()` and ends with `.hotReloadable()`. Keep that pattern in new views.
