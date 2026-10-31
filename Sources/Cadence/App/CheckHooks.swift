#if DEBUG
import AppKit
import notify

/// Hooks for automated checks of a throwaway copy (`make check`), posted with
/// `notifyutil -p com.owenconti.cadence.check.<name>`. Only a copy launched with
/// `CADENCE_CHECK_DIR` listens, so the user's own app ignores them.
///
/// - `snapshot`: writes `window.png` and `state.json` to the check folder.
/// - `play`: plays the first demo playlist from its third song, 48 s in.
/// - `restart`: chooses Restart app.
@MainActor
enum CheckHooks {
    private static var tokens: [Int32] = []

    static func install(_ model: AppModel) {
        guard RunMode.current == .check, let path = ProcessInfo.processInfo.environment["CADENCE_CHECK_DIR"] else { return }
        let dir = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        listen("snapshot") { write(model, to: dir) }
        listen("play") {
            Task {
                guard let playlist = try? await model.provider.playlists().first,
                      let tracks = try? await model.provider.tracks(in: playlist) else { return }
                model.play(tracks, startAt: 2)
                model.player.seek(to: 48)
            }
        }
        listen("restart") { model.restartApp() }
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
            "phase": model.phase == .ready ? "ready" : "onboarding",
            "section": model.section.rawValue,
            "track": model.player.current?.title ?? NSNull(),
            "position": model.player.position,
            "playing": model.player.isPlaying,
            "queue": model.player.queue.count,
            "updateReady": model.update.isReady,
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
#endif
