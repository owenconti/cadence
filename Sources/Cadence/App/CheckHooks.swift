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
/// - `open-largest`: opens the biggest playlist from Discover and records the
///   longest main-thread stall during the page transition (`stallMs`) and over
///   the next 2 s (`stallMsOverall`).
@MainActor
enum CheckHooks {
    private static var tokens: [Int32] = []
    private static var stallMs: Double = 0
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
            "track": model.player.current?.title ?? NSNull(),
            "position": model.player.position,
            "playing": model.player.isPlaying,
            "queue": model.player.queue.count,
            "shuffled": model.player.isShuffled,
            "source": model.player.source.map { "\($0.label): \($0.title)" } ?? NSNull(),
            "upNext": model.player.upNext.prefix(5).map(\.title).joined(separator: " / "),
            "updateReady": model.update.isReady,
            "stallMs": stallMs,
            "stallMsOverall": stallMsOverall,
            "windows": NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) \(Int($0.frame.width))x\(Int($0.frame.height))" },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("state.json"))
        }
        guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("window.png"))
    }
}
