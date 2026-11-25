import SwiftUI

struct PlaylistsView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""

    var body: some View {
        @Bindable var model = model
        let sort = model.playlistSort
        let playlists = visible
        // Until the playlists (or, for Largest, their song counts) are in,
        // cards of the same size stand in so nothing moves when they arrive.
        let waiting = !model.playlistsLoaded
            || (sort == .size && playlists.contains { model.size(of: $0) == nil && !model.uncountedPlaylists.contains($0.id) })
        PageScroll {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Playlists").font(.display(34, .heavy))
                    Text("\(model.playlists.count) playlists").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        .redacted(reason: model.playlistsLoaded ? [] : .placeholder)
                }
                Spacer()
                Picker("Sort", selection: $model.playlistSort) {
                    ForEach(PlaylistSort.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
                FilterField(prompt: "Filter playlists", text: $filter)
                Button { model.playlistPrompt = .create(with: nil) } label: { Label("New Playlist", systemImage: "plus") }
                    .buttonStyle(PillButtonStyle(prominent: false))
                    .help("New Playlist (⌘N)")
            }

            if waiting {
                grid(model.playlistsLoaded ? Placeholder.playlists(playlists.count) : Placeholder.playlists(12)).skeleton()
            } else if playlists.isEmpty {
                EmptyNote(symbol: "music.note.list", title: filter.isEmpty ? "No playlists yet" : "Nothing matches “\(filter)”")
            } else {
                grid(playlists)
            }
        }
        .task { await model.refreshPlaylists() }
    }

    private func grid(_ playlists: [PlaylistItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 6)], alignment: .leading, spacing: 10) {
            ForEach(playlists) { playlist in
                let size = model.size(of: playlist)
                let counting = size == nil && model.provider.isLive && !model.uncountedPlaylists.contains(playlist.id)
                MediaCard(
                    title: playlist.name,
                    // Apple Music playlists say how many songs once counted.
                    subtitle: size.map { "\($0) songs" } ?? (counting ? "000 songs" : playlist.curator ?? "Playlist"),
                    subtitlePending: counting,
                    artwork: model.artwork(for: playlist),
                    width: nil
                ) {
                    model.navigate(.playlist(playlist))
                } play: {
                    Task { await model.play(.playlist(playlist)) }
                }
            }
        }
        .padding(.horizontal, -10)
    }

    private var visible: [PlaylistItem] {
        model.sortedPlaylists(by: model.playlistSort, filter: filter)
    }
}

/// My Playlists: Cadence's own, synced through iCloud. New ones start empty
/// or as a copy of an Apple Music playlist. Folders come first, each opening
/// and closing in place; drag a playlist onto one to file it there.
struct MyPlaylistsView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""

    var body: some View {
        let all = model.myPlaylists
        let groups = MyPlaylistGroups(model: model, filter: filter)
        PageScroll {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("My Playlists").font(.display(34, .heavy))
                        .lineLimit(1).fixedSize()
                    Text("\(all.count) \(all.count == 1 ? "playlist" : "playlists") · \(model.mineLocation)")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        .lineLimit(1).fixedSize()
                        .help(model.cloudProblem ?? "")
                }
                Spacer()
                if model.showsCloudSync { SyncNowButton() }
                FilterField(prompt: "Filter playlists", text: $filter, width: 170)
                CopyPlaylistMenu()
                Button { model.playlistPrompt = .createFolder(moving: nil) } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(IconButtonStyle(size: 34))
                    .help("New Folder in My Playlists (⌥⇧⌘N)")
                    .accessibilityLabel("New Folder")
                Button { model.playlistPrompt = .createMine(with: nil) } label: { Label("New Playlist", systemImage: "plus") }
                    .buttonStyle(PillButtonStyle(prominent: false))
                    .help("New Playlist in My Playlists (⇧⌘N)")
            }

            if all.isEmpty && model.myFolders.isEmpty {
                EmptyNote(symbol: "rectangle.stack.badge.person.crop", title: "No playlists here yet",
                          message: "Make one, or copy one of your Apple Music playlists. They sync to all your devices.")
            } else if groups.isEmpty {
                EmptyNote(symbol: "music.note.list", title: "Nothing matches “\(filter)”")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(groups.folders, id: \.folder.id) { group in
                        let open = groups.filtering || !model.collapsedFolders.contains(group.folder.id)
                        FolderDropArea(folder: group.folder) {
                            VStack(alignment: .leading, spacing: 4) {
                                FolderHeader(folder: group.folder, count: model.myPlaylists(in: group.folder).count, open: open)
                                if open {
                                    if group.playlists.isEmpty {
                                        FolderEmptyNote(text: "Empty. Drag a playlist here, or use Move to Folder on one.")
                                    } else {
                                        grid(group.playlists)
                                    }
                                }
                            }
                        }
                    }
                    if !groups.folders.isEmpty, groups.loose.isEmpty == false || !groups.filtering {
                        FolderDropArea(folder: nil) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("NOT IN A FOLDER").eyebrow()
                                    .padding(.horizontal, 10)
                                    .frame(height: 34)
                                if groups.loose.isEmpty {
                                    FolderEmptyNote(text: "Drag a playlist here to take it out of its folder.")
                                } else {
                                    grid(groups.loose)
                                }
                            }
                        }
                        .padding(.top, 10)
                    } else if !groups.loose.isEmpty {
                        grid(groups.loose)
                    }
                }
            }
        }
    }

    private func grid(_ playlists: [PlaylistItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 6)], alignment: .leading, spacing: 10) {
            ForEach(playlists) { playlist in
                MediaCard(title: playlist.name, subtitle: "\(playlist.trackCount ?? 0) songs",
                          artwork: model.artwork(for: playlist), width: nil) {
                    model.navigate(.playlist(playlist))
                } play: {
                    Task { await model.play(.playlist(playlist)) }
                }
                .draggable(playlist.id)
                .contextMenu { MyPlaylistContextMenu(playlist: playlist) }
            }
        }
        .padding(.horizontal, -10)
    }
}

/// My Playlists split into folders (A–Z) and those in none, narrowed by a
/// filter: a folder whose name matches keeps all its playlists.
struct MyPlaylistGroups {
    struct Group {
        let folder: PlaylistFolder
        let playlists: [PlaylistItem]
    }

    let folders: [Group]
    let loose: [PlaylistItem]
    let filtering: Bool

    var isEmpty: Bool { folders.isEmpty && loose.isEmpty }

    @MainActor
    init(model: AppModel, filter: String) {
        let filter = filter.trimmingCharacters(in: .whitespaces)
        filtering = !filter.isEmpty
        func matches(_ playlist: PlaylistItem) -> Bool { filter.isEmpty || playlist.name.localizedCaseInsensitiveContains(filter) }
        folders = model.myFolders.compactMap { folder in
            let inside = model.myPlaylists(in: folder)
            if filter.isEmpty || folder.name.localizedCaseInsensitiveContains(filter) { return Group(folder: folder, playlists: inside) }
            let shown = inside.filter(matches)
            return shown.isEmpty ? nil : Group(folder: folder, playlists: shown)
        }
        loose = model.myPlaylists(in: nil).filter(matches)
    }
}

/// A folder's row: click to open or close it; its menu renames or deletes it.
struct FolderHeader: View {
    @Environment(AppModel.self) private var model
    let folder: PlaylistFolder
    let count: Int
    let open: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.tertiary)
                .rotationEffect(.degrees(open ? 90 : 0))
                .animation(.snappy(duration: 0.18), value: open)
                .frame(width: 12)
            Image(systemName: open ? "folder.fill" : "folder")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(folder.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text(count == 1 ? "1 playlist" : "\(count) playlists")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
            Spacer(minLength: 8)
            FolderMenu(folder: folder)
                .opacity(hovering || !isMac ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Theme.card : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { toggle() }
        .contextMenu { FolderMenuItems(folder: folder) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(folder.name), folder, \(count) playlists")
        .accessibilityValue(open ? "Open" : "Closed")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
    }

    private func toggle() {
        if open { model.collapsedFolders.insert(folder.id) } else { model.collapsedFolders.remove(folder.id) }
    }

    private var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }
}

/// Rename and Delete for a folder.
struct FolderMenuItems: View {
    @Environment(AppModel.self) private var model
    let folder: PlaylistFolder

    var body: some View {
        Button("Rename Folder…", systemImage: "pencil") { model.playlistPrompt = .renameFolder(folder) }
        Button("Delete Folder…", systemImage: "trash", role: .destructive) { model.playlistPrompt = .deleteFolder(folder) }
    }
}

private struct FolderMenu: View {
    let folder: PlaylistFolder

    var body: some View {
        Menu { FolderMenuItems(folder: folder) } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Manage folder")
    }
}

/// A playlist card's right-click (or long-press) menu in My Playlists.
struct MyPlaylistContextMenu: View {
    @Environment(AppModel.self) private var model
    let playlist: PlaylistItem

    var body: some View {
        Button("Play", systemImage: "play.fill") { Task { await model.play(.playlist(playlist)) } }
        Button("Shuffle", systemImage: "shuffle") { Task { await model.play(.playlist(playlist), shuffled: true) } }
        Divider()
        MoveToFolderMenu(playlist: playlist)
        Button("Rename…", systemImage: "pencil") { model.playlistPrompt = .rename(playlist) }
        Divider()
        Button("Delete Playlist…", systemImage: "trash", role: .destructive) { model.playlistPrompt = .delete(playlist) }
    }
}

/// A folder (or, nil, "not in a folder") that playlists dragged from My
/// Playlists can be dropped on, lit while one is over it.
struct FolderDropArea<Content: View>: View {
    @Environment(AppModel.self) private var model
    let folder: PlaylistFolder?
    @ViewBuilder let content: Content
    @State private var targeted = false

    var body: some View {
        content
            .padding(.bottom, 4)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.accent.opacity(targeted ? 0.12 : 0))
                    .padding(.horizontal, -6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.accent.opacity(targeted ? 0.5 : 0), lineWidth: 1.5)
                    .padding(.horizontal, -6)
            )
            .animation(.snappy(duration: 0.15), value: targeted)
            .dropDestination(for: String.self) { ids, _ in
                let dropped = ids.compactMap { id in model.myPlaylists.first { $0.id == id } }
                for playlist in dropped { model.move(playlist, to: folder) }
                return !dropped.isEmpty
            } isTargeted: { targeted = $0 }
    }
}

/// What an open folder with nothing in it says (and the drop area under folders).
struct FolderEmptyNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            )
            .padding(.leading, 22)
    }
}

/// Sends this device's changes to iCloud and fetches other devices' now,
/// rather than on the next return to the app. Spins while syncing.
struct SyncNowButton: View {
    @Environment(AppModel.self) private var model
    var compact = false

    var body: some View {
        let syncing = model.cloud.status == .syncing || model.cloud.status == .starting
        Group {
            if compact {
                Button(action: model.syncCloud) {
                    symbol(syncing)
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Theme.card))
                        .overlay(Circle().stroke(Theme.hairline))
                }
                .buttonStyle(.plain)
            } else {
                Button(action: model.syncCloud) {
                    Label { Text("Sync Now") } icon: { symbol(syncing) }
                }
                .buttonStyle(PillButtonStyle(prominent: false))
            }
        }
        .disabled(!model.cloud.canSync)
        .help("Sync My Playlists with iCloud now")
        .accessibilityLabel("Sync Now")
    }

    private func symbol(_ syncing: Bool) -> some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .symbolEffect(.rotate, options: .repeat(.continuous), isActive: syncing)
    }
}

/// Copies one of the Apple Music playlists into My Playlists.
struct CopyPlaylistMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ForEach(model.sortedPlaylists(by: .name)) { playlist in
                Button(playlist.name) { model.copyToMine(playlist) }
            }
        } label: {
            Label("Copy a Playlist", systemImage: "square.on.square")
        }
        .menuIndicator(.hidden)
        .buttonStyle(PillButtonStyle(prominent: false))
        .fixedSize()
        .disabled(model.playlists.isEmpty)
        .help("Copy an Apple Music playlist into My Playlists")
    }
}

struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var model
    let route: PlaylistItem

    init(playlist: PlaylistItem) { route = playlist }

    var body: some View {
        let playlist = model.fresh(route)
        CollectionDetailView(
            kind: "Playlist",
            title: playlist.name,
            byline: model.folder(of: playlist).map { "My Playlists › \($0.name)" } ?? playlist.curator,
            summary: playlist.summary,
            artwork: model.artwork(for: playlist),
            source: .playlist(playlist),
            showArtwork: true,
            playlist: playlist,
            load: { try await model.tracks(in: playlist) }
        )
    }
}

struct AlbumDetailView: View {
    @Environment(AppModel.self) private var model
    let album: AlbumItem

    var body: some View {
        CollectionDetailView(
            kind: ["Album", album.year].compactMap { $0 }.joined(separator: " · "),
            title: album.title,
            byline: album.artistName,
            onByline: { model.openArtist(id: album.artistID, name: album.artistName) },
            summary: nil,
            artwork: album.artwork,
            source: .album(album),
            showArtwork: false,
            load: { try await model.provider.tracks(in: album) }
        )
    }
}

/// Shared layout for anything that is a titled list of tracks.
struct CollectionDetailView: View {
    @Environment(AppModel.self) private var model
    let kind: String
    let title: String
    let byline: String?
    var onByline: (() -> Void)?
    let summary: String?
    let artwork: ArtworkSource
    let source: QueueSource
    let showArtwork: Bool
    /// The playlist this is, for managing it.
    var playlist: PlaylistItem?
    let load: () async throws -> [TrackItem]

    @State private var tracks: Loadable<[TrackItem]> = .loading
    @State private var filter = ""

    var body: some View {
        let all: [TrackItem] = if case .loaded(let t) = tracks { t } else { [] }
        #if os(iOS)
        if let playlist, model.editingPlaylistID == playlist.id {
            PlaylistSongEditor(playlist: playlist, tracks: all)
        } else {
            page(all)
        }
        #else
        page(all)
        #endif
    }

    private func page(_ all: [TrackItem]) -> some View {
        let shown = filter.isEmpty ? all : all.filter {
            $0.title.localizedCaseInsensitiveContains(filter)
                || $0.artistName.localizedCaseInsensitiveContains(filter)
                || $0.albumTitle.localizedCaseInsensitiveContains(filter)
        }

        return PageScroll {
            HStack(alignment: .bottom, spacing: 30) {
                ArtworkView(source: artwork, cornerRadius: 16, resolution: 600)
                    .frame(width: 230, height: 230)
                    .shadow(color: artwork.palette.primary.opacity(0.35), radius: 40, y: 18)

                VStack(alignment: .leading, spacing: 10) {
                    Text(kind.uppercased()).eyebrow()
                    Text(title)
                        .font(.display(46, .heavy))
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                    if let summary {
                        Text(summary).font(.system(size: 14)).foregroundStyle(Theme.secondary).lineLimit(2)
                    }
                    meta(all)
                    HStack(spacing: 10) {
                        Button { model.play(shown, shuffled: false, from: source) } label: { Label("Play", systemImage: "play.fill") }
                            .buttonStyle(PillButtonStyle())
                            .disabled(all.isEmpty)
                        Button { model.play(shown, shuffled: true, from: source) } label: { Label("Shuffle", systemImage: "shuffle") }
                            .buttonStyle(PillButtonStyle(prominent: false))
                            .disabled(all.isEmpty)
                        if let playlist, !playlist.isCadence {
                            Button { model.copyToMine(playlist) } label: { Label("Copy to My Playlists", systemImage: "square.on.square") }
                                .buttonStyle(PillButtonStyle(prominent: false))
                                .help("Make a copy in My Playlists, synced to all your devices")
                        }
                        if let playlist, model.canManage(playlist) {
                            ManagePlaylistMenu(playlist: playlist, canEditSongs: isLoaded)
                        }
                    }
                    .padding(.top, 6)
                }
            }

            // Lazy: long playlists only build the rows on screen.
            LazyVStack(spacing: 2) {
                FilterField(prompt: "Find in \(kind.lowercased().split(separator: " ").first ?? "list")", text: $filter)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.bottom, 12)
                TrackListHeader(showArtwork: showArtwork, showAlbum: showArtwork, count: shown.count)
                switch tracks {
                case .loading:
                    LoadingRows(count: 12, showArtwork: showArtwork, showAlbum: showArtwork)
                case .failed(let message):
                    EmptyNote(symbol: "exclamationmark.triangle", title: "Couldn't load tracks", message: message)
                case .loaded:
                    if shown.isEmpty {
                        EmptyNote(symbol: "magnifyingglass", title: all.isEmpty ? "No tracks" : "No matches for “\(filter)”")
                    }
                    ForEach(Array(shown.enumerated()), id: \.offset) { i, track in
                        TrackRow(track: track, number: i + 1, context: shown, showArtwork: showArtwork, showAlbum: showArtwork)
                            .environment(\.queueSource, source)
                    }
                }
            }
        }
        // Again when songs are added to it, keeping the list until they're in.
        .task(id: playlist.map(model.revision(of:)) ?? "") {
            do { tracks = .loaded(try await load()) } catch { tracks = .failed(error.localizedDescription) }
        }
    }

    private var isLoaded: Bool {
        if case .loaded = tracks { true } else { false }
    }

    private func meta(_ tracks: [TrackItem]) -> some View {
        HStack(spacing: 6) {
            if let byline {
                if let onByline {
                    Button(byline, action: onByline).buttonStyle(.plain).fontWeight(.semibold).foregroundStyle(Theme.text)
                } else {
                    Text(byline).fontWeight(.semibold).foregroundStyle(Theme.text)
                }
            }
            if !tracks.isEmpty {
                Text("\(byline == nil ? "" : "· ")\(tracks.count) songs · \(tracks.reduce(0) { $0 + $1.duration }.longForm)")
            } else if case .loading = self.tracks {
                Text("\(byline == nil ? "" : "· ")00 songs · 0 hr 00 min").skeleton()
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.secondary)
    }
}
