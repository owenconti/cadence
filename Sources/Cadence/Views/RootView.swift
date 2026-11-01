import SwiftUI

#if os(macOS)
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
#endif

struct MainShell: View {
    @Environment(AppModel.self) private var model
    /// The middle column never gets narrower than this.
    private let contentMinimum: CGFloat = 460

    var body: some View {
        @Bindable var model = model
        if model.nowPlayingMode, model.player.current != nil {
            NowPlayingView()
        } else {
            GeometryReader { geo in
                let sidebar = model.sidebarHidden ? 0 : model.sidebarWidth
                HStack(spacing: 0) {
                    if !model.sidebarHidden {
                        Sidebar()
                            .frame(width: model.sidebarWidth)
                            .overlay(alignment: .trailing) {
                                ResizeHandle(width: $model.sidebarWidth, defaultWidth: 232,
                                             range: 190...min(380, max(190, geo.size.width - model.nowPanelWidth - contentMinimum)),
                                             edge: .trailing)
                            }
                    }
                    ContentArea()
                    NowPanel()
                        .frame(width: model.nowPanelWidth)
                        .overlay(alignment: .leading) {
                            ResizeHandle(width: $model.nowPanelWidth, defaultWidth: 340,
                                         range: 280...min(560, max(280, geo.size.width - sidebar - contentMinimum)),
                                         edge: .leading)
                        }
                }
            }
        }
    }
}

/// The draggable edge of a side panel. `edge` is the panel's side it sits on:
/// dragging a trailing edge right widens the panel, a leading edge left.
/// Double-click puts the default width back.
struct ResizeHandle: View {
    @Binding var width: CGFloat
    let defaultWidth: CGFloat
    let range: ClosedRange<CGFloat>
    let edge: HorizontalEdge
    @State private var start: CGFloat?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(Theme.accent.opacity(start != nil ? 0.8 : hovering ? 0.45 : 0))
            .frame(width: 2)
            .frame(width: 10)
            .contentShape(Rectangle())
            .offset(x: edge == .trailing ? 5 : -5)
            #if os(macOS)
            .pointerStyle(.columnResize)
            #endif
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let from = start ?? width
                        start = from
                        let delta = edge == .trailing ? drag.translation.width : -drag.translation.width
                        width = min(max(from + delta, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in start = nil }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { width = min(max(defaultWidth, range.lowerBound), range.upperBound) })
            .help("Drag to resize · double-click to reset")
            .onChange(of: range) { _, range in
                // The window got smaller: keep the middle column usable.
                if width > range.upperBound { width = range.upperBound }
            }
    }
}

struct ContentArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let route = model.route
        ZStack {
            #if os(iOS)
            // The iPad has no ⌘K palette; search fills the page instead.
            if model.palette.isPresented {
                PhoneSearch()
            } else {
                page(for: route).id(route)
            }
            #else
            page(for: route)
                .id(route)
            #endif
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
