#if DEBUG
import SwiftUI
import UIKit

/// Development aid, the phone's `make snapshots`: `CADENCE_SNAPSHOTS=/some/dir`
/// walks through the main screens on the demo library and writes a PNG of the
/// screen for each, then quits. `make phone-snapshots` runs it in the simulator.
@MainActor
enum PhoneSnapshotTour {
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
            await shot("1-discover", wait: 2.2)

            let playlists = try? await model.provider.playlists()
            if let first = playlists?.first, let tracks = try? await model.provider.tracks(in: first) {
                model.play(tracks, startAt: 2, from: .playlist(first))
                model.player.seek(to: 48)
            }
            await shot("2-discover-playing", wait: 2)

            if let first = playlists?.first { model.navigate(.playlist(first)) }
            await shot("3-playlist")

            model.select(.playlists)
            await shot("4-playlists")

            model.select(.artists)
            await shot("5-artists")
            if let artist = try? await model.provider.artists().first { model.navigate(.artist(artist)) }
            await shot("6-artist")

            model.palette.present()
            await shot("7-search-empty")
            model.palette.query = "glass"
            await shot("8-search", wait: 1.6)
            model.palette.dismiss()

            model.select(.discover)
            model.toggleNowPlayingMode()
            await shot("9-now-playing")
            model.toggleNowPlayingMode()

            // The iPad in landscape: the Mac's three columns. iPadOS won't let
            // an app rotate itself, so the layout is drawn in a window of
            // landscape size instead.
            if UIDevice.current.userInterfaceIdiom == .pad {
                model.select(.discover)
                await landscape("10-landscape-discover", model)
                if let first = playlists?.first { model.navigate(.playlist(first)) }
                await landscape("11-landscape-playlist", model)
                model.palette.present()
                model.palette.query = "glass"
                await landscape("12-landscape-search", model, wait: 1.6)
                model.palette.dismiss()
            }
            @MainActor func landscape(_ name: String, _ model: AppModel, wait: Double = 1.2) async {
                guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: 1210, height: 834)
                let root = ZStack { AmbientBackground(); TabletShell() }
                    .environment(model)
                    .preferredColorScheme(.dark)
                window.rootViewController = UIHostingController(rootView: root)
                window.isHidden = false
                try? await Task.sleep(for: .seconds(wait))
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                try? image.pngData()?.write(to: out.appendingPathComponent("\(name).png"))
                window.isHidden = true
            }
            FileManager.default.createFile(atPath: out.appendingPathComponent(".done").path, contents: nil)
            exit(0)
        }
    }

    private static func capture(to url: URL) {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: url)
    }
}
#endif
