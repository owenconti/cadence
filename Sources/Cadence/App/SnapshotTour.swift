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
            await shot("1-discover-empty", wait: 2.2)

            let playlists = try? await model.provider.playlists()
            if let first = playlists?.first, let tracks = try? await model.provider.tracks(in: first) {
                model.play(tracks, startAt: 2, from: .playlist(first))
                model.player.seek(to: 48)
            }
            await shot("2-discover-playing", wait: 2)
            model.nudgeTempo(by: 6)
            await shot("2a-tempo-faster", wait: 0.8)
            model.resetTempo()

            if let first = playlists?.first { model.navigate(.playlist(first)) }
            await shot("3-playlist")

            model.select(.artists)
            await shot("4-artists")
            if let artist = try? await model.provider.artists().first { model.navigate(.artist(artist)) }
            await shot("5-artist")
            // A song's other versions: an explicit one, then one with no clean twin.
            var explicitSong: TrackItem?
            for playlist in playlists ?? [] where explicitSong == nil {
                explicitSong = try? await model.provider.tracks(in: playlist).first(where: \.isExplicit)
            }
            if let explicitSong {
                model.navigate(.versions(explicitSong))
                await shot("5a-versions-explicit")
                model.navigate(.versions(DemoVersion.live.version(of: explicitSong)))
                await shot("5b-versions-live")
            }

            model.select(.playlists)
            await shot("6-playlists")

            // My Playlists: empty, then with a copy of a demo playlist.
            model.mine.removeAll()
            model.mine.folderRecords.removeAll()
            model.select(.mine)
            await shot("6a-my-playlists-empty")
            if let first = playlists?.first {
                model.navigate(.playlist(first))
                await model.copyToMine(first).value
                await shot("6b-my-playlist-copy", wait: 1.5)
            }
            model.select(.mine)
            await shot("6c-my-playlists")
            // Folders: one holding the copy, one empty, and a playlist in none.
            if let copy = model.myPlaylists.first, let second = playlists?.dropFirst().first {
                await model.copyToMine(second).value
                model.select(.mine)
                model.createFolder(named: "Road Trips", moving: copy)
                model.createFolder(named: "Workouts")
                await shot("6d-my-playlists-folders", wait: 1.0)
                model.navigate(.playlist(copy))
                await shot("6e-my-playlist-in-folder")
                model.collapsedFolders.insert(model.myFolders.first { $0.name == "Road Trips" }?.id ?? "")
                model.select(.mine)
                await shot("6f-my-playlists-folder-closed")
                model.collapsedFolders = []
            }

            model.palette.present()
            await shot("7-palette-commands", wait: 1.2)
            model.palette.query = "glass"
            await shot("8-palette", wait: 1.6)
            model.palette.dismiss()

            model.select(.discover)
            await shot("9-upnext")
            // Shuffled, with two songs queued: they're listed, the rest isn't.
            if let first = playlists?.first, let tracks = try? await model.provider.tracks(in: first), tracks.count > 6 {
                model.play(tracks, shuffled: true, from: .playlist(first))
                model.player.addToQueue(tracks[5])
                model.player.addToQueue(tracks[6])
                await shot("9a-upnext-shuffled", wait: 1.0)
                model.player.setShuffle(false)
            }

            // Loading states, each next to what replaces it: nothing should
            // move when the data arrives.
            DemoProvider.extraLatency = .seconds(3)
            if let first = playlists?.first { model.navigate(.playlist(first)) }
            await shot("10-playlist-loading", wait: 0.6)
            await shot("10-playlist-loaded", wait: 3.4)
            model.select(.artists)
            await shot("11-artists-loading", wait: 0.6)
            await shot("11-artists-loaded", wait: 3.4)
            if let artist = try? await model.provider.artists().first { model.navigate(.artist(artist)) }
            await shot("12-artist-loading", wait: 0.6)
            await shot("12-artist-loaded", wait: 3.4)
            model.select(.discover)
            model.reloadLibrary()
            await shot("13-discover-loading", wait: 0.6)
            await shot("13-discover-loaded", wait: 3.4)
            model.select(.playlists)
            await shot("14-playlists", wait: 0.6)
            DemoProvider.extraLatency = .zero
            model.toggleNowPlayingMode()
            await shot("15-now-playing")
            model.toggleNowPlayingMode()
            model.toggleSidebar()
            await shot("16-sidebar-hidden")
            model.toggleSidebar()
            NSApp.terminate(nil)
        }
    }

    private static func capture(to url: URL) {
        guard let view = NSApp.appWindow?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
