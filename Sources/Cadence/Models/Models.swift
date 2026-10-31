import SwiftUI
import MusicKit

// UI-facing models. They are deliberately independent of MusicKit so the
// whole interface can run against the demo library, and they carry the
// underlying MusicKit item (when there is one) for playback and detail fetches.

struct Palette: Hashable, Sendable {
    var primary: Color
    var secondary: Color

    static let neutral = Palette(primary: Color(hex: 0x3A3A48), secondary: Color(hex: 0x15151B))
}

enum ArtworkSource: Hashable, Sendable {
    case generated(seed: UInt64, style: Int, palette: Palette)
    case musicKit(Artwork, palette: Palette)
    case none

    var palette: Palette {
        switch self {
        case .generated(_, _, let palette), .musicKit(_, let palette): palette
        case .none: .neutral
        }
    }

    init(_ artwork: Artwork?) {
        guard let artwork else { self = .none; return }
        let primary = artwork.backgroundColor.map { Color(cgColor: $0) } ?? Palette.neutral.primary
        let secondary = (artwork.secondaryTextColor ?? artwork.primaryTextColor).map { Color(cgColor: $0) } ?? Palette.neutral.secondary
        self = .musicKit(artwork, palette: Palette(primary: primary, secondary: secondary))
    }
}

struct TrackItem: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var artistName: String
    var artistID: String?
    var albumTitle: String
    var albumID: String?
    var duration: TimeInterval
    var artwork: ArtworkSource
    var isExplicit = false
    var song: Song?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct AlbumItem: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var artistName: String
    var artistID: String?
    var year: String?
    var artwork: ArtworkSource
    var album: Album?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ArtistItem: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var genre: String?
    var artwork: ArtworkSource
    var artist: Artist?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct PlaylistItem: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var curator: String?
    var summary: String?
    var artwork: ArtworkSource
    var trackCount: Int?
    var playlist: Playlist?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum PlaylistSort: String, CaseIterable {
    case recent = "Recent"
    case name = "A–Z"
    case size = "Largest"
}

enum ShelfItem: Identifiable, Hashable {
    case album(AlbumItem)
    case playlist(PlaylistItem)

    var id: String {
        switch self {
        case .album(let a): "album:\(a.id)"
        case .playlist(let p): "playlist:\(p.id)"
        }
    }

    var title: String {
        switch self {
        case .album(let a): a.title
        case .playlist(let p): p.name
        }
    }

    var subtitle: String {
        switch self {
        case .album(let a): a.artistName
        case .playlist(let p): p.curator ?? "Playlist"
        }
    }

    var artwork: ArtworkSource {
        switch self {
        case .album(let a): a.artwork
        case .playlist(let p): p.artwork
        }
    }
}

struct Shelf: Identifiable {
    var id: String { title }
    var title: String
    var subtitle: String?
    var items: [ShelfItem]
}

struct DiscoverFeed {
    var recent: [ShelfItem] = []
    var shelves: [Shelf] = []
    var trending: [TrackItem] = []
    var newReleases: [AlbumItem] = []
}

struct ArtistDetail {
    var artist: ArtistItem
    var topSongs: [TrackItem] = []
    var albums: [AlbumItem] = []
    var similar: [ArtistItem] = []
    var bio: String?
}

struct SearchResults {
    var songs: [TrackItem] = []
    var artists: [ArtistItem] = []
    var albums: [AlbumItem] = []
    var playlists: [PlaylistItem] = []
}

enum Loadable<Value> {
    case loading
    case loaded(Value)
    case failed(String)
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case discover, playlists, artists

    var id: String { rawValue }

    var title: String {
        switch self {
        case .discover: "Discover"
        case .playlists: "Playlists"
        case .artists: "Artists"
        }
    }

    var symbol: String {
        switch self {
        case .discover: "sparkles"
        case .playlists: "music.note.list"
        case .artists: "person.2.fill"
        }
    }

    var route: Route {
        switch self {
        case .discover: .discover
        case .playlists: .playlists
        case .artists: .artists
        }
    }
}

enum Route: Hashable {
    case discover
    case playlists
    case artists
    case playlist(PlaylistItem)
    case album(AlbumItem)
    case artist(ArtistItem)
}

extension TimeInterval {
    var clock: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(self.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var longForm: String {
        let minutes = Int((self / 60).rounded())
        let hours = minutes / 60
        return hours > 0 ? "\(hours) hr \(minutes % 60) min" : "\(minutes) min"
    }
}

/// Where the queue came from, shown above Now Playing ("Playing from
/// playlist · 2026") and saved with the queue.
struct QueueSource: Codable, Hashable {
    enum Kind: String, Codable {
        case playlist, album, artist, trending, search
    }

    var kind: Kind
    var title: String
    var id: String?
    /// The page to open for it; not saved, so a restored album has none.
    var route: Route?

    private enum CodingKeys: String, CodingKey { case kind, title, id }

    var label: String {
        switch kind {
        case .playlist: "Playlist"
        case .album: "Album"
        case .artist: "Artist"
        case .trending: "Discover"
        case .search: "Search"
        }
    }

    static func playlist(_ playlist: PlaylistItem) -> QueueSource {
        QueueSource(kind: .playlist, title: playlist.name, id: playlist.id, route: .playlist(playlist))
    }

    static func album(_ album: AlbumItem) -> QueueSource {
        QueueSource(kind: .album, title: album.title, id: album.id, route: .album(album))
    }

    static func artist(_ artist: ArtistItem) -> QueueSource {
        QueueSource(kind: .artist, title: artist.name, id: artist.id, route: .artist(artist))
    }

    static let trending = QueueSource(kind: .trending, title: "Trending now", route: .discover)

    static func search(_ query: String) -> QueueSource {
        QueueSource(kind: .search, title: "“\(query)”")
    }
}

extension EnvironmentValues {
    /// The list a song row belongs to, so playing it records where from.
    @Entry var queueSource: QueueSource?
}
