import SwiftUI

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = HotReload.observe()
        Group {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) {
                    LogoMark()
                    Text("cadence").font(.display(18, .heavy))
                }
                .padding(.horizontal, 20)
                .padding(.top, Theme.titlebarInset)
                .padding(.bottom, 18)

                SearchLauncher()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)

                VStack(spacing: 2) {
                    ForEach(SidebarSection.allCases) { section in
                        SidebarRow(title: section.title, symbol: section.symbol, selected: model.section == section && model.stack.isEmpty) {
                            model.select(section)
                        }
                    }
                }
                .padding(.horizontal, 10)

                Text("PINNED")
                    .eyebrow()
                    .padding(.horizontal, 22)
                    .padding(.top, 26)
                    .padding(.bottom, 8)

                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.playlists.prefix(14)) { playlist in
                            PinnedRow(playlist: playlist)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .scrollIndicators(.never)

                Spacer(minLength: 0)
                SourceBadge()
            }
            .frame(width: 232)
            .background(Theme.panel)
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairline).frame(width: 1) }
        }
        .hotReloadable()
    }
}

private struct SearchLauncher: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let _ = HotReload.observe()
        Group {
            Button(action: model.palette.present) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text("Search")
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("⌘K")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.card))
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Theme.cardHover : Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.hairline))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
        .hotReloadable()
    }
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let _ = HotReload.observe()
        Group {
            Button(action: action) {
                HStack(spacing: 11) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? Theme.accent : Theme.secondary)
                        .frame(width: 18)
                    Text(title)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.text : Theme.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? Theme.cardHover : (hovering ? Theme.card : .clear)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
        .hotReloadable()
    }
}

private struct PinnedRow: View {
    @Environment(AppModel.self) private var model
    let playlist: PlaylistItem
    @State private var hovering = false

    private var isOpen: Bool {
        if case .playlist(let open) = model.route { return open.id == playlist.id }
        return false
    }

    var body: some View {
        let _ = HotReload.observe()
        Group {
            HStack(spacing: 10) {
                ArtworkView(source: playlist.artwork, cornerRadius: 5, resolution: 80)
                    .frame(width: 28, height: 28)
                Text(playlist.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isOpen ? Theme.text : Theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if hovering {
                    Button {
                        Task { await model.play(.playlist(playlist)) }
                    } label: {
                        Image(systemName: "play.fill").font(.system(size: 10))
                    }
                    .buttonStyle(IconButtonStyle(size: 22))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isOpen ? Theme.cardHover : (hovering ? Theme.card : .clear)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { model.navigate(.playlist(playlist)) }
        }
        .hotReloadable()
    }
}

private struct SourceBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = HotReload.observe()
        Group {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(model.provider.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                    if !model.provider.isLive {
                        Button("Connect") {
                            withAnimation(.smooth(duration: 0.4)) { model.phase = .onboarding }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    }
                }
                if model.provider.isLive, model.canPlayCatalog == false {
                    Text("Browsing only. Playback needs an Apple Music subscription.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Subscribe", action: model.openSubscribePage)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
        .hotReloadable()
    }

    private var statusColor: Color {
        guard model.provider.isLive else { return .orange }
        return model.canPlayCatalog == false ? .yellow : .green
    }
}
