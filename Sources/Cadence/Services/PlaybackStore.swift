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
        var position: TimeInterval
        var isPlaying: Bool
        var savedAt = Date()
    }

    private let directory: URL
    private var savedQueueIDs: [String]?
    private var savedPosition: Position?
    private static let log = Logger(subsystem: "com.owenconti.cadence", category: "playback-store")

    init() {
        // Per bundle ID, so throwaway check copies keep their own.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Cadence", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var queueFile: URL { directory.appendingPathComponent("queue.json") }
    private var positionFile: URL { directory.appendingPathComponent("position.json") }

    /// Writes whatever changed: the queue only when its songs change, the
    /// position when the song or play state changes or every few seconds.
    func save(_ player: Player, force: Bool = false) {
        guard let current = player.current else { return }
        let ids = player.queue.map(\.id)
        if ids != savedQueueIDs {
            let entries = player.queue.map { Entry(id: $0.id, song: $0.song) }
            do {
                try JSONEncoder().encode(entries).write(to: queueFile, options: .atomic)
                savedQueueIDs = ids
            } catch {
                Self.log.error("couldn't save the queue: \(error.localizedDescription, privacy: .public)")
            }
        }
        let position = Position(live: player.backend == .musicKit, trackID: current.id, position: player.position, isPlaying: player.isPlaying)
        let last = savedPosition
        guard force || last == nil || last!.trackID != position.trackID || last!.isPlaying != position.isPlaying
                || abs(last!.position - position.position) >= 3 else { return }
        if let data = try? JSONEncoder().encode(position), (try? data.write(to: positionFile, options: .atomic)) != nil {
            savedPosition = position
        }
    }

    /// The saved queue and where it was. Songs stored whole come back as they
    /// were; the rest are looked up by ID with `lookup`.
    func load(lookup: ([String]) async -> [TrackItem]) async -> (tracks: [TrackItem], position: Position)? {
        guard let queueData = try? Data(contentsOf: queueFile),
              let positionData = try? Data(contentsOf: positionFile) else { return nil }
        let entries: [Entry]
        let position: Position
        do {
            entries = try JSONDecoder().decode([Entry].self, from: queueData)
            position = try JSONDecoder().decode(Position.self, from: positionData)
        } catch {
            Self.log.error("couldn't read saved playback: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let missing = entries.filter { $0.song == nil }.map(\.id)
        let found = missing.isEmpty ? [:] : Dictionary((await lookup(missing)).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let tracks = entries.compactMap { entry in entry.song.map(TrackItem.init(song:)) ?? found[entry.id] }
        Self.log.info("restored \(tracks.count, privacy: .public) of \(entries.count, privacy: .public) queued songs (\(entries.count - missing.count, privacy: .public) stored whole)")
        savedQueueIDs = tracks.map(\.id)
        savedPosition = position
        return (tracks, position)
    }
}
