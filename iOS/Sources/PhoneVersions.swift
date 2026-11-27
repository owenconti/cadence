import SwiftUI

/// The phone's Other Versions page: the song, its clean (or explicit)
/// version, then other takes by the same artist.
struct PhoneVersionsPage: View {
    @Environment(AppModel.self) private var model
    let track: TrackItem
    @State private var versions: Loadable<SongVersions> = .loading

    var body: some View {
        PhonePage {
            VStack(spacing: 10) {
                ArtworkView(source: track.artwork, cornerRadius: 14, resolution: 500)
                    .frame(width: 170, height: 170)
                    .shadow(color: track.artwork.palette.primary.opacity(0.35), radius: 30, y: 12)
                    .padding(.bottom, 6)
                Text("OTHER VERSIONS").eyebrow()
                HStack(spacing: 8) {
                    Text(track.title)
                        .font(.display(24, .heavy))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    if track.isExplicit { ExplicitBadge() }
                }
                Button(track.artistName) { model.openArtist(id: track.artistID, name: track.artistName) }
                    .buttonStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                if !track.albumTitle.isEmpty {
                    Text("\(track.albumTitle) · \(track.duration.clock)")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)

            switch versions {
            case .loading:
                if track.isExplicit {
                    section(VersionsCopy.counterpartTitle(for: track, count: 1), subtitle: VersionsCopy.counterpartSubtitle(for: track)) {
                        LoadingRows(count: 1, showAlbum: false).padding(.horizontal, -12)
                    }
                }
                section("Other versions", subtitle: VersionsCopy.othersSubtitle(for: track)) {
                    LoadingRows(count: 4, showAlbum: false).padding(.horizontal, -12)
                }
            case .failed(let message):
                EmptyNote(symbol: "exclamationmark.triangle", title: "Couldn't look for versions", message: message)
            case .loaded(let found):
                if track.isExplicit || !found.counterparts.isEmpty {
                    section(VersionsCopy.counterpartTitle(for: track, count: found.counterparts.count),
                            subtitle: VersionsCopy.counterpartSubtitle(for: track)) {
                        if found.counterparts.isEmpty {
                            VersionsNote(text: VersionsCopy.noCounterpart(for: track)).padding(.horizontal, -12)
                        } else {
                            PhoneTrackList(tracks: found.counterparts)
                        }
                    }
                }
                if !found.others.isEmpty {
                    section("Other versions", subtitle: VersionsCopy.othersSubtitle(for: track)) {
                        PhoneTrackList(tracks: found.others)
                    }
                } else if found.counterparts.isEmpty && !track.isExplicit {
                    EmptyNote(symbol: "square.on.square", title: "No other versions",
                              message: "Apple Music doesn't seem to have another version of this song by \(track.artistName).")
                }
            }
        }
        .task(id: track.id) { versions = await VersionsCopy.load(track, from: model.provider) }
    }

    private func section<Content: View>(_ title: String, subtitle: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title, subtitle: subtitle)
            content()
        }
    }
}
