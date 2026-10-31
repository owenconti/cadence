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
    private(set) var queue: [TrackItem] = [] {
        didSet { if keys.count != queue.count { keys = queue.map { _ in newKey() } } }
    }
    /// One key per queued copy of a song, in step with `queue`, so the same
    /// song queued twice stays two distinct entries (shuffle, Apple Music).
    @ObservationIgnored private(set) var keys: [Int] = []
    @ObservationIgnored private var lastKey = 0
    private(set) var index: Int?
    /// Shown as playing: what was asked for, or what Apple Music reports once
    /// no command is still on its way.
    private(set) var isPlaying = false
    /// What was last asked for. Apple Music commands act on this when they
    /// run, so a later pause wins over an earlier play still in flight.
    @ObservationIgnored private var wantsPlaying = false
    /// Apple Music commands not yet finished; until they are, its reported
    /// state is out of date and doesn't overwrite `isPlaying`.
    @ObservationIgnored private var pendingCommands = 0
    @ObservationIgnored private var commandChain: Task<Void, Never>?
    /// When the last command finished; Apple Music takes a moment to report
    /// its effect.
    @ObservationIgnored private var settledAt = Date.distantPast
    /// Bumped by anything that starts or replaces playback, so work begun
    /// before (restoring, loading an album to play) can tell it's been
    /// overtaken.
    @ObservationIgnored private(set) var revision = 0
    private(set) var position: TimeInterval = 0
    /// Where the queue came from (a playlist, album, …).
    private(set) var source: QueueSource?
    /// Shuffle mode: songs after the current one play in random order.
    private(set) var isShuffled = false
    /// The queue's own order, to return to when shuffle is turned off.
    @ObservationIgnored private(set) var unshuffled: [TrackItem]?
    @ObservationIgnored private var unshuffledKeys: [Int]?
    /// A short message about something that didn't work (a song Apple Music
    /// wouldn't queue), shown in the Now panel for a few seconds.
    private(set) var notice: String?
    @ObservationIgnored private var noticeClear: Task<Void, Never>?
    /// Bumped whenever Apple Music is given a new queue, so a start still
    /// preparing for an older one gives up instead of acting on the new one.
    @ObservationIgnored private var liveGeneration = 0

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

    private func newKey() -> Int {
        lastKey += 1
        return lastKey
    }

    /// Sets the queue with fresh keys for every entry.
    private func setQueue(_ tracks: [TrackItem]) {
        keys = tracks.map { _ in newKey() }
        queue = tracks
    }

    private func setPlaying(intent playing: Bool) {
        wantsPlaying = playing
        isPlaying = playing
    }

    // MARK: Commands

    /// Plays `tracks` from `start`. `shuffled` turns shuffle mode on or off;
    /// nil keeps the current mode (picking a song while shuffled plays it
    /// first, then the rest shuffled).
    func play(_ tracks: [TrackItem], startAt start: Int = 0, shuffled: Bool? = nil, from source: QueueSource? = nil) {
        guard !tracks.isEmpty else { return }
        revision += 1
        self.source = source
        let startIndex = min(max(start, 0), tracks.count - 1)
        let tracksKeys = tracks.map { _ in newKey() }
        var order = Array(tracks.indices)
        isShuffled = shuffled ?? isShuffled
        if isShuffled {
            unshuffled = tracks
            unshuffledKeys = tracksKeys
            if shuffled == true {
                order.shuffle()
            } else {
                order.remove(at: startIndex)
                order = [startIndex] + order.shuffled()
            }
        } else {
            unshuffled = nil
            unshuffledKeys = nil
        }
        keys = order.map { tracksKeys[$0] }
        queue = order.map { tracks[$0] }
        index = isShuffled ? 0 : startIndex
        position = 0
        setPlaying(intent: true)
        if backend == .musicKit { startLive(at: index ?? 0) }
    }

    /// Picks up a queue carried over from before a restart.
    func resume(_ tracks: [TrackItem], at start: Int, position: TimeInterval, playing: Bool,
                shuffled: Bool = false, unshuffled: [TrackItem]? = nil, from source: QueueSource? = nil) {
        guard tracks.indices.contains(start) else { return }
        revision += 1
        self.source = source
        isShuffled = shuffled
        setQueue(tracks)
        // Copies of a song in the saved order pair up with copies in the queue.
        if shuffled, let unshuffled {
            var pool: [String: [Int]] = [:]
            for (track, key) in zip(tracks, keys) { pool[track.id, default: []].append(key) }
            self.unshuffledKeys = unshuffled.map { track in pool[track.id]?.isEmpty == false ? pool[track.id]!.removeFirst() : newKey() }
            self.unshuffled = unshuffled
        } else {
            self.unshuffled = nil
            self.unshuffledKeys = nil
        }
        index = start
        self.position = min(max(position, 0), tracks[start].duration)
        setPlaying(intent: playing)
        if backend == .musicKit { startLive(at: start, from: self.position) }
    }

    func toggle() {
        guard current != nil else { return }
        setPlaying(intent: !wantsPlaying)
        guard backend == .musicKit else { return }
        // Acts on the latest intent when its turn comes.
        live {
            let player = ApplicationMusicPlayer.shared
            if self.wantsPlaying { try await player.play() } else { player.pause() }
        }
    }

    func next() {
        guard let index else { return }
        if backend == .musicKit { live { try await ApplicationMusicPlayer.shared.skipToNextEntry() } }
        if index + 1 < queue.count {
            self.index = index + 1
            position = 0
        } else {
            setPlaying(intent: false)
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

    /// Plays the song at `target` in the queue. By position rather than by
    /// song, since the same song can be queued more than once.
    func jump(toQueueIndex target: Int) {
        guard queue.indices.contains(target) else { return }
        revision += 1
        index = target
        position = 0
        setPlaying(intent: true)
        if backend == .musicKit { startLive(at: target) }
    }

    func seek(to time: TimeInterval) {
        position = max(0, time)
        guard backend == .musicKit else { return }
        let time = position
        live { ApplicationMusicPlayer.shared.playbackTime = time }
    }

    func playNext(_ track: TrackItem) {
        guard index != nil else { play([track]); return }
        // Mirrors Apple Music's queue exactly (no de-duplicating), so positions
        // in the two stay aligned for syncing the current song. With Apple
        // Music, ours changes only once it has taken the song.
        insertLive(track, position: .afterCurrentEntry) { [weak self] in
            guard let self, let index = self.index else { return }
            let key = self.newKey()
            if let keys = self.unshuffledKeys, let at = keys.firstIndex(of: self.keys[index]) {
                self.unshuffledKeys?.insert(key, at: at + 1)
                self.unshuffled?.insert(track, at: at + 1)
            }
            self.keys.insert(key, at: index + 1)
            self.queue.insert(track, at: index + 1)
        }
    }

    func addToQueue(_ track: TrackItem) {
        guard index != nil else { play([track]); return }
        insertLive(track, position: .tail) { [weak self] in
            guard let self else { return }
            let key = self.newKey()
            self.keys.append(key)
            self.queue.append(track)
            self.unshuffledKeys?.append(key)
            self.unshuffled?.append(track)
        }
    }

    /// Runs `apply` once Apple Music has queued `track` (at once in demo
    /// mode); if it won't, nothing changes and the Now panel says so. If the
    /// queue was replaced before its turn came, it's dropped from both.
    private func insertLive(_ track: TrackItem, position: MusicPlayer.Queue.EntryInsertionPosition, apply: @escaping @MainActor () -> Void) {
        guard backend == .musicKit else { return apply() }
        guard let song = track.song else {
            return report("Couldn't queue “\(track.title)”: Apple Music doesn't have it")
        }
        let generation = liveGeneration
        enqueue {
            guard generation == self.liveGeneration else { return }
            do {
                try await ApplicationMusicPlayer.shared.queue.insert(song, position: position)
                apply()
            } catch {
                Self.log.error("couldn't queue \(track.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
                self.report("Couldn't queue “\(track.title)”: \(error.localizedDescription)")
            }
        }
    }

    func report(_ message: String) {
        notice = message
        noticeClear?.cancel()
        noticeClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.notice = nil
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
        let upcoming = Array(queue.indices.dropFirst(index + 1))
        if on {
            unshuffled = queue
            unshuffledKeys = keys
            reorderUpcoming(upcoming.shuffled())
        } else {
            // The entries still to come, in the queue's own order; by key, so
            // a song queued twice puts back the copy that's actually left.
            let place = Dictionary(uniqueKeysWithValues: upcoming.map { (keys[$0], $0) })
            var ordered = (unshuffledKeys ?? []).compactMap { place[$0] }
            let placed = Set(ordered)
            ordered += upcoming.filter { !placed.contains($0) }
            unshuffled = nil
            unshuffledKeys = nil
            reorderUpcoming(ordered)
        }
    }

    /// Puts the entries after the current one in `order` (queue indices), and
    /// moves Apple Music's own queue entries to match without restarting
    /// what's playing.
    private func reorderUpcoming(_ order: [Int]) {
        guard let index else { return }
        let before = Array(queue[(index + 1)...])
        let newKeys = order.map { keys[$0] }
        let upcoming = order.map { queue[$0] }
        keys.replaceSubrange((index + 1)..., with: newKeys)
        queue.replaceSubrange((index + 1)..., with: upcoming)
        guard backend == .musicKit else { return }

        let generation = liveGeneration
        live {
            guard generation == self.liveGeneration else { return }
            let player = ApplicationMusicPlayer.shared
            var entries = player.queue.entries
            guard let current = player.queue.currentEntry,
                  let at = entries.firstIndex(where: { $0.id == current.id }) else { return }
            let next = entries.index(after: at)
            let liveUpcoming = Array(entries[next...])
            guard liveUpcoming.count == before.count else {
                Self.log.error("Apple Music has \(liveUpcoming.count, privacy: .public) songs up next, we have \(before.count, privacy: .public); rebuilding its queue")
                self.startLive(at: index, from: self.position)
                return
            }
            // Each of our songs keeps its own Apple Music entry, now in the new
            // order (copies of one song are interchangeable).
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
    }

    /// Swaps in working artwork for queued songs, by song ID. Nothing else
    /// about the queue or playback changes.
    func refreshArtwork(_ artwork: [String: ArtworkSource]) {
        guard !artwork.isEmpty else { return }
        func updated(_ track: TrackItem) -> TrackItem {
            guard let fresh = artwork[track.id] else { return track }
            var track = track
            track.artwork = fresh
            return track
        }
        queue = queue.map(updated)
        unshuffled = unshuffled?.map(updated)
    }

    func stop() {
        revision += 1
        liveGeneration += 1
        if backend == .musicKit { live { ApplicationMusicPlayer.shared.stop() } }
        setQueue([])
        unshuffled = nil
        unshuffledKeys = nil
        source = nil
        index = nil
        setPlaying(intent: false)
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
            // While a command is on its way, Apple Music's state is the old one.
            guard current != nil, pendingCommands == 0, Date().timeIntervalSince(settledAt) > 1 else { return }
            let player = ApplicationMusicPlayer.shared
            position = player.playbackTime
            // Paused or played from outside (headphones, another app).
            let playing = player.state.playbackStatus == .playing
            if playing != isPlaying { isPlaying = playing; wantsPlaying = playing }
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
        if playing != wantsPlaying { toggle() }
    }

    // MARK: MusicKit

    /// Gives Apple Music the queue, starting at `start`. One entry per copy of
    /// a song, starting at the very copy asked for. Whether it then plays
    /// follows what's wanted when preparing finishes, so a pause in the
    /// meantime holds; a newer queue cancels this one.
    private func startLive(at start: Int, from position: TimeInterval = 0) {
        liveGeneration += 1
        let generation = liveGeneration
        let tracks = queue
        live {
            guard generation == self.liveGeneration else { return }
            var entries: [MusicPlayer.Queue.Entry] = []
            var first: MusicPlayer.Queue.Entry?
            for (i, track) in tracks.enumerated() {
                guard let song = track.song else { continue }
                let entry = MusicPlayer.Queue.Entry(song)
                entries.append(entry)
                if i >= start, first == nil { first = entry }
            }
            guard !entries.isEmpty else { return }
            let player = ApplicationMusicPlayer.shared
            player.queue = ApplicationMusicPlayer.Queue(entries, startingAt: first)
            try await player.prepareToPlay()
            guard generation == self.liveGeneration else { return }
            if position > 0 { player.playbackTime = position }
            if self.wantsPlaying { try await player.play() } else { player.pause() }
        }
    }

    /// Runs Apple Music commands one at a time, in the order they were
    /// given, reporting any that fail.
    private func live(_ work: @escaping @MainActor () async throws -> Void) {
        enqueue {
            do {
                try await work()
            } catch {
                Self.log.error("Apple Music: \(error.localizedDescription, privacy: .public)")
                self.report(error.localizedDescription)
            }
        }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = commandChain
        pendingCommands += 1
        commandChain = Task { @MainActor in
            await previous?.value
            await work()
            self.pendingCommands -= 1
            self.settledAt = Date()
        }
    }
}
