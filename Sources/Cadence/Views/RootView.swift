import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = HotReload.observe()
        Group {
            ZStack {
                AmbientBackground()

                switch model.phase {
                case .onboarding:
                    OnboardingView().transition(.opacity)
                case .ready:
                    MainShell().transition(.opacity)
                }

                if model.palette.isPresented {
                    CommandPalette()
                        .transition(.opacity)
                        .zIndex(2)
                }
            }
            .ignoresSafeArea()
            .preferredColorScheme(.dark)
            .frame(minWidth: 1080, minHeight: 680)
        }
        .hotReloadable()
    }
}

struct MainShell: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = HotReload.observe()
        Group {
            HStack(spacing: 0) {
                Sidebar()
                ContentArea()
                NowPanel()
            }
        }
        .hotReloadable()
    }
}

struct ContentArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = HotReload.observe()
        Group {
            let route = model.route
            ZStack {
                page(for: route)
                    .id(route)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
            }
            .animation(.snappy(duration: 0.28), value: route)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(model.providerGeneration)
        }
        .hotReloadable()
    }

    @ViewBuilder
    private func page(for route: Route) -> some View {
        switch route {
        case .discover: DiscoverView()
        case .playlists: PlaylistsView()
        case .artists: ArtistsView()
        case .playlist(let playlist): PlaylistDetailView(playlist: playlist)
        case .album(let album): AlbumDetailView(album: album)
        case .artist(let artist): ArtistDetailView(artist: artist)
        }
    }
}
