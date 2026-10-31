import Foundation
import MusicKit

/// What actually plays the music. `Player` keeps the queue and decides what
/// should happen; an engine does it. Apple Music for the real library, a
/// simulated one for the demo library, which `make check` can also slow down
/// or make refuse things, to test the timing paths the real one hits.
///
/// The engine's queue holds one entry per queued copy of a song, in the same
/// order as `Player.queue` (songs it can't play are left out).
@MainActor
protocol LiveEngine: AnyObject {
    /// Replaces the queue, ready to start at the entry for `start` (an index
    /// into `tracks`).
    func setQueue(_ tracks: [TrackItem], startingAt start: Int)
    func prepare() async throws
    func play() async throws
    func pause()
    func stop()
    func skipToNext() async throws
    func skipToPrevious() async throws
    var playbackTime: TimeInterval { get set }
    var isPlaying: Bool { get }
    /// Adds a song after the current entry or at the end. Throws if it can't
    /// be queued.
    func insert(_ track: TrackItem, afterCurrent: Bool) async throws
    /// Puts the entries after the current one in a new order: `order` lists
    /// their present offsets (0 is the entry right after the current one).
    /// False if the engine's upcoming entries don't line up with `order`.
    func reorderUpcoming(_ order: [Int]) -> Bool
    /// Where the engine is: its current entry's place among its entries,
    /// how many it has, and the song's title and artist.
    var currentEntry: (position: Int, count: Int, title: String, artist: String?)? { get }
}

/// The engine for the real library: Apple Music's application player.
@MainActor
final class MusicKitEngine: LiveEngine {
    private var player: ApplicationMusicPlayer { .shared }

    func setQueue(_ tracks: [TrackItem], startingAt start: Int) {
        var entries: [MusicPlayer.Queue.Entry] = []
        var first: MusicPlayer.Queue.Entry?
        for (i, track) in tracks.enumerated() {
            guard let song = track.song else { continue }
            // One entry per copy, so a song queued twice is two entries and
            // the start is the very copy asked for.
            let entry = MusicPlayer.Queue.Entry(song)
            entries.append(entry)
            if i >= start, first == nil { first = entry }
        }
        player.queue = ApplicationMusicPlayer.Queue(entries, startingAt: first)
    }

    func prepare() async throws { try await player.prepareToPlay() }
    func play() async throws { try await player.play() }
    func pause() { player.pause() }
    func stop() { player.stop() }
    func skipToNext() async throws { try await player.skipToNextEntry() }
    func skipToPrevious() async throws { try await player.skipToPreviousEntry() }

    var playbackTime: TimeInterval {
        get { player.playbackTime }
        set { player.playbackTime = newValue }
    }

    var isPlaying: Bool { player.state.playbackStatus == .playing }

    func insert(_ track: TrackItem, afterCurrent: Bool) async throws {
        guard let song = track.song else { throw EngineError.notInAppleMusic }
        try await player.queue.insert(song, position: afterCurrent ? .afterCurrentEntry : .tail)
    }

    func reorderUpcoming(_ order: [Int]) -> Bool {
        var entries = player.queue.entries
        guard let current = player.queue.currentEntry,
              let at = entries.firstIndex(where: { $0.id == current.id }) else { return false }
        let next = entries.index(after: at)
        let upcoming = Array(entries[next...])
        guard upcoming.count == order.count, Set(order) == Set(upcoming.indices) else { return false }
        entries.replaceSubrange(next..., with: order.map { upcoming[$0] })
        player.queue.entries = entries
        return true
    }

    var currentEntry: (position: Int, count: Int, title: String, artist: String?)? {
        guard let entry = player.queue.currentEntry else { return nil }
        let entries = player.queue.entries
        guard let position = entries.firstIndex(where: { $0.id == entry.id }) else { return nil }
        return (position, entries.count, entry.title, entry.subtitle)
    }
}

enum EngineError: LocalizedError {
    case notInAppleMusic
    case refused

    var errorDescription: String? {
        switch self {
        case .notInAppleMusic: "Apple Music doesn't have it"
        case .refused: "The player refused it"
        }
    }
}

/// The demo library's engine: keeps time itself. `make check` sets `delays`
/// and `refuseInserts` to make it slow or unwilling, like Apple Music can be.
@MainActor
final class SimulatedEngine: LiveEngine {
    struct Delays {
        var prepare: Duration = .zero
        var play: Duration = .zero
        var insert: Duration = .zero
    }

    var delays = Delays()
    var refuseInserts = false
    private(set) var entries: [TrackItem] = []
    private(set) var index: Int?
    private var playing = false
    /// Time into the current entry when it was last paused or started, and when.
    private var base: TimeInterval = 0
    private var since = Date()

    func setQueue(_ tracks: [TrackItem], startingAt start: Int) {
        entries = tracks
        index = tracks.indices.contains(start) ? start : nil
        playing = false
        base = 0
    }

    func prepare() async throws {
        try await Task.sleep(for: delays.prepare)
    }

    func play() async throws {
        try await Task.sleep(for: delays.play)
        guard index != nil, !playing else { return }
        playing = true
        since = Date()
    }

    func pause() {
        guard playing else { return }
        base = playbackTime
        playing = false
    }

    func stop() {
        pause()
        entries = []
        index = nil
        base = 0
    }

    func skipToNext() async throws { move(by: 1) }
    func skipToPrevious() async throws { move(by: -1) }

    private func move(by step: Int) {
        guard let index else { return }
        let target = index + step
        guard entries.indices.contains(target) else {
            playing = false
            base = 0
            return
        }
        self.index = target
        base = 0
        since = Date()
    }

    var playbackTime: TimeInterval {
        get {
            advanceIfFinished()
            return playing ? base + Date().timeIntervalSince(since) : base
        }
        set {
            base = max(0, newValue)
            since = Date()
        }
    }

    var isPlaying: Bool {
        advanceIfFinished()
        return playing
    }

    /// Moves on to the next entry once the current one has played through.
    private func advanceIfFinished() {
        guard playing, let index, entries.indices.contains(index) else { return }
        let elapsed = base + Date().timeIntervalSince(since)
        guard elapsed >= entries[index].duration else { return }
        move(by: 1)
    }

    func insert(_ track: TrackItem, afterCurrent: Bool) async throws {
        try await Task.sleep(for: delays.insert)
        if refuseInserts { throw EngineError.refused }
        if afterCurrent, let index {
            entries.insert(track, at: index + 1)
        } else {
            entries.append(track)
        }
    }

    func reorderUpcoming(_ order: [Int]) -> Bool {
        guard let index else { return false }
        let upcoming = Array(entries[(index + 1)...])
        guard upcoming.count == order.count, Set(order) == Set(upcoming.indices) else { return false }
        entries.replaceSubrange((index + 1)..., with: order.map { upcoming[$0] })
        return true
    }

    var currentEntry: (position: Int, count: Int, title: String, artist: String?)? {
        advanceIfFinished()
        guard let index, entries.indices.contains(index) else { return nil }
        return (index, entries.count, entries[index].title, entries[index].artistName)
    }
}
