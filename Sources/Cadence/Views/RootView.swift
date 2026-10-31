import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            AmbientBackground()

            switch model.phase {
            case .launching:
                SplashView()
            case .onboarding:
                OnboardingView()
            case .ready:
                MainShell()
            }

            if model.palette.isPresented, model.phase != .launching {
                CommandPalette()
                    .zIndex(2)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .frame(minWidth: 1080, minHeight: 680)
    }
}

struct MainShell: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            ContentArea()
            NowPanel()
        }
    }
}

struct ContentArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let route = model.route
        ZStack {
            page(for: route)
                .id(route)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(model.providerGeneration)
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
