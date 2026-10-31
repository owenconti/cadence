import Foundation
import MusicKit
import os

/// What's playing, kept on disk in Application Support so it survives
/// quitting, crashes and Restart app. Apple Music songs are stored whole
/// (MusicKit items are Codable), so restoring needs no lookups; demo tracks
/// are stored by ID.
@MainActor
final class PlaybackStore {
    private struct Entry: Codable {
        var id: String
        var song: Song?
    }

    struct Position: Codable {
        /// Saved from Apple Music rather than the demo library.
        var live: Bool
        var trackID: String
        /// Where in the queue, since a song can be queued more than once.
        var index: Int?
        /// The queue file this position goes with (older saves: queue.json).
        var queueFile: String?
        var position: TimeInterval
        var isPlaying: Bool
        var shuffled: Bool? = false
        /// IDs in the queue's own order while shuffled.
        var unshuffledIDs: [String]?
        var source: QueueSource?
        var savedAt = Date()
    }

    private let directory: URL
    private var savedQueueIDs: [String]?
    private var savedPosition: Position?
    nonisolated private static let log = Logger(subsystem: "com.owenconti.cadence", category: "playback-store")

    init() {
        // Per bundle ID, so throwaway check copies keep their own.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Cadence", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var positionFile: URL { directory.appendingPathComponent("position.json") }
    /// The queue file the saved position belongs to.
    private var savedQueueFile: String?
    /// Encoding and writing happen here, in order, off the main thread.
    private let writer = DispatchQueue(label: "com.owenconti.cadence.playback-store", qos: .utility)

    /// Writes whatever changed: the queue only when its songs change, the
    /// position when the song or play state changes or every few seconds.
    ///
    /// Each queue gets a new file and the position names the file it goes
    /// with; older queue files go only once that position is written. A crash
    /// part-way through leaves the previous queue and position, which match.
    func save(_ player: Player, force: Bool = false) {
        guard let current = player.current, let index = player.index else { return }
        let ids = player.queue.map(\.id)
        var newQueue: (name: String, entries: [Entry])?
        if ids != savedQueueIDs {
            newQueue = ("queue-\(UUID().uuidString).json", player.queue.map { Entry(id: $0.id, song: $0.song) })
        }
        let queueFile = newQueue?.name ?? savedQueueFile ?? "queue.json"
        let position = Position(live: player.backend == .musicKit, trackID: current.id, index: index, queueFile: queueFile,
                                position: player.position, isPlaying: player.isPlaying, shuffled: player.isShuffled,
                                unshuffledIDs: player.unshuffled?.map(\.id), source: player.source)
        if newQueue == nil, !force, let last = savedPosition, last.trackID == position.trackID, last.index == position.index,
           last.isPlaying == position.isPlaying, last.shuffled == position.shuffled, last.unshuffledIDs == position.unshuffledIDs,
           last.source == position.source, abs(last.position - position.position) < 3 {
            return
        }

        let previous = (ids: savedQueueIDs, file: savedQueueFile, position: savedPosition)
        if newQueue != nil { savedQueueIDs = ids }
        savedQueueFile = queueFile
        savedPosition = position
        let directory = self.directory, positionFile = self.positionFile
        writer.async {
            func undo(_ what: String, _ error: Error) {
                Self.log.error("couldn't save \(what, privacy: .public): \(error.localizedDescription, privacy: .public)")
                // Try again on the next save.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.savedQueueIDs = previous.ids
                        self.savedQueueFile = previous.file
                        self.savedPosition = previous.position
                    }
                }
            }
            if let newQueue {
                do {
                    try JSONEncoder().encode(newQueue.entries).write(to: directory.appendingPathComponent(newQueue.name), options: .atomic)
                } catch {
                    return undo("the queue", error)
                }
            }
            do {
                try JSONEncoder().encode(position).write(to: positionFile, options: .atomic)
            } catch {
                return undo("the position", error)
            }
            guard newQueue != nil else { return }
            let stale = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in stale where name.hasPrefix("queue") && name.hasSuffix(".json") && name != queueFile {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        // Quitting or restarting: be on disk before going.
        if force { writer.sync {} }
    }

    /// The saved queue and where it was. Songs stored whole come back as they
    /// were; the rest are looked up by ID with `lookup`.
    func load(lookup: ([String]) async -> [TrackItem]) async -> (tracks: [TrackItem], position: Position)? {
        let directory = self.directory, positionFile = self.positionFile
        let read = await Task.detached(priority: .userInitiated) { () -> (entries: [Entry], position: Position)? in
            guard let positionData = try? Data(contentsOf: positionFile) else { return nil }
            do {
                let position = try JSONDecoder().decode(Position.self, from: positionData)
                let queueData = try Data(contentsOf: directory.appendingPathComponent(position.queueFile ?? "queue.json"))
                return (try JSONDecoder().decode([Entry].self, from: queueData), position)
            } catch {
                Self.log.error("couldn't read saved playback: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }.value
        guard let read else { return nil }
        let entries = read.entries
        let missing = entries.filter { $0.song == nil }.map(\.id)
        let found = missing.isEmpty ? [:] : Dictionary((await lookup(missing)).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let tracks = entries.compactMap { entry in entry.song.map(TrackItem.init(song:)) ?? found[entry.id] }
        Self.log.info("restored \(tracks.count, privacy: .public) of \(entries.count, privacy: .public) queued songs (\(entries.count - missing.count, privacy: .public) stored whole)")
        // A song that's gone shifts the positions; the index then no longer fits.
        var position = read.position
        if tracks.count != entries.count { position.index = nil }
        savedQueueIDs = tracks.map(\.id)
        savedQueueFile = position.queueFile
        savedPosition = position
        return (tracks, position)
    }
}
