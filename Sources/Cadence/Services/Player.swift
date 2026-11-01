import Foundation
import Observation
import os

/// Owns the play queue and decides what plays; a `LiveEngine` does the
/// playing (Apple Music, or the simulated engine for the demo library).
@MainActor
@Observable
final class Player {
    enum Backend { case demo, musicKit }

    var backend: Backend = .demo {
        didSet { engine = backend == .musicKit ? MusicKitEngine() : SimulatedEngine() }
    }
    /// What plays the music. Every command reaches it through `live`, in order.
    @ObservationIgnored private(set) var engine: LiveEngine = SimulatedEngine()

    private(set) var queue: [TrackItem] = []
    /// One key per queued copy of a song, in step with `queue`, so the same
    /// song queued twice stays two distinct entries (shuffle, saving).
    @ObservationIgnored private(set) var keys: [Int] = []
    @ObservationIgnored private var lastKey = 0
    private(set) var index: Int?
    /// Shown as playing: what was asked for, or what the engine reports once
    /// no command is still on its way.
    private(set) var isPlaying = false
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

    /// What was last asked for. Commands act on this when their turn comes,
    /// so a later pause wins over an earlier play still in flight.
    @ObservationIgnored private var wantsPlaying = false
    /// Engine commands not yet finished; until they are, its reported play
    /// state is out of date and doesn't overwrite `isPlaying`.
    @ObservationIgnored private var pendingCommands = 0
    /// Queue replacements not yet handed to the engine; until they are, its
    /// time and current entry belong to the old queue.
    @ObservationIgnored private var pendingStarts = 0
    @ObservationIgnored private var commandChain: Task<Void, Never>?
    /// When the last command finished; the engine takes a moment to report
    /// its effect.
    @ObservationIgnored private var settledAt = Date.distantPast
    /// Bumped whenever the engine is to get a new queue, so a command meant
    /// for an older one gives up instead of acting on the new one.
    @ObservationIgnored private var liveGeneration = 0
    /// Bumped by every user request to play something (including one still
    /// loading its songs, via `claim`), so work begun before, like restoring
    /// the saved queue, can tell it's been overtaken.
    @ObservationIgnored private(set) var revision = 0

    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var lastUnmatchedEntry: String?
    private static let log = Logger(subsystem: "com.owenconti.cadence", category: "player")

    var current: TrackItem? {
        guard let index, queue.indices.contains(index) else { return nil }
        return queue[index]
    }

    var upNext: ArraySlice<TrackItem> {
        guard let index, index + 1 < queue.count else { return [] }
        return queue[(index + 1)...]
    }

    /// For saving: each entry of the queue's own order, as a place in `queue`.
    var unshuffledPositions: [Int]? {
        guard let unshuffledKeys else { return nil }
        let place = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
        let positions = unshuffledKeys.compactMap { place[$0] }
        return positions.count == unshuffledKeys.count ? positions : nil
    }

    /// Which copy of the current song is playing, counted in the order the
    /// list was played from (`unshuffled`, else the queue): 0 for the first.
    /// Lets a song list mark the right row when a song appears twice.
    var currentCopy: Int? {
        guard let index, let current else { return nil }
        let key = keys[index]
        let order: [(Int, String)] = if let unshuffledKeys, let unshuffled {
            zip(unshuffledKeys, unshuffled.map(\.id)).map { ($0, $1) }
        } else {
            zip(keys, queue.map(\.id)).map { ($0, $1) }
        }
        var copy = 0
        for (k, id) in order where id == current.id {
            if k == key { return copy }
            copy += 1
        }
        return nil
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

    private func setPlaying(intent playing: Bool) {
        wantsPlaying = playing
        isPlaying = playing
    }

    // MARK: Commands

    /// Marks a request to play something that still has to load its songs:
    /// anything begun before (a restore) gives way. Check `stillCurrent`
    /// with the result once loaded.
    func claim() -> Int {
        revision += 1
        return revision
    }

    func stillCurrent(_ claim: Int) -> Bool { revision == claim }

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
        startLive(at: index ?? 0)
    }

    /// Picks up a queue carried over from before a restart. Not a request of
    /// its own: a play asked for meanwhile has already won (see `claim`).
    /// `unshuffledPositions` is the queue's own order as places in `tracks`;
    /// older saves only have the songs (`unshuffled`).
    func resume(_ tracks: [TrackItem], at start: Int, position: TimeInterval, playing: Bool, shuffled: Bool = false,
                unshuffledPositions: [Int]? = nil, unshuffled: [TrackItem]? = nil, from source: QueueSource? = nil) {
        guard tracks.indices.contains(start) else { return }
        self.source = source
        isShuffled = shuffled
        keys = tracks.map { _ in newKey() }
        queue = tracks
        if shuffled, let positions = unshuffledPositions, positions.allSatisfy(tracks.indices.contains) {
            self.unshuffled = positions.map { tracks[$0] }
            unshuffledKeys = positions.map { keys[$0] }
        } else if shuffled, let unshuffled {
            // Copies of a song pair up in order of appearance.
            var pool: [String: [Int]] = [:]
            for (track, key) in zip(tracks, keys) { pool[track.id, default: []].append(key) }
            unshuffledKeys = unshuffled.map { track in pool[track.id]?.isEmpty == false ? pool[track.id]!.removeFirst() : newKey() }
            self.unshuffled = unshuffled
        } else {
            self.unshuffled = nil
            unshuffledKeys = nil
        }
        index = start
        self.position = min(max(position, 0), tracks[start].duration)
        setPlaying(intent: playing)
        startLive(at: start, from: self.position)
    }

    func toggle() {
        guard current != nil else { return }
        setPlaying(intent: !wantsPlaying)
        // Acts on the latest intent when its turn comes.
        live { engine in
            if self.wantsPlaying { try await engine.play() } else { engine.pause() }
        }
    }

    func next() {
        guard let index else { return }
        live { engine in try await engine.skipToNext() }
        if index + 1 < queue.count {
            self.index = index + 1
            position = 0
        } else {
            setPlaying(intent: false)
            position = 0
        }
    }

    /// A few seconds into a song, restarts it; otherwise goes back a song.
    func previous() { previous(always: false) }

    /// `always` goes back a song regardless (swiping the phone's Now Playing).
    func previous(always: Bool) {
        guard let index else { return }
        if index == 0 || (position > 3 && !always) {
            seek(to: 0)
            return
        }
        live { engine in try await engine.skipToPrevious() }
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
        startLive(at: target)
    }

    func seek(to time: TimeInterval) {
        position = max(0, time)
        let time = position
        live { engine in engine.playbackTime = time }
    }

    func playNext(_ track: TrackItem) {
        guard index != nil else { play([track]); return }
        // Mirrors the engine's queue exactly (no de-duplicating), so positions
        // in the two stay aligned for syncing the current song. Ours changes
        // only once the engine has taken the song.
        insertLive(track, afterCurrent: true) { [weak self] in
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
        insertLive(track, afterCurrent: false) { [weak self] in
            guard let self else { return }
            let key = self.newKey()
            self.keys.append(key)
            self.queue.append(track)
            self.unshuffledKeys?.append(key)
            self.unshuffled?.append(track)
        }
    }

    /// Runs `apply` once the engine has queued `track`; if it won't, nothing
    /// changes and the Now panel says so. If the queue is replaced before or
    /// while it's being added, it's dropped from ours too: the engine gets
    /// the new queue next, without it.
    private func insertLive(_ track: TrackItem, afterCurrent: Bool, apply: @escaping @MainActor () -> Void) {
        let generation = liveGeneration
        enqueue { engine in
            guard generation == self.liveGeneration else { return }
            do {
                try await engine.insert(track, afterCurrent: afterCurrent)
                guard generation == self.liveGeneration else { return }
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
    /// moves the engine's entries to match without restarting what's playing.
    private func reorderUpcoming(_ order: [Int]) {
        guard let index else { return }
        let offsets = order.map { $0 - (index + 1) }
        keys.replaceSubrange((index + 1)..., with: order.map { keys[$0] })
        queue.replaceSubrange((index + 1)..., with: order.map { queue[$0] })
        let generation = liveGeneration
        live { engine in
            guard generation == self.liveGeneration else { return }
            if !engine.reorderUpcoming(offsets) {
                Self.log.error("the player's songs up next don't line up with ours; rebuilding its queue")
                self.startLive(at: index, from: self.position)
            }
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
        live { engine in engine.stop() }
        keys = []
        queue = []
        unshuffled = nil
        unshuffledKeys = nil
        source = nil
        index = nil
        setPlaying(intent: false)
        position = 0
    }

    /// For system controls (media keys, Control Center).
    func setPlaying(_ playing: Bool) {
        if playing != wantsPlaying { toggle() }
    }

    // MARK: Clock

    private func tick() {
        guard current != nil else { return }
        // Time and the current song carry on during other commands (adding a
        // song, say); only a queue not yet handed over makes them stale.
        if pendingStarts == 0 {
            position = engine.playbackTime
            syncCurrentEntry()
        }
        // The play state, though, is only believed once commands have landed.
        guard pendingCommands == 0, Date().timeIntervalSince(settledAt) > 1 else { return }
        let playing = engine.isPlaying
        if playing != isPlaying {
            // Paused, played or run out from outside (headphones, another app,
            // the end of the queue).
            isPlaying = playing
            wantsPlaying = playing
        }
    }

    /// Follows the engine onto whichever song it's playing. Its entries
    /// mirror our queue, so match by position; if they don't line up (songs
    /// it couldn't play), fall back to the nearest same title and artist.
    private func syncCurrentEntry() {
        guard let entry = engine.currentEntry else { return }
        var match: Int?
        if entry.count == queue.count, queue.indices.contains(entry.position), queue[entry.position].title == entry.title {
            match = entry.position
        } else {
            let here = index ?? 0
            match = queue.indices
                .filter { queue[$0].title == entry.title && (entry.artist == nil || queue[$0].artistName == entry.artist) }
                .min { abs($0 - here) < abs($1 - here) }
        }
        if let match {
            if match != index {
                Self.log.info("now playing #\(match, privacy: .public) \(entry.title, privacy: .public) (was #\(self.index ?? -1, privacy: .public))")
                index = match
            }
        } else if lastUnmatchedEntry != entry.title {
            lastUnmatchedEntry = entry.title
            Self.log.error("can't find \(entry.title, privacy: .public) – \(entry.artist ?? "", privacy: .public) in our queue of \(self.queue.count, privacy: .public); the player has \(entry.count, privacy: .public) entries")
        }
    }

    // MARK: Engine

    /// Gives the engine the queue as it is now, starting at `start`. Whether
    /// it then plays follows what's wanted when preparing finishes, so a
    /// pause in the meantime holds; a newer queue cancels this one.
    private func startLive(at start: Int, from position: TimeInterval = 0) {
        liveGeneration += 1
        let generation = liveGeneration
        let tracks = queue
        pendingStarts += 1
        enqueue { engine in
            defer { self.pendingStarts -= 1 }
            guard generation == self.liveGeneration else { return }
            do {
                engine.setQueue(tracks, startingAt: start)
                try await engine.prepare()
                guard generation == self.liveGeneration else { return }
                if position > 0 { engine.playbackTime = position }
                if self.wantsPlaying { try await engine.play() } else { engine.pause() }
            } catch {
                Self.log.error("couldn't start playing: \(error.localizedDescription, privacy: .public)")
                self.report(error.localizedDescription)
            }
        }
    }

    /// Runs an engine command in turn, reporting it if it fails.
    private func live(_ work: @escaping @MainActor (LiveEngine) async throws -> Void) {
        enqueue { engine in
            do {
                try await work(engine)
            } catch {
                Self.log.error("player: \(error.localizedDescription, privacy: .public)")
                self.report(error.localizedDescription)
            }
        }
    }

    /// Engine commands run one at a time, in the order they were given, on
    /// the engine of the moment they were given (switching library stops the
    /// old one, not the new).
    private func enqueue(_ work: @escaping @MainActor (LiveEngine) async -> Void) {
        let previous = commandChain, engine = self.engine
        pendingCommands += 1
        commandChain = Task { @MainActor in
            await previous?.value
            await work(engine)
            self.pendingCommands -= 1
            self.settledAt = Date()
        }
    }
}
