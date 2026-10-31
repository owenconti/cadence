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
        handle(commands.playCommand) { $0.setPlaying(true) }
        handle(commands.pauseCommand) { $0.setPlaying(false) }
        handle(commands.togglePlayPauseCommand) { $0.toggle() }
        handle(commands.nextTrackCommand) { $0.next() }
        handle(commands.previousTrackCommand) { $0.previous() }
        commands.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            return MainActor.assumeIsolated {
                guard let self, self.player.current != nil else { return .noActionableNowPlayingItem }
                self.player.setShuffle(event.shuffleType != .off)
                self.publish()
                return .success
            }
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return MainActor.assumeIsolated {
                guard let self, self.player.current != nil else { return .noActionableNowPlayingItem }
                self.player.seek(to: event.positionTime)
                self.publish()
                return .success
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishIfChanged() }
        }
    }

    private func handle(_ command: MPRemoteCommand, _ action: @escaping @MainActor (Player) -> Void) {
        command.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.player.current != nil else { return .noActionableNowPlayingItem }
                action(self.player)
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
        case .none:
            return nil
        }
    }
}

/// Control Center's picture of the playing song. Loads once per song and
/// artwork, so when a restored song's dead artwork is swapped for a working
/// copy, that copy loads instead of the failed attempt sticking.
@MainActor
final class NowPlayingArtwork {
    private var current: (id: String, source: ArtworkSource, image: NSImage?)?
    /// Called when an image arrives for the song that's still current.
    var loaded: () -> Void = {}

    /// The image if it's ready; otherwise starts loading it and returns nil.
    func image(for track: TrackItem) -> NSImage? {
        if let current, current.id == track.id, current.source == track.artwork { return current.image }
        current = (track.id, track.artwork, nil)
        Task {
            let image = await NowPlaying.image(for: track.artwork)
            guard let image, let current, current.id == track.id, current.source == track.artwork else { return }
            self.current?.image = image
            loaded()
        }
        return nil
    }
}
