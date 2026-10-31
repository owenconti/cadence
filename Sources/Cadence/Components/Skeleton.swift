import SwiftUI

// Loading placeholders. A skeleton is the real component filled with
// placeholder data and drawn redacted, so it takes exactly the space of what
// replaces it and nothing moves when the data arrives.

extension View {
    /// Draws this as a gently pulsing, non-interactive loading placeholder.
    func skeleton() -> some View { modifier(SkeletonEffect()) }
}

private struct SkeletonEffect: ViewModifier {
    func body(content: Content) -> some View {
        content
            .redacted(reason: .placeholder)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .modifier(Pulse())
    }
}

/// The gentle fade loading placeholders share.
struct Pulse: ViewModifier {
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.45 : 0.9)
            .animation(.easeInOut(duration: 0.9).repeatForever(), value: dim)
            .onAppear { dim = true }
    }
}

enum Placeholder {
    static func track(_ i: Int) -> TrackItem {
        TrackItem(id: "placeholder-track-\(i)", title: ["Placeholder song", "A longer placeholder title", "Song title"][i % 3],
                  artistName: "Artist name", albumTitle: "Album title", duration: 200, artwork: .none)
    }

    static func tracks(_ count: Int) -> [TrackItem] { (0..<count).map(track) }

    static func playlist(_ i: Int) -> PlaylistItem {
        PlaylistItem(id: "placeholder-playlist-\(i)", name: ["Playlist name", "Longer playlist name", "Mix"][i % 3],
                     curator: "Curator", summary: nil, artwork: .none, trackCount: 100)
    }

    static func playlists(_ count: Int) -> [PlaylistItem] { (0..<count).map(playlist) }

    static func album(_ i: Int) -> AlbumItem {
        AlbumItem(id: "placeholder-album-\(i)", title: ["Album title", "A longer album title", "Album"][i % 3],
                  artistName: "Artist name", year: "2026", artwork: .none)
    }

    static func artist(_ i: Int) -> ArtistItem {
        ArtistItem(id: "placeholder-artist-\(i)", name: ["Artist name", "Band", "Longer artist name"][i % 3], genre: "Genre", artwork: .none)
    }

    /// Apple Music's shelves have no subtitle line; the demo's do.
    static func discover(subtitles: Bool) -> DiscoverFeed { DiscoverFeed(
        recent: (0..<6).map { .playlist(playlist($0)) },
        shelves: ["Made for you", "Because you played"].enumerated().map { n, title in
            Shelf(title: title, subtitle: subtitles ? "A line about this shelf" : nil, items: (0..<8).map { .playlist(playlist(n * 8 + $0)) })
        },
        trending: tracks(10),
        newReleases: (0..<8).map(album)
    ) }

    static func artistDetail(_ artist: ArtistItem) -> ArtistDetail {
        ArtistDetail(artist: artist, topSongs: tracks(5), albums: (0..<8).map(album), similar: (0..<8).map(Placeholder.artist))
    }
}
