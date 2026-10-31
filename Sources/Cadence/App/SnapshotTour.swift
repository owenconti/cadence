#if DEBUG
import AppKit
import SwiftUI

/// Development aid: `CADENCE_SNAPSHOTS=/some/dir` walks through the main
/// screens in demo mode and writes a PNG of the window for each.
@MainActor
enum SnapshotTour {
    static func runIfRequested(_ model: AppModel) {
        guard let dir = ProcessInfo.processInfo.environment["CADENCE_SNAPSHOTS"] else { return }
        let out = URL(fileURLWithPath: dir)
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            @MainActor func shot(_ name: String, wait: Double = 1.2) async {
                try? await Task.sleep(for: .seconds(wait))
                capture(to: out.appendingPathComponent("\(name).png"))
            }

            model.phase = .onboarding
            await shot("0-onboarding")
            model.startDemo()
            await shot("1-discover-empty")

            let playlists = try? await model.provider.playlists()
            if let first = playlists?.first, let tracks = try? await model.provider.tracks(in: first) {
                model.play(tracks, startAt: 2)
                model.player.seek(to: 48)
            }
            await shot("2-discover-playing", wait: 2)

            if let first = playlists?.first { model.navigate(.playlist(first)) }
            await shot("3-playlist")

            model.select(.artists)
            await shot("4-artists")
            if let artist = try? await model.provider.artists().first { model.navigate(.artist(artist)) }
            await shot("5-artist")

            model.select(.playlists)
            await shot("6-playlists")

            model.palette.present()
            model.palette.query = "glass"
            await shot("8-palette", wait: 1.6)
            model.palette.dismiss()

            model.select(.discover)
            await shot("9-upnext")
            NSApp.terminate(nil)
        }
    }

    private static func capture(to url: URL) {
        guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
