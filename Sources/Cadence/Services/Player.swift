import Foundation
import MusicKit
import Observation
import os

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
    /// Shuffle mode: songs after the current one play in random order.
    private(set) var isShuffled = false
    /// The queue's own order, to return to when shuffle is turned off.
    @ObservationIgnored private(set) var unshuffled: [TrackItem]?
    var lastError: String?

    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var lastUnmatchedEntry: String?
    private static let log = Logger(subsystem: "com.owenconti.cadence", category: "player")
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

    /// Plays `tracks` from `start`. `shuffled` turns shuffle mode on or off;
    /// nil keeps the current mode (picking a song while shuffled plays it
    /// first, then the rest shuffled).
    func play(_ tracks: [TrackItem], startAt start: Int = 0, shuffled: Bool? = nil) {
        guard !tracks.isEmpty else { return }
        var list = tracks
        var startIndex = min(max(start, 0), tracks.count - 1)
        isShuffled = shuffled ?? isShuffled
        if isShuffled {
            unshuffled = tracks
            if shuffled == true {
                list.shuffle()
            } else {
                let first = list.remove(at: startIndex)
                list = [first] + list.shuffled()
            }
            startIndex = 0
        } else {
            unshuffled = nil
        }
        queue = list
        index = startIndex
        position = 0
        isPlaying = true
        if backend == .musicKit { live { try await self.startLiveQueue(list, at: startIndex) } }
    }

    /// Picks up a queue carried over from before a restart.
    func resume(_ tracks: [TrackItem], at start: Int, position: TimeInterval, playing: Bool,
                shuffled: Bool = false, unshuffled: [TrackItem]? = nil) {
        guard tracks.indices.contains(start) else { return }
        isShuffled = shuffled
        self.unshuffled = shuffled ? unshuffled : nil
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
        // Mirrors Apple Music's queue exactly (no de-duplicating), so positions
        // in the two stay aligned for syncing the current song.
        queue.insert(track, at: index + 1)
        if let current, let at = unshuffled?.firstIndex(of: current) { unshuffled?.insert(track, at: at + 1) }
        if backend == .musicKit, let song = track.song {
            live { try await ApplicationMusicPlayer.shared.queue.insert(song, position: .afterCurrentEntry) }
        }
    }

    func addToQueue(_ track: TrackItem) {
        guard index != nil else { play([track]); return }
        queue.append(track)
        unshuffled?.append(track)
        if backend == .musicKit, let song = track.song {
            live { try await ApplicationMusicPlayer.shared.queue.insert(song, position: .tail) }
        }
    }

    func toggleShuffle() { setShuffle(!isShuffled) }

    /// Turning shuffle on shuffles the songs after this one; turning it off
    /// puts them back in the queue's own order. The playing song is never
    /// touched, so playback carries on uninterrupted.
    func setShuffle(_ on: Bool) {
        guard on != isShuffled else { return }
        isShuffled = on
        guard let index else { return }
        let upcoming = Array(queue[(index + 1)...])
        if on {
            unshuffled = queue
            reorderUpcoming(upcoming.shuffled())
        } else {
            // The songs still to come, in their own order.
            var left = Dictionary(upcoming.map { ($0.id, 1) }, uniquingKeysWith: +)
            var ordered = (unshuffled ?? queue).filter { track in
                guard let n = left[track.id], n > 0 else { return false }
                left[track.id] = n - 1
                return true
            }
            ordered += upcoming.filter { (left[$0.id] ?? 0) > 0 }
            unshuffled = nil
            reorderUpcoming(ordered)
        }
    }

    /// Replaces the songs after the current one, and moves Apple Music's own
    /// queue entries to match without restarting what's playing.
    private func reorderUpcoming(_ upcoming: [TrackItem]) {
        guard let index else { return }
        let before = Array(queue[(index + 1)...])
        queue.replaceSubrange((index + 1)..., with: upcoming)
        guard backend == .musicKit else { return }

        let player = ApplicationMusicPlayer.shared
        var entries = player.queue.entries
        guard let current = player.queue.currentEntry,
              let at = entries.firstIndex(where: { $0.id == current.id }) else { return }
        let next = entries.index(after: at)
        let liveUpcoming = Array(entries[next...])
        guard liveUpcoming.count == before.count else {
            Self.log.error("Apple Music has \(liveUpcoming.count, privacy: .public) songs up next, we have \(before.count, privacy: .public); rebuilding its queue")
            let list = queue, pos = position, playing = isPlaying
            live { try await self.startLiveQueue(list, at: index, from: pos, autoplay: playing) }
            return
        }
        // Each of our songs keeps its own Apple Music entry, now in the new order.
        var pool: [String: [MusicPlayer.Queue.Entry]] = [:]
        for (track, entry) in zip(before, liveUpcoming) { pool[track.id, default: []].append(entry) }
        let reordered = upcoming.compactMap { track -> MusicPlayer.Queue.Entry? in
            guard var list = pool[track.id], !list.isEmpty else { return nil }
            let entry = list.removeFirst()
            pool[track.id] = list
            return entry
        }
        entries.replaceSubrange(next..., with: reordered)
        player.queue.entries = entries
    }

    /// Swaps in fresher copies of queued songs (same IDs), e.g. with working
    /// artwork after a restore. Order and playback are unchanged.
    func refresh(_ tracks: [TrackItem]) {
        let fresh = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        queue = queue.map { fresh[$0.id] ?? $0 }
        unshuffled = unshuffled?.map { fresh[$0.id] ?? $0 }
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
            syncCurrentEntry(player)
        }
    }

    /// Follows Apple Music onto whichever song it's playing. Library songs can
    /// report a different ID than the one queued, so match by position in its
    /// queue (which mirrors ours), falling back to title and artist.
    private func syncCurrentEntry(_ player: ApplicationMusicPlayer) {
        guard let entry = player.queue.currentEntry else { return }
        let entries = player.queue.entries
        var match: Int?
        if entries.count == queue.count, let position = entries.firstIndex(where: { $0.id == entry.id }),
           queue[position].title == entry.title {
            match = position
        } else {
            // The nearest song with the same title and artist to where we were.
            let here = index ?? 0
            match = queue.indices
                .filter { queue[$0].title == entry.title && (entry.subtitle == nil || queue[$0].artistName == entry.subtitle) }
                .min { abs($0 - here) < abs($1 - here) }
        }
        if let match {
            if match != index {
                Self.log.info("now playing #\(match, privacy: .public) \(entry.title, privacy: .public) (was #\(self.index ?? -1, privacy: .public))")
                index = match
            }
        } else if lastUnmatchedEntry != entry.id {
            lastUnmatchedEntry = entry.id
            Self.log.error("can't find \(entry.title, privacy: .public) – \(entry.subtitle ?? "", privacy: .public) in our queue of \(self.queue.count, privacy: .public); Apple Music has \(entries.count, privacy: .public) entries")
        }
    }

    /// For system controls (media keys, Control Center).
    func setPlaying(_ playing: Bool) {
        if playing != isPlaying { toggle() }
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
