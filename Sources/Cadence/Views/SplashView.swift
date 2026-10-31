import SwiftUI

/// Shown while launching: access is checked and the library loaded behind it,
/// then the app or the connect screen replaces it.
struct SplashView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            LogoMark(size: 84)
                .shadow(color: Theme.accent.opacity(0.4), radius: 26)

            Text("cadence")
                .font(.display(30, .heavy))

            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.launchStatus)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
            }
            .frame(height: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
