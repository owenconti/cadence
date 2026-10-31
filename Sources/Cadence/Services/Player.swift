import Foundation
import MusicKit
import Observation

/// Owns the play queue. In demo mode it simulates playback with a clock; in
/// live mode it drives `ApplicationMusicPlayer` and mirrors its state.
@MainActor
@Observable
final class Player {
    enum Backend { case demo, musicKit }

    var backend: Backend = .demo
    private(set) var queue: [TrackItem] = []
    private(set) var index: Int?
    private(set) var isPlaying = false
    private(set) var position: TimeInterval = 0
    var lastError: String?

    @ObservationIgnored private var ticker: Task<Void, Never>?
    private let tickInterval: TimeInterval = 0.25

    var current: TrackItem? {
        guard let index, queue.indices.contains(index) else { return nil }
        return queue[index]
    }

    var upNext: ArraySlice<TrackItem> {
        guard let index, index + 1 < queue.count else { return [] }
        return queue[(index + 1)...]
    }

    init() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.tick()
            }
        }
    }

    // MARK: Commands

    func play(_ tracks: [TrackItem], startAt start: Int = 0, shuffled: Bool = false) {
        guard !tracks.isEmpty else { return }
        var list = tracks
        var startIndex = min(max(start, 0), tracks.count - 1)
        if shuffled {
            list.shuffle()
            startIndex = 0
        }
        queue = list
        index = startIndex
        position = 0
        isPlaying = true
        if backend == .musicKit { live { try await self.startLiveQueue(list, at: startIndex) } }
    }

    /// Picks up a queue carried over from before a restart.
    func resume(_ tracks: [TrackItem], at start: Int, position: TimeInterval, playing: Bool) {
        guard tracks.indices.contains(start) else { return }
        queue = tracks
        index = start
        self.position = min(max(position, 0), tracks[start].duration)
        isPlaying = playing
        if backend == .musicKit {
            let resumeAt = self.position
            live { try await self.startLiveQueue(tracks, at: start, from: resumeAt, autoplay: playing) }
        }
    }

    func toggle() {
        guard current != nil else { return }
        isPlaying.toggle()
        guard backend == .musicKit else { return }
        let player = ApplicationMusicPlayer.shared
        if isPlaying { live { try await player.play() } } else { player.pause() }
    }

    func next() {
        guard let index else { return }
        if backend == .musicKit { live { try await ApplicationMusicPlayer.shared.skipToNextEntry() } }
        if index + 1 < queue.count {
            self.index = index + 1
            position = 0
        } else {
            isPlaying = false
            position = 0
        }
    }

    func previous() {
        guard let index else { return }
        if position > 3 || index == 0 {
            seek(to: 0)
            return
        }
        if backend == .musicKit { live { try await ApplicationMusicPlayer.shared.skipToPreviousEntry() } }
        self.index = index - 1
        position = 0
    }

    func jump(to track: TrackItem) {
        guard let target = queue.firstIndex(of: track) else { return }
        if backend == .musicKit {
            let list = queue
            live { try await self.startLiveQueue(list, at: target) }
        }
        index = target
        position = 0
        isPlaying = true
    }

    func seek(to time: TimeInterval) {
        position = max(0, time)
        if backend == .musicKit { ApplicationMusicPlayer.shared.playbackTime = position }
    }

    func playNext(_ track: TrackItem) {
        guard let index else { play([track]); return }
        queue.removeAll { $0 == track && $0 != current }
        queue.insert(track, at: index + 1)
        if backend == .musicKit, let song = track.song {
            live { try await ApplicationMusicPlayer.shared.queue.insert(song, position: .afterCurrentEntry) }
        }
    }

    func addToQueue(_ track: TrackItem) {
        guard index != nil else { play([track]); return }
        queue.append(track)
        if backend == .musicKit, let song = track.song {
            live { try await ApplicationMusicPlayer.shared.queue.insert(song, position: .tail) }
        }
    }

    func shuffleUpcoming() {
        guard let index, index + 1 < queue.count else { return }
        let rest = queue[(index + 1)...].shuffled()
        queue.replaceSubrange((index + 1)..., with: rest)
        if backend == .musicKit {
            let list = queue, pos = position
            live {
                try await self.startLiveQueue(list, at: index)
                ApplicationMusicPlayer.shared.playbackTime = pos
            }
        }
    }

    func stop() {
        if backend == .musicKit { ApplicationMusicPlayer.shared.stop() }
        queue = []
        index = nil
        isPlaying = false
        position = 0
    }

    // MARK: Clock

    private func tick() {
        switch backend {
        case .demo:
            guard isPlaying, let current else { return }
            position += tickInterval
            if position >= current.duration { next() }
        case .musicKit:
            guard current != nil else { return }
            let player = ApplicationMusicPlayer.shared
            position = player.playbackTime
            isPlaying = player.state.playbackStatus == .playing
            if case .song(let song)? = player.queue.currentEntry?.item,
               let match = queue.firstIndex(where: { $0.song?.id == song.id }), match != index {
                index = match
            }
        }
    }

    // MARK: MusicKit

    private func startLiveQueue(_ tracks: [TrackItem], at start: Int, from position: TimeInterval = 0, autoplay: Bool = true) async throws {
        let songs = tracks.compactMap(\.song)
        guard !songs.isEmpty else { return }
        let player = ApplicationMusicPlayer.shared
        let first = tracks[start].song
        player.queue = ApplicationMusicPlayer.Queue(for: songs, startingAt: first)
        try await player.prepareToPlay()
        if position > 0 { player.playbackTime = position }
        if autoplay { try await player.play() }
    }

    private func live(_ work: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await work() } catch { self.lastError = error.localizedDescription }
        }
    }
}
