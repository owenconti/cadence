import AppKit
import MediaPlayer
import SwiftUI

/// Connects playback to macOS's Now Playing: Control Center and the menu bar
/// show the current song, and media keys, headphone buttons and Control
/// Center's controls drive the player.
@MainActor
final class NowPlaying {
    private let player: Player
    private var timer: Timer?
    private var published: (id: String?, artwork: ArtworkSource?, playing: Bool, shuffled: Bool, position: TimeInterval, at: Date)?
    private let artwork = NowPlayingArtwork()

    init(player: Player) {
        self.player = player
        artwork.loaded = { [weak self] in self?.publish() }
        let commands = MPRemoteCommandCenter.shared()
        handle(commands.playCommand) { player, _ in player.setPlaying(true) }
        handle(commands.pauseCommand) { player, _ in player.setPlaying(false) }
        handle(commands.togglePlayPauseCommand) { player, _ in player.toggle() }
        handle(commands.nextTrackCommand) { player, _ in player.next() }
        handle(commands.previousTrackCommand) { player, _ in player.previous() }
        handle(commands.changeShuffleModeCommand) { player, event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else { return }
            player.setShuffle(event.shuffleType != .off)
        }
        handle(commands.changePlaybackPositionCommand) { player, event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return }
            player.seek(to: event.positionTime)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishIfChanged() }
        }
    }

    /// Runs `action` on the main actor. Nothing promises which thread these
    /// commands arrive on: on the main one it answers at once; on another it
    /// hops over and answers success.
    private func handle(_ command: MPRemoteCommand, _ action: @escaping @MainActor (Player, MPRemoteCommandEvent) -> Void) {
        command.addTarget { [weak self] event in
            nonisolated(unsafe) let event = event
            guard Thread.isMainThread else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.player.current != nil else { return }
                        action(self.player, event)
                        self.publish()
                    }
                }
                return .success
            }
            return MainActor.assumeIsolated {
                guard let self, self.player.current != nil else { return .noActionableNowPlayingItem }
                action(self.player, event)
                self.publish()
                return .success
            }
        }
    }

    /// macOS extrapolates elapsed time from the rate, so publish only when the
    /// song, play state or position changes in a way it can't predict.
    private func publishIfChanged() {
        let id = player.current?.id
        guard let last = published else { return publish() }
        if let track = player.current, artwork.retryDue(for: track) { return publish() }
        let expected = last.position + (last.playing ? Date().timeIntervalSince(last.at) : 0)
        // A restored song's artwork is swapped for a working copy after launch.
        if id != last.id || player.current?.artwork != last.artwork || player.isPlaying != last.playing || player.isShuffled != last.shuffled
            || abs(player.position - expected) > 1.5 {
            publish()
        }
    }

    private func publish() {
        let center = MPNowPlayingInfoCenter.default()
        published = (player.current?.id, player.current?.artwork, player.isPlaying, player.isShuffled, player.position, Date())
        MPRemoteCommandCenter.shared().changeShuffleModeCommand.currentShuffleType = player.isShuffled ? .items : .off
        guard let track = player.current else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artistName,
            MPMediaItemPropertyAlbumTitle: track.albumTitle,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.position,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
        ]
        if let image = artwork.image(for: track) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        center.nowPlayingInfo = info
        center.playbackState = player.isPlaying ? .playing : .paused
    }

    static func image(for source: ArtworkSource) async -> NSImage? {
        switch source {
        case .musicKit(let artwork, _):
            // Catalog artwork is a plain web URL; library artwork uses
            // musicKit:// URLs that only MusicKit's views can load.
            if let url = artwork.url(width: 600, height: 600), url.scheme?.hasPrefix("http") == true,
               let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) {
                return image
            }
            return await ArtworkSnapshot.image(artwork)
        case .generated(let seed, let style, let palette):
            let renderer = ImageRenderer(content: GeneratedArt(seed: seed, style: style, palette: palette).frame(width: 600, height: 600))
            return renderer.nsImage
        case .mosaic(let tiles):
            guard let first = tiles.first else { return nil }
            return await image(for: first)
        case .none:
            return nil
        }
    }
}

/// Control Center's picture of the playing song. Loads once per song and
/// artwork, so when a restored song's dead artwork is swapped for a working
/// copy, that copy loads instead of the failed attempt sticking. A load that
/// fails is tried again after a while (10 s, doubling to 2 min), in case it
/// was the network.
@MainActor
final class NowPlayingArtwork {
    private struct Attempt {
        let id: String
        let source: ArtworkSource
        var image: NSImage?
        var loading = true
        var failures = 0
        var retryAt = Date.distantFuture
    }

    private var current: Attempt?
    /// Called when an image arrives for the song that's still current.
    var loaded: () -> Void = {}

    /// The image if it's ready; otherwise starts loading it (unless a load is
    /// under way or a failed one isn't due again yet) and returns nil.
    func image(for track: TrackItem) -> NSImage? {
        if let current, current.id == track.id, current.source == track.artwork {
            if current.image != nil || current.loading || Date() < current.retryAt { return current.image }
        } else {
            current = Attempt(id: track.id, source: track.artwork)
        }
        current?.loading = true
        Task {
            let image = await NowPlaying.image(for: track.artwork)
            guard var attempt = self.current, attempt.id == track.id, attempt.source == track.artwork else { return }
            attempt.loading = false
            attempt.image = image
            if image == nil, track.artwork != .none {
                attempt.failures += 1
                attempt.retryAt = Date().addingTimeInterval(min(10 * pow(2, Double(attempt.failures - 1)), 120))
            }
            self.current = attempt
            if image != nil { loaded() }
        }
        return nil
    }

    /// Whether a failed load for `track` is due another try.
    func retryDue(for track: TrackItem) -> Bool {
        guard let current, current.id == track.id, current.source == track.artwork else { return false }
        return current.image == nil && !current.loading && Date() >= current.retryAt
    }
}
