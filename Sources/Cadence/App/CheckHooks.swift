import AppKit
import notify

/// Hooks for automated checks of a throwaway copy (`make check`), posted with
/// `notifyutil -p com.owenconti.cadence.check.<name>`. Only a copy launched with
/// `CADENCE_CHECK_DIR` listens, so the user's own app ignores them.
///
/// - `snapshot`: writes `window.png` and `state.json` to the check folder.
/// - `play`: plays the first demo playlist from its third song, 48 s in.
/// - `restart`: chooses Restart app.
/// - `quit`: quits normally, as ⌘Q would.
/// - `shuffle`: toggles shuffle mode.
/// - `open-album`: opens the playing song's album.
/// - `play-last-playlist`: plays the last playlist in library order.
/// - `palette`, `palette-close`: opens or closes ⌘K.
/// - `sidebar-hide`, `sidebar-show`: ⌘B. `now-playing-on`, `now-playing-off`: ⇧⌘F.
///   Set rather than toggle, so a resent notification is harmless.
/// - `focus-filter`: opens Playlists and puts the cursor in its filter field.
/// - `press`: presses the key named in `press.txt` ("<number> cmd-b"; also
///   shift-cmd-f, cmd-k, esc) as the keyboard would, so menus, shortcuts and
///   key handling all see it. Numbered, so a late or repeated notification
///   never presses twice; `pressed` in state.json says which number ran.
/// - `select-artists`: goes to Artists.
/// - `run`: runs the steps in `run.txt` in order, once per number on its
///   first line, then reports that number as `ran`. Steps: `sim prepare=2
///   play=0 insert=2 refuse=1` (the simulated engine's delays in seconds, and
///   whether it refuses songs), `play-playlist N`, `add-to-queue N I` (song I
///   of playlist N; -1 for the last), `toggle`, `wait S`, `play-duplicates N
///   [shuffled]` (A, B, A, C from entry N, shuffle mode on or off).
/// - `play-duplicates`: plays A, B, A, C from the second A; `play-duplicates-first`
///   from the first.
/// - `type-glass`: types "glass" into the window, as the keyboard would.
/// - `open-largest`: opens the biggest playlist from Discover and records the
///   longest main-thread stall during the page transition (`stallMs`) and over
///   the next 2 s (`stallMsOverall`).
@MainActor
enum CheckHooks {
    private static var tokens: [Int32] = []
    private static var stallMs: Double = 0
    private static var lastPress = ""
    private static var lastRun = ""
    private static var running = false
    private static var activity: NSObjectProtocol?
    private static let keys: [String: (String, UInt16, NSEvent.ModifierFlags)] = [
        "cmd-b": ("b", 11, .command), "shift-cmd-f": ("f", 3, [.command, .shift]),
        "cmd-k": ("k", 40, .command), "esc": ("\u{1b}", 53, []), "cmd-s": ("s", 1, .command),
    ]
    private static var stallMsOverall: Double = 0

    /// Samples the main thread every 4 ms and reports the longest gap, the
    /// time the UI (and any animation) was frozen.
    private static func measureStall(for seconds: Double, report: @escaping @MainActor (Double) -> Void) {
        var last = CACurrentMediaTime()
        var worst = 0.0
        let end = last + seconds
        let timer = Timer(timeInterval: 0.004, repeats: true) { timer in
            let now = CACurrentMediaTime()
            worst = max(worst, now - last)
            last = now
            if now >= end {
                timer.invalidate()
                MainActor.assumeIsolated { report((worst * 1000).rounded()) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    static func install(_ model: AppModel) {
        guard RunMode.current == .check, let path = ProcessInfo.processInfo.environment["CADENCE_CHECK_DIR"] else { return }
        let dir = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A check copy runs in the background, where App Nap would otherwise
        // hold its notifications and timers back by seconds.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Automated check")
        listen("snapshot") { write(model, to: dir) }
        listen("play") {
            Task {
                guard let playlist = try? await model.provider.playlists().first,
                      let tracks = try? await model.provider.tracks(in: playlist) else { return }
                model.play(tracks, startAt: 2, from: .playlist(playlist))
                model.player.seek(to: 48)
            }
        }
        listen("restart") { model.restartApp() }
        listen("quit") { NSApp.terminate(nil) }
        listen("shuffle") { model.player.toggleShuffle() }
        listen("palette") { model.palette.present() }
        listen("palette-close") { model.palette.dismiss() }
        listen("sidebar-hide") { if !model.sidebarHidden { model.toggleSidebar() } }
        listen("sidebar-show") { if model.sidebarHidden { model.toggleSidebar() } }
        listen("press") {
            // `press.txt` holds "<number> <key>"; each number is pressed once,
            // however many times (or late) the notification arrives.
            let line = (try? String(contentsOf: dir.appendingPathComponent("press.txt"), encoding: .utf8)) ?? ""
            let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] != lastPress, let (chars, code, modifiers) = keys[parts[1]] else { return }
            lastPress = parts[0]
            press(chars, keyCode: code, modifiers: modifiers)
        }
        listen("select-artists") { model.select(.artists) }
        listen("run") {
            let lines = ((try? String(contentsOf: dir.appendingPathComponent("run.txt"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let number = lines.first, number != lastRun, !running else { return }
            running = true
            Task {
                for step in lines.dropFirst() { await run(step, model) }
                lastRun = number
                running = false
            }
        }
        for (name, start) in [("play-duplicates", 2), ("play-duplicates-first", 0)] {
            listen(name) {
                Task {
                    guard let playlist = model.playlists.first,
                          let tracks = try? await model.provider.tracks(in: playlist), tracks.count >= 3 else { return }
                    model.play([tracks[0], tracks[1], tracks[0], tracks[2]], startAt: start, shuffled: false, from: .playlist(playlist))
                }
            }
        }
        listen("focus-filter") {
            model.select(.playlists)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let window = NSApp.appWindow, let field = editableFields(in: window.contentView).first else { return }
                window.makeFirstResponder(field)
            }
        }
        listen("type-glass") {
            guard let window = NSApp.appWindow else { return }
            for c in "glass" {
                let chars = String(c)
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, characters: chars,
                                                    charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0) {
                        window.sendEvent(event)
                    }
                }
            }
        }
        listen("now-playing-on") { if !model.nowPlayingMode { model.toggleNowPlayingMode() } }
        listen("now-playing-off") { if model.nowPlayingMode { model.toggleNowPlayingMode() } }
        listen("play-last-playlist") {
            Task {
                guard let playlist = model.playlists.last,
                      let tracks = try? await model.provider.tracks(in: playlist) else { return }
                model.play(tracks, from: .playlist(playlist))
            }
        }
        listen("open-album") { if let track = model.player.current { model.openAlbum(of: track) } }
        listen("open-largest") {
            guard let largest = model.playlists.max(by: { ($0.trackCount ?? 0) < ($1.trackCount ?? 0) }) else { return }
            model.select(.discover)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                measureStall(for: 0.35) { stallMs = $0 }
                measureStall(for: 2) { stallMsOverall = $0 }
                model.navigate(.playlist(largest))
            }
        }
    }

    private static func listen(_ name: String, _ action: @escaping @MainActor () -> Void) {
        var token: Int32 = 0
        notify_register_dispatch("com.owenconti.cadence.check.\(name)", &token, .main) { _ in
            MainActor.assumeIsolated { action() }
        }
        tokens.append(token)
    }

    private static func write(_ model: AppModel, to dir: URL) {
        let state: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "bundle": Bundle.main.bundlePath,
            "phase": "\(model.phase)",
            "section": model.section.rawValue,
            "playlistsRecent": model.sortedPlaylists(by: .recent).map(\.name),
            "playlistsName": model.sortedPlaylists(by: .name).map(\.name),
            "playlistsSize": model.sortedPlaylists(by: .size).map { "\($0.name):\(model.size(of: $0) ?? -1)" },
            "page": "\(model.route)".components(separatedBy: "(").first ?? "",
            "pageTitle": { () -> String in
                switch model.route {
                case .album(let album): album.title
                case .playlist(let playlist): playlist.name
                case .artist(let artist): artist.name
                default: ""
                }
            }(),
            "track": model.player.current?.title ?? NSNull(),
            "position": model.player.position,
            "playing": model.player.isPlaying,
            "queue": model.player.queue.count,
            "shuffled": model.player.isShuffled,
            "source": model.player.source.map { "\($0.label): \($0.title)" } ?? NSNull(),
            "upNext": model.player.upNext.prefix(5).map(\.title).joined(separator: " / "),
            "updateReady": model.update.isReady,
            "paletteOpen": model.palette.isPresented,
            "paletteQuery": model.palette.query,
            "pressed": lastPress,
            "ran": lastRun,
            "playingNow": model.player.isPlaying,
            "notice": model.player.notice ?? "",
            "engineQueueIDs": (model.player.engine as? SimulatedEngine)?.entries.map(\.id).joined(separator: ",") ?? "",
            "engineIndex": (model.player.engine as? SimulatedEngine)?.index ?? -1,
            "enginePlaying": model.player.engine.isPlaying,
            "engineTime": model.player.engine.playbackTime,
            "snapshot": (try? String(contentsOf: dir.appendingPathComponent("snapshot.txt"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            "queueIDs": model.player.queue.map(\.id).joined(separator: ","),
            "index": model.player.index ?? -1,
            "upNextAll": model.player.upNext.map(\.id).joined(separator: ","),
            "unshuffledIDs": model.player.unshuffled?.map(\.id).joined(separator: ",") ?? "",
            "filterText": editableFields(in: NSApp.appWindow?.contentView).filter { !($0 is FocusingTextField) }.map(\.stringValue).joined(),
            "sidebarHidden": model.sidebarHidden,
            "nowPlayingMode": model.nowPlayingMode,
            "stallMs": stallMs,
            "stallMsOverall": stallMsOverall,
            "windows": NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) \(Int($0.frame.width))x\(Int($0.frame.height))" },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("state.json"))
        }
        guard let view = NSApp.appWindow?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("window.png"))
    }

    /// Text fields the user can type in, front to back.
    private static func editableFields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        let own = (view as? NSTextField).flatMap { $0.isEditable ? [$0] : nil } ?? []
        return own + view.subviews.flatMap { editableFields(in: $0) }
    }

    /// A key press delivered through the app, as if typed.
    private static func press(_ chars: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        guard let window = NSApp.appWindow else { return }
        for kind in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: chars,
                                            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode) {
                NSApp.sendEvent(event)
            }
        }
    }

    /// One step of a `run` script.
    private static func run(_ step: String, _ model: AppModel) async {
        let words = step.split(separator: " ").map(String.init)
        func playlist(_ word: String) -> PlaylistItem? {
            let n = Int(word) ?? 0
            return n < 0 ? model.playlists.last : model.playlists.indices.contains(n) ? model.playlists[n] : nil
        }
        switch words.first {
        case "sim":
            guard let engine = model.player.engine as? SimulatedEngine else { return }
            for setting in words.dropFirst() {
                let pair = setting.split(separator: "=").map(String.init)
                guard pair.count == 2, let value = Double(pair[1]) else { continue }
                switch pair[0] {
                case "prepare": engine.delays.prepare = .milliseconds(Int(value * 1000))
                case "play": engine.delays.play = .milliseconds(Int(value * 1000))
                case "insert": engine.delays.insert = .milliseconds(Int(value * 1000))
                case "refuse": engine.refuseInserts = value != 0
                default: break
                }
            }
        case "play-playlist":
            guard words.count > 1, let playlist = playlist(words[1]),
                  let tracks = try? await model.provider.tracks(in: playlist) else { return }
            model.play(tracks, shuffled: false, from: .playlist(playlist))
        case "add-to-queue":
            guard words.count > 2, let playlist = playlist(words[1]),
                  let tracks = try? await model.provider.tracks(in: playlist), !tracks.isEmpty else { return }
            let i = Int(words[2]) ?? 0
            model.player.addToQueue(tracks[i < 0 ? tracks.count - 1 : min(i, tracks.count - 1)])
        case "toggle":
            model.player.toggle()
        case "play-duplicates":
            guard let playlist = model.playlists.first,
                  let tracks = try? await model.provider.tracks(in: playlist), tracks.count >= 3 else { return }
            let shuffled = words.contains("shuffled")
            model.player.setShuffle(shuffled)
            model.play([tracks[0], tracks[1], tracks[0], tracks[2]], startAt: Int(words.count > 1 ? words[1] : "0") ?? 0,
                       from: .playlist(playlist))
        case "wait":
            try? await Task.sleep(for: .milliseconds(Int((Double(words.count > 1 ? words[1] : "0") ?? 0) * 1000)))
        default:
            break
        }
    }
}
