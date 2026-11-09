import CloudKit
import Foundation
import os

/// My Playlists: Cadence's own playlists, kept on disk and, for Apple Music,
/// synced through the user's iCloud (`CloudStore`). Unlike Apple Music's
/// playlists, Cadence can do anything with these on every device.
///
/// Each playlist is one "Playlist" record: its name, dates, where it was
/// copied from, and its songs as JSON (`songs`). Edits replace the record, so
/// two devices editing one playlist at once keep the last save.
@MainActor
@Observable
final class CadencePlaylists: CloudRecordKind {
    /// Newest change first.
    private(set) var all: [CadencePlaylist] = []

    let recordType = "Playlist"
    /// CloudKit's own fields for each record (its change tag), by playlist ID,
    /// so a save replaces the server's copy rather than clashing with it.
    @ObservationIgnored private var systemFields: [String: Data] = [:]
    @ObservationIgnored private let file: URL
    @ObservationIgnored weak var cloud: CloudStore?
    nonisolated private static let log = Logger(subsystem: "com.owenconti.cadence", category: "my-playlists")

    private struct Saved: Codable {
        var playlists: [CadencePlaylist]
        var systemFields: [String: Data]
    }

    /// `name` keeps the demo library's playlists apart from Apple Music's.
    init(name: String) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Cadence", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("\(name).json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            all = saved.playlists
            systemFields = saved.systemFields
            sort()
        }
    }

    func playlist(id: String) -> CadencePlaylist? {
        let id = id.hasPrefix(CadencePlaylist.idPrefix) ? String(id.dropFirst(CadencePlaylist.idPrefix.count)) : id
        return all.first { $0.id == id }
    }

    // MARK: Changes

    @discardableResult
    func create(named name: String, songs: [SongRef] = [], copiedFrom: String? = nil) -> CadencePlaylist {
        let now = Date()
        let playlist = CadencePlaylist(id: UUID().uuidString, name: name, songs: songs, createdAt: now, modifiedAt: now, copiedFrom: copiedFrom)
        all.insert(playlist, at: 0)
        changed(playlist.id)
        return playlist
    }

    func rename(_ id: String, to name: String) {
        update(id) { $0.name = name }
    }

    func setSongs(_ id: String, _ songs: [SongRef]) {
        update(id) { $0.songs = songs }
    }

    func append(_ songs: [SongRef], to id: String) {
        update(id) { $0.songs += songs }
    }

    func delete(_ id: String) {
        guard let playlist = playlist(id: id) else { return }
        all.removeAll { $0.id == playlist.id }
        systemFields[playlist.id] = nil
        save()
        cloud?.deleted(playlist.id, of: self)
    }

    private func update(_ id: String, _ change: (inout CadencePlaylist) -> Void) {
        guard let playlist = playlist(id: id), let i = all.firstIndex(where: { $0.id == playlist.id }) else { return }
        change(&all[i])
        all[i].modifiedAt = Date()
        sort()
        changed(playlist.id)
    }

    private func changed(_ id: String) {
        save()
        cloud?.saved(id, of: self)
    }

    private func sort() {
        all.sort { $0.modifiedAt > $1.modifiedAt }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(Saved(playlists: all, systemFields: systemFields))
            try data.write(to: file, options: .atomic)
        } catch {
            Self.log.error("couldn't save My Playlists: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: CloudRecordKind

    func record(for id: String, recordID: CKRecord.ID) -> CKRecord? {
        guard let playlist = all.first(where: { $0.id == id }) else { return nil }
        let record = systemFields[id].flatMap(Self.record(fromSystemFields:)) ?? CKRecord(recordType: recordType, recordID: recordID)
        record["name"] = playlist.name
        record["createdAt"] = playlist.createdAt
        record["modifiedAt"] = playlist.modifiedAt
        record["copiedFrom"] = playlist.copiedFrom
        record["songs"] = (try? JSONEncoder().encode(playlist.songs)).flatMap { String(data: $0, encoding: .utf8) }
        return record
    }

    func apply(_ record: CKRecord, id: String) {
        systemFields[id] = Self.systemFields(of: record)
        let songs = (record["songs"] as? String).flatMap { try? JSONDecoder().decode([SongRef].self, from: Data($0.utf8)) } ?? []
        let now = Date()
        let playlist = CadencePlaylist(
            id: id,
            name: record["name"] as? String ?? "Untitled",
            songs: songs,
            createdAt: record["createdAt"] as? Date ?? now,
            modifiedAt: record["modifiedAt"] as? Date ?? now,
            copiedFrom: record["copiedFrom"] as? String
        )
        if let i = all.firstIndex(where: { $0.id == id }) {
            // A record we just sent comes back with only its tag changed.
            if all[i] != playlist { all[i] = playlist }
        } else {
            all.append(playlist)
        }
        sort()
        save()
    }

    func remove(id: String) {
        all.removeAll { $0.id == id }
        systemFields[id] = nil
        save()
    }

    func removeAll() {
        all = []
        systemFields = [:]
        save()
    }

    /// Playlists iCloud has never had: made before syncing started, or with
    /// no iCloud account.
    var unsentIDs: [String] { all.map(\.id).filter { systemFields[$0] == nil } }

    private static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    private static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }
}
