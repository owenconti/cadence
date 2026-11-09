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
                if case .delete = prompt {
                    Button("Delete", role: .destructive) { model.submit(prompt, name: "") }
                } else {
                    TextField("Playlist name", text: $name)
                    Button(button(prompt)) { model.submit(prompt, name: name) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { prompt in
                switch prompt {
                case .create(let track?): Text("It starts with “\(track.title)”.")
                case .createMine(let track): Text((track.map { "It starts with “\($0.title)”. " } ?? "") + "My Playlists sync through iCloud to all your devices.")
                case .delete(let playlist): Text("“\(playlist.name)” is removed from My Playlists on all your devices.")
                default: EmptyView()
                }
            }
            .onChange(of: prompt?.id) {
                if case .rename(let playlist) = model.playlistPrompt { name = playlist.name } else { name = "" }
            }
    }

    private func title(_ prompt: PlaylistPrompt?) -> String {
        switch prompt {
        case .rename: "Rename Playlist"
        case .createMine: "New Playlist in My Playlists"
        case .delete(let playlist): "Delete “\(playlist.name)”?"
        default: "New Playlist"
        }
    }

    private func button(_ prompt: PlaylistPrompt) -> String {
        if case .rename = prompt { "Rename" } else { "Create" }
    }
}

/// "New Playlist…" and the playlists a song can be added to, for its menus.
struct AddToPlaylistMenu: View {
    @Environment(AppModel.self) private var model
    let track: TrackItem
    var title = "Add to Playlist"

    var body: some View {
        Menu(title, systemImage: "text.badge.plus") {
            Button("New Playlist…", systemImage: "plus") { model.playlistPrompt = .create(with: track) }
            Button("New Playlist in My Playlists…", systemImage: "rectangle.stack.badge.plus") { model.playlistPrompt = .createMine(with: track) }
            let mine = model.addableMine
            if !mine.isEmpty {
                Section("My Playlists") {
                    ForEach(mine) { playlist in
                        Button(playlist.name) { model.add(track, to: playlist) }
                    }
                }
            }
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
}

/// Rename and Edit Songs, for a playlist Cadence made (iPhone and iPad), and
/// Delete for My Playlists. Edit Songs is iPhone and iPad only.
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
