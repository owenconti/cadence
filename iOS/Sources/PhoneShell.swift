import SwiftUI

/// The app on a phone: the page for the current route, with the mini player
/// and the tab bar along the bottom. Search is the fourth tab; it's the Mac's
/// ⌘K palette (`model.palette`), so "Playing from search" can reopen it.
struct PhoneShell: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let route = model.route
        ZStack {
            if model.palette.isPresented {
                PhoneSearch()
            } else {
                page(for: route)
                    .id(route)
            }
        }
        .id(model.providerGeneration)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                ToastView()
                MiniPlayer()
                PhoneTabBar()
            }
            .padding(.top, 8)
            .background(alignment: .top) {
                Rectangle().fill(.ultraThinMaterial)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                    .ignoresSafeArea()
            }
        }
        // Going anywhere leaves search.
        .onChange(of: route) { model.palette.dismiss() }
    }

    @ViewBuilder
    private func page(for route: Route) -> some View {
        switch route {
        case .discover: PhoneDiscover()
        case .playlists: PhonePlaylists()
        case .myPlaylists: PhoneMyPlaylists()
        case .artists: PhoneArtists()
        case .playlist(let playlist): PhonePlaylistPage(playlist: playlist)
        case .album(let album): PhoneAlbumPage(album: album)
        case .artist(let artist): PhoneArtistPage(artist: artist)
        }
    }
}

/// A page's scrolling body, with a back button when the route was pushed.
/// Swiping in from the left edge goes back too.
struct PhonePage<Content: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                content
            }
            .padding(.horizontal, Phone.gutter)
            .padding(.top, model.stack.isEmpty ? 12 : 54)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .overlay(alignment: .topLeading) {
            if !model.stack.isEmpty {
                Button(action: model.back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(PressableStyle())
                .padding(.leading, 14)
                .padding(.top, 6)
                .accessibilityLabel("Back")
            }
        }
        .overlay(alignment: .leading) {
            if !model.stack.isEmpty {
                Color.clear
                    .frame(width: 22)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 16).onEnded { drag in
                        if drag.translation.width > 70 { model.back() }
                    })
            }
        }
    }
}

enum Phone {
    static let gutter: CGFloat = 20
}

/// A sideways row of cards that runs to the screen's edges.
struct PhoneCardRow<Item: Identifiable, Card: View>: View {
    let items: [Item]
    @ViewBuilder var card: (Item) -> Card

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 0) {
                ForEach(items) { card($0) }
            }
            .padding(.horizontal, Phone.gutter - 10)
        }
        .scrollIndicators(.never)
        .padding(.horizontal, -Phone.gutter)
    }
}

/// A big page title, with an optional subtitle.
struct PhoneTitle: View {
    let title: String
    var subtitle: String?
    var subtitlePending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.display(32, .heavy))
            if let subtitle {
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    .redacted(reason: subtitlePending ? .placeholder : [])
            }
        }
    }
}

struct PhoneTabBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SidebarSection.allCases) { section in
                tab(section.title, section.symbol, selected: !model.palette.isPresented && model.section == section) {
                    model.palette.dismiss()
                    model.select(section)
                }
            }
            tab("Search", "magnifyingglass", selected: model.palette.isPresented) {
                if !model.palette.isPresented { model.palette.present() }
            }
        }
        .padding(.horizontal, 8)
    }

    private func tab(_ title: String, _ symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 19, weight: .semibold))
                Text(title).font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(selected ? Theme.accent : Theme.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// What's playing, above the tab bar. Tap it for Now Playing.
struct MiniPlayer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let track = model.player.current {
            let player = model.player
            let fraction = track.duration > 0 ? min(player.position / track.duration, 1) : 0
            HStack(spacing: 12) {
                ArtworkView(source: track.artwork, cornerRadius: 7, resolution: 120)
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(track.artistName).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: player.toggle) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button(action: player.next) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("Next track")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.text)
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.cardHover))
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    Capsule().fill(Theme.text.opacity(0.85)).frame(width: geo.size.width * fraction, height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 14)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.toggleNowPlayingMode() }
            .padding(.horizontal, 10)
        }
    }
}
