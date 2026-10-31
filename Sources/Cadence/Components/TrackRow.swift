import SwiftUI

struct TrackRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.queueSource) private var source
    let track: TrackItem
    var number: Int?
    /// The list this row belongs to; playing a row queues the whole list.
    let context: [TrackItem]
    var showArtwork = true
    var showAlbum = true

    @State private var hovering = false

    private var isCurrent: Bool { model.player.current?.id == track.id }

    var body: some View {
        HStack(spacing: 14) {
            leading.frame(width: 24)

            if showArtwork {
                ArtworkView(source: track.artwork, cornerRadius: 5, resolution: 96)
                    .frame(width: 38, height: 38)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isCurrent ? Theme.accent : Theme.text)
                    if track.isExplicit { ExplicitBadge() }
                }
                Button(track.artistName) { model.openArtist(id: track.artistID, name: track.artistName) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            if showAlbum {
                Text(track.albumTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // A Menu is a full AppKit control, so only the hovered row has one.
            Group {
                if hovering {
                    Menu {
                        TrackMenu(track: track)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                            .frame(width: 24, height: 24)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                }
            }
            .frame(width: 24)

            Text(track.duration.clock)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 54)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovering ? Theme.card : (isCurrent ? Theme.accent.opacity(0.07) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: play)
        .contextMenu { TrackMenu(track: track) }
    }

    @ViewBuilder
    private var leading: some View {
        if hovering {
            Button(action: isCurrent ? model.player.toggle : play) {
                Image(systemName: isCurrent && model.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.text)
            }
            .buttonStyle(.plain)
        } else if isCurrent {
            EqualizerBars(active: model.player.isPlaying)
        } else if let number {
            Text("\(number)")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
        }
    }

    private func play() {
        let index = context.firstIndex(of: track) ?? 0
        model.play(context.isEmpty ? [track] : context, startAt: index, from: source)
    }
}

struct TrackMenu: View {
    @Environment(AppModel.self) private var model
    let track: TrackItem

    var body: some View {
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { model.player.playNext(track) }
        Button("Add to Queue", systemImage: "text.append") { model.player.addToQueue(track) }
        Divider()
        Button("Go to Artist", systemImage: "person") { model.openArtist(id: track.artistID, name: track.artistName) }
    }
}

struct TrackListHeader: View {
    var showArtwork = true
    var showAlbum = true

    var body: some View {
        HStack(spacing: 14) {
            Text("#").frame(width: 24)
            if showArtwork { Color.clear.frame(width: 38, height: 1) }
            Text("TITLE").frame(maxWidth: .infinity, alignment: .leading)
            if showAlbum { Text("ALBUM").frame(maxWidth: .infinity, alignment: .leading) }
            Color.clear.frame(width: 24, height: 1)
            Image(systemName: "clock").frame(width: 40, alignment: .trailing)
        }
        .eyebrow()
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}
