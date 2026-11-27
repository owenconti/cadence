import SwiftUI

/// A song's other versions: its clean (or explicit) version first, then
/// live, acoustic, remixed and edited takes by the same artist.
struct VersionsView: View {
    @Environment(AppModel.self) private var model
    let track: TrackItem
    @State private var versions: Loadable<SongVersions> = .loading

    var body: some View {
        PageScroll {
            hero
            switch versions {
            case .loading:
                if track.isExplicit {
                    section(VersionsCopy.counterpartTitle(for: track, count: 1), subtitle: VersionsCopy.counterpartSubtitle(for: track)) {
                        LoadingRows(count: 1)
                    }
                }
                section("Other versions", subtitle: VersionsCopy.othersSubtitle(for: track)) { LoadingRows(count: 4) }
            case .failed(let message):
                EmptyNote(symbol: "exclamationmark.triangle", title: "Couldn't look for versions", message: message)
            case .loaded(let found):
                content(found)
            }
        }
        .task(id: track.id) { versions = await VersionsCopy.load(track, from: model.provider) }
    }

    private var hero: some View {
        HStack(alignment: .bottom, spacing: 26) {
            ArtworkView(source: track.artwork, cornerRadius: 14, resolution: 400)
                .frame(width: 160, height: 160)
                .shadow(color: track.artwork.palette.primary.opacity(0.35), radius: 30, y: 14)
            VStack(alignment: .leading, spacing: 8) {
                Text("OTHER VERSIONS").eyebrow()
                HStack(alignment: .center, spacing: 10) {
                    Text(track.title)
                        .font(.display(40, .heavy))
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                    if track.isExplicit { ExplicitBadge() }
                }
                HStack(spacing: 6) {
                    Button(track.artistName) { model.openArtist(id: track.artistID, name: track.artistName) }
                        .buttonStyle(.plain).fontWeight(.semibold).foregroundStyle(Theme.text)
                    if !track.albumTitle.isEmpty {
                        Text("·")
                        Button(track.albumTitle) { model.openAlbum(of: track) }
                            .buttonStyle(LinkButtonStyle())
                            .lineLimit(1)
                    }
                    Text("· \(track.duration.clock)")
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
            }
        }
    }

    @ViewBuilder
    private func content(_ found: SongVersions) -> some View {
        if track.isExplicit || !found.counterparts.isEmpty {
            section(VersionsCopy.counterpartTitle(for: track, count: found.counterparts.count),
                    subtitle: VersionsCopy.counterpartSubtitle(for: track)) {
                if found.counterparts.isEmpty {
                    VersionsNote(text: VersionsCopy.noCounterpart(for: track))
                } else {
                    rows(found.counterparts)
                }
            }
        }
        if !found.others.isEmpty {
            section("Other versions", subtitle: VersionsCopy.othersSubtitle(for: track)) { rows(found.others) }
        } else if found.counterparts.isEmpty && !track.isExplicit {
            EmptyNote(symbol: "square.on.square", title: "No other versions",
                      message: "Apple Music doesn't seem to have another version of this song by \(track.artistName).")
        }
    }

    private func rows(_ tracks: [TrackItem]) -> some View {
        VStack(spacing: 2) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, version in
                TrackRow(track: version, number: i + 1, context: tracks)
            }
        }
    }

    private func section<Content: View>(_ title: String, subtitle: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, subtitle: subtitle)
            content()
        }
    }
}

/// The page's wording and loading, shared with the phone's.
enum VersionsCopy {
    static func load(_ track: TrackItem, from provider: MusicProvider) async -> Loadable<SongVersions> {
        do { return .loaded(try await provider.versions(of: track)) } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func counterpartTitle(for track: TrackItem, count: Int) -> String {
        let kind = track.isExplicit ? "Clean" : "Explicit"
        return count > 1 ? "\(kind) versions" : "\(kind) version"
    }

    static func counterpartSubtitle(for track: TrackItem) -> String {
        track.isExplicit ? "The same song with the explicit lyrics edited out" : "The same song, unedited"
    }

    static func noCounterpart(for track: TrackItem) -> String {
        "Apple Music doesn't seem to have a clean version of “\(track.title)”."
    }

    static func othersSubtitle(for track: TrackItem) -> String {
        "Live, acoustic, remixed and re-released takes by \(track.artistName)"
    }
}

/// A quiet line in place of a section's songs.
struct VersionsNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }
}
