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
        /// The same order as places in the queue, which tells copies of a
        /// song apart.
        var unshuffledPositions: [Int]?
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
    /// Encoding and writing happen here, in order, off the main thread.
    private let writer = DispatchQueue(label: "com.owenconti.cadence.playback-store", qos: .utility)
    /// What's on disk, kept by the writer itself, so a position is only ever
    /// written naming a queue file that was written in full.
    private let disk = Disk()

    private final class Disk: @unchecked Sendable {
        // Only touched on `writer`.
        var queueFile: String?
        var queueIDs: [String]?
    }

    /// Writes whatever changed: the queue only when its songs change, the
    /// position when the song or play state changes or every few seconds.
    ///
    /// Each queue gets a new file and the position names the file it goes
    /// with; older queue files go only once that position is written. A crash
    /// or a failed write leaves the previous queue and position, which match.
    /// Returns whether a forced save reached the disk.
    @discardableResult
    func save(_ player: Player, force: Bool = false) -> Bool {
        guard let current = player.current, let index = player.index else { return false }
        let ids = player.queue.map(\.id)
        let entries = ids != savedQueueIDs ? player.queue.map { Entry(id: $0.id, song: $0.song) } : nil
        let position = Position(live: player.backend == .musicKit, trackID: current.id, index: index, queueFile: nil,
                                position: player.position, isPlaying: player.isPlaying, shuffled: player.isShuffled,
                                unshuffledIDs: player.unshuffled?.map(\.id), unshuffledPositions: player.unshuffledPositions,
                                source: player.source)
        if entries == nil, !force, let last = savedPosition, last.trackID == position.trackID, last.index == position.index,
           last.isPlaying == position.isPlaying, last.shuffled == position.shuffled, last.unshuffledPositions == position.unshuffledPositions,
           last.source == position.source, abs(last.position - position.position) < 3 {
            return true
        }
        savedQueueIDs = ids
        savedPosition = position

        let directory = self.directory, positionFile = self.positionFile, disk = self.disk
        let work = { () -> Bool in
            func failed(_ what: String, _ error: Error) -> Bool {
                Self.log.error("couldn't save \(what, privacy: .public): \(error.localizedDescription, privacy: .public)")
                // Write everything again next time.
                DispatchQueue.main.async { MainActor.assumeIsolated { self.savedQueueIDs = nil; self.savedPosition = nil } }
                return false
            }
            var wroteQueue = false
            if let entries, ids != disk.queueIDs {
                let name = "queue-\(UUID().uuidString).json"
                do {
                    try JSONEncoder().encode(entries).write(to: directory.appendingPathComponent(name), options: .atomic)
                } catch {
                    return failed("the queue", error)
                }
                disk.queueFile = name
                disk.queueIDs = ids
                wroteQueue = true
            }
            // Only a position that matches the queue on disk.
            guard let queueFile = disk.queueFile, disk.queueIDs == ids else { return false }
            var position = position
            position.queueFile = queueFile
            do {
                try JSONEncoder().encode(position).write(to: positionFile, options: .atomic)
            } catch {
                return failed("the position", error)
            }
            if wroteQueue {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
                for name in names where name.hasPrefix("queue") && name.hasSuffix(".json") && name != queueFile {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
                }
            }
            return true
        }
        // Quitting or restarting: be on disk before going.
        if force { return writer.sync(execute: work) }
        writer.async { _ = work() }
        return true
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
        if tracks.count != entries.count {
            position.index = nil
            position.unshuffledPositions = nil
        }
        // What's on disk now: the queue as saved, before any lookups dropped songs.
        let disk = self.disk, savedIDs = entries.map(\.id), file = position.queueFile ?? "queue.json"
        writer.sync {
            disk.queueFile = file
            disk.queueIDs = savedIDs
        }
        savedQueueIDs = savedIDs
        savedPosition = position
        return (tracks, position)
    }
}
