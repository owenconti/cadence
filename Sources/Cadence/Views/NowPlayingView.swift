import SwiftUI

/// ⇧⌘F: the whole window given to what's playing. Big artwork over a blur of
/// itself, the controls, and what's up next. Esc or ⇧⌘F leaves.
struct NowPlayingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let track = model.player.current {
            GeometryReader { geo in
                let queueWidth = min(380, geo.size.width * 0.3)
                let art = min(geo.size.height - 420, geo.size.width - queueWidth - 200, 560)
                HStack(spacing: 0) {
                    VStack(spacing: 28) {
                        Spacer(minLength: 0)
                        ArtworkView(source: track.artwork, cornerRadius: 18, resolution: 1200)
                            .frame(width: max(art, 200), height: max(art, 200))
                            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
                        VStack(spacing: 18) {
                            titles(track)
                            Scrubber()
                            TransportControls(large: true)
                        }
                        .frame(width: max(art, 360))
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 40)

                    VStack(alignment: .leading, spacing: 14) {
                        PlayingFrom()
                        QueueHeader()
                        UpNextList()
                            .frame(maxHeight: .infinity)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, Theme.titlebarInset)
                    .frame(width: queueWidth)
                    .background(.black.opacity(0.18))
                }
            }
            .background { Backdrop(artwork: track.artwork) }
            .overlay(alignment: .topLeading) {
                Button(action: model.toggleNowPlayingMode) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                }
                .buttonStyle(IconButtonStyle(size: 30))
                .background(Circle().fill(.ultraThinMaterial))
                .help("Leave Now Playing (Esc)")
                .padding(.leading, 84)
                .padding(.top, 10)
            }
        }
    }

    private func titles(_ track: TrackItem) -> some View {
        VStack(spacing: 6) {
            Text(track.title)
                .font(.display(30, .heavy))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            HStack(spacing: 6) {
                Button(track.artistName) { model.openArtist(id: track.artistID, name: track.artistName) }
                    .buttonStyle(LinkButtonStyle())
                    .help("Go to \(track.artistName)")
                if !track.albumTitle.isEmpty {
                    Text("·").foregroundStyle(Theme.tertiary)
                    Button(track.albumTitle) { model.openAlbum(of: track) }
                        .buttonStyle(LinkButtonStyle(color: Theme.tertiary))
                        .help("Go to \(track.albumTitle)")
                }
            }
            .font(.system(size: 15, weight: .medium))
            .lineLimit(1)
        }
    }
}

/// The artwork, blown up and blurred, darkened enough for text to sit on.
private struct Backdrop: View {
    let artwork: ArtworkSource

    var body: some View {
        GeometryReader { geo in
            ArtworkView(source: artwork, cornerRadius: 0, resolution: 300)
                .frame(width: max(geo.size.width, geo.size.height) * 1.3, height: max(geo.size.width, geo.size.height) * 1.3)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .blur(radius: 90)
                .overlay(Color.black.opacity(0.5))
        }
        .clipped()
        .ignoresSafeArea()
    }
}
