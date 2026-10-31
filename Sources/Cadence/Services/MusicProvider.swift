import Foundation

/// Everything the UI needs from a music source. Implemented by the live
/// MusicKit backend and by the offline demo library.
@MainActor
protocol MusicProvider: AnyObject {
    var displayName: String { get }
    var isLive: Bool { get }

    func discover() async throws -> DiscoverFeed
    func playlists() async throws -> [PlaylistItem]
    func tracks(in playlist: PlaylistItem) async throws -> [TrackItem]
    func tracks(in album: AlbumItem) async throws -> [TrackItem]
    func artists() async throws -> [ArtistItem]
    func detail(for artist: ArtistItem) async throws -> ArtistDetail
    func search(_ term: String) async throws -> SearchResults
}
