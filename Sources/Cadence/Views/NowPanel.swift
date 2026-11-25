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
        .frame(maxWidth: .infinity)
        .background(Theme.panel)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.hairline).frame(width: 1) }
    }

    private func playing(_ track: TrackItem, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                PlayingFrom()
                Spacer(minLength: 8)
                CrossfadeMenu(size: 28)
                Button(action: model.toggleNowPlayingMode) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(IconButtonStyle(size: 28))
                .help("Now Playing (⇧⌘F)")
            }

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
            TempoControl()
                .frame(maxWidth: .infinity)

            if let notice = model.player.notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
                    .transition(.opacity)
            }
            QueueHeader()
            UpNextList()
                .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 22)
        .padding(.top, Theme.titlebarInset)
        .animation(.smooth(duration: 0.35), value: track.id)
    }

    private func titles(_ track: TrackItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(track.title)
                .font(.display(19, .bold))
                .lineLimit(2)
                .contentTransition(.opacity)
            Button(track.artistName) { model.openArtist(id: track.artistID, name: track.artistName) }
                .buttonStyle(LinkButtonStyle())
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .help("Go to \(track.artistName)")
            if !track.albumTitle.isEmpty {
                Button(track.albumTitle) { model.openAlbum(of: track) }
                    .buttonStyle(LinkButtonStyle(color: Theme.tertiary))
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .help("Go to \(track.albumTitle)")
            }
        }
    }
}

/// "Playing from playlist" and its name, which opens it.
struct PlayingFrom: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let source = model.player.source {
            VStack(alignment: .leading, spacing: 4) {
                Text("PLAYING FROM \(source.label.uppercased())").eyebrow()
                if canOpen(source) {
                    Button { model.open(source) } label: {
                        HStack(spacing: 4) {
                            Text(source.title).lineLimit(1)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                        }
                    }
                    .buttonStyle(LinkButtonStyle())
                    .font(.system(size: 13, weight: .semibold))
                } else {
                    Text(source.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }
        } else {
            Text("NOW PLAYING").eyebrow()
        }
    }

    private func canOpen(_ source: QueueSource) -> Bool {
        switch source.kind {
        case .album: source.route != nil
        case .playlist: source.route != nil || model.playlists.contains { $0.id == source.id }
        default: true
        }
    }
}

struct QueueHeader: View {
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

struct UpNextList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        let upcoming = player.upNext
        if upcoming.isEmpty {
            EmptyNote(symbol: "text.append", title: "Queue is empty", message: "Use “Play Next” or “Add to Queue” on any song.")
        } else {
            // Shuffled, only the songs you queued have a set order; the rest
            // is picked as it goes.
            let rows = player.isShuffled ? player.queuedUpNext : Array(upcoming.indices)
            ScrollView {
                LazyVStack(spacing: 2) {
                    // By queue position: the same song can be queued twice.
                    ForEach(rows, id: \.self) { i in
                        QueueRow(track: player.queue[i], queueIndex: i)
                    }
                    if player.isShuffled, upcoming.count > rows.count {
                        ShuffledRest(count: upcoming.count - rows.count, source: player.source, afterQueued: !rows.isEmpty)
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.never)
        }
    }
}

/// Stands in for the shuffled songs after any you queued: how many, and from where.
private struct ShuffledRest: View {
    let count: Int
    let source: QueueSource?
    let afterQueued: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "shuffle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.card))
            VStack(alignment: .leading, spacing: 1) {
                Text("\(afterQueued ? "Then " : "")\(count) \(count == 1 ? "song" : "songs") shuffled")
                    .font(.system(size: 12.5, weight: .medium))
                Text(source.map { "From \($0.title)" } ?? "Each picked as it comes")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .accessibilityElement(children: .combine)
    }
}

private struct QueueRow: View {
    @Environment(AppModel.self) private var model
    let track: TrackItem
    let queueIndex: Int
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
        .onTapGesture { model.player.jump(toQueueIndex: queueIndex) }
        .contextMenu { TrackMenu(track: track) }
    }
}
