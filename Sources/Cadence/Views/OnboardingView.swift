import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var appeared = false

    var body: some View {
        let _ = HotReload.observe()
        Group {
            VStack(spacing: 36) {
                VStack(spacing: 16) {
                    LogoMark(size: 64)
                    Text("Your music, minus the clutter.")
                        .font(.display(44, .heavy))
                    Text("Playlists, artists and discovery, all one glance away.")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.secondary)
                }

                HStack(spacing: 14) {
                    feature("music.note.list", "Playlists", "Filter, shuffle, and queue in a click")
                    feature("person.2.fill", "Artists", "Top songs, albums and who's similar")
                    feature("sparkles", "Discovery", "Recommendations, charts and new releases")
                    feature("text.append", "Smart queue", "Play next, shuffle up next, jump anywhere")
                }

                VStack(spacing: 12) {
                    Button {
                        Task { await model.connectAppleMusic() }
                    } label: {
                        HStack(spacing: 8) {
                            if model.access == .connecting { ProgressView().controlSize(.small) }
                            Image(systemName: "applelogo")
                            Text("Continue with Apple Music")
                        }
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(model.access == .connecting)

                    Text("Uses the Apple ID you're signed into on this Mac.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiary)

                    AccessNotice()
                        .animation(.smooth(duration: 0.3), value: model.access)

                    Button("or explore with the demo library", action: model.startDemo)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .padding(.top, 8)
                }
            }
            .padding(60)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)
            .onAppear { withAnimation(.smooth(duration: 0.8)) { appeared = true } }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .hotReloadable()
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 170, height: 124, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.hairline))
    }
}

/// Explains why connecting didn't work and offers the one action that fixes it.
private struct AccessNotice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = HotReload.observe()
        Group {
            switch model.access {
            case .idle, .connecting:
                EmptyView()
            case .denied:
                card(
                    symbol: "lock.fill",
                    title: "Apple Music access is turned off",
                    message: "Turn on Cadence under Privacy & Security › Media & Apple Music, then come back.",
                    action: ("Open System Settings", model.openPrivacySettings)
                )
            case .restricted:
                card(
                    symbol: "hand.raised.fill",
                    title: "Apple Music is restricted on this Mac",
                    message: "Screen Time or a management profile is blocking access to Apple Music.",
                    action: nil
                )
            case .failed(let reason):
                card(
                    symbol: "exclamationmark.triangle.fill",
                    title: "Couldn't reach Apple Music",
                    message: reason,
                    action: ("Try Again", { Task { await model.connectAppleMusic() } })
                )
            }
        }
        .hotReloadable()
    }

    private func card(symbol: String, title: String, message: String, action: (String, () -> Void)?) -> some View {
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
        .frame(width: 420)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.hairline))
        .transition(.opacity.combined(with: .offset(y: -6)))
    }
}

/// The Cadence mark: three rising bars inside a rounded square.
struct LogoMark: View {
    var size: CGFloat = 22

    var body: some View {
        let _ = HotReload.observe()
        Group {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.accent, Color(hex: 0xC0397A)], startPoint: .topLeading, endPoint: .bottomTrailing))
                HStack(alignment: .bottom, spacing: size * 0.08) {
                    ForEach([0.32, 0.55, 0.42], id: \.self) { h in
                        Capsule().fill(.white).frame(width: size * 0.11, height: size * h)
                    }
                }
            }
            .frame(width: size, height: size)
        }
        .hotReloadable()
    }
}
