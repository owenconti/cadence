import SwiftUI

/// The Search tab: songs, artists, albums and playlists from the catalog (or
/// the demo library). The query is the palette's, so it survives leaving the
/// tab and "Playing from search" brings it back.
struct PhoneSearch: View {
    @Environment(AppModel.self) private var model
    @State private var results: SearchResults?
    @State private var searching = false
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var palette = model.palette
        let query = palette.query.trimmingCharacters(in: .whitespaces)

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
                TextField("Songs, artists, albums, playlists", text: $palette.query)
                    .font(.system(size: 16))
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                if searching {
                    ProgressView().controlSize(.small)
                } else if !palette.query.isEmpty {
                    Button { palette.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().stroke(Theme.hairline))
            .padding(.horizontal, Phone.gutter)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if query.count < 2 {
                        recentPlaylists
                    } else if let results {
                        found(results, query: query)
                    } else {
                        LoadingRows(count: 6, showAlbum: false).padding(.horizontal, -12)
                    }
                }
                .padding(.horizontal, Phone.gutter)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .scrollDismissesKeyboard(.immediately)
        }
        .onAppear { if model.palette.query.isEmpty { focused = true } }
        .task(id: query) { await search(query) }
    }

    private func search(_ query: String) async {
        results = nil
        guard query.count >= 2 else { return }
        // Only ask the catalog once typing pauses.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        let found = (try? await model.provider.search(query)) ?? SearchResults()
        guard !Task.isCancelled else { return }
        results = found
    }

    @ViewBuilder
    private var recentPlaylists: some View {
        if !model.playlists.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Your playlists")
                PhoneCardRow(items: Array(model.sortedPlaylists(by: .recent).prefix(10))) { playlist in
                    MediaCard(title: playlist.name, subtitle: playlist.curator ?? "Playlist", artwork: model.artwork(for: playlist), width: 140) {
                        model.navigate(.playlist(playlist))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func found(_ results: SearchResults, query: String) -> some View {
        if results.songs.isEmpty && results.artists.isEmpty && results.albums.isEmpty && results.playlists.isEmpty {
            EmptyNote(symbol: "magnifyingglass", title: "Nothing found for “\(query)”")
        }
        if !results.songs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Songs")
                PhoneTrackList(tracks: Array(results.songs.prefix(8)), context: results.songs, source: .search(query))
            }
        }
        if !results.artists.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Artists")
                PhoneCardRow(items: results.artists) { artist in
                    MediaCard(title: artist.name, subtitle: artist.genre ?? "Artist", artwork: artist.artwork, circular: true, width: 120) {
                        model.navigate(.artist(artist))
                    }
                }
            }
        }
        if !results.albums.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Albums")
                PhoneCardRow(items: results.albums) { album in
                    MediaCard(title: album.title, subtitle: album.artistName, artwork: album.artwork, width: 140) {
                        model.navigate(.album(album))
                    }
                }
            }
        }
        if !results.playlists.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Playlists")
                PhoneCardRow(items: results.playlists) { playlist in
                    MediaCard(title: playlist.name, subtitle: playlist.curator ?? "Playlist", artwork: model.artwork(for: playlist), width: 140) {
                        model.navigate(.playlist(playlist))
                    }
                }
            }
        }
    }
}
