import SwiftUI

struct ArtistsView: View {
    @Environment(AppModel.self) private var model
    @State private var artists: Loadable<[ArtistItem]> = .loading
    @State private var filter = ""

    var body: some View {
        let all: [ArtistItem] = if case .loaded(let a) = artists { a } else { [] }
        let shown = filter.isEmpty ? all : all.filter {
            $0.name.localizedCaseInsensitiveContains(filter) || ($0.genre ?? "").localizedCaseInsensitiveContains(filter)
        }

        PageScroll {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Artists").font(.display(34, .heavy))
                    Text("\(all.count) in your library").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                FilterField(prompt: "Filter by name or genre", text: $filter)
            }

            switch artists {
            case .loading:
                LoadingRows()
            case .failed(let message):
                EmptyNote(symbol: "person.crop.circle.badge.exclamationmark", title: "Couldn't load artists", message: message)
            case .loaded:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 6)], alignment: .leading, spacing: 14) {
                    ForEach(shown) { artist in
                        MediaCard(title: artist.name, subtitle: artist.genre ?? "Artist", artwork: artist.artwork, circular: true, width: nil) {
                            model.navigate(.artist(artist))
                        }
                    }
                }
                .padding(.horizontal, -10)
            }
        }
        .task {
            do { artists = .loaded(try await model.provider.artists()) } catch { artists = .failed(error.localizedDescription) }
        }
    }
}

struct ArtistDetailView: View {
    @Environment(AppModel.self) private var model
    let artist: ArtistItem
    @State private var detail: Loadable<ArtistDetail> = .loading
    @State private var showAllSongs = false

    var body: some View {
        let loaded: ArtistDetail? = if case .loaded(let d) = detail { d } else { nil }
        let shownArtist = loaded?.artist ?? artist

        PageScroll {
            hero(shownArtist, songs: loaded?.topSongs ?? [])

            switch detail {
            case .loading:
                LoadingRows(count: 5)
            case .failed(let message):
                EmptyNote(symbol: "exclamationmark.triangle", title: "Couldn't load this artist", message: message)
            case .loaded(let detail):
                content(detail)
            }
        }
        .task {
            do { detail = .loaded(try await model.provider.detail(for: artist)) } catch { detail = .failed(error.localizedDescription) }
        }
    }

    private func hero(_ artist: ArtistItem, songs: [TrackItem]) -> some View {
        let palette = artist.artwork.palette
        return HStack(alignment: .center, spacing: 30) {
            ArtworkView(source: artist.artwork, circular: true, resolution: 500)
                .frame(width: 190, height: 190)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
            VStack(alignment: .leading, spacing: 10) {
                Text("ARTIST").eyebrow().foregroundStyle(.white.opacity(0.7))
                Text(artist.name)
                    .font(.display(54, .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let genre = artist.genre {
                    Text(genre).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                }
                HStack(spacing: 10) {
                    Button { model.play(songs) } label: { Label("Play", systemImage: "play.fill") }
                        .buttonStyle(PillButtonStyle())
                    Button { model.play(songs, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                        .buttonStyle(PillButtonStyle(prominent: false))
                }
                .disabled(songs.isEmpty)
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(30)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LinearGradient(colors: [palette.primary.opacity(0.75), palette.secondary.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.white.opacity(0.08)))
    }

    @ViewBuilder
    private func content(_ detail: ArtistDetail) -> some View {
        if !detail.topSongs.isEmpty {
            let songs = showAllSongs ? detail.topSongs : Array(detail.topSongs.prefix(5))
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Popular") {
                    if detail.topSongs.count > 5 {
                        Button(showAllSongs ? "Show less" : "Show all \(detail.topSongs.count)") {
                            showAllSongs.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                    }
                }
                VStack(spacing: 2) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { i, track in
                        TrackRow(track: track, number: i + 1, context: detail.topSongs)
                    }
                }
            }
        }

        if !detail.albums.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Discography")
                CardRow(items: detail.albums) { album in
                    MediaCard(title: album.title, subtitle: album.year ?? "Album", artwork: album.artwork) {
                        model.navigate(.album(album))
                    } play: {
                        Task { await model.play(.album(album)) }
                    }
                }
            }
        }

        if !detail.similar.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Fans also like")
                CardRow(items: detail.similar) { artist in
                    MediaCard(title: artist.name, subtitle: artist.genre ?? "Artist", artwork: artist.artwork, circular: true, width: 150) {
                        model.navigate(.artist(artist))
                    }
                }
            }
        }

        if let bio = detail.bio {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "About")
                Text(bio)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondary)
                    .lineSpacing(4)
                    .frame(maxWidth: 640, alignment: .leading)
            }
        }
    }
}
