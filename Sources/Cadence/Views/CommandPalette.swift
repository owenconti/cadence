import SwiftUI

/// ⌘K: search the catalog and jump anywhere, all from the keyboard.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @State private var searching = false

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
                    TextField("Songs, artists, playlists, or a command…", text: $palette.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18))
                        .focused($focused)
                    if searching { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 20)
                .frame(height: 60)

                Rectangle().fill(Theme.hairline).frame(height: 1)

                results(palette)

                HStack(spacing: 16) {
                    hint("↑↓", "navigate")
                    hint("↩", "open")
                    hint("esc", "close")
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
        .onAppear { focused = true }
        .task(id: palette.query) { await rebuild() }
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
                            .onTapGesture {
                                palette.selection = i
                                palette.runSelection()
                            }
                            .onHover { if $0 { palette.selection = i } }
                    }
                    if palette.entries.isEmpty && !searching {
                        EmptyNote(symbol: "magnifyingglass", title: "No results for “\(palette.query)”")
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

    private func rebuild() async {
        let palette = model.palette
        let query = palette.query.trimmingCharacters(in: .whitespaces)
        var entries = commands.filter { $0.matches(query) }

        let playlistHits = model.playlists
            .filter { !query.isEmpty && $0.name.localizedCaseInsensitiveContains(query) }
            .prefix(4)
            .map(playlistEntry)
        entries.append(contentsOf: playlistHits)

        palette.entries = query.isEmpty ? entries + recentPlaylists : entries
        palette.selection = 0
        guard query.count >= 2 else { return }

        // Debounce so we only hit the catalog once typing pauses.
        try? await Task.sleep(for: .milliseconds(220))
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        guard let results = try? await model.provider.search(query), !Task.isCancelled else { return }

        let songs = results.songs
        entries.append(contentsOf: songs.prefix(5).map { track in
            .init(id: "song:\(track.id)", group: "Songs", title: track.title, subtitle: track.artistName, artwork: track.artwork, hint: "Play") {
                model.play(songs, startAt: songs.firstIndex(of: track) ?? 0, from: .search(query))
            }
        })
        entries.append(contentsOf: results.artists.prefix(4).map { artist in
            .init(id: "artist:\(artist.id)", group: "Artists", title: artist.name, subtitle: artist.genre, artwork: artist.artwork, circular: true) {
                model.navigate(.artist(artist))
            }
        })
        entries.append(contentsOf: results.albums.prefix(4).map { album in
            .init(id: "album:\(album.id)", group: "Albums", title: album.title, subtitle: album.artistName, artwork: album.artwork) {
                model.navigate(.album(album))
            }
        })
        let known = Set(playlistHits.map(\.id))
        entries.append(contentsOf: results.playlists.prefix(4).map(playlistEntry).filter { !known.contains($0.id) })
        palette.entries = entries
        palette.selection = min(palette.selection, max(entries.count - 1, 0))
    }

    private func playlistEntry(_ playlist: PlaylistItem) -> PaletteModel.Entry {
        .init(id: "playlist:\(playlist.id)", group: "Playlists", title: playlist.name, subtitle: playlist.curator, artwork: playlist.artwork) {
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
        if model.update.isReady {
            var ready = restart
            ready.group = "Update ready"
            list.append(ready)
        }

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
            list += [
                .init(id: "cmd:toggle", group: "Playback", title: player.isPlaying ? "Pause" : "Resume", symbol: player.isPlaying ? "pause.fill" : "play.fill", hint: "Space", keywords: "play") { player.toggle() },
                .init(id: "cmd:next", group: "Playback", title: "Next track", symbol: "forward.fill", hint: "⌘→", keywords: "skip") { player.next() },
                .init(id: "cmd:previous", group: "Playback", title: "Previous track", symbol: "backward.fill", hint: "⌘←", keywords: "back restart song") { player.previous() },
                .init(id: "cmd:shuffle", group: "Playback", title: player.isShuffled ? "Turn shuffle off" : "Turn shuffle on",
                      symbol: "shuffle", hint: "⌘S", keywords: "shuffle random order mode") { player.toggleShuffle() },
            ]
        }

        list.append(.init(id: "lib:reload", group: "Library", title: "Reload library", symbol: "arrow.triangle.2.circlepath", keywords: "refresh playlists") {
            model.reloadLibrary()
        })
        if !model.provider.isLive {
            list.append(.init(id: "lib:connect", group: "Library", title: "Connect Apple Music", symbol: "applelogo", keywords: "sign in account library") {
                model.phase = .onboarding
            })
        }
        if !model.update.isReady { list.append(restart) }
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
