import AppKit
import MusicKit
import os

/// `make artwork`: with `CADENCE_ARTWORK_AUDIT=<folder>`, walks every place
/// the app gets artwork from, through the same provider calls the screens
/// use, against the real Apple Music library, and draws each one the way the
/// app does. Anything that doesn't draw fails the audit. Read-only: it
/// starts nothing, saves nothing and quits when done.
///
/// A control proves the test can fail: a song's artwork as saved to disk by
/// an earlier session is a dead handle and must come out blank.
@MainActor
enum ArtworkAudit {
    private struct Item {
        var surface: String
        var title: String
        var source: ArtworkSource
    }

    static func runIfRequested() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["CADENCE_ARTWORK_AUDIT"] else { return false }
        let dir = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task {
            // Keep the app's own window out of the way while this runs.
            NSApp.windows.forEach { $0.orderOut(nil) }
            let report = await run()
            try? report.joined(separator: "\n").write(to: dir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
            exit(0)
        }
        return true
    }

    private static func run() async -> [String] {
        guard MusicAuthorization.currentStatus == .authorized else {
            return ["FAIL Apple Music access isn't granted to com.owenconti.cadence (\(MusicAuthorization.currentStatus))"]
        }
        let provider = MusicKitProvider()
        var items: [Item] = []
        func add(_ surface: String, _ title: String, _ source: ArtworkSource) {
            items.append(Item(surface: surface, title: title, source: source))
        }
        func addTracks(_ surface: String, _ tracks: [TrackItem]) {
            for track in tracks { add(surface, "\(track.title) – \(track.artistName)", track.artwork) }
        }
        // A request that fails would quietly leave its surface untested.
        var problems: [String] = []
        func fetch<T>(_ what: String, _ work: () async throws -> T) async -> T? {
            do { return try await work() } catch {
                problems.append("FAIL couldn't load \(what): \(error.localizedDescription)")
                return nil
            }
        }

        // Discover.
        if let feed = await fetch("Discover", { try await provider.discover() }) {
            problems += feed.problems.map { "FAIL couldn't load Discover's \($0)" }
            for item in feed.recent { add("Discover: Jump back in", item.title, item.artwork) }
            for shelf in feed.shelves { for item in shelf.items { add("Discover: \(shelf.title)", item.title, item.artwork) } }
            addTracks("Discover: Trending", feed.trending)
            for album in feed.newReleases { add("Discover: New releases", album.title, album.artwork) }
        }

        // Playlists: the sidebar and list, each page's header, and its songs.
        let playlists = await fetch("playlists", { try await provider.playlists() }) ?? []
        var songs: [TrackItem] = []
        for playlist in playlists {
            add("Playlists", playlist.name, playlist.artwork)
            let tracks = await fetch("the songs of \(playlist.name)", { try await provider.tracks(in: playlist) }) ?? []
            addTracks("Playlist songs: \(playlist.name)", Array(tracks.prefix(20)))
            songs += tracks.prefix(20)
        }

        // Albums opened from songs (Now Playing, song lists, ⌘K), their songs.
        let restored = await PlaybackStore().load { ids in (try? await provider.tracks(withIDs: ids)) ?? [] }
        var albumSources = Array(restored?.tracks.prefix(10) ?? [])
        albumSources += stride(from: 0, to: songs.count, by: max(1, songs.count / 20)).map { songs[$0] }
        var seenAlbums = Set<String>()
        var albumsMissing = 0
        for track in albumSources {
            guard let album = await provider.album(for: track) else { albumsMissing += 1; continue }
            guard seenAlbums.insert(album.id).inserted else { continue }
            add("Album pages", "\(album.title) – \(album.artistName)", album.artwork)
            addTracks("Album songs: \(album.title)", Array((await fetch("the songs of \(album.title)", { try await provider.tracks(in: album) }) ?? []).prefix(5)))
        }
        if albumsMissing * 2 > albumSources.count {
            problems.append("FAIL couldn't find the album for \(albumsMissing) of \(albumSources.count) songs")
        }

        // Artists: the list, and artist pages (opened from the list or a song).
        let artists = await fetch("artists", { try await provider.artists() }) ?? []
        for artist in artists { add("Artists", artist.name, artist.artwork) }
        var pageArtists = Array(artists.prefix(2))
        if let track = restored?.tracks.first {
            pageArtists.append(ArtistItem(id: "name:\(track.artistName)", name: track.artistName, genre: nil, artwork: .none))
        }
        var similarPage: ArtistItem?
        for artist in pageArtists {
            guard let detail = await fetch("the artist page for \(artist.name)", { try await provider.detail(for: artist) }) else { continue }
            if similarPage == nil { similarPage = detail.similar.first }
            add("Artist pages", detail.artist.name, detail.artist.artwork)
            addTracks("Artist top songs: \(detail.artist.name)", detail.topSongs)
            for album in detail.albums.prefix(12) { add("Artist albums: \(detail.artist.name)", album.title, album.artwork) }
            for similar in detail.similar { add("Similar artists: \(detail.artist.name)", similar.name, similar.artwork) }
        }

        // A catalog artist's page (from "Fans also like" or search) opens that
        // exact artist.
        if let similarPage, let detail = await fetch("the artist page for \(similarPage.name)", { try await provider.detail(for: similarPage) }) {
            add("Artist pages", detail.artist.name, detail.artist.artwork)
            if detail.artist.id != similarPage.id {
                problems.append("FAIL opening \(similarPage.name) (\(similarPage.id)) showed \(detail.artist.name) (\(detail.artist.id))")
            }
        }

        // ⌘K search.
        if let term = restored?.tracks.first?.artistName ?? artists.first?.name,
           let results = await fetch("search", { try await provider.search(term) }) {
            addTracks("Search", results.songs)
            for artist in results.artists { add("Search", artist.name, artist.artwork) }
            for album in results.albums { add("Search", album.title, album.artwork) }
            for playlist in results.playlists { add("Search", playlist.name, playlist.artwork) }
        }

        // The queue brought back after a relaunch, after its artwork refresh.
        var control: ArtworkSource?
        if let restored {
            control = restored.tracks.first?.artwork
            let fresh = await provider.freshArtwork(for: restored.tracks.map(\.id))
            for track in restored.tracks {
                add("Restored queue", "\(track.title) – \(track.artistName)", fresh[track.id] ?? track.artwork)
            }
        }

        // Draw everything.
        var lines: [String] = []
        var failures: [String] = []
        var placeholders: [String] = []
        var drawn = 0
        var results = [Bool?](repeating: nil, count: items.count)
        let started = Date()
        for batch in stride(from: 0, to: items.count, by: 24) {
            let range = batch..<min(batch + 24, items.count)
            await withTaskGroup(of: (Int, Bool?).self) { group in
                for i in range {
                    let source = items[i].source
                    group.addTask { @MainActor in (i, await draws(source)) }
                }
                for await (i, ok) in group { results[i] = ok }
            }
        }
        for (item, result) in zip(items, results) {
            switch result {
            case true?: drawn += 1
            case false?:
                // A library artist with no picture shows the placeholder, as in
                // Music. That's right when the catalog has none either, and for
                // Various Artists, whose catalog picture is just some compilation.
                // A lookup that fails proves nothing, so it doesn't excuse a blank.
                let lookup: Result<String?, Error>? = item.surface == "Artists" ? await catalogArtistArtwork(item.title) : nil
                switch lookup {
                case .success(let catalog)?:
                    if let catalog, item.title != "Various Artists" {
                        failures.append("FAIL \(item.surface): \(item.title)  \(url(item.source)); the catalog has \(catalog)")
                    } else {
                        placeholders.append("note \(item.surface): \(item.title) has no picture in Apple Music; shows the placeholder")
                    }
                case .failure(let error)?:
                    failures.append("FAIL \(item.surface): \(item.title) didn't draw, and looking it up in the catalog failed: \(error.localizedDescription)")
                case nil:
                    failures.append("FAIL \(item.surface): \(item.title)  \(url(item.source))")
                }
            case nil: placeholders.append("note \(item.surface): \(item.title) has no artwork in Apple Music; shows the placeholder")
            }
        }

        // The same artwork through the app's own view, as on screen: a sample
        // from every surface, at the sizes rows, cards and headers use. A
        // dead handle stays on its placeholder here too (the first control).
        var viewChecked = 0
        for surface in Set(items.map(\.surface)).sorted() {
            for item in items.filter({ $0.surface == surface }).prefix(2) {
                guard case .musicKit = item.source else { continue }
                let circular = surface.hasPrefix("Artist") && !surface.hasPrefix("Artist albums") && !surface.hasPrefix("Artist top")
                    || surface.hasPrefix("Similar")
                for size: CGFloat in [38, 164] {
                    viewChecked += 1
                    if await !ArtworkSnapshot.viewDraws(item.source, size: size, circular: circular),
                       !placeholders.contains(where: { $0.contains(item.title) }) {
                        failures.append("FAIL \(surface): \(item.title) shows its placeholder at \(Int(size)) pt in the app's artwork view")
                    }
                }
            }
        }
        if let control, case .musicKit = control, await ArtworkSnapshot.viewDraws(control, size: 164, circular: false, timeout: .seconds(10)) {
            failures.append("FAIL control drew in the app's artwork view: it can't tell artwork from its placeholder")
        }
        lines.append("     app's artwork view: \(viewChecked) samples across every surface, at row and card sizes")

        // The controls must not draw, or a blank result means nothing: a song
        // saved to disk by an earlier session, and an album reached through
        // its song (the empty album cover of 6cedca0).
        var controls: [(String, Artwork)] = []
        if case .musicKit(let artwork, _)? = control, artwork.url(width: 10, height: 10)?.scheme?.hasPrefix("http") == false {
            controls.append(("a saved song's artwork", artwork))
        }
        if let song = restored?.tracks.first?.song, let fresh = await MusicKitProvider.librarySong(id: song.id.rawValue),
           let stub = try? await fresh.with([.albums]).albums?.first, let artwork = stub.artwork {
            controls.append(("an album reached through its song", artwork))
        }
        if controls.count < 2 {
            failures.append("FAIL controls: only \(controls.count) of 2 could be built (they come from the saved queue; play something first)")
        }
        for (name, artwork) in controls {
            if await ArtworkSnapshot.image(artwork, size: 120, timeout: .seconds(15)) != nil {
                failures.append("FAIL control drew: \(name) is known not to load, so this test can't detect broken artwork")
            } else {
                lines.append("ok   control: \(name) stays blank, so broken artwork is detected")
            }
        }

        // Control Center's artwork for the playing song, through its loader as
        // after a relaunch: first the saved (dead) artwork, which fails, then
        // the refreshed copy, which must load rather than the failure sticking.
        if let current = restored?.tracks.first(where: { $0.id == restored?.position.trackID }) {
            let loader = NowPlayingArtwork()
            _ = loader.image(for: current)
            try? await Task.sleep(for: .seconds(9))
            var refreshed = current
            refreshed.artwork = await provider.freshArtwork(for: [current.id])[current.id] ?? current.artwork
            var image = loader.image(for: refreshed)
            for _ in 0..<150 where image == nil {
                try? await Task.sleep(for: .milliseconds(100))
                image = loader.image(for: refreshed)
            }
            if image == nil, refreshed.artwork != .none {
                failures.append("FAIL Control Center: no artwork for \(current.title) after its artwork was refreshed")
            } else {
                drawn += 1
                lines.append("ok   Control Center: artwork loads once a restored song's artwork is refreshed")
            }
            // A failed load of the same artwork is tried again after a while
            // (10 s at first), not given up on.
            let retrier = NowPlayingArtwork()
            _ = retrier.image(for: current)
            try? await Task.sleep(for: .seconds(9))
            let early = retrier.retryDue(for: current)
            try? await Task.sleep(for: .seconds(11))
            if early || !retrier.retryDue(for: current) {
                failures.append("FAIL Control Center: a failed artwork load isn't retried after its wait (due early: \(early))")
            } else {
                lines.append("ok   Control Center: a failed artwork load is tried again after 10 s")
            }
        } else {
            failures.append("FAIL Control Center: no saved queue to test with; play something first")
        }

        // Every surface must have been tested, or a PASS means little.
        var required = ["Discover: Jump back in", "Discover: Trending", "Discover: New releases", "Playlists", "Playlist songs", "Album pages", "Album songs", "Artists", "Artist pages",
                        "Artist top songs", "Search", "Restored queue"]
        if restored == nil { required.removeAll { $0 == "Restored queue" } }
        for surface in required where !items.contains(where: { $0.surface.hasPrefix(surface) }) {
            failures.append("FAIL nothing tested for \(surface)")
        }
        // Recommendation shelves are named by Apple Music.
        let fixed: Set = ["Discover: Jump back in", "Discover: Trending", "Discover: New releases"]
        if !items.contains(where: { $0.surface.hasPrefix("Discover: ") && !fixed.contains($0.surface) }) {
            failures.append("FAIL nothing tested for Discover's recommendations")
        }
        failures = problems + failures

        lines.insert(failures.isEmpty ? "PASS" : "FAIL", at: 0)
        lines.insert("\(drawn) of \(drawn + failures.count) artworks drew in \(Int(Date().timeIntervalSince(started))) s, across \(Set(items.map(\.surface)).count) surfaces", at: 1)
        lines += failures
        lines += placeholders
        return lines
    }

    /// Whether the artwork draws as the app draws it; nil when there's none.
    private static func draws(_ source: ArtworkSource) async -> Bool? {
        switch source {
        case .musicKit(let artwork, _): await ArtworkSnapshot.image(artwork, size: 120, timeout: .seconds(15)) != nil
        case .generated: true
        case .none: nil
        }
    }

    /// The catalog artist's picture, for a library artist whose own didn't draw.
    /// Its URL, nil if the catalog has no picture, or the lookup's error.
    private static func catalogArtistArtwork(_ name: String) async -> Result<String?, Error> {
        var search = MusicCatalogSearchRequest(term: name, types: [Artist.self])
        search.limit = 5
        do {
            let artists = try await search.response().artists
            return .success(artists.first { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.artwork != nil }?
                .artwork?.url(width: 300, height: 300)?.absoluteString)
        } catch {
            return .failure(error)
        }
    }

    private static func url(_ source: ArtworkSource) -> String {
        guard case .musicKit(let artwork, _) = source else { return "" }
        return artwork.url(width: 100, height: 100)?.absoluteString ?? "no url"
    }
}
