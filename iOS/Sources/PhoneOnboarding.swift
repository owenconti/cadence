import SwiftUI

/// The connect screen, sized for a phone.
struct PhoneOnboarding: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 14) {
                LogoMark(size: 64)
                Text("Your music, minus the clutter.")
                    .font(.display(32, .heavy))
                    .multilineTextAlignment(.center)
                Text("Playlists, artists and discovery, all one glance away.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            VStack(spacing: 12) {
                notice
                Button {
                    model.continueWithAppleMusic()
                } label: {
                    HStack(spacing: 8) {
                        if model.access == .connecting { ProgressView().controlSize(.small) }
                        Image(systemName: "applelogo")
                        Text("Continue with Apple Music")
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                }
                .buttonStyle(PillButtonStyle())
                .disabled(model.access == .connecting)

                Text("Uses the Apple ID signed into this \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone").")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)

                Button("or explore with the demo library", action: model.startDemo)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .padding(.top, 6)
            }
        }
        .padding(28)
        .animation(.smooth(duration: 0.3), value: model.access)
    }

    @ViewBuilder
    private var notice: some View {
        switch model.access {
        case .idle, .connecting:
            EmptyView()
        case .denied:
            card("lock.fill", "Apple Music access is turned off", "Turn on Media & Apple Music for Cadence in Settings, then come back.",
                 ("Open Settings", model.openPrivacySettings))
        case .restricted:
            card("hand.raised.fill", "Apple Music is restricted", "Screen Time or a management profile is blocking access to Apple Music.", nil)
        case .failed(let reason):
            card("exclamationmark.triangle.fill", "Couldn't reach Apple Music", reason, ("Try Again", model.continueWithAppleMusic))
        }
    }

    private func card(_ symbol: String, _ title: String, _ message: String, _ action: (String, () -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button(action.0, action: action.1)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.hairline))
        .transition(.opacity)
    }
}
