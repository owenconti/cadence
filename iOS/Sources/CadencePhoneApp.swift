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
            #if DEBUG
                .onAppear { PhoneSnapshotTour.runIfRequested(model) }
            #endif
        }
    }
}

/// Splash, connect screen or the app, swapped instantly (no transitions).
struct PhoneRoot: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            AmbientBackground()

            switch model.phase {
            case .launching:
                SplashView()
            case .onboarding:
                PhoneOnboarding()
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
