#if os(macOS)
import AppKit
#else
import UIKit
#endif
import MusicKit
import Observation
import os
import SwiftUI

enum AccessState: Equatable {
    case idle
    case connecting
    /// The user said no to the macOS prompt; only System Settings can undo it.
    case denied
    /// Blocked by Screen Time or a device management profile.
    case restricted
    case failed(String)
}

@MainActor
@Observable
final class AppModel {
    enum Phase { case launching, onboarding, ready }

    var phase: Phase = .launching
    /// What the splash says while launching.
    private(set) var launchStatus = "Starting…"
    private(set) var provider: any MusicProvider = DemoProvider()
    /// Bumped whenever the provider changes so views reload their data.
    private(set) var providerGeneration = 0
    let player = Player()
    let palette = PaletteModel()
    #if os(macOS)
    let update = AppUpdate()
    /// The playing song's BPM, from its preview clip; shown in the Now panel.
    let tempo = TempoStore()
    #endif
    /// What's playing, on disk so it survives quitting, crashes and restarts.
    @ObservationIgnored private let playbackStore = PlaybackStore()
    @ObservationIgnored private var saveTimer: Timer?
    /// Media keys and Control Center; only the user's own copy takes them.
    @ObservationIgnored private var nowPlaying: NowPlaying?

    var section: SidebarSection = .discover
    /// The Playlists page's sort, here so ⌘K can set it too.
    var playlistSort: PlaylistSort = .recent
    /// The open artist page shows all its popular songs, not just five.
    var showAllPopular = false
    /// How many popular songs the open artist page has (0 until loaded).
    var popularSongCount = 0
    /// ⌘B. Kept across launches.
    var sidebarHidden = UserDefaults.standard.bool(forKey: AppModel.sidebarHiddenKey) {
        didSet { UserDefaults.standard.set(sidebarHidden, forKey: Self.sidebarHiddenKey) }
    }
    /// Panel widths, dragged by their inner edges. Kept across launches.
    var sidebarWidth = AppModel.savedWidth(AppModel.sidebarWidthKey, default: 232) {
        didSet { UserDefaults.standard.set(Double(sidebarWidth), forKey: Self.sidebarWidthKey) }
    }
    var nowPanelWidth = AppModel.savedWidth(AppModel.nowPanelWidthKey, default: 340) {
        didSet { UserDefaults.standard.set(Double(nowPanelWidth), forKey: Self.nowPanelWidthKey) }
    }
    /// The full-window Now Playing view (⌘⇧F); only while something plays.
    var nowPlayingMode = false
    private(set) var stack: [Route] = []
    var playlists: [PlaylistItem] = []
    /// False until the current source's playlists have arrived.
    private(set) var playlistsLoaded = false
    /// Song counts by playlist ID. Apple Music doesn't include them, so
    /// they're counted in the background and kept for the next launch.
    private(set) var playlistSizes = UserDefaults.standard.dictionary(forKey: AppModel.sizesKey) as? [String: Int] ?? [:]
    /// When each playlist was last played from Cadence. Apple Music gives
    /// library playlists no dates.
    private(set) var playlistPlayedAt = UserDefaults.standard.dictionary(forKey: AppModel.playedKey) as? [String: Date] ?? [:]
    /// Names of playlists Apple Music lists as recently played, newest first.
    private(set) var recentPlaylistNames: [String] = []
    /// Covers made from each playlist's songs (`ArtworkSource.mosaic`), by
    /// playlist ID; built with the song counts, once a launch.
    private(set) var playlistMosaics: [String: ArtworkSource] = [:]
    /// Playlists whose songs couldn't be counted; Largest puts them last.
    private(set) var uncountedPlaylists: Set<String> = []
    @ObservationIgnored private var countTask: Task<Void, Never>?
    @ObservationIgnored private var countedSizes = false
    /// Discover's feed, loaded behind the splash and kept until the library reloads.
    var discoverFeed: DiscoverFeed?
    var access: AccessState = .idle
    /// Nil until known; only meaningful when connected to Apple Music.
    var canPlayCatalog: Bool?

    #if os(macOS)
    @ObservationIgnored private var keyMonitor: Any?
    /// Playback and place carried over from the copy that restarted into this one.
    @ObservationIgnored private var handoff: Handoff?
    #endif
    @ObservationIgnored private var preloading = false
    /// Bumped by every switch of library (connecting, the demo), so a slow
    /// one finishing late can't undo a newer choice.
    @ObservationIgnored private var sourceGeneration = 0
    /// Counts moves between pages, so a slow lookup can tell it's been passed by.
    @ObservationIgnored private var navigationMoves = 0
    /// Counts playlist refreshes; only the latest one's result is used.
    @ObservationIgnored private var playlistRefreshes = 0
    private static let sourceKey = "cadence.source"
    private static let sizesKey = "cadence.playlistSizes"
    private static let sidebarHiddenKey = "cadence.sidebarHidden"
    private static let sidebarWidthKey = "cadence.sidebarWidth"
    private static let nowPanelWidthKey = "cadence.nowPanelWidth"

    private static func savedWidth(_ key: String, default value: CGFloat) -> CGFloat {
        let saved = UserDefaults.standard.double(forKey: key)
        return saved > 0 ? saved : value
    }
    private static let playedKey = "cadence.playlistPlayedAt"
    private static let log = Logger(subsystem: "com.owenconti.cadence", category: "app")

    var route: Route { stack.last ?? section.route }

    init() {
        #if os(macOS)
        if ArtworkAudit.runIfRequested() { return }
        installKeyMonitor()
        CheckHooks.install(self)
        #endif
        // The snapshot tour moves between screens itself.
        if RunMode.current == .normal { nowPlaying = NowPlaying(player: player) }
        guard RunMode.current != .snapshots else {
            phase = .onboarding
            return
        }
        saveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                _ = self.savePlayback()
                #if os(macOS)
                if let track = self.player.current { self.tempo.measure(track) }
                #endif
            }
        }
        #if os(macOS)
        handoff = Handoff.take()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.savePlayback(force: true) }
        }
        if let frame = handoff?.windowFrame {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.appWindow?.setFrame(frame, display: true)
            }
        }
        #else
        // iOS suspends a backgrounded app without warning, so save on the way out.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.savePlayback(force: true) }
        }
        #endif
        // Check copies stay on the demo library, away from the user's music.
        if RunMode.current == .check {
            startDemo()
            return
        }
        Task { await launch() }
    }

    // MARK: Launch

    /// Behind the splash: check access, connect and preload, then show the app,
    /// or the connect screen when Apple Music isn't available yet.
    private func launch() async {
        let started = Date()
        var ready = false
        switch MusicAuthorization.currentStatus {
        case .authorized:
            // Apple Music always uses the Apple ID signed into macOS, so once
            // access has been granted there's nothing to ask.
            ready = await connectAppleMusic()
        case .denied:
            access = .denied
        case .restricted:
            access = .restricted
        default:
            if UserDefaults.standard.string(forKey: Self.sourceKey) == "demo" {
                await load(DemoProvider(), backend: .demo)
                ready = true
            }
        }
        await reveal(ready ? .ready : .onboarding, since: started)
    }

    /// Leaves the splash, after long enough that it reads as a splash rather
    /// than a flicker.
    private func reveal(_ next: Phase, since started: Date) async {
        let shown = Date().timeIntervalSince(started)
        if shown < 0.8 { try? await Task.sleep(for: .seconds(0.8 - shown)) }
        phase = next
    }

    // MARK: Source

    /// The connect screen's button: asks for access (macOS only prompts the
    /// first time), then loads the library behind the splash.
    func continueWithAppleMusic() {
        Task {
            let started = Date()
            if await connectAppleMusic() { await reveal(.ready, since: started) }
        }
    }

    func startDemo() {
        sourceGeneration += 1
        // A connection under way is abandoned; the connect screen starts fresh.
        access = .idle
        let generation = sourceGeneration
        Task {
            let started = Date()
            phase = .launching
            launchStatus = "Loading the demo library…"
            await load(DemoProvider(), backend: .demo, status: launchStatus)
            guard generation == sourceGeneration else { return }
            UserDefaults.standard.set("demo", forKey: Self.sourceKey)
            await reveal(.ready, since: started)
        }
    }

    /// Connects to Apple Music and loads the library. Returns whether the app
    /// can be shown; otherwise `access` says why not.
    private func connectAppleMusic() async -> Bool {
        sourceGeneration += 1
        let generation = sourceGeneration
        access = .connecting
        launchStatus = "Connecting to Apple Music…"

        let status = await MusicAuthorization.request()
        guard generation == sourceGeneration else { return false }
        switch status {
        case .authorized: break
        case .denied:
            access = .denied
            return false
        case .restricted:
            access = .restricted
            return false
        default:
            access = .idle
            return false
        }

        let provider = MusicKitProvider()
        let playlists: [PlaylistItem]
        do {
            playlists = try await provider.playlists()
        } catch {
            if generation == sourceGeneration { access = .failed(error.localizedDescription) }
            return false
        }
        guard generation == sourceGeneration else { return false }

        access = .idle
        phase = .launching
        await load(provider, backend: .musicKit, playlists: playlists)
        guard generation == sourceGeneration else { return false }
        UserDefaults.standard.set("musicKit", forKey: Self.sourceKey)
        Task { await watchSubscription() }
        return true
    }

    func openPrivacySettings() {
        #if os(macOS)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media")!)
        #else
        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
        #endif
    }

    func openSubscribePage() {
        let url = URL(string: "https://www.apple.com/apple-music/")!
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    private func watchSubscription() async {
        for await subscription in MusicSubscription.subscriptionUpdates {
            canPlayCatalog = subscription.canPlayCatalogContent
        }
    }

    /// Switches to `provider` and loads what the first screen needs, so the app
    /// opens filled in. Stops waiting after a few seconds on a slow connection;
    /// whatever is still loading fills in once the app is showing.
    private func load(_ provider: any MusicProvider, backend: Player.Backend, playlists: [PlaylistItem]? = nil,
                      status: String = "Loading your library…") async {
        launchStatus = status
        player.stop()
        canPlayCatalog = nil
        player.backend = backend
        resetPlaylistCounts()
        self.provider = provider
        providerGeneration += 1
        discoverFeed = nil
        stack = []
        section = .discover
        #if os(macOS)
        let handoff = self.handoff
        self.handoff = nil
        if let section = handoff.flatMap({ SidebarSection(rawValue: $0.section) }) { self.section = section }
        let keepPlaying = handoff?.keepPlaying ?? false
        #else
        let keepPlaying = false
        #endif
        Task { await restorePlayback(keepPlaying: keepPlaying) }

        if playlists == nil {
            self.playlists = []
            playlistsLoaded = false
        }
        preloading = true
        Task {
            async let feed = try? await provider.discover()
            let loaded: [PlaylistItem]
            if let playlists {
                loaded = playlists
            } else {
                loaded = (try? await provider.playlists()) ?? []
            }
            // Another library took over while this one loaded.
            guard self.provider === provider else { return }
            self.playlists = loaded
            self.playlistsLoaded = true
            let feedValue = await feed
            guard self.provider === provider else { return }
            if self.discoverFeed == nil { self.discoverFeed = feedValue }
            self.preloading = false
            await self.loadPlaylistOrder()
        }
        let deadline = Date().addingTimeInterval(8)
        while preloading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Discover's feed, if it isn't loaded. Dropped if the library changed or
    /// was reloaded meanwhile (a newer load is on its way).
    func loadDiscover() async throws {
        let generation = providerGeneration, provider = self.provider
        let feed = try await provider.discover()
        guard !Task.isCancelled, generation == providerGeneration, provider === self.provider else { return }
        discoverFeed = feed
    }

    /// Reloads every page from the library, keeping where you are.
    func reloadLibrary() {
        discoverFeed = nil
        providerGeneration += 1
        Task { await refreshPlaylists(recount: true) }
    }

    #if os(macOS)
    // MARK: Restart

    /// Relaunches into the build on disk (newer, if `update.isReady`), carrying
    /// the queue and position across so music resumes after a brief pause.
    func restartApp() {
        // Restarting without what's playing on disk would lose it.
        guard savePlayback(force: true) || player.current == nil else {
            player.report("Couldn't save what's playing, so Cadence didn't restart. Check there's space on the disk.")
            return
        }
        update.relaunch(saving: Handoff(
            section: section.rawValue,
            windowFrame: NSApp.appWindow?.frame,
            keepPlaying: player.isPlaying
        ))
    }

    #endif

    @discardableResult
    func savePlayback(force: Bool = false) -> Bool {
        guard RunMode.current != .snapshots else { return true }
        return playbackStore.save(player, force: force)
    }

    /// Brings back what was playing when the app last ran: paused on a normal
    /// launch, still playing after Restart app.
    private func restorePlayback(keepPlaying: Bool) async {
        let provider = self.provider
        // Anything played meanwhile wins over what was saved.
        let revision = player.revision
        guard RunMode.current != .snapshots,
              let saved = await playbackStore.load(lookup: { ids in (try? await provider.tracks(withIDs: ids)) ?? [] }),
              self.provider === provider, player.revision == revision,
              saved.position.live == provider.isLive,
              let start = saved.position.index.flatMap({ saved.tracks.indices.contains($0) && saved.tracks[$0].id == saved.position.trackID ? $0 : nil })
                ?? saved.tracks.firstIndex(where: { $0.id == saved.position.trackID }) else { return }
        let playing = keepPlaying && saved.position.isPlaying
        let elapsed = playing ? Date().timeIntervalSince(saved.position.savedAt) : 0
        let byID = Dictionary(saved.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let unshuffled = saved.position.unshuffledIDs?.compactMap { byID[$0] }
        player.resume(saved.tracks, at: start, position: saved.position.position + elapsed, playing: playing,
                      shuffled: saved.position.shuffled ?? false, unshuffledPositions: saved.position.unshuffledPositions,
                      unshuffled: unshuffled, from: saved.position.source)
        // Library artwork is a handle that only works in the session that
        // fetched it, so restored songs need theirs fetched again. The playing
        // song and what's next come first.
        guard let live = provider as? MusicKitProvider else { return }
        let ids = saved.tracks.map(\.id)
        let first = Array(ids[start...].prefix(12)) + ids[..<start].suffix(1)
        let rest = ids.filter { !first.contains($0) }
        var refreshed = 0
        for batch in [first, rest] {
            let artwork = await live.freshArtwork(for: batch)
            guard self.provider === provider else { return }
            player.refreshArtwork(artwork)
            refreshed += artwork.count
        }
        Self.log.info("refreshed artwork for \(refreshed, privacy: .public) of \(ids.count, privacy: .public) restored songs")
    }

    func refreshPlaylists(recount: Bool = false) async {
        let provider = self.provider
        playlistRefreshes += 1
        let refresh = playlistRefreshes
        if let fresh = try? await provider.playlists(), self.provider === provider, refresh == playlistRefreshes {
            playlists = fresh
            playlistsLoaded = true
        }
        await loadPlaylistOrder(recount: recount)
    }

    /// What the Recent and Largest sorts need.
    private func loadPlaylistOrder(recount: Bool = false) async {
        let provider = self.provider
        let names = await provider.recentlyPlayedPlaylistNames()
        guard self.provider === provider else { return }
        recentPlaylistNames = names
        countPlaylistSizes(recount: recount)
    }

    /// The Playlists page's order.
    func sortedPlaylists(by sort: PlaylistSort, filter: String = "") -> [PlaylistItem] {
        let filtered = filter.isEmpty ? playlists : playlists.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        let byName = filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        switch sort {
        case .recent:
            // Played in Cadence (newest first), then what Apple Music lists as
            // recently played, then the library's own order.
            func rank(_ p: PlaylistItem) -> (Date, Int) {
                (playlistPlayedAt[p.id] ?? .distantPast, recentPlaylistNames.firstIndex(of: p.name) ?? recentPlaylistNames.count)
            }
            return filtered.enumerated().sorted { a, b in
                let (ra, rb) = (rank(a.element), rank(b.element))
                if ra.0 != rb.0 { return ra.0 > rb.0 }
                if ra.1 != rb.1 { return ra.1 < rb.1 }
                return a.offset < b.offset
            }.map(\.element)
        case .name:
            return byName
        case .size:
            // Biggest first; any still being counted go last.
            return byName.enumerated().sorted { a, b in
                let (sa, sb) = (size(of: a.element) ?? -1, size(of: b.element) ?? -1)
                return sa != sb ? sa > sb : a.offset < b.offset
            }.map(\.element)
        }
    }

    /// A library playlist's cover: a grid of its songs' covers once they've
    /// loaded, its own artwork until then.
    func artwork(for playlist: PlaylistItem) -> ArtworkSource {
        playlistMosaics[playlist.id] ?? playlist.artwork
    }

    func size(of playlist: PlaylistItem) -> Int? {
        playlist.trackCount ?? playlistSizes[playlist.id]
    }

    /// Loads each playlist's songs, a few at a time, for what the playlist
    /// doesn't say itself: its song count (for Largest and the cards) and its
    /// cover grid. Everything the first time a launch and on `recount`
    /// (Reload library); otherwise only what's missing, which retries failures.
    private func countPlaylistSizes(recount: Bool = false) {
        let everything = recount || !countedSizes
        let pending = playlists.filter {
            everything || playlistMosaics[$0.id] == nil || ($0.trackCount == nil && playlistSizes[$0.id] == nil)
        }
        guard !pending.isEmpty else { return }
        // One count at a time; a recount replaces one under way.
        if countTask != nil, !recount { return }
        countTask?.cancel()
        let provider = self.provider
        uncountedPlaylists.subtract(pending.map(\.id))
        countTask = Task {
            var queue = pending[...]
            await withTaskGroup(of: (PlaylistItem, [TrackItem]?).self) { group in
                func next() {
                    guard let playlist = queue.popFirst() else { return }
                    group.addTask { @MainActor in (playlist, try? await provider.tracks(in: playlist)) }
                }
                for _ in 0..<4 { next() }
                for await (playlist, tracks) in group {
                    let id = playlist.id
                    guard !Task.isCancelled, provider === self.provider else { continue }
                    if let tracks {
                        if let mosaic = ArtworkSource.mosaic(of: tracks) { playlistMosaics[id] = mosaic }
                        if playlist.trackCount == nil { playlistSizes[id] = tracks.count }
                    } else if playlist.trackCount == nil {
                        // An old count may no longer be right; without one it
                        // sorts last and is tried again next time.
                        playlistSizes[id] = nil
                        uncountedPlaylists.insert(id)
                    }
                    next()
                }
            }
            guard !Task.isCancelled, provider === self.provider else { return }
            countedSizes = true
            countTask = nil
            UserDefaults.standard.set(playlistSizes, forKey: Self.sizesKey)
        }
    }

    /// Stops counting for a library that's being replaced.
    private func resetPlaylistCounts() {
        countTask?.cancel()
        countTask = nil
        countedSizes = false
        uncountedPlaylists = []
        playlistMosaics = [:]
    }

    // MARK: Layout

    /// What belongs to the page being left.
    private func leavePage() {
        showAllPopular = false
        popularSongCount = 0
    }

    func resetPanelWidths() {
        sidebarWidth = 232
        nowPanelWidth = 340
    }

    func toggleSidebar() {
        sidebarHidden.toggle()
    }

    func toggleNowPlayingMode() {
        nowPlayingMode = !nowPlayingMode && player.current != nil
    }

    // MARK: Navigation

    func select(_ section: SidebarSection) {
        navigationMoves += 1
        leavePage()
        self.section = section
        stack = []
        nowPlayingMode = false
    }

    func navigate(_ route: Route) {
        navigationMoves += 1
        if route != self.route { leavePage() }
        nowPlayingMode = false
        guard route != self.route else { return }
        stack.append(route)
    }

    func back() {
        navigationMoves += 1
        leavePage()
        _ = stack.popLast()
    }

    func open(_ item: ShelfItem) {
        switch item {
        case .album(let album): navigate(.album(album))
        case .playlist(let playlist): navigate(.playlist(playlist))
        }
    }

    func openArtist(id: String?, name: String) {
        navigate(.artist(ArtistItem(id: id ?? "name:\(name)", name: name, genre: nil, artwork: .none)))
    }

    // MARK: Playback helpers

    func play(_ tracks: [TrackItem], startAt index: Int = 0, shuffled: Bool? = nil, from source: QueueSource? = nil) {
        player.play(tracks, startAt: index, shuffled: shuffled, from: source)
        if let source, source.kind == .playlist, let id = source.id {
            playlistPlayedAt[id] = Date()
            UserDefaults.standard.set(playlistPlayedAt, forKey: Self.playedKey)
        }
    }

    /// Loads an album or playlist and plays it, unless something else was
    /// played (or another one asked for) while it loaded.
    func play(_ item: ShelfItem, shuffled: Bool? = false) async {
        // Claimed now, while loading: a restore finishing meanwhile gives way.
        let claim = player.claim(), provider = self.provider
        let tracks: [TrackItem]?, source: QueueSource
        switch item {
        case .album(let album):
            tracks = try? await provider.tracks(in: album)
            source = .album(album)
        case .playlist(let playlist):
            tracks = try? await provider.tracks(in: playlist)
            source = .playlist(playlist)
        }
        guard let tracks, player.stillCurrent(claim), provider === self.provider else { return }
        play(tracks, shuffled: shuffled, from: source)
    }

    /// Opens the album a song is on.
    func openAlbum(of track: TrackItem) {
        let moves = navigationMoves, provider = self.provider
        Task {
            // Not if you've gone somewhere else while it was being looked up.
            guard let album = await provider.album(for: track), moves == navigationMoves, provider === self.provider else { return }
            navigate(.album(album))
        }
    }

    /// Opens the page for where the music is playing from.
    func open(_ source: QueueSource) {
        switch source.kind {
        case .playlist:
            if let route = source.route {
                navigate(route)
            } else if let playlist = playlists.first(where: { $0.id == source.id }) {
                navigate(.playlist(playlist))
            }
        case .artist:
            if let route = source.route { navigate(route) } else { openArtist(id: source.id, name: source.title) }
        case .album:
            if let route = source.route { navigate(route) }
        case .trending:
            select(.discover)
        case .search:
            palette.present()
            palette.query = source.title.trimmingCharacters(in: CharacterSet(charactersIn: "“”"))
        }
    }

    #if os(macOS)
    // MARK: Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors are always called on the main thread.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        if palette.isPresented {
            switch event.keyCode {
            case 125: palette.move(1); return true
            case 126: palette.move(-1); return true
            case 36, 76:
                // ⌘↩ and ⌥↩ queue a selected song; on anything else they're
                // left to the menus (⌘↩ is Play/Pause).
                let entry = palette.entries.indices.contains(palette.selection) ? palette.entries[palette.selection] : nil
                switch modifiers {
                case []: palette.runSelection()
                case .command where entry?.playNext != nil: palette.runSelection(.playNext)
                case .option where entry?.addToQueue != nil: palette.runSelection(.addToQueue)
                case .option: palette.runSelection()
                default: return false
                }
                return true
            case 53: palette.dismiss(); return true
            default: return false
            }
        }
        if nowPlayingMode, event.keyCode == 53 {
            nowPlayingMode = false
            return true
        }
        let editingText = NSApp.keyWindow?.firstResponder is NSTextView
        if event.keyCode == 49, modifiers.isEmpty, !editingText, phase == .ready {
            player.toggle()
            return true
        }
        return false
    }
    #endif
}
