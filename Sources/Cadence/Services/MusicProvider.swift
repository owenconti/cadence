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
    /// Makes a playlist in the user's library, starting with `tracks`. Nil
    /// when the library doesn't say yet which playlist it is (the Mac, where
    /// it's made through the Apple Music API and shows up a little later).
    func createPlaylist(named name: String, with tracks: [TrackItem]) async throws -> PlaylistItem?
    /// Whether playlists Cadence made can be renamed and have their songs
    /// removed or reordered. Apple only allows it on iPhone and iPad; the
    /// Mac's MusicKit and the Apple Music API can't.
    var canEditPlaylists: Bool { get }
    func rename(_ playlist: PlaylistItem, to name: String) async throws -> PlaylistItem
    /// Replaces a playlist's songs: what's left after removing and reordering.
    func replaceTracks(of playlist: PlaylistItem, with tracks: [TrackItem]) async throws

    /// How My Playlists keep songs: by IDs that mean the same on every
    /// device. `playlist` is where they came from, when copying one.
    func songRefs(for tracks: [TrackItem], from playlist: PlaylistItem?) async -> [SongRef]
    /// My Playlists' songs, looked up, in order, under `SongRef.key`;
    /// any that can't be found are left out.
    func tracks(for refs: [SongRef]) async -> [TrackItem]
}
