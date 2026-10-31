import Foundation
import MusicKit

/// Live backend: the user's Apple Music library plus the catalog, via MusicKit.
@MainActor
final class MusicKitProvider: MusicProvider {
    let displayName = "Apple Music"
    let isLive = true

    func discover() async throws -> DiscoverFeed {
        var feed = DiscoverFeed()

        if let recent = try? await MusicRecentlyPlayedContainerRequest().response() {
            feed.recent = recent.items.prefix(6).compactMap { item in
                switch item {
                case .album(let album): .album(AlbumItem(album))
                case .playlist(let playlist): .playlist(PlaylistItem(playlist))
                default: nil
                }
            }
        }

        if let recs = try? await MusicPersonalRecommendationsRequest().response() {
            feed.shelves = recs.recommendations.prefix(5).compactMap { rec in
                let items = rec.playlists.map { ShelfItem.playlist(PlaylistItem($0)) }
                    + rec.albums.map { ShelfItem.album(AlbumItem($0)) }
                guard !items.isEmpty else { return nil }
                return Shelf(title: rec.title ?? "For you", items: Array(items.prefix(12)))
            }
        }

        if let charts = try? await MusicCatalogChartsRequest(kinds: [.mostPlayed], types: [Song.self, Album.self]).response() {
            feed.trending = charts.songCharts.first?.items.prefix(10).map(TrackItem.init(song:)) ?? []
            feed.newReleases = charts.albumCharts.first?.items.prefix(12).map(AlbumItem.init) ?? []
        }

        return feed
    }

    func playlists() async throws -> [PlaylistItem] {
        let response = try await MusicLibraryRequest<Playlist>().response()
        return response.items.map(PlaylistItem.init)
    }

    func tracks(in playlist: PlaylistItem) async throws -> [TrackItem] {
        guard let playlist = playlist.playlist else { return [] }
        let detailed = try await playlist.with([.tracks])
        return detailed.tracks?.compactMap(TrackItem.init(track:)) ?? []
    }

    func tracks(in album: AlbumItem) async throws -> [TrackItem] {
        guard let album = album.album else { return [] }
        let detailed = try await album.with([.tracks])
        return detailed.tracks?.compactMap(TrackItem.init(track:)) ?? []
    }

    func artists() async throws -> [ArtistItem] {
        let response = try await MusicLibraryRequest<Artist>().response()
        return response.items.map(ArtistItem.init)
    }

    func detail(for artist: ArtistItem) async throws -> ArtistDetail {
        // Library artists are sparse; resolve to the catalog artist for
        // top songs, discography and similar artists.
        var search = MusicCatalogSearchRequest(term: artist.name, types: [Artist.self])
        search.limit = 1
        guard let catalog = try await search.response().artists.first else {
            return ArtistDetail(artist: artist)
        }
        let detailed = try await catalog.with([.topSongs, .albums, .similarArtists])
        return ArtistDetail(
            artist: ArtistItem(detailed),
            topSongs: detailed.topSongs?.prefix(10).map(TrackItem.init(song:)) ?? [],
            albums: detailed.albums?.map(AlbumItem.init) ?? [],
            similar: detailed.similarArtists?.prefix(12).map(ArtistItem.init) ?? []
        )
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
