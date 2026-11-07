import SwiftUI

@main
struct CadencePhoneApp: App {
    /// One for the app, shared by the phone's window and CarPlay.
    @MainActor static let model = AppModel()
    private let model = CadencePhoneApp.model

    var body: some Scene {
        WindowGroup {
            PhoneRoot()
                .environment(model)
                .onAppear { WatchBridge.shared.start(model.player) }
            #if DEBUG
                .onAppear { PhoneSnapshotTour.runIfRequested(model) }
            #endif
        }
    }
}

/// Splash, connect screen or the app, swapped instantly (no transitions).
/// A full-width iPad gets the Mac's layout (sidebar, pages, Now panel); a
/// phone, or an iPad app squeezed narrow in Split View, the phone's.
struct PhoneRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ZStack {
            AmbientBackground()

            switch model.phase {
            case .launching:
                SplashView()
            case .onboarding:
                PhoneOnboarding()
            case .ready where sizeClass == .regular:
                TabletShell()
            case .ready:
                if model.nowPlayingMode, model.player.current != nil {
                    PhoneNowPlaying()
                } else {
                    PhoneShell()
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}

/// The iPad. Wide (landscape): the Mac's three columns (`MainShell`).
/// Narrower (portrait): the sidebar and pages, with the phone's mini player
/// opening the Mac's full-window Now Playing. Search, the Mac's ⌘K palette,
/// fills the page column (see `ContentArea`).
struct TabletShell: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            if geo.size.width >= 1100 {
                MainShell()
            } else if model.nowPlayingMode, model.player.current != nil {
                NowPlayingView()
            } else {
                HStack(spacing: 0) {
                    if !model.sidebarHidden {
                        Sidebar().frame(width: 250)
                    }
                    ContentArea()
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            MiniPlayer()
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial).padding(.horizontal, 10))
                                .frame(maxWidth: 560)
                                .padding(.bottom, 8)
                        }
                }
            }
        }
        // Going anywhere leaves search.
        .onChange(of: model.route) { model.palette.dismiss() }
    }
}
