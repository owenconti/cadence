import SwiftUI

/// The whole screen given to what's playing: artwork (or Up Next) over a blur
/// of it, the scrubber and the controls. Swipe down or tap the chevron to leave.
struct PhoneNowPlaying: View {
    @Environment(AppModel.self) private var model
    @State private var showingQueue = false

    var body: some View {
        if let track = model.player.current {
            VStack(spacing: 0) {
                HStack {
                    Button(action: model.toggleNowPlayingMode) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(.ultraThinMaterial))
                    }
                    .accessibilityLabel("Close Now Playing")
                    Spacer()
                    Button { showingQueue.toggle() } label: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(showingQueue ? Theme.canvas : Theme.text)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(showingQueue ? AnyShapeStyle(Theme.text) : AnyShapeStyle(.ultraThinMaterial)))
                    }
                    .accessibilityLabel(showingQueue ? "Hide Up Next" : "Up Next")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.text)
                .padding(.top, 6)

                if showingQueue {
                    VStack(alignment: .leading, spacing: 10) {
                        PlayingFrom()
                        QueueHeader()
                        UpNextList()
                            .frame(maxHeight: .infinity)
                    }
                    .padding(.top, 12)
                } else {
                    Spacer(minLength: 16)
                    ArtworkView(source: track.artwork, cornerRadius: 16, resolution: 1000)
                        .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                        .scaleEffect(model.player.isPlaying ? 1 : 0.9)
                        .animation(.spring(duration: 0.45, bounce: 0.25), value: model.player.isPlaying)
                    Spacer(minLength: 16)
                }

                VStack(spacing: 18) {
                    titles(track)
                    Scrubber()
                    TransportControls(large: true)
                }
                .padding(.top, 16)
                .padding(.bottom, 12)
            }
            .padding(.horizontal, 24)
            .background { Backdrop(artwork: track.artwork) }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 30).onEnded { drag in
                if drag.translation.height > 110, abs(drag.translation.width) < drag.translation.height {
                    model.toggleNowPlayingMode()
                }
            })
        }
    }

    private func titles(_ track: TrackItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(track.title)
                    .font(.display(22, .heavy))
                    .lineLimit(1)
                if track.isExplicit { ExplicitBadge() }
            }
            Button(track.artistName) { model.openArtist(id: track.artistID, name: track.artistName) }
                .buttonStyle(.plain)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu { TrackMenu(track: track) }
    }
}
