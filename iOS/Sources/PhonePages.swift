import SwiftUI

// The phone's pages. Same data and actions as the Mac's (DiscoverView,
// PlaylistsView, ArtistsView), laid out in one narrow column.

struct PhoneDiscover: View {
    @Environment(AppModel.self) private var model
    @State private var loadError: String?

    var body: some View {
        PhonePage {
            HStack(alignment: .top) {
                PhoneTitle(title: greeting, subtitle: "Fresh picks tuned to what you've been playing.")
                Spacer(minLength: 8)
                Menu {
                    Button("Reload Library", systemImage: "arrow.clockwise") { model.reloadLibrary() }
                    if model.provider.isLive {
                        Button("Explore the Demo Library", systemImage: "sparkles") { model.startDemo() }
                    } else {
                        Button("Connect Apple Music", systemImage: "applelogo") { model.continueWithAppleMusic() }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Theme.card))
                }
            }

            if let feed = model.discoverFeed {
                sections(feed)
            } else if let loadError {
                EmptyNote(symbol: "wifi.exclamationmark", title: "Couldn't load Discover", message: loadError)
            } else {
                Group { sections(Placeholder.discover(subtitles: !model.provider.isLive)) }.skeleton()
            }
        }
        .task {
            guard model.discoverFeed == nil else { return }
            do { try await model.loadDiscover() } catch { loadError = error.localizedDescription }
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Up late?"
        }
    }

    @ViewBuilder
    private func sections(_ feed: DiscoverFeed) -> some View {
        if !feed.recent.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Jump back in")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                    ForEach(feed.recent.prefix(6)) { PhoneQuickTile(item: $0) }
                }
            }
        }

        ForEach(feed.shelves) { shelf in
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: shelf.title, subtitle: shelf.subtitle)
                PhoneCardRow(items: shelf.items) { item in
                    MediaCard(title: item.title, subtitle: item.subtitle, artwork: item.artwork, width: 156) {
                        model.open(item)
                    }
                }
            }
        }

        if !feed.trending.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Trending now", subtitle: "What everyone's playing this week") {
                    Button("Play all") { model.play(feed.trending, shuffled: false, from: .trending) }
                        .buttonStyle(PillButtonStyle(prominent: false))
                }
                PhoneTrackList(tracks: Array(feed.trending.prefix(10)), context: feed.trending, source: .trending)
            }
        }

        if !feed.newReleases.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "New releases")
                PhoneCardRow(items: feed.newReleases) { album in
                    MediaCard(title: album.title, subtitle: [album.artistName, album.year].compactMap { $0 }.joined(separator: " · "),
                              artwork: album.artwork, width: 156) {
                        model.navigate(.album(album))
                    }
                }
            }
        }
    }
}

private struct PhoneQuickTile: View {
    @Environment(AppModel.self) private var model
    let item: ShelfItem

    var body: some View {
        Button { model.open(item) } label: {
            HStack(spacing: 10) {
                ArtworkView(source: item.artwork, cornerRadius: 0, resolution: 120)
                    .frame(width: 52, height: 52)
                Text(item.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            Button("Play", systemImage: "play.fill") { Task { await model.play(item) } }
            Button("Shuffle", systemImage: "shuffle") { Task { await model.play(item, shuffled: true) } }
        }
    }
}

/// Songs in a column, numbered; tapping one plays `context` from it.
struct PhoneTrackList: View {
    let tracks: [TrackItem]
    var context: [TrackItem]?
    let source: QueueSource
    var showArtwork = true

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { i, track in
                TrackRow(track: track, number: i + 1, context: context ?? tracks, showArtwork: showArtwork, showAlbum: false)
                    .environment(\.queueSource, source)
                    .padding(.horizontal, -12)
            }
        }
    }
}

// MARK: Playlists

struct PhonePlaylists: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""

    var body: some View {
        @Bindable var model = model
        let sort = model.playlistSort
        let playlists = model.sortedPlaylists(by: sort, filter: filter)
        let waiting = !model.playlistsLoaded
            || (sort == .size && playlists.contains { model.size(of: $0) == nil && !model.uncountedPlaylists.contains($0.id) })
        PhonePage {
            VStack(alignment: .leading, spacing: 14) {
                PhoneTitle(title: "Playlists", subtitle: "\(model.playlists.count) playlists", subtitlePending: !model.playlistsLoaded)
                Picker("Sort", selection: $model.playlistSort) {
                    ForEach(PlaylistSort.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                FilterField(prompt: "Filter playlists", text: $filter, width: nil)
            }

            if waiting {
                grid(model.playlistsLoaded ? Placeholder.playlists(playlists.count) : Placeholder.playlists(8)).skeleton()
            } else if playlists.isEmpty {
                EmptyNote(symbol: "music.note.list", title: filter.isEmpty ? "No playlists yet" : "Nothing matches “\(filter)”")
            } else {
                grid(playlists)
            }
        }
        .task { await model.refreshPlaylists() }
    }

    private func grid(_ playlists: [PlaylistItem]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 2), alignment: .leading, spacing: 4) {
            ForEach(playlists) { playlist in
                let size = model.size(of: playlist)
                let counting = size == nil && model.provider.isLive && !model.uncountedPlaylists.contains(playlist.id)
                MediaCard(
                    title: playlist.name,
                    subtitle: size.map { "\($0) songs" } ?? (counting ? "000 songs" : playlist.curator ?? "Playlist"),
                    subtitlePending: counting,
                    artwork: model.artwork(for: playlist),
                    width: nil
                ) {
                    model.navigate(.playlist(playlist))
                }
            }
        }
        .padding(.horizontal, -10)
    }
}

struct PhonePlaylistPage: View {
    @Environment(AppModel.self) private var model
    let playlist: PlaylistItem

    var body: some View {
        PhoneCollection(kind: "Playlist", title: playlist.name, byline: playlist.curator, summary: playlist.summary,
                        artwork: model.artwork(for: playlist), source: .playlist(playlist), showArtwork: true) {
            try await model.provider.tracks(in: playlist)
        }
    }
}

struct PhoneAlbumPage: View {
    @Environment(AppModel.self) private var model
    let album: AlbumItem

    var body: some View {
        PhoneCollection(kind: ["Album", album.year].compactMap { $0 }.joined(separator: " · "), title: album.title,
                        byline: album.artistName, onByline: { model.openArtist(id: album.artistID, name: album.artistName) },
                        summary: nil, artwork: album.artwork, source: .album(album), showArtwork: false) {
            try await model.provider.tracks(in: album)
        }
    }
}

/// A playlist or album: its cover and title, Play and Shuffle, and its songs.
struct PhoneCollection: View {
    @Environment(AppModel.self) private var model
    let kind: String
    let title: String
    let byline: String?
    var onByline: (() -> Void)?
    let summary: String?
    let artwork: ArtworkSource
    let source: QueueSource
    let showArtwork: Bool
    let load: () async throws -> [TrackItem]

    @State private var tracks: Loadable<[TrackItem]> = .loading
    @State private var filter = ""

    var body: some View {
        let all: [TrackItem] = if case .loaded(let t) = tracks { t } else { [] }
        let shown = filter.isEmpty ? all : all.filter {
            $0.title.localizedCaseInsensitiveContains(filter)
                || $0.artistName.localizedCaseInsensitiveContains(filter)
                || $0.albumTitle.localizedCaseInsensitiveContains(filter)
        }

        PhonePage {
            VStack(spacing: 12) {
                ArtworkView(source: artwork, cornerRadius: 14, resolution: 700)
                    .frame(width: 250, height: 250)
                    .shadow(color: artwork.palette.primary.opacity(0.35), radius: 34, y: 14)
                    .padding(.bottom, 6)
                Text(kind.uppercased()).eyebrow()
                Text(title)
                    .font(.display(26, .heavy))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                if let byline {
                    if let onByline {
                        Button(byline, action: onByline).buttonStyle(.plain)
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                    } else {
                        Text(byline).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.secondary)
                    }
                }
                if let summary {
                    Text(summary).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center).lineLimit(3)
                }
                meta(all)
                HStack(spacing: 10) {
                    Button { model.play(shown, shuffled: false, from: source) } label: {
                        Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle())
                    Button { model.play(shown, shuffled: true, from: source) } label: {
                        Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle(prominent: false))
                }
                .disabled(all.isEmpty)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 10) {
                if all.count > 12 {
                    FilterField(prompt: "Find in \(kind.lowercased().split(separator: " ").first ?? "list")", text: $filter, width: nil)
                }
                switch tracks {
                case .loading:
                    LoadingRows(count: 10, showArtwork: showArtwork, showAlbum: false)
                        .padding(.horizontal, -12)
                case .failed(let message):
                    EmptyNote(symbol: "exclamationmark.triangle", title: "Couldn't load tracks", message: message)
                case .loaded:
                    if shown.isEmpty {
                        EmptyNote(symbol: "magnifyingglass", title: all.isEmpty ? "No tracks" : "No matches for “\(filter)”")
                    }
                    PhoneTrackList(tracks: shown, source: source, showArtwork: showArtwork)
                }
            }
        }
        // Again when songs are added to it, keeping the list until they're in.
        .task(id: source.kind == .playlist ? model.playlistEdits[source.id ?? ""] ?? 0 : 0) {
            do { tracks = .loaded(try await load()) } catch { tracks = .failed(error.localizedDescription) }
        }
    }

    @ViewBuilder
    private func meta(_ tracks: [TrackItem]) -> some View {
        Group {
            if !tracks.isEmpty {
                Text("\(tracks.count) songs · \(tracks.reduce(0) { $0 + $1.duration }.longForm)")
            } else if case .loading = self.tracks {
                Text("00 songs · 0 hr 00 min").skeleton()
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.tertiary)
    }
}

// MARK: Artists

struct PhoneArtists: View {
    @Environment(AppModel.self) private var model
    @State private var artists: Loadable<[ArtistItem]> = .loading
    @State private var filter = ""

    var body: some View {
        let all: [ArtistItem] = if case .loaded(let a) = artists { a } else { [] }
        let shown = filter.isEmpty ? all : all.filter {
            $0.name.localizedCaseInsensitiveContains(filter) || ($0.genre ?? "").localizedCaseInsensitiveContains(filter)
        }
        let loading: Bool = if case .loading = artists { true } else { false }

        PhonePage {
            VStack(alignment: .leading, spacing: 14) {
                PhoneTitle(title: "Artists", subtitle: "\(all.count) in your library", subtitlePending: loading)
                FilterField(prompt: "Filter by name or genre", text: $filter, width: nil)
            }

            switch artists {
            case .loading:
                grid((0..<12).map(Placeholder.artist)).skeleton()
            case .failed(let message):
                EmptyNote(symbol: "person.crop.circle.badge.exclamationmark", title: "Couldn't load artists", message: message)
            case .loaded:
                grid(shown)
            }
        }
        .task {
            do { artists = .loaded(try await model.provider.artists()) } catch { artists = .failed(error.localizedDescription) }
        }
    }

    private func grid(_ artists: [ArtistItem]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 3), alignment: .leading, spacing: 6) {
            ForEach(artists) { artist in
                MediaCard(title: artist.name, subtitle: artist.genre ?? "Artist", artwork: artist.artwork, circular: true, width: nil) {
                    model.navigate(.artist(artist))
                }
            }
        }
        .padding(.horizontal, -10)
    }
}

struct PhoneArtistPage: View {
    @Environment(AppModel.self) private var model
    let artist: ArtistItem
    @State private var detail: Loadable<ArtistDetail> = .loading

    var body: some View {
        let loaded: ArtistDetail? = if case .loaded(let d) = detail { d } else { nil }
        let shown = loaded?.artist ?? artist
        let songs = loaded?.topSongs ?? []

        PhonePage {
            VStack(spacing: 12) {
                ArtworkView(source: shown.artwork, circular: true, resolution: 500)
                    .frame(width: 180, height: 180)
                    .shadow(color: shown.artwork.palette.primary.opacity(0.4), radius: 30, y: 12)
                Text("ARTIST").eyebrow()
                Text(shown.name)
                    .font(.display(30, .heavy))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                if let genre = shown.genre {
                    Text(genre).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.secondary)
                }
                HStack(spacing: 10) {
                    Button { model.play(songs, shuffled: false, from: .artist(shown)) } label: {
                        Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle())
                    Button { model.play(songs, shuffled: true, from: .artist(shown)) } label: {
                        Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle(prominent: false))
                }
                .disabled(songs.isEmpty)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)

            switch detail {
            case .loading:
                Group { content(Placeholder.artistDetail(shown)) }.skeleton()
            case .failed(let message):
                EmptyNote(symbol: "exclamationmark.triangle", title: "Couldn't load this artist", message: message)
            case .loaded(let detail):
                content(detail)
            }
        }
        .task {
            do {
                let loaded = try await model.provider.detail(for: artist)
                detail = .loaded(loaded)
                model.popularSongCount = loaded.topSongs.count
            } catch {
                detail = .failed(error.localizedDescription)
            }
        }
    }

    @ViewBuilder
    private func content(_ detail: ArtistDetail) -> some View {
        if !detail.topSongs.isEmpty {
            let songs = model.showAllPopular ? detail.topSongs : Array(detail.topSongs.prefix(5))
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Popular") {
                    if detail.topSongs.count > 5 {
                        Button(model.showAllPopular ? "Show less" : "Show all \(detail.topSongs.count)") {
                            withAnimation(.snappy) { model.showAllPopular.toggle() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                    }
                }
                PhoneTrackList(tracks: songs, context: detail.topSongs, source: .artist(detail.artist))
            }
        }

        if !detail.albums.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Discography")
                PhoneCardRow(items: detail.albums) { album in
                    MediaCard(title: album.title, subtitle: album.year ?? "Album", artwork: album.artwork, width: 156) {
                        model.navigate(.album(album))
                    }
                }
            }
        }

        if !detail.similar.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Fans also like")
                PhoneCardRow(items: detail.similar) { artist in
                    MediaCard(title: artist.name, subtitle: artist.genre ?? "Artist", artwork: artist.artwork, circular: true, width: 130) {
                        model.navigate(.artist(artist))
                    }
                }
            }
        }

        if let bio = detail.bio {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "About")
                Text(bio)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondary)
                    .lineSpacing(4)
            }
        }
    }
}
