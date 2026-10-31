import SwiftUI

/// Offline backend with a fictional catalog and generated artwork. Lets the
/// whole UI run without MusicKit credentials.
@MainActor
final class DemoProvider: MusicProvider {
    let displayName = "Demo library"
    let isLive = false

    private let library = DemoLibrary()

    func discover() async throws -> DiscoverFeed {
        try await Task.sleep(for: .milliseconds(250))
        let lib = library
        let byYear = lib.albums.sorted { ($0.year ?? "") > ($1.year ?? "") }
        return DiscoverFeed(
            recent: [
                .playlist(lib.playlists[0]), .album(lib.albums[4]), .playlist(lib.playlists[3]),
                .album(lib.albums[10]), .playlist(lib.playlists[1]), .album(lib.albums[2]),
            ],
            shelves: [
                Shelf(title: "Made for you", subtitle: "Mixes that learn from every skip and replay", items: lib.playlists.map { .playlist($0) }),
                Shelf(title: "Because you played Nova Halcyon", subtitle: "Hazy, melodic, a little nostalgic", items: [1, 7, 15, 9, 14, 6].map { .album(lib.albums[$0]) }),
                Shelf(title: "Deeper cuts", subtitle: "Albums from artists you already love", items: lib.albums.shuffled(seed: 9).prefix(8).map { .album($0) }),
            ],
            trending: Array(lib.tracks.shuffled(seed: 3).prefix(10)),
            newReleases: Array(byYear.prefix(8))
        )
    }

    func playlists() async throws -> [PlaylistItem] { library.playlists }

    func tracks(in playlist: PlaylistItem) async throws -> [TrackItem] {
        try await Task.sleep(for: .milliseconds(120))
        return library.playlistTracks[playlist.id] ?? []
    }

    func tracks(in album: AlbumItem) async throws -> [TrackItem] {
        try await Task.sleep(for: .milliseconds(120))
        return library.tracks.filter { $0.albumID == album.id }
    }

    func artists() async throws -> [ArtistItem] { library.artists }

    func detail(for artist: ArtistItem) async throws -> ArtistDetail {
        try await Task.sleep(for: .milliseconds(150))
        guard let artist = library.artists.first(where: { $0.id == artist.id || $0.name == artist.name }) else {
            return ArtistDetail(artist: artist)
        }
        return ArtistDetail(
            artist: artist,
            topSongs: Array(library.tracks.filter { $0.artistID == artist.id }.shuffled(seed: 5)),
            albums: library.albums.filter { $0.artistID == artist.id },
            similar: library.artists.filter { $0.id != artist.id }.shuffled(seed: UInt64(artist.name.count)).prefix(5).map { $0 },
            bio: library.bios[artist.id]
        )
    }

    func recentlyPlayedPlaylistNames() async -> [String] { [] }

    func album(for track: TrackItem) async -> AlbumItem? {
        library.albums.first { $0.id == track.albumID }
    }

    func tracks(withIDs ids: [String]) async throws -> [TrackItem] {
        let byID = Dictionary(library.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    func search(_ term: String) async throws -> SearchResults {
        let q = term.lowercased()
        func hit(_ s: String) -> Bool { s.lowercased().contains(q) }
        return SearchResults(
            songs: Array(library.tracks.filter { hit($0.title) || hit($0.artistName) }.prefix(6)),
            artists: library.artists.filter { hit($0.name) || hit($0.genre ?? "") },
            albums: library.albums.filter { hit($0.title) || hit($0.artistName) },
            playlists: library.playlists.filter { hit($0.name) }
        )
    }

}

// MARK: - Catalog

private struct DemoLibrary {
    var artists: [ArtistItem] = []
    var albums: [AlbumItem] = []
    var tracks: [TrackItem] = []
    var playlists: [PlaylistItem] = []
    var playlistTracks: [String: [TrackItem]] = [:]
    var bios: [String: String] = [:]
    private var genres: [String: String] = [:]

    func genre(of track: TrackItem) -> String { genres[track.artistID ?? ""] ?? "" }

    private static let palettes: [Palette] = [
        (0xFF6B5E, 0x5B2A86), (0x2EC4B6, 0x16325C), (0xF9C74F, 0xE4572E), (0x9D4EDD, 0x24104F),
        (0x48CAE4, 0x03256C), (0xFF8FAB, 0x5E0B4E), (0x80ED99, 0x1F4E5F), (0xE9C46A, 0x264653),
        (0xF72585, 0x3A0CA3), (0xFFB4A2, 0x4A4E69), (0xA8DADC, 0x1D3557), (0xFFD6A5, 0xB5179E),
    ].map { Palette(primary: Color(hex: $0.0), secondary: Color(hex: $0.1)) }

    private static let catalog: [(name: String, genre: String, bio: String, albums: [(String, String, [String])])] = [
        ("Nova Halcyon", "Dream Pop", "Nova Halcyon records in a converted lighthouse, layering tape-warped synths under whispered hooks. Their songs feel like the last ten minutes of a road trip.", [
            ("Glass Weather", "2024", ["Satellite Hearts", "Paper Moon Motel", "Low Tide Radio", "Honey in the Static", "Glass Weather"]),
            ("Soft Machines", "2021", ["Velvet Circuit", "Afterglow Avenue", "Slow Bloom", "Holograms", "Still Life With You"]),
        ]),
        ("The Paper Tigers", "Indie Rock", "Four friends from a town with one stoplight, playing every song like it might be their last show.", [
            ("Loud Little Town", "2023", ["Main Street Fireworks", "Borrowed Jacket", "Teenage Static", "Drive Like You Mean It", "Closing Time Again"]),
            ("Neon Parish", "2020", ["Cathedral Lights", "Running Red", "Kerosene Summer", "Best Worst Idea", "Parish Road"]),
        ]),
        ("Mira Okafor", "Neo-Soul", "Mira Okafor blends gospel harmonies with late-night bass grooves. Her voice is warm enough to heat a room.", [
            ("Sundays in Lagos", "2025", ["Golden Hour Gospel", "Slow Burn", "Mango Skies", "Call Me Home", "Linen"]),
            ("Velvet Psalms", "2022", ["Psalm for the Tired", "Indigo", "Hold Still", "Overflow", "Brown Sugar Dawn"]),
        ]),
        ("Glasshouse", "Electronic", "A duo making precise, glowing club music for people who like to dance with their eyes closed.", [
            ("Prism Theory", "2024", ["Refraction", "Night Bus", "Phase Garden", "Chromatic", "Exit Light"]),
            ("Signals", "2021", ["Pulse Code", "Ferrous", "Daylight Savings", "Marble Run", "Afterhours"]),
        ]),
        ("Juniper & Vale", "Folk", "Close harmonies, a borrowed banjo, and songs written on porches across three states.", [
            ("Lanterns", "2023", ["Pine Smoke", "River Letters", "The Long Way Home", "Lantern Song", "Morning Fields"]),
            ("Woodgrain", "2019", ["Oak & Ash", "Little Fires", "Cold Creek", "Grandmother's Hands", "Northbound"]),
        ]),
        ("Kenji Arclight", "Synthwave", "Kenji Arclight scores movies that were never made: chrome, rain, and endless highways at 2am.", [
            ("Tokyo Overdrive", "2024", ["Shibuya 1987", "Chrome Heart", "Midnight Expressway", "Laser Rain", "Arcade Ghosts"]),
            ("Sunset Grid", "2022", ["Palm Circuit", "Turbo Romance", "VHS Dreams", "Grid Runner", "Boulevard Zero"]),
        ]),
        ("Low Orbit Choir", "Ambient", "Field recordings, slow choirs and patient synths. Built for deep work and long flights.", [
            ("Weightless", "2025", ["Ascent", "Perigee", "Quiet Atmosphere", "Solar Wind", "Reentry"]),
            ("Tidal", "2020", ["Undertow", "Salt Hymn", "Breathing Room", "Kelp Forest", "Moonpull"]),
        ]),
        ("Saffron Days", "Alt R&B", "Saffron Days writes hotel-room confessionals over hazy, half-time beats.", [
            ("Late Checkout", "2024", ["Room 404", "Do Not Disturb", "Ice Machine", "Elevator Talk", "Lobby Lights"]),
            ("Marigold", "2022", ["Marigold", "Gloss", "Slow Motion", "Text Me Back", "Saffron"]),
        ]),
    ]

    init() {
        var rng = SeededRandom(seed: 42)
        var paletteIndex = 0
        func nextPalette() -> Palette {
            defer { paletteIndex += 1 }
            return Self.palettes[paletteIndex % Self.palettes.count]
        }

        for (a, entry) in Self.catalog.enumerated() {
            let artistID = "artist-\(a)"
            artists.append(ArtistItem(
                id: artistID, name: entry.name, genre: entry.genre,
                artwork: .generated(seed: UInt64(a * 977 + 13), style: 4, palette: Self.palettes[(a * 5) % Self.palettes.count])
            ))
            bios[artistID] = entry.bio
            genres[artistID] = entry.genre

            for (b, album) in entry.albums.enumerated() {
                let albumID = "album-\(a)-\(b)"
                let art = ArtworkSource.generated(seed: UInt64(a * 31 + b * 7 + 1), style: a + b, palette: nextPalette())
                albums.append(AlbumItem(id: albumID, title: album.0, artistName: entry.name, artistID: artistID, year: album.1, artwork: art))
                for (t, title) in album.2.enumerated() {
                    tracks.append(TrackItem(
                        id: "track-\(a)-\(b)-\(t)", title: title, artistName: entry.name, artistID: artistID,
                        albumTitle: album.0, albumID: albumID, duration: Double(rng.int(in: 158...286)),
                        artwork: art, isExplicit: entry.genre == "Alt R&B" && t % 2 == 0
                    ))
                }
            }
        }

        let mixes: [(String, String, Set<String>)] = [
            ("Late Night Drive", "Neon, chrome and empty highways.", ["Synthwave", "Electronic", "Alt R&B"]),
            ("Deep Focus", "Low-key textures that stay out of your way.", ["Ambient", "Electronic"]),
            ("Sunday Slow", "Coffee, sunlight, nowhere to be.", ["Folk", "Neo-Soul", "Dream Pop"]),
            ("Loud & Bright", "Windows down, volume up.", ["Indie Rock", "Synthwave"]),
            ("Rainy Window", "Soft songs for grey afternoons.", ["Dream Pop", "Ambient", "Folk"]),
            ("Golden Hour", "Warm grooves for the last light of the day.", ["Neo-Soul", "Alt R&B", "Dream Pop"]),
            ("Fresh Finds", "New this year from the artists you follow.", []),
            ("All Songs", "Every song in the library.", ["*"]),
        ]
        for (i, mix) in mixes.enumerated() {
            let id = "playlist-\(i)"
            let pool = mix.2 == ["*"] ? tracks : mix.2.isEmpty
                ? tracks.filter { t in albums.first { $0.id == t.albumID }?.year.map { $0 >= "2024" } ?? false }
                : tracks.filter { mix.2.contains(genres[$0.artistID ?? ""] ?? "") }
            let picked = mix.2 == ["*"] ? pool : Array(pool.shuffled(seed: UInt64(i + 100)).prefix(18))
            playlistTracks[id] = picked
            playlists.append(PlaylistItem(
                id: id, name: mix.0, curator: "Cadence", summary: mix.1,
                artwork: .generated(seed: UInt64(i * 53 + 7), style: i + 1, palette: Self.palettes[(i * 3 + 2) % Self.palettes.count]),
                trackCount: picked.count
            ))
        }
    }
}

// MARK: - Deterministic randomness

struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func double(in range: ClosedRange<Double>) -> Double { range.lowerBound + unit() * (range.upperBound - range.lowerBound) }
    mutating func int(in range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &self) }
}

extension Array {
    func shuffled(seed: UInt64) -> [Element] {
        var rng = SeededRandom(seed: seed)
        return shuffled(using: &rng)
    }
}
