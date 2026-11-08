import Foundation
import MusicKit

/// Live backend: the user's Apple Music library plus the catalog, via MusicKit.
enum ProviderError: LocalizedError {
    case tooLong(Int)
    case notEditable

    var errorDescription: String? {
        switch self {
        case .tooLong(let count): "Stopped at \(count) items; that's longer than Cadence shows."
        case .notEditable: "Apple Music doesn't let Cadence change that playlist."
        }
    }
}

@MainActor
final class MusicKitProvider: MusicProvider {
    let displayName = "Apple Music"
    let isLive = true

    func discover() async throws -> DiscoverFeed {
        var feed = DiscoverFeed()
        // Each section is optional (Discover shows what it can), but what
        // failed is kept, for `make artwork`.
        func attempt<T>(_ what: String, _ work: () async throws -> T) async -> T? {
            do { return try await work() } catch {
                feed.problems.append("\(what): \(error.localizedDescription)")
                return nil
            }
        }

        if let recent = await attempt("recently played", { try await MusicRecentlyPlayedContainerRequest().response() }) {
            feed.recent = recent.items.prefix(6).compactMap { item in
                switch item {
                case .album(let album): .album(AlbumItem(album))
                case .playlist(let playlist): .playlist(PlaylistItem(playlist))
                default: nil
                }
            }
        }

        if let recs = await attempt("recommendations", { try await MusicPersonalRecommendationsRequest().response() }) {
            feed.shelves = recs.recommendations.prefix(5).compactMap { rec in
                let items = rec.playlists.map { ShelfItem.playlist(PlaylistItem($0)) }
                    + rec.albums.map { ShelfItem.album(AlbumItem($0)) }
                guard !items.isEmpty else { return nil }
                return Shelf(title: rec.title ?? "For you", items: Array(items.prefix(12)))
            }
        }

        if let charts = await attempt("charts", { try await MusicCatalogChartsRequest(kinds: [.mostPlayed], types: [Song.self, Album.self]).response() }) {
            feed.trending = charts.songCharts.first?.items.prefix(10).map(TrackItem.init(song:)) ?? []
            feed.newReleases = charts.albumCharts.first?.items.prefix(12).map(AlbumItem.init) ?? []
        }

        return feed
    }

    func playlists() async throws -> [PlaylistItem] {
        let response = try await MusicLibraryRequest<Playlist>().response()
        return try await everything(response.items).map(PlaylistItem.init)
    }

    func tracks(in playlist: PlaylistItem) async throws -> [TrackItem] {
        guard let playlist = playlist.playlist else { return [] }
        let detailed = try await playlist.with([.tracks])
        return try await everything(detailed.tracks).compactMap(TrackItem.init(track:))
    }

    func tracks(in album: AlbumItem) async throws -> [TrackItem] {
        guard let album = album.album else { return [] }
        let detailed = try await album.with([.tracks])
        return try await everything(detailed.tracks).compactMap(TrackItem.init(track:))
    }

    func artists() async throws -> [ArtistItem] {
        let response = try await MusicLibraryRequest<Artist>().response()
        return try await everything(response.items).map {
            var artist = ArtistItem($0)
            artist.fromLibrary = true
            return artist
        }
    }

    func detail(for artist: ArtistItem) async throws -> ArtistDetail {
        // A catalog artist (from search, similar artists) is used as is.
        // Library artists are sparse and name-only ones have no item, so those
        // resolve to the catalog artist of the same name.
        var catalog = artist.fromLibrary ? nil : artist.artist
        if catalog == nil {
            var search = MusicCatalogSearchRequest(term: artist.name, types: [Artist.self])
            search.limit = 10
            let found = try await search.response().artists
            catalog = found.first { $0.name.compare(artist.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
                ?? found.first
        }
        guard let catalog else { return ArtistDetail(artist: artist) }
        let detailed = try await catalog.with([.topSongs, .albums, .similarArtists])
        return ArtistDetail(
            artist: ArtistItem(detailed),
            topSongs: detailed.topSongs?.prefix(10).map(TrackItem.init(song:)) ?? [],
            albums: try await everything(detailed.albums).map(AlbumItem.init),
            similar: detailed.similarArtists?.prefix(12).map(ArtistItem.init) ?? []
        )
    }

    func recentlyPlayedPlaylistNames() async -> [String] {
        // Recently played items carry catalog IDs, not library ones, so
        // they're matched to library playlists by name.
        let items = (try? await MusicRecentlyPlayedContainerRequest().response().items) ?? []
        return items.compactMap { item in
            if case .playlist(let playlist) = item { playlist.name } else { nil }
        }
    }

    // MARK: Editing playlists

    /// The Apple Music API's ID for each playlist the user can change, by
    /// MusicKit's ID. On the Mac, MusicKit gives library playlists local IDs
    /// and can't edit them, so changes go through the API instead, matched
    /// by name (playlists sharing a name are left out, as they can't be told
    /// apart).
    private var apiPlaylistIDs: [String: String] = [:]

    func editablePlaylistIDs(in playlists: [PlaylistItem]) async -> Set<String> {
        guard let remote = try? await apiPlaylists() else { return Set(apiPlaylistIDs.keys) }
        let remoteByName = Dictionary(grouping: remote, by: \.name)
        let localByName = Dictionary(grouping: playlists, by: \.name)
        var ids: [String: String] = [:]
        for playlist in playlists {
            guard localByName[playlist.name]?.count == 1, let match = remoteByName[playlist.name],
                  match.count == 1, match[0].canEdit else { continue }
            ids[playlist.id] = match[0].id
        }
        apiPlaylistIDs = ids
        return Set(ids.keys)
    }

    func add(_ track: TrackItem, to playlist: PlaylistItem) async throws {
        #if os(iOS)
        guard let song = track.song, let target = playlist.playlist else { throw ProviderError.notEditable }
        try await MusicLibrary.shared.add(song, to: target)
        #else
        guard let target = apiPlaylistIDs[playlist.id] else { throw ProviderError.notEditable }
        let song = await apiSongReference(track)
        var request = URLRequest(url: URL(string: "https://api.music.apple.com/v1/me/library/playlists/\(target)/tracks")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["data": [["id": song.id, "type": song.type]]])
        _ = try await MusicDataRequest(urlRequest: request).response()
        #endif
    }

    #if os(iOS)
    let canEditPlaylists = true
    #else
    let canEditPlaylists = false
    #endif

    func createPlaylist(named name: String, with tracks: [TrackItem]) async throws -> PlaylistItem? {
        #if os(iOS)
        let songs = tracks.compactMap(\.song)
        let playlist = songs.isEmpty
            ? try await MusicLibrary.shared.createPlaylist(name: name)
            : try await MusicLibrary.shared.createPlaylist(name: name, items: songs)
        return PlaylistItem(playlist)
        #else
        var songs: [[String: String]] = []
        for track in tracks {
            let song = await apiSongReference(track)
            songs.append(["id": song.id, "type": song.type])
        }
        var body: [String: Any] = ["attributes": ["name": name]]
        if !songs.isEmpty { body["relationships"] = ["tracks": ["data": songs]] }
        var request = URLRequest(url: URL(string: "https://api.music.apple.com/v1/me/library/playlists")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await MusicDataRequest(urlRequest: request).response()
        // The Mac's library lists it under a local ID once it syncs.
        return nil
        #endif
    }

    func rename(_ playlist: PlaylistItem, to name: String) async throws -> PlaylistItem {
        #if os(iOS)
        guard let target = playlist.playlist else { throw ProviderError.notEditable }
        var renamed = PlaylistItem(try await MusicLibrary.shared.edit(target, name: name))
        renamed.trackCount = playlist.trackCount
        return renamed
        #else
        throw ProviderError.notEditable
        #endif
    }

    func replaceTracks(of playlist: PlaylistItem, with tracks: [TrackItem]) async throws {
        #if os(iOS)
        let songs = tracks.compactMap(\.song)
        guard let target = playlist.playlist, songs.count == tracks.count else { throw ProviderError.notEditable }
        _ = try await MusicLibrary.shared.edit(target, items: songs)
        #else
        throw ProviderError.notEditable
        #endif
    }

    private struct APIPlaylistPage: Decodable {
        struct Item: Decodable {
            struct Attributes: Decodable {
                let name: String
                let canEdit: Bool?
            }
            let id: String
            let attributes: Attributes?
        }
        let data: [Item]
        let next: String?
    }

    /// Every library playlist, as the Apple Music API lists them.
    private func apiPlaylists() async throws -> [(id: String, name: String, canEdit: Bool)] {
        var found: [(id: String, name: String, canEdit: Bool)] = []
        var path: String? = "/v1/me/library/playlists?limit=100"
        while let next = path, let url = URL(string: "https://api.music.apple.com" + next) {
            guard found.count < 10_000 else { throw ProviderError.tooLong(found.count) }
            let data = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response().data
            let page = try JSONDecoder().decode(APIPlaylistPage.self, from: data)
            found += page.data.compactMap { item in
                item.attributes.map { (item.id, $0.name, $0.canEdit ?? false) }
            }
            path = page.next
        }
        return found
    }

    /// How the API names a song: a library song by its "i." ID, anything else
    /// as a catalog song.
    private func apiSongReference(_ track: TrackItem) async -> (id: String, type: String) {
        if track.id.hasPrefix("i.") { return (track.id, "library-songs") }
        // A song in a playlist has a local numeric ID; the library knows it
        // under its "i." one.
        if let song = await Self.librarySong(id: track.id), song.id.rawValue.hasPrefix("i.") {
            return (song.id.rawValue, "library-songs")
        }
        return (track.id, "songs")
    }

    // MARK: Lookups

    func album(for track: TrackItem) async -> AlbumItem? {
        // A song in a playlist often isn't on an album saved to the library;
        // its album then comes back as a stub with no tracks. Use the library
        // album only when it has songs, otherwise find it in the catalog.
        // The album reached through the song has an artwork handle that never
        // loads, so the album is fetched again from the library by ID.
        if let song = track.song, let stub = try? await song.with([.albums]).albums?.first {
            var request = MusicLibraryRequest<Album>()
            request.filter(matching: \.id, equalTo: stub.id)
            if let album = try? await request.response().items.first,
               let detailed = try? await album.with([.tracks]), !(detailed.tracks ?? []).isEmpty {
                return AlbumItem(detailed)
            }
        }
        var search = MusicCatalogSearchRequest(term: "\(track.albumTitle) \(track.artistName)", types: [Album.self])
        search.limit = 10
        let albums = (try? await search.response().albums) ?? []
        func same(_ a: String, _ b: String) -> Bool { a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        let byArtist = albums.filter { same($0.artistName, track.artistName) }
        let match = byArtist.first { same($0.title, track.albumTitle) }
            ?? byArtist.first { $0.title.localizedCaseInsensitiveContains(track.albumTitle) || track.albumTitle.localizedCaseInsensitiveContains($0.title) }
            ?? albums.first { same($0.title, track.albumTitle) }
            ?? byArtist.first
        return match.map(AlbumItem.init)
    }

    /// Every item in a relationship. MusicKit hands long ones over a batch
    /// at a time (a big playlist, a long discography). A batch that fails
    /// fails the whole load rather than passing off the first part as all.
    /// (Decodable matters: without it MusicKit traps on the next batch.)
    private func everything<Item: Decodable>(_ first: MusicItemCollection<Item>?) async throws -> [Item] {
        guard var batch = first else { return [] }
        var items = Array(batch)
        while batch.hasNextBatch {
            guard items.count < 50_000 else { throw ProviderError.tooLong(items.count) }
            guard let next = try await batch.nextBatch() else { break }
            items += next
            batch = next
        }
        return items
    }

    func tracks(withIDs ids: [String]) async throws -> [TrackItem] {
        let songs = await songs(withIDs: ids)
        return ids.compactMap { id in songs[id].map { song in withID(id, TrackItem(song: song)) } }
    }

    /// Fresh artwork for songs by ID. Library artwork is a handle that only
    /// works in the session that fetched it, so saved songs need this.
    func freshArtwork(for ids: [String]) async -> [String: ArtworkSource] {
        await songs(withIDs: ids).mapValues { ArtworkSource($0.artwork) }
    }

    /// Looks songs up one ID at a time, in the library and then the catalog.
    /// One at a time because a library song found by the numeric ID it has in
    /// a playlist comes back under a different ("i.…") ID, so results can't be
    /// matched to a batch request's IDs.
    private func songs(withIDs ids: [String]) async -> [String: Song] {
        await withTaskGroup(of: (String, Song?).self) { group in
            var found: [String: Song] = [:]
            var pending = ids[...]
            func next() {
                guard let id = pending.popFirst() else { return }
                group.addTask { (id, await Self.song(withID: id)) }
            }
            for _ in 0..<8 { next() }
            for await (id, song) in group {
                if let song { found[id] = song }
                next()
            }
            return found
        }
    }

    nonisolated static func librarySong(id: String) async -> Song? {
        var library = MusicLibraryRequest<Song>()
        library.filter(matching: \.id, equalTo: MusicItemID(id))
        return try? await library.response().items.first
    }

    private nonisolated static func song(withID id: String) async -> Song? {
        var library = MusicLibraryRequest<Song>()
        library.filter(matching: \.id, equalTo: MusicItemID(id))
        if let song = try? await library.response().items.first { return song }
        let catalog = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
        return try? await catalog.response().items.first
    }

    /// Keeps the ID the song was asked for, so it lines up with queues and
    /// saved state that use it.
    private func withID(_ id: String, _ track: TrackItem) -> TrackItem {
        TrackItem(id: id, title: track.title, artistName: track.artistName, artistID: track.artistID,
                  albumTitle: track.albumTitle, albumID: track.albumID, duration: track.duration,
                  artwork: track.artwork, isExplicit: track.isExplicit, song: track.song)
    }

    func search(_ term: String) async throws -> SearchResults {
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self, Artist.self, Album.self, Playlist.self])
        request.limit = 6
        let response = try await request.response()
        return SearchResults(
            songs: response.songs.map(TrackItem.init(song:)),
            artists: response.artists.map(ArtistItem.init),
            albums: response.albums.map(AlbumItem.init),
            playlists: response.playlists.map(PlaylistItem.init)
        )
    }

}

// MARK: - Mapping

extension TrackItem {
    init(song: Song) {
        self.init(
            id: song.id.rawValue,
            title: song.title,
            artistName: song.artistName,
            artistID: nil,
            albumTitle: song.albumTitle ?? "",
            albumID: nil,
            duration: song.duration ?? 0,
            artwork: ArtworkSource(song.artwork),
            isExplicit: song.contentRating == .explicit,
            song: song
        )
    }

    init?(track: Track) {
        guard case .song(let song) = track else { return nil }
        self.init(song: song)
    }
}

extension AlbumItem {
    init(_ album: Album) {
        self.init(
            id: album.id.rawValue,
            title: album.title,
            artistName: album.artistName,
            artistID: nil,
            year: album.releaseDate.map { String(Calendar.current.component(.year, from: $0)) },
            artwork: ArtworkSource(album.artwork),
            album: album
        )
    }
}

extension ArtistItem {
    init(_ artist: Artist) {
        self.init(id: artist.id.rawValue, name: artist.name, genre: artist.genreNames?.first, artwork: ArtworkSource(artist.artwork), artist: artist)
    }
}

extension PlaylistItem {
    init(_ playlist: Playlist) {
        self.init(
            id: playlist.id.rawValue,
            name: playlist.name,
            curator: playlist.curatorName,
            summary: playlist.shortDescription ?? playlist.standardDescription,
            artwork: ArtworkSource(playlist.artwork),
            trackCount: nil,
            playlist: playlist
        )
    }
}
