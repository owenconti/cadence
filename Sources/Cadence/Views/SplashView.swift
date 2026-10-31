import SwiftUI

/// Shown while launching: access is checked and the library loaded behind it,
/// then the app or the connect screen replaces it.
struct SplashView: View {
    @Environment(AppModel.self) private var model
    @State private var breathing = false

    var body: some View {
        VStack(spacing: 22) {
            LogoMark(size: 84)
                .shadow(color: Theme.accent.opacity(breathing ? 0.55 : 0.25), radius: breathing ? 34 : 18)
                .scaleEffect(breathing ? 1.04 : 1)
                .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: breathing)

            Text("cadence")
                .font(.display(30, .heavy))

            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.launchStatus)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .contentTransition(.opacity)
            }
            .animation(.smooth(duration: 0.3), value: model.launchStatus)
            .frame(height: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            breathing = true
        }
    }
}
