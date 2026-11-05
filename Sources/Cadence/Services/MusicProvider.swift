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
    /// Songs by ID, in the order given, skipping any that no longer exist.
    func tracks(withIDs ids: [String]) async throws -> [TrackItem]
    /// The album a song is on, to open its page.
    func album(for track: TrackItem) async -> AlbumItem?
    /// Names of playlists recently played anywhere, newest first.
    func recentlyPlayedPlaylistNames() async -> [String]
    /// Which of `playlists` songs can be added to: the user's own, not
    /// smart playlists or ones followed from someone else.
    func editablePlaylistIDs(in playlists: [PlaylistItem]) async -> Set<String>
    /// Adds a song to the end of one of the user's playlists.
    func add(_ track: TrackItem, to playlist: PlaylistItem) async throws
}
