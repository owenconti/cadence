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
    private var published: (id: String?, playing: Bool, shuffled: Bool, position: TimeInterval, at: Date)?
    private var artwork: (id: String, image: MPMediaItemArtwork?)?

    init(player: Player) {
        self.player = player
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
        if id != last.id || player.isPlaying != last.playing || player.isShuffled != last.shuffled
            || abs(player.position - expected) > 1.5 {
            publish()
        }
    }

    private func publish() {
        let center = MPNowPlayingInfoCenter.default()
        published = (player.current?.id, player.isPlaying, player.isShuffled, player.position, Date())
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
        if let artwork, artwork.id == track.id, let image = artwork.image {
            info[MPMediaItemPropertyArtwork] = image
        } else if artwork?.id != track.id {
            loadArtwork(for: track)
        }
        center.nowPlayingInfo = info
        center.playbackState = player.isPlaying ? .playing : .paused
    }

    private func loadArtwork(for track: TrackItem) {
        artwork = (track.id, nil)
        Task {
            guard let image = await Self.image(for: track.artwork), artwork?.id == track.id else { return }
            artwork = (track.id, MPMediaItemArtwork(boundsSize: image.size) { _ in image })
            publish()
        }
    }

    private static func image(for source: ArtworkSource) async -> NSImage? {
        switch source {
        case .musicKit(let artwork, _):
            // Library artwork uses musickit:// URLs that only MusicKit's views can
            // load; catalog artwork is a plain web URL.
            guard let url = artwork.url(width: 600, height: 600), url.scheme?.hasPrefix("http") == true,
                  let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)
        case .generated(let seed, let style, let palette):
            let renderer = ImageRenderer(content: GeneratedArt(seed: seed, style: style, palette: palette).frame(width: 600, height: 600))
            return renderer.nsImage
        case .none:
            return nil
        }
    }
}
