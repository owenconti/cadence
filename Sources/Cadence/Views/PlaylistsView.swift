import SwiftUI

struct PlaylistsView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""

    var body: some View {
        @Bindable var model = model
        let sort = model.playlistSort
        let playlists = visible
        // Until the playlists (or, for Largest, their song counts) are in,
        // cards of the same size stand in so nothing moves when they arrive.
        let waiting = !model.playlistsLoaded
            || (sort == .size && playlists.contains { model.size(of: $0) == nil && !model.uncountedPlaylists.contains($0.id) })
        PageScroll {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Playlists").font(.display(34, .heavy))
                    Text("\(model.playlists.count) playlists").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        .redacted(reason: model.playlistsLoaded ? [] : .placeholder)
                }
                Spacer()
                Picker("Sort", selection: $model.playlistSort) {
                    ForEach(PlaylistSort.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
                FilterField(prompt: "Filter playlists", text: $filter)
                Button { model.playlistPrompt = .create(with: nil) } label: { Label("New Playlist", systemImage: "plus") }
                    .buttonStyle(PillButtonStyle(prominent: false))
                    .help("New Playlist (⌘N)")
            }

            if waiting {
                grid(model.playlistsLoaded ? Placeholder.playlists(playlists.count) : Placeholder.playlists(12)).skeleton()
            } else if playlists.isEmpty {
                EmptyNote(symbol: "music.note.list", title: filter.isEmpty ? "No playlists yet" : "Nothing matches “\(filter)”")
            } else {
                grid(playlists)
            }
        }
        .task { await model.refreshPlaylists() }
    }

    private func grid(_ playlists: [PlaylistItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 6)], alignment: .leading, spacing: 10) {
            ForEach(playlists) { playlist in
                let size = model.size(of: playlist)
                let counting = size == nil && model.provider.isLive && !model.uncountedPlaylists.contains(playlist.id)
                MediaCard(
                    title: playlist.name,
                    // Apple Music playlists say how many songs once counted.
                    subtitle: size.map { "\($0) songs" } ?? (counting ? "000 songs" : playlist.curator ?? "Playlist"),
                    subtitlePending: counting,
                    artwork: model.artwork(for: playlist),
                    width: nil
                ) {
                    model.navigate(.playlist(playlist))
                } play: {
                    Task { await model.play(.playlist(playlist)) }
                }
            }
        }
        .padding(.horizontal, -10)
    }

    private var visible: [PlaylistItem] {
        model.sortedPlaylists(by: model.playlistSort, filter: filter)
    }
}

struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var model
    let playlist: PlaylistItem

    var body: some View {
        CollectionDetailView(
            kind: "Playlist",
            title: playlist.name,
            byline: playlist.curator,
            summary: playlist.summary,
            artwork: model.artwork(for: playlist),
            source: .playlist(playlist),
            showArtwork: true,
            playlist: playlist,
            load: { try await model.tracks(in: playlist) }
        )
    }
}

struct AlbumDetailView: View {
    @Environment(AppModel.self) private var model
    let album: AlbumItem

    var body: some View {
        CollectionDetailView(
            kind: ["Album", album.year].compactMap { $0 }.joined(separator: " · "),
            title: album.title,
            byline: album.artistName,
            onByline: { model.openArtist(id: album.artistID, name: album.artistName) },
            summary: nil,
            artwork: album.artwork,
            source: .album(album),
            showArtwork: false,
            load: { try await model.provider.tracks(in: album) }
        )
    }
}

/// Shared layout for anything that is a titled list of tracks.
struct CollectionDetailView: View {
    @Environment(AppModel.self) private var model
    let kind: String
    let title: String
    let byline: String?
    var onByline: (() -> Void)?
    let summary: String?
    let artwork: ArtworkSource
    let source: QueueSource
    let showArtwork: Bool
    /// The playlist this is, for managing it.
    var playlist: PlaylistItem?
    let load: () async throws -> [TrackItem]

    @State private var tracks: Loadable<[TrackItem]> = .loading
    @State private var filter = ""

    var body: some View {
        let all: [TrackItem] = if case .loaded(let t) = tracks { t } else { [] }
        #if os(iOS)
        if let playlist, model.editingPlaylistID == playlist.id {
            PlaylistSongEditor(playlist: playlist, tracks: all)
        } else {
            page(all)
        }
        #else
        page(all)
        #endif
    }

    private func page(_ all: [TrackItem]) -> some View {
        let shown = filter.isEmpty ? all : all.filter {
            $0.title.localizedCaseInsensitiveContains(filter)
                || $0.artistName.localizedCaseInsensitiveContains(filter)
                || $0.albumTitle.localizedCaseInsensitiveContains(filter)
        }

        return PageScroll {
            HStack(alignment: .bottom, spacing: 30) {
                ArtworkView(source: artwork, cornerRadius: 16, resolution: 600)
                    .frame(width: 230, height: 230)
                    .shadow(color: artwork.palette.primary.opacity(0.35), radius: 40, y: 18)

                VStack(alignment: .leading, spacing: 10) {
                    Text(kind.uppercased()).eyebrow()
                    Text(title)
                        .font(.display(46, .heavy))
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                    if let summary {
                        Text(summary).font(.system(size: 14)).foregroundStyle(Theme.secondary).lineLimit(2)
                    }
                    meta(all)
                    HStack(spacing: 10) {
                        Button { model.play(shown, shuffled: false, from: source) } label: { Label("Play", systemImage: "play.fill") }
                            .buttonStyle(PillButtonStyle())
                            .disabled(all.isEmpty)
                        Button { model.play(shown, shuffled: true, from: source) } label: { Label("Shuffle", systemImage: "shuffle") }
                            .buttonStyle(PillButtonStyle(prominent: false))
                            .disabled(all.isEmpty)
                        if let playlist, model.canManage(playlist) {
                            ManagePlaylistMenu(playlist: playlist, canEditSongs: isLoaded)
                        }
                    }
                    .padding(.top, 6)
                }
            }

            // Lazy: long playlists only build the rows on screen.
            LazyVStack(spacing: 2) {
                FilterField(prompt: "Find in \(kind.lowercased().split(separator: " ").first ?? "list")", text: $filter)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.bottom, 12)
                TrackListHeader(showArtwork: showArtwork, showAlbum: showArtwork, count: shown.count)
                switch tracks {
                case .loading:
                    LoadingRows(count: 12, showArtwork: showArtwork, showAlbum: showArtwork)
                case .failed(let message):
                    EmptyNote(symbol: "exclamationmark.triangle", title: "Couldn't load tracks", message: message)
                case .loaded:
                    if shown.isEmpty {
                        EmptyNote(symbol: "magnifyingglass", title: all.isEmpty ? "No tracks" : "No matches for “\(filter)”")
                    }
                    ForEach(Array(shown.enumerated()), id: \.offset) { i, track in
                        TrackRow(track: track, number: i + 1, context: shown, showArtwork: showArtwork, showAlbum: showArtwork)
                            .environment(\.queueSource, source)
                    }
                }
            }
        }
        // Again when songs are added to it, keeping the list until they're in.
        .task(id: source.kind == .playlist ? model.playlistEdits[source.id ?? ""] ?? 0 : 0) {
            do { tracks = .loaded(try await load()) } catch { tracks = .failed(error.localizedDescription) }
        }
    }

    private var isLoaded: Bool {
        if case .loaded = tracks { true } else { false }
    }

    private func meta(_ tracks: [TrackItem]) -> some View {
        HStack(spacing: 6) {
            if let byline {
                if let onByline {
                    Button(byline, action: onByline).buttonStyle(.plain).fontWeight(.semibold).foregroundStyle(Theme.text)
                } else {
                    Text(byline).fontWeight(.semibold).foregroundStyle(Theme.text)
                }
            }
            if !tracks.isEmpty {
                Text("\(byline == nil ? "" : "· ")\(tracks.count) songs · \(tracks.reduce(0) { $0 + $1.duration }.longForm)")
            } else if case .loading = self.tracks {
                Text("\(byline == nil ? "" : "· ")00 songs · 0 hr 00 min").skeleton()
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.secondary)
    }
}
