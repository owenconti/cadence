import SwiftUI

/// ⌘K: search the catalog and jump anywhere, all from the keyboard.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @State private var searching = false
    /// Catalog results for the current query.
    @State private var catalog: [PaletteModel.Entry] = []

    var body: some View {
        @Bindable var palette = model.palette

        ZStack(alignment: .top) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture(perform: palette.dismiss)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                    PaletteSearchField(text: $palette.query, placeholder: palette.addingToPlaylist.map { "Add “\($0.title)” to a playlist…" }
                                       ?? "Songs, artists, playlists, or a command…")
                    if searching { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 20)
                .frame(height: 60)

                Rectangle().fill(Theme.hairline).frame(height: 1)

                results(palette)

                HStack(spacing: 16) {
                    hint("↑↓", "navigate")
                    if palette.addingToPlaylist != nil {
                        hint("↩", "add")
                    } else {
                        hint("↩", "open")
                    }
                    if palette.entries.indices.contains(palette.selection), palette.entries[palette.selection].playNext != nil {
                        hint("⌘↩", "play next")
                        hint("⌥↩", "add to queue")
                        hint("⇧↩", "add to playlist")
                    }
                    hint("esc", palette.addingToPlaylist != nil ? "back" : "close")
                    Spacer()
                }
                .padding(.horizontal, 20)
                .frame(height: 36)
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            }
            .frame(width: 640)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.ultraThickMaterial))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.1)))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 50, y: 24)
            .padding(.top, 110)
        }
        .task(id: palette.query) { await search() }
        .onChange(of: stateKey) { apply() }
    }

    private func results(_ palette: PaletteModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(palette.entries.enumerated()), id: \.element.id) { i, entry in
                        if i == 0 || palette.entries[i - 1].group != entry.group {
                            Text(entry.group.uppercased())
                                .eyebrow()
                                .padding(.horizontal, 12)
                                .padding(.top, i == 0 ? 4 : 12)
                                .padding(.bottom, 4)
                        }
                        PaletteRow(entry: entry, selected: i == palette.selection)
                            .id(entry.id)
                            .contextMenu { if let track = entry.track { TrackMenu(track: track) } }
                            .onTapGesture {
                                palette.selection = i
                                palette.runSelection()
                            }
                            .onHover { if $0 { palette.selection = i } }
                    }
                    if palette.entries.isEmpty && !searching {
                        if palette.addingToPlaylist != nil {
                            EmptyNote(symbol: "music.note.list", title: palette.query.isEmpty ? "No playlists to add to" : "No playlists match “\(palette.query)”")
                        } else {
                            EmptyNote(symbol: "magnifyingglass", title: "No results for “\(palette.query)”")
                        }
                    }
                }
                .padding(8)
            }
            .frame(height: 380)
            .onChange(of: palette.selection) { _, new in
                if palette.entries.indices.contains(new) { proxy.scrollTo(palette.entries[new].id) }
            }
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.card))
            Text(label).font(.system(size: 11))
        }
        .foregroundStyle(Theme.tertiary)
    }

    // MARK: Results

    /// What the app's own state decides: commands, the current song, your
    /// playlists. Rebuilt when any of it changes, so an open palette never
    /// offers a stale "Pause" or the previous song's album.
    private var stateKey: String {
        let player = model.player
        return [player.current?.id ?? "", "\(player.isPlaying)", "\(player.isShuffled)", "\(model.sidebarHidden)",
                "\(model.nowPlayingMode)", "\(model.stack.count)", "\(model.update.isReady)", "\(model.route)",
                "\(model.playlistSort)", "\(model.showAllPopular)", "\(model.popularSongCount)",
                "\(String(describing: model.canPlayCatalog))", "\(model.provider.isLive)", "\(model.phase)", "\(model.access)",
                model.palette.addingToPlaylist?.id ?? "", "\(model.editablePlaylistIDs.count)",
                // Names too: a renamed or replaced playlist, same count.
                model.playlists.map { "\($0.id)=\($0.name)" }.joined(separator: ","),
                model.myPlaylists.map { "\($0.id)=\($0.name)" }.joined(separator: ",")]
            .joined(separator: "|")
    }

    /// Recombines local entries with the latest catalog results, keeping the
    /// selected entry selected.
    private func apply(resetSelection: Bool = false) {
        let palette = model.palette
        let selected = palette.entries.indices.contains(palette.selection) ? palette.entries[palette.selection].id : nil
        let query = palette.query.trimmingCharacters(in: .whitespaces)
        var entries: [PaletteModel.Entry]
        if let track = palette.addingToPlaylist {
            // Typing a name no playlist has offers to make it.
            let named = query.isEmpty || model.problem(naming: query) != nil ? nil : query
            entries = [.init(id: "add:new", group: "Add “\(track.title)” to", title: named.map { "New playlist “\($0)”" } ?? "New playlist…",
                             symbol: "plus", keywords: "create make") {
                if let named { model.createPlaylist(named: named, with: track) } else { model.playlistPrompt = .create(with: track) }
            }]
            entries += model.addableMine.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.map { playlist in
                .init(id: "add:\(playlist.id)", group: "Add “\(track.title)” to", title: playlist.name,
                      subtitle: "My Playlists · \(playlist.trackCount ?? 0) songs", artwork: model.artwork(for: playlist)) {
                    model.add(track, to: playlist)
                }
            }
            entries += model.addablePlaylists.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.map { playlist in
                .init(id: "add:\(playlist.id)", group: "Add “\(track.title)” to", title: playlist.name,
                      subtitle: model.size(of: playlist).map { "\($0) songs" }, artwork: model.artwork(for: playlist)) {
                    model.add(track, to: playlist)
                }
            }
            palette.entries = entries
            palette.selection = resetSelection ? 0 : min(palette.selection, max(entries.count - 1, 0))
            return
        }
        entries = commands.filter { $0.matches(query) }
        let playlistHits = (model.myPlaylists + model.playlists)
            .filter { !query.isEmpty && $0.name.localizedCaseInsensitiveContains(query) }
            .prefix(5)
            .map(playlistEntry)
        entries += playlistHits
        // On My Playlists, typing a playlist's name offers to copy it there.
        if model.route == .myPlaylists, !query.isEmpty {
            entries += model.sortedPlaylists(by: .name, filter: query).prefix(4).map { playlist in
                .init(id: "copy:\(playlist.id)", group: "Copy to My Playlists", title: playlist.name,
                      subtitle: model.size(of: playlist).map { "\($0) songs" }, symbol: "square.on.square") { model.copyToMine(playlist) }
            }
        }
        if query.isEmpty {
            entries += recentPlaylists
        } else {
            let known = Set(entries.map(\.id))
            entries += catalog.filter { !known.contains($0.id) }
        }
        palette.entries = entries
        if resetSelection {
            palette.selection = 0
        } else {
            palette.selection = selected.flatMap { id in entries.firstIndex { $0.id == id } } ?? min(palette.selection, max(entries.count - 1, 0))
        }
    }

    private func search() async {
        let query = model.palette.query.trimmingCharacters(in: .whitespaces)
        catalog = []
        apply(resetSelection: true)
        guard query.count >= 2, model.palette.addingToPlaylist == nil else { return }

        // Debounce so we only hit the catalog once typing pauses.
        try? await Task.sleep(for: .milliseconds(220))
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        guard let results = try? await model.provider.search(query), !Task.isCancelled else { return }

        let songs = results.songs
        var found: [PaletteModel.Entry] = songs.prefix(5).enumerated().map { i, track in
            var entry = PaletteModel.Entry(id: "song:\(track.id)", group: "Songs", title: track.title, subtitle: track.artistName,
                                           artwork: track.artwork, hint: "Play") {
                model.play(songs, startAt: i, from: .search(query))
            }
            entry.playNext = { model.player.playNext(track) }
            entry.addToQueue = { model.player.addToQueue(track) }
            entry.track = track
            return entry
        }
        found += results.artists.prefix(4).map { artist in
            .init(id: "artist:\(artist.id)", group: "Artists", title: artist.name, subtitle: artist.genre, artwork: artist.artwork, circular: true) {
                model.navigate(.artist(artist))
            }
        }
        found += results.albums.prefix(4).map { album in
            .init(id: "album:\(album.id)", group: "Albums", title: album.title, subtitle: album.artistName, artwork: album.artwork) {
                model.navigate(.album(album))
            }
        }
        found += results.playlists.prefix(4).map(playlistEntry)
        catalog = found
        apply()
    }

    private func playlistEntry(_ playlist: PlaylistItem) -> PaletteModel.Entry {
        .init(id: "playlist:\(playlist.id)", group: "Playlists", title: playlist.name, subtitle: playlist.curator, artwork: model.artwork(for: playlist)) {
            model.navigate(.playlist(playlist))
        }
    }

    private var recentPlaylists: [PaletteModel.Entry] {
        model.playlists.prefix(4).map {
            var entry = playlistEntry($0)
            entry.group = "Your playlists"
            return entry
        }
    }

    /// What the open page's own buttons do.
    private var pageCommands: [PaletteModel.Entry] {
        func playing(_ item: ShelfItem, _ name: String) -> [PaletteModel.Entry] {
            [
                .init(id: "page:play", group: "This page", title: "Play “\(name)”", symbol: "play.fill", keywords: "start listen") {
                    Task { await model.play(item, shuffled: false) }
                },
                .init(id: "page:shuffle", group: "This page", title: "Shuffle “\(name)”", symbol: "shuffle", keywords: "random") {
                    Task { await model.play(item, shuffled: true) }
                },
            ]
        }
        switch model.route {
        case .playlist(let route):
            let playlist = model.fresh(route)
            var list = playing(.playlist(playlist), playlist.name)
            if playlist.isCadence {
                list.append(.init(id: "page:rename", group: "This page", title: "Rename “\(playlist.name)”…", symbol: "pencil",
                                  keywords: "name title playlist") { model.playlistPrompt = .rename(playlist) })
                list.append(.init(id: "page:delete", group: "This page", title: "Delete “\(playlist.name)”…", symbol: "trash",
                                  keywords: "remove playlist my playlists") { model.playlistPrompt = .delete(playlist) })
            } else {
                list.append(.init(id: "page:copy", group: "This page", title: "Copy “\(playlist.name)” to My Playlists", symbol: "square.on.square",
                                  keywords: "duplicate save sync icloud my playlists") { model.copyToMine(playlist) })
                if model.canManage(playlist) {
                    list.append(.init(id: "page:rename", group: "This page", title: "Rename “\(playlist.name)”…", symbol: "pencil",
                                      keywords: "name title playlist") { model.playlistPrompt = .rename(playlist) })
                }
            }
            return list

        case .album(let album):
            return playing(.album(album), album.title)
        case .playlists:
            return PlaylistSort.allCases.filter { $0 != model.playlistSort }.map { sort in
                .init(id: "page:sort:\(sort.rawValue)", group: "This page", title: "Sort playlists: \(sort.rawValue)",
                      symbol: "arrow.up.arrow.down", keywords: "order recent name alphabetical largest size") { model.playlistSort = sort }
            }
        case .artist where model.popularSongCount > 5:
            return [.init(id: "page:popular", group: "This page",
                          title: model.showAllPopular ? "Show fewer popular songs" : "Show all \(model.popularSongCount) popular songs",
                          symbol: "list.bullet", keywords: "top songs more expand") { model.showAllPopular.toggle() }]
        default:
            return []
        }
    }

    /// Everything the app can do, each shown only when it would work. Keep this
    /// in step with buttons, menu items and shortcuts (see CLAUDE.md).
    private var commands: [PaletteModel.Entry] {
        let player = model.player
        let restart = PaletteModel.Entry(
            id: "app:restart", group: "App", title: "Restart app",
            subtitle: model.update.isReady ? "Update ready: load the new build" : "Relaunch Cadence; music picks up where it was",
            symbol: "arrow.clockwise", hint: "⌥⌘R", keywords: "update reload relaunch new build"
        ) { model.restartApp() }

        var list: [PaletteModel.Entry] = []
        // The connect screen's own actions, while it's showing.
        if model.phase == .onboarding {
            switch model.access {
            case .denied:
                list.append(.init(id: "connect:settings", group: "Connect", title: "Open System Settings", subtitle: "Turn on Apple Music access for Cadence",
                                  symbol: "gearshape", keywords: "privacy permission access apple music") { model.openPrivacySettings() })
            case .failed:
                list.append(.init(id: "connect:retry", group: "Connect", title: "Try connecting again", symbol: "arrow.clockwise",
                                  keywords: "apple music retry reconnect") { model.continueWithAppleMusic() })
            case .idle:
                list.append(.init(id: "connect:apple", group: "Connect", title: "Continue with Apple Music", symbol: "applelogo",
                                  keywords: "connect sign in library") { model.continueWithAppleMusic() })
            case .connecting, .restricted:
                break
            }
            list.append(.init(id: "connect:demo", group: "Connect", title: "Explore the demo library", symbol: "sparkles",
                              keywords: "demo try offline sample") { model.startDemo() })
        }
        if model.update.isReady {
            var ready = restart
            ready.group = "Update ready"
            list.append(ready)
        }

        list += pageCommands

        list += SidebarSection.allCases.enumerated().map { i, section in
            .init(id: "go:\(section.rawValue)", group: "Go to", title: section.title, symbol: section.symbol, hint: "⌘\(i + 1)") {
                model.select(section)
            }
        }
        if !model.stack.isEmpty {
            list.append(.init(id: "go:back", group: "Go to", title: "Back", symbol: "chevron.left", hint: "⌘[") { model.back() })
        }
        if let track = player.current {
            list.append(.init(id: "go:artist", group: "Go to", title: "Current artist", subtitle: track.artistName, symbol: "person.fill") {
                model.openArtist(id: track.artistID, name: track.artistName)
            })
            if !track.albumTitle.isEmpty {
                list.append(.init(id: "go:album", group: "Go to", title: "Current album", subtitle: track.albumTitle, symbol: "square.stack") {
                    model.openAlbum(of: track)
                })
            }
            list.append(.init(id: "cmd:add-to-playlist", group: "Playback", title: "Add current song to a playlist…", subtitle: track.title,
                              symbol: "text.badge.plus", keywords: "playlist save add song track new create") {
                model.palette.choosePlaylist(for: track)
            })
            list += [
                .init(id: "cmd:toggle", group: "Playback", title: player.isPlaying ? "Pause" : "Resume", symbol: player.isPlaying ? "pause.fill" : "play.fill", hint: "Space · ⌘↩", keywords: "play") { player.toggle() },
                .init(id: "cmd:next", group: "Playback", title: "Next track", symbol: "forward.fill", hint: "⌘→", keywords: "skip") { player.next() },
                .init(id: "cmd:previous", group: "Playback", title: "Previous track", symbol: "backward.fill", hint: "⌘←", keywords: "back restart song") { player.previous() },
            ]
        }
        // Like the Playback menu: shuffle is a mode, set even with nothing playing.
        list.append(.init(id: "cmd:shuffle", group: "Playback", title: player.isShuffled ? "Turn shuffle off" : "Turn shuffle on",
                          symbol: "shuffle", hint: "⌘S", keywords: "shuffle random order mode") { player.toggleShuffle() })

        list.append(.init(id: "view:sidebar", group: "View", title: model.sidebarHidden ? "Show sidebar" : "Hide sidebar",
                          symbol: "sidebar.left", hint: "⌘B", keywords: "toggle sidebar panel collapse") { model.toggleSidebar() })
        if player.current != nil {
            list.append(.init(id: "view:nowplaying", group: "View", title: model.nowPlayingMode ? "Leave Now Playing" : "Now Playing",
                              subtitle: model.nowPlayingMode ? nil : "Fill the window with what's playing",
                              symbol: "arrow.up.left.and.arrow.down.right", hint: "⇧⌘F",
                              keywords: "full player fullscreen mode big artwork") { model.toggleNowPlayingMode() })
        }
        list.append(.init(id: "view:close", group: "View", title: "Close window", subtitle: "Cadence keeps running and playing",
                          symbol: "xmark.square", hint: "⌘W", keywords: "hide background keep playing") {
            // After the palette has gone, so the window it's in is the one closed.
            DispatchQueue.main.async { NSApp.appWindow?.performClose(nil) }
        })
        list.append(.init(id: "view:widths", group: "View", title: "Reset panel widths", subtitle: "Sidebar and Now panel back to their usual size",
                          symbol: "rectangle.split.3x1", keywords: "resize sidebar now panel width default") { model.resetPanelWidths() })

        if model.phase == .ready {
            list.append(.init(id: "lib:new-playlist", group: "Library", title: "New playlist…", symbol: "plus", hint: "⌘N",
                              keywords: "create make add playlist apple music") { model.playlistPrompt = .create(with: nil) })
            list.append(.init(id: "lib:new-mine", group: "Library", title: "New playlist in My Playlists…", symbol: "rectangle.stack.badge.plus",
                              hint: "⇧⌘N", keywords: "create make add playlist icloud sync mine") { model.playlistPrompt = .createMine(with: nil) })
        }
        list.append(.init(id: "lib:reload", group: "Library", title: "Reload library", symbol: "arrow.triangle.2.circlepath", keywords: "refresh playlists") {
            model.reloadLibrary()
        })
        if model.provider.isLive, model.canPlayCatalog == false {
            list.append(.init(id: "lib:subscribe", group: "Library", title: "Subscribe to Apple Music", subtitle: "Playback needs a subscription",
                              symbol: "music.note", keywords: "subscription plan buy") { model.openSubscribePage() })
        }
        if !model.provider.isLive {
            list.append(.init(id: "lib:connect", group: "Library", title: "Connect Apple Music", symbol: "applelogo", keywords: "sign in account library") {
                model.phase = .onboarding
            })
        }
        if !model.update.isReady { list.append(restart) }
        if let updater = Updater.shared {
            list.append(.init(id: "app:check-updates", group: "App", title: "Check for updates",
                              subtitle: "Cadence \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")",
                              symbol: "arrow.down.circle", keywords: "update new version release sparkle") { updater.checkNow() })
        }
        return list
    }
}

private struct PaletteRow: View {
    let entry: PaletteModel.Entry
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let artwork = entry.artwork {
                ArtworkView(source: artwork, cornerRadius: 5, circular: entry.circular, resolution: 80)
                    .frame(width: 32, height: 32)
            } else if let symbol = entry.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? Theme.accent : Theme.secondary)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.system(size: 13.5, weight: .medium))
                if let subtitle = entry.subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
            .lineLimit(1)
            Spacer()
            if let hint = entry.hint {
                Text(hint).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Color.white.opacity(0.1) : .clear))
        .contentShape(Rectangle())
    }
}

/// The palette's search field. An AppKit field that takes keyboard focus as
/// soon as it's in the window, so typing goes straight into it; SwiftUI's
/// focus request on appear doesn't reliably land on macOS.
private struct PaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeNSView(context: Context) -> FocusingTextField {
        let field = FocusingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18)
        field.textColor = .white
        setPlaceholder(on: field)
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: FocusingTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderAttributedString?.string != placeholder { setPlaceholder(on: field) }
    }

    private func setPlaceholder(on field: NSTextField) {
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.white.withAlphaComponent(0.36),
        ])
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

final class FocusingTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.makeFirstResponder(self)
        // Again once SwiftUI has finished placing it.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window, !(window.firstResponder is NSTextView) else { return }
            window.makeFirstResponder(self)
        }
    }
}
