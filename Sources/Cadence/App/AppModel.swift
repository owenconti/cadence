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
    enum Phase { case onboarding, ready }

    var phase: Phase = .onboarding
    private(set) var provider: any MusicProvider = DemoProvider()
    /// Bumped whenever the provider changes so views reload their data.
    private(set) var providerGeneration = 0
    let player = Player()
    let palette = PaletteModel()

    var section: SidebarSection = .discover
    private(set) var stack: [Route] = []
    var playlists: [PlaylistItem] = []
    var access: AccessState = .idle
    /// Nil until known; only meaningful when connected to Apple Music.
    var canPlayCatalog: Bool?

    @ObservationIgnored private var keyMonitor: Any?
    private static let sourceKey = "cadence.source"

    var route: Route { stack.last ?? section.route }

    init() {
        installKeyMonitor()
        // Apple Music always uses the Apple ID signed into macOS, so once
        // access has been granted there's nothing to ask: connect straight away.
        if MusicAuthorization.currentStatus == .authorized {
            Task { await connectAppleMusic() }
        } else if UserDefaults.standard.string(forKey: Self.sourceKey) == "demo" {
            startDemo()
        }
    }

    // MARK: Source

    func startDemo() {
        use(DemoProvider(), backend: .demo)
        UserDefaults.standard.set("demo", forKey: Self.sourceKey)
    }

    func connectAppleMusic() async {
        access = .connecting

        switch await MusicAuthorization.request() {
        case .authorized: break
        case .denied:
            access = .denied
            return
        case .restricted:
            access = .restricted
            return
        default:
            access = .idle
            return
        }

        let provider = MusicKitProvider()
        do {
            _ = try await provider.playlists()
        } catch {
            access = .failed(error.localizedDescription)
            return
        }

        access = .idle
        use(provider, backend: .musicKit)
        UserDefaults.standard.set("musicKit", forKey: Self.sourceKey)
        Task { await watchSubscription() }
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

    private func use(_ provider: any MusicProvider, backend: Player.Backend) {
        player.stop()
        canPlayCatalog = nil
        player.backend = backend
        self.provider = provider
        providerGeneration += 1
        stack = []
        section = .discover
        withAnimation(.smooth(duration: 0.5)) { phase = .ready }
        Task { await refreshPlaylists() }
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

    func play(_ tracks: [TrackItem], startAt index: Int = 0, shuffled: Bool = false) {
        player.play(tracks, startAt: index, shuffled: shuffled)
    }

    func play(_ item: ShelfItem, shuffled: Bool = false) async {
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
