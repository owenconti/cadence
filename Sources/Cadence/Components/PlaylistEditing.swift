import SwiftUI

extension View {
    /// Asks for a playlist's name when `model.playlistPrompt` is set (New
    /// Playlist, Rename). Attached once, at the root.
    func playlistPrompt() -> some View { modifier(PlaylistPromptHost()) }
}

private struct PlaylistPromptHost: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var name = ""

    func body(content: Content) -> some View {
        let prompt = model.playlistPrompt
        content
            .alert(Text(title(prompt)), isPresented: Binding(get: { model.playlistPrompt != nil },
                                                            set: { if !$0 { model.playlistPrompt = nil } }),
                   presenting: prompt) { prompt in
                if prompt.isDelete {
                    Button("Delete", role: .destructive) { model.submit(prompt, name: "") }
                } else {
                    TextField(prompt.isFolder ? "Folder name" : "Playlist name", text: $name)
                    Button(button(prompt)) { model.submit(prompt, name: name) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { prompt in
                switch prompt {
                case .create(let track?): Text("It starts with “\(track.title)”.")
                case .createMine(let track): Text((track.map { "It starts with “\($0.title)”. " } ?? "") + "My Playlists sync through iCloud to all your devices.")
                case .delete(let playlist): Text("“\(playlist.name)” is removed from My Playlists on all your devices.")
                case .createFolder(let playlist?): Text("“\(playlist.name)” moves into it.")
                case .deleteFolder(let folder):
                    let count = model.myPlaylists(in: folder).count
                    Text(count == 0 ? "It's empty." : "Its \(count == 1 ? "playlist stays" : "\(count) playlists stay") in My Playlists, out of any folder.")
                default: EmptyView()
                }
            }
            .onChange(of: prompt?.id) {
                switch model.playlistPrompt {
                case .rename(let playlist): name = playlist.name
                case .renameFolder(let folder): name = folder.name
                default: name = ""
                }
            }
    }

    private func title(_ prompt: PlaylistPrompt?) -> String {
        switch prompt {
        case .rename: "Rename Playlist"
        case .createMine: "New Playlist in My Playlists"
        case .delete(let playlist): "Delete “\(playlist.name)”?"
        case .createFolder: "New Folder in My Playlists"
        case .renameFolder: "Rename Folder"
        case .deleteFolder(let folder): "Delete the folder “\(folder.name)”?"
        default: "New Playlist"
        }
    }

    private func button(_ prompt: PlaylistPrompt) -> String {
        switch prompt {
        case .rename, .renameFolder: "Rename"
        default: "Create"
        }
    }
}

private extension PlaylistPrompt {
    var isDelete: Bool {
        switch self {
        case .delete, .deleteFolder: true
        default: false
        }
    }

    var isFolder: Bool {
        switch self {
        case .createFolder, .renameFolder, .deleteFolder: true
        default: false
        }
    }
}

/// My Playlists a song can be added to: those in no folder, then a submenu
/// per folder. Takes the model itself so the app's menus can use it.
struct AddToMyPlaylistsItems: View {
    let model: AppModel
    let track: TrackItem

    private func newest(in folder: PlaylistFolder) -> Date {
        model.myPlaylists(in: folder).compactMap { model.lastChange(of: $0) }.max() ?? .distantPast
    }

    var body: some View {
        // Most recently changed first, folders by their newest playlist.
        let loose = model.byLastChange(model.myPlaylists(in: nil))
        let folders = model.myFolders.filter { !model.myPlaylists(in: $0).isEmpty }.sorted { newest(in: $0) > newest(in: $1) }
        if !loose.isEmpty || !folders.isEmpty {
            Section("My Playlists") {
                ForEach(folders) { folder in
                    Menu(folder.name, systemImage: "folder") {
                        ForEach(model.byLastChange(model.myPlaylists(in: folder))) { playlist in
                            Button(playlist.name) { model.add(track, to: playlist) }
                        }
                    }
                }
                ForEach(loose) { playlist in
                    Button(playlist.name) { model.add(track, to: playlist) }
                }
            }
        }
    }
}

/// Moves one of My Playlists into a folder (a new one, too) or out of its folder.
struct MoveToFolderMenu: View {
    @Environment(AppModel.self) private var model
    let playlist: PlaylistItem

    var body: some View {
        let current = model.folder(of: playlist)
        Menu("Move to Folder", systemImage: "folder") {
            Button("New Folder…", systemImage: "folder.badge.plus") { model.playlistPrompt = .createFolder(moving: playlist) }
            if !model.myFolders.isEmpty {
                Divider()
                ForEach(model.myFolders) { folder in
                    Button(folder.name) { model.move(playlist, to: folder) }
                        .disabled(folder.id == current?.id)
                }
            }
            if let current {
                Divider()
                Button("Remove from “\(current.name)”", systemImage: "folder.badge.minus") { model.move(playlist, to: nil) }
            }
        }
    }
}

/// "New Playlist…" and the playlists a song can be added to, for its menus.
struct AddToPlaylistMenu: View {
    @Environment(AppModel.self) private var model
    let track: TrackItem
    var title = "Add to Playlist"

    var body: some View {
        Menu(title, systemImage: "text.badge.plus") { AddToPlaylistItems(track: track) }
    }
}

/// The Add to Playlist menu as a round icon button, for Now Playing.
struct AddToPlaylistButton: View {
    let track: TrackItem
    var size: CGFloat = 40

    var body: some View {
        Menu { AddToPlaylistItems(track: track) } label: {
            Image(systemName: "text.badge.plus")
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(Theme.text)
                .frame(width: size, height: size)
                .background(Circle().fill(.ultraThinMaterial))
                .contentShape(Circle())
        }
        .menuIndicator(.hidden)
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Add to Playlist")
        .accessibilityLabel("Add “\(track.title)” to a playlist")
    }
}

private struct AddToPlaylistItems: View {
    @Environment(AppModel.self) private var model
    let track: TrackItem

    var body: some View {
        Button("New Playlist…", systemImage: "plus") { model.playlistPrompt = .create(with: track) }
        Button("New Playlist in My Playlists…", systemImage: "rectangle.stack.badge.plus") { model.playlistPrompt = .createMine(with: track) }
        AddToMyPlaylistsItems(model: model, track: track)
        let playlists = model.addablePlaylists
        if !playlists.isEmpty {
            Section("Apple Music") {
                ForEach(playlists) { playlist in
                    Button(playlist.name) { model.add(track, to: playlist) }
                }
            }
        }
    }
}

/// Rename and Edit Songs, for a playlist Cadence made (iPhone and iPad), and
/// Move to Folder and Delete for My Playlists. Edit Songs is iPhone and iPad only.
struct ManagePlaylistMenu: View {
    @Environment(AppModel.self) private var model
    let playlist: PlaylistItem
    /// Edit Songs needs the songs loaded.
    let canEditSongs: Bool

    var body: some View {
        Menu {
            Button("Rename…", systemImage: "pencil") { model.playlistPrompt = .rename(playlist) }
            #if os(iOS)
            Button("Edit Songs", systemImage: "list.bullet") { model.editingPlaylistID = playlist.id }
                .disabled(!canEditSongs)
            #endif
            if playlist.isCadence {
                MoveToFolderMenu(playlist: playlist)
                Divider()
                Button("Delete Playlist…", systemImage: "trash", role: .destructive) { model.playlistPrompt = .delete(playlist) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.card))
                .overlay(Circle().stroke(Theme.hairline))
                .contentShape(Circle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Manage playlist")
    }
}

#if os(iOS)
/// Removing and reordering a playlist's songs, in place of its page: swipe
/// or tap − to remove, drag the handle to move. Nothing changes until Save.
struct PlaylistSongEditor: View {
    @Environment(AppModel.self) private var model
    let playlist: PlaylistItem
    private let original: [Row]
    @State private var rows: [Row]

    private struct Row: Identifiable, Equatable {
        /// Its place in the playlist as loaded: a song can be in it twice.
        let id: Int
        let track: TrackItem
    }

    init(playlist: PlaylistItem, tracks: [TrackItem]) {
        self.playlist = playlist
        let rows = tracks.enumerated().map { Row(id: $0.offset, track: $0.element) }
        original = rows
        _rows = State(initialValue: rows)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { model.editingPlaylistID = nil }
                Spacer()
                VStack(spacing: 2) {
                    Text("Edit Songs").font(.system(size: 16, weight: .semibold))
                    Text(playlist.name).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer()
                Button("Save") { model.saveTracks(rows.map(\.track), of: playlist) }
                    .fontWeight(.semibold)
                    .disabled(rows == original)
            }
            .font(.system(size: 16))
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }

            if rows.isEmpty {
                EmptyNote(symbol: "music.note.list", title: "No songs", message: "Save to leave the playlist empty.")
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(rows) { row in
                        HStack(spacing: 12) {
                            ArtworkView(source: row.track.artwork, cornerRadius: 5, resolution: 100)
                                .frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.track.title).font(.system(size: 15)).lineLimit(1)
                                Text(row.track.artistName).font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1)
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Theme.hairline)
                    }
                    .onDelete { rows.remove(atOffsets: $0) }
                    .onMove { rows.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(.active))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
