import SwiftUI

/// Always-visible right column: what's playing, controls, and the queue.
struct NowPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            Group {
                if let track = model.player.current {
                    playing(track, compact: geo.size.height < 900)
                } else {
                    EmptyNote(symbol: "play.circle", title: "Nothing playing", message: "Pick a playlist, an album, or an artist and it'll show up here.")
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .frame(width: 340)
        .background(Theme.panel)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.hairline).frame(width: 1) }
    }

    private func playing(_ track: TrackItem, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("NOW PLAYING").eyebrow()

            if compact {
                HStack(spacing: 14) {
                    ArtworkView(source: track.artwork, cornerRadius: 10, resolution: 200)
                        .frame(width: 76, height: 76)
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
                    titles(track)
                }
            } else {
                ArtworkView(source: track.artwork, cornerRadius: 16, resolution: 640)
                    .shadow(color: track.artwork.palette.primary.opacity(0.35), radius: 30, y: 14)
                titles(track)
            }

            Scrubber()
            TransportControls()

            QueueHeader()
            UpNextList()
                .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 22)
        .padding(.top, Theme.titlebarInset)
    }

    private func titles(_ track: TrackItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(track.title)
                .font(.display(19, .bold))
                .lineLimit(2)
            Button(track.artistName) { model.openArtist(id: track.artistID, name: track.artistName) }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.secondary)
            Text(track.albumTitle)
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
        }
    }
}

private struct QueueHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Text("UP NEXT").eyebrow()
            Spacer()
            Text("\(model.player.upNext.count) songs").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

private struct UpNextList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let upcoming = Array(model.player.upNext)
        if upcoming.isEmpty {
            EmptyNote(symbol: "text.append", title: "Queue is empty", message: "Use “Play Next” or “Add to Queue” on any song.")
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(upcoming) { track in
                        QueueRow(track: track)
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.never)
        }
    }
}

private struct QueueRow: View {
    @Environment(AppModel.self) private var model
    let track: TrackItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(source: track.artwork, cornerRadius: 5, resolution: 80)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).font(.system(size: 12.5, weight: .medium))
                Text(track.artistName).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            Text(track.duration.clock).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.card : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.player.jump(to: track) }
        .contextMenu { TrackMenu(track: track) }
    }
}
