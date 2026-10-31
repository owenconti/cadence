import AppKit
import MusicKit
import Observation
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
    let update = AppUpdate()
    /// What's playing, on disk so it survives quitting, crashes and restarts.
    @ObservationIgnored private let playbackStore = PlaybackStore()
    @ObservationIgnored private var saveTimer: Timer?
    /// Media keys and Control Center; only the user's own copy takes them.
    @ObservationIgnored private var nowPlaying: NowPlaying?

    var section: SidebarSection = .discover
    private(set) var stack: [Route] = []
    var playlists: [PlaylistItem] = []
    /// Discover's feed, loaded behind the splash and kept until the library reloads.
    var discoverFeed: DiscoverFeed?
    var access: AccessState = .idle
    /// Nil until known; only meaningful when connected to Apple Music.
    var canPlayCatalog: Bool?

    @ObservationIgnored private var keyMonitor: Any?
    /// Playback and place carried over from the copy that restarted into this one.
    @ObservationIgnored private var handoff: Handoff?
    @ObservationIgnored private var preloading = false
    private static let sourceKey = "cadence.source"

    var route: Route { stack.last ?? section.route }

    init() {
        installKeyMonitor()
        CheckHooks.install(self)
        // The snapshot tour moves between screens itself.
        if RunMode.current == .normal { nowPlaying = NowPlaying(player: player) }
        guard RunMode.current != .snapshots else {
            phase = .onboarding
            return
        }
        handoff = Handoff.take()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.savePlayback() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.savePlayback(force: true) }
        }
        if let frame = handoff?.windowFrame {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.windows.first { $0.isVisible }?.setFrame(frame, display: true)
            }
        }
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
        Task {
            let started = Date()
            phase = .launching
            launchStatus = "Loading the demo library…"
            await load(DemoProvider(), backend: .demo, status: launchStatus)
            UserDefaults.standard.set("demo", forKey: Self.sourceKey)
            await reveal(.ready, since: started)
        }
    }

    /// Connects to Apple Music and loads the library. Returns whether the app
    /// can be shown; otherwise `access` says why not.
    private func connectAppleMusic() async -> Bool {
        access = .connecting
        launchStatus = "Connecting to Apple Music…"

        switch await MusicAuthorization.request() {
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
            access = .failed(error.localizedDescription)
            return false
        }

        access = .idle
        phase = .launching
        await load(provider, backend: .musicKit, playlists: playlists)
        UserDefaults.standard.set("musicKit", forKey: Self.sourceKey)
        Task { await watchSubscription() }
        return true
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media")!)
    }

    func openSubscribePage() {
        NSWorkspace.shared.open(URL(string: "https://www.apple.com/apple-music/")!)
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
        self.provider = provider
        providerGeneration += 1
        discoverFeed = nil
        stack = []
        section = .discover
        let handoff = self.handoff
        self.handoff = nil
        if let section = handoff.flatMap({ SidebarSection(rawValue: $0.section) }) { self.section = section }
        Task { await restorePlayback(keepPlaying: handoff?.keepPlaying ?? false) }

        preloading = true
        Task {
            async let feed = try? await provider.discover()
            if let playlists {
                self.playlists = playlists
            } else {
                self.playlists = (try? await provider.playlists()) ?? []
            }
            if self.discoverFeed == nil { self.discoverFeed = await feed }
            self.preloading = false
        }
        let deadline = Date().addingTimeInterval(8)
        while preloading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Reloads every page from the library, keeping where you are.
    func reloadLibrary() {
        discoverFeed = nil
        providerGeneration += 1
        Task { await refreshPlaylists() }
    }

    // MARK: Restart

    /// Relaunches into the build on disk (newer, if `update.isReady`), carrying
    /// the queue and position across so music resumes after a brief pause.
    func restartApp() {
        savePlayback(force: true)
        update.relaunch(saving: Handoff(
            section: section.rawValue,
            windowFrame: NSApp.windows.first { $0.isVisible }?.frame,
            keepPlaying: player.isPlaying
        ))
    }

    func savePlayback(force: Bool = false) {
        guard RunMode.current != .snapshots else { return }
        playbackStore.save(player, force: force)
    }

    /// Brings back what was playing when the app last ran: paused on a normal
    /// launch, still playing after Restart app.
    private func restorePlayback(keepPlaying: Bool) async {
        let provider = self.provider
        guard RunMode.current != .snapshots,
              let saved = await playbackStore.load(lookup: { ids in (try? await provider.tracks(withIDs: ids)) ?? [] }),
              saved.position.live == provider.isLive,
              let start = saved.tracks.firstIndex(where: { $0.id == saved.position.trackID }) else { return }
        let playing = keepPlaying && saved.position.isPlaying
        let elapsed = playing ? Date().timeIntervalSince(saved.position.savedAt) : 0
        let byID = Dictionary(saved.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let unshuffled = saved.position.unshuffledIDs?.compactMap { byID[$0] }
        player.resume(saved.tracks, at: start, position: saved.position.position + elapsed, playing: playing,
                      shuffled: saved.position.shuffled ?? false, unshuffled: unshuffled)
    }

    func refreshPlaylists() async {
        playlists = (try? await provider.playlists()) ?? []
    }

    // MARK: Navigation

    func select(_ section: SidebarSection) {
        self.section = section
        stack = []
    }

    func navigate(_ route: Route) {
        guard route != self.route else { return }
        stack.append(route)
    }

    func back() {
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

    func play(_ tracks: [TrackItem], startAt index: Int = 0, shuffled: Bool? = nil) {
        player.play(tracks, startAt: index, shuffled: shuffled)
    }

    func play(_ item: ShelfItem, shuffled: Bool? = false) async {
        let tracks: [TrackItem]? = switch item {
        case .album(let album): try? await provider.tracks(in: album)
        case .playlist(let playlist): try? await provider.tracks(in: playlist)
        }
        if let tracks { play(tracks, shuffled: shuffled) }
    }

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
            case 36, 76: palette.runSelection(); return true
            case 53: palette.dismiss(); return true
            default: return false
            }
        }
        let editingText = NSApp.keyWindow?.firstResponder is NSTextView
        if event.keyCode == 49, modifiers.isEmpty, !editingText, phase == .ready {
            player.toggle()
            return true
        }
        return false
    }
}
