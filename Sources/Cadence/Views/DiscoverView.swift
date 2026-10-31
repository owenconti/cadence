import SwiftUI

struct DiscoverView: View {
    @Environment(AppModel.self) private var model
    @State private var loadError: String?

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 6) {
                Text(greeting).font(.display(34, .heavy))
                Text("Fresh picks tuned to what you've been playing.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondary)
            }

            // Usually loaded behind the splash; otherwise it loads here.
            if let feed = model.discoverFeed {
                sections(feed)
            } else if let loadError {
                EmptyNote(symbol: "wifi.exclamationmark", title: "Couldn't load Discover", message: loadError)
            } else {
                LoadingRows()
            }
        }
        .task {
            guard model.discoverFeed == nil else { return }
            do { model.discoverFeed = try await model.provider.discover() } catch { loadError = error.localizedDescription }
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
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Jump back in")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(feed.recent) { QuickTile(item: $0) }
                }
            }
        }

        ForEach(feed.shelves) { shelf in
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: shelf.title, subtitle: shelf.subtitle)
                CardRow(items: shelf.items) { item in
                    MediaCard(title: item.title, subtitle: item.subtitle, artwork: item.artwork) {
                        model.open(item)
                    } play: {
                        Task { await model.play(item) }
                    }
                }
            }
        }

        if !feed.trending.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Trending now", subtitle: "What everyone's playing this week") {
                    Button("Play all") { model.play(feed.trending, shuffled: false, from: .trending) }
                        .buttonStyle(PillButtonStyle(prominent: false))
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)], spacing: 4) {
                    ForEach(Array(feed.trending.enumerated()), id: \.element.id) { i, track in
                        TrackRow(track: track, number: i + 1, context: feed.trending, showAlbum: false)
                            .environment(\.queueSource, .trending)
                    }
                }
            }
        }

        if !feed.newReleases.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "New releases")
                CardRow(items: feed.newReleases) { album in
                    MediaCard(title: album.title, subtitle: [album.artistName, album.year].compactMap { $0 }.joined(separator: " · "), artwork: album.artwork) {
                        model.navigate(.album(album))
                    } play: {
                        Task { await model.play(.album(album)) }
                    }
                }
            }
        }
    }
}

private struct QuickTile: View {
    @Environment(AppModel.self) private var model
    let item: ShelfItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(source: item.artwork, cornerRadius: 0, resolution: 140)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 13, weight: .semibold))
                Text(item.subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if hovering {
                PlayFab(size: 32) { Task { await model.play(item) } }
                    .padding(.trailing, 12)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .background(hovering ? Theme.cardHover : Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.snappy(duration: 0.18)) { hovering = h } }
        .onTapGesture { model.open(item) }
    }
}
