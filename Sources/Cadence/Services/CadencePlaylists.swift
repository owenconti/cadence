import CloudKit
import Foundation
import os

/// My Playlists: Cadence's own playlists, kept on disk and, for Apple Music,
/// synced through the user's iCloud (`CloudStore`). Unlike Apple Music's
/// playlists, Cadence can do anything with these on every device.
///
/// Each playlist is one "Playlist" record: its name, dates, where it was
/// copied from, its folder, and its songs as JSON (`songs`). Each folder is
/// one "Folder" record (`folderRecords`). Edits replace the record, so two
/// devices editing one playlist at once keep the last save.
@MainActor
@Observable
final class CadencePlaylists: CloudRecordKind {
    /// Newest change first.
    private(set) var all: [CadencePlaylist] = []
    /// Folders, A–Z.
    fileprivate(set) var folders: [PlaylistFolder] = []

    let recordType = "Playlist"
    /// The folders' side of syncing; register it with the store too.
    @ObservationIgnored let folderRecords = FolderRecords()
    /// CloudKit's own fields for each record (its change tag), by playlist ID,
    /// so a save replaces the server's copy rather than clashing with it.
    @ObservationIgnored private var systemFields: [String: Data] = [:]
    @ObservationIgnored fileprivate var folderSystemFields: [String: Data] = [:]
    /// Changes iCloud hasn't confirmed saving yet, by ID, sent again by the
    /// next sync (Sync Now, or the next launch): a save iCloud refused (say,
    /// before a new field was deployed to its schema) isn't lost.
    @ObservationIgnored private var unconfirmed: Set<String> = []
    @ObservationIgnored fileprivate var unconfirmedFolders: Set<String> = []
    @ObservationIgnored private let file: URL
    @ObservationIgnored weak var cloud: CloudStore?
    nonisolated fileprivate static let log = Logger(subsystem: "com.owenconti.cadence", category: "my-playlists")

    private struct Saved: Codable {
        var playlists: [CadencePlaylist]
        var systemFields: [String: Data]
        // Added with folders; older files have none.
        var folders: [PlaylistFolder]?
        var folderSystemFields: [String: Data]?
        var unconfirmed: Set<String>?
        var unconfirmedFolders: Set<String>?
    }

    /// `name` keeps the demo library's playlists apart from Apple Music's;
    /// `directory` is the app's own unless given (the audit's).
    init(name: String, directory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = directory ?? support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Cadence", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("\(name).json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            all = saved.playlists
            systemFields = saved.systemFields
            folders = saved.folders ?? []
            folderSystemFields = saved.folderSystemFields ?? [:]
            unconfirmed = saved.unconfirmed ?? []
            unconfirmedFolders = saved.unconfirmedFolders ?? []
            sort()
        }
        folderRecords.owner = self
    }

    func playlist(id: String) -> CadencePlaylist? {
        let id = id.hasPrefix(CadencePlaylist.idPrefix) ? String(id.dropFirst(CadencePlaylist.idPrefix.count)) : id
        return all.first { $0.id == id }
    }

    func folder(id: String?) -> PlaylistFolder? {
        guard let id else { return nil }
        return folders.first { $0.id == id }
    }

    /// The folder a playlist is in, if it's in one that exists.
    func folder(of playlist: CadencePlaylist) -> PlaylistFolder? {
        folder(id: playlist.folderID)
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

    /// Puts a playlist in a folder, or (nil) takes it out of its folder.
    func move(_ id: String, to folderID: String?) {
        guard let playlist = playlist(id: id), playlist.folderID != folderID else { return }
        update(id) { $0.folderID = folderID }
    }

    func delete(_ id: String) {
        guard let playlist = playlist(id: id) else { return }
        all.removeAll { $0.id == playlist.id }
        systemFields[playlist.id] = nil
        unconfirmed.remove(playlist.id)
        save()
        cloud?.deleted(playlist.id, of: self)
    }

    // MARK: Folders

    @discardableResult
    func createFolder(named name: String) -> PlaylistFolder {
        let now = Date()
        let folder = PlaylistFolder(id: UUID().uuidString, name: name, createdAt: now, modifiedAt: now)
        folders.append(folder)
        sortFolders()
        folderChanged(folder.id)
        return folder
    }

    func renameFolder(_ id: String, to name: String) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].name = name
        folders[i].modifiedAt = Date()
        sortFolders()
        folderChanged(id)
    }

    /// Deletes a folder; its playlists stay, out of any folder.
    func deleteFolder(_ id: String) {
        guard folders.contains(where: { $0.id == id }) else { return }
        for playlist in all where playlist.folderID == id { move(playlist.id, to: nil) }
        folders.removeAll { $0.id == id }
        folderSystemFields[id] = nil
        unconfirmedFolders.remove(id)
        save()
        cloud?.deleted(id, of: folderRecords)
    }

    private func folderChanged(_ id: String) {
        unconfirmedFolders.insert(id)
        save()
        cloud?.saved(id, of: folderRecords)
    }

    fileprivate func sortFolders() {
        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func update(_ id: String, _ change: (inout CadencePlaylist) -> Void) {
        guard let playlist = playlist(id: id), let i = all.firstIndex(where: { $0.id == playlist.id }) else { return }
        change(&all[i])
        all[i].modifiedAt = Date()
        sort()
        changed(playlist.id)
    }

    private func changed(_ id: String) {
        unconfirmed.insert(id)
        save()
        cloud?.saved(id, of: self)
    }

    private func sort() {
        all.sort { $0.modifiedAt > $1.modifiedAt }
    }

    fileprivate func save() {
        do {
            let data = try JSONEncoder().encode(Saved(playlists: all, systemFields: systemFields, folders: folders,
                                                      folderSystemFields: folderSystemFields, unconfirmed: unconfirmed,
                                                      unconfirmedFolders: unconfirmedFolders))
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
        record["folder"] = playlist.folderID
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
            copiedFrom: record["copiedFrom"] as? String,
            folderID: record["folder"] as? String
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

    func saved(_ record: CKRecord?, id: String) {
        systemFields[id] = record.map(Self.systemFields(of:))
        save()
    }

    func confirmed(_ record: CKRecord, id: String) {
        // Unless it changed again since this copy was sent.
        guard let playlist = all.first(where: { $0.id == id }), record["modifiedAt"] as? Date == playlist.modifiedAt else { return }
        if unconfirmed.remove(id) != nil { save() }
    }

    func remove(id: String) {
        all.removeAll { $0.id == id }
        systemFields[id] = nil
        unconfirmed.remove(id)
        save()
    }

    func removeAll() {
        all = []
        systemFields = [:]
        unconfirmed = []
        save()
    }

    /// Playlists iCloud has never had (made before syncing started, or with
    /// no iCloud account), and changes it hasn't confirmed.
    var unsentIDs: [String] { all.map(\.id).filter { systemFields[$0] == nil || unconfirmed.contains($0) } }

    fileprivate static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    fileprivate static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }
}

/// My Playlists' folders as iCloud records: one "Folder" record each, with
/// its name and dates. Playlists name their folder in their own record
/// ("folder"), so moving one saves only the playlist.
@MainActor
final class FolderRecords: CloudRecordKind {
    let recordType = "Folder"
    fileprivate weak var owner: CadencePlaylists?

    func record(for id: String, recordID: CKRecord.ID) -> CKRecord? {
        guard let owner, let folder = owner.folders.first(where: { $0.id == id }) else { return nil }
        let record = owner.folderSystemFields[id].flatMap(CadencePlaylists.record(fromSystemFields:))
            ?? CKRecord(recordType: recordType, recordID: recordID)
        record["name"] = folder.name
        record["createdAt"] = folder.createdAt
        record["modifiedAt"] = folder.modifiedAt
        return record
    }

    func apply(_ record: CKRecord, id: String) {
        guard let owner else { return }
        owner.folderSystemFields[id] = CadencePlaylists.systemFields(of: record)
        let now = Date()
        let folder = PlaylistFolder(
            id: id,
            name: record["name"] as? String ?? "Untitled Folder",
            createdAt: record["createdAt"] as? Date ?? now,
            modifiedAt: record["modifiedAt"] as? Date ?? now
        )
        if let i = owner.folders.firstIndex(where: { $0.id == id }) {
            if owner.folders[i] != folder { owner.folders[i] = folder }
        } else {
            owner.folders.append(folder)
        }
        owner.sortFolders()
        owner.save()
    }

    func saved(_ record: CKRecord?, id: String) {
        owner?.folderSystemFields[id] = record.map(CadencePlaylists.systemFields(of:))
        owner?.save()
    }

    func confirmed(_ record: CKRecord, id: String) {
        guard let owner, let folder = owner.folders.first(where: { $0.id == id }),
              record["modifiedAt"] as? Date == folder.modifiedAt else { return }
        if owner.unconfirmedFolders.remove(id) != nil { owner.save() }
    }

    /// Deleted on another device: its playlists there were taken out of it,
    /// and any here that still name it count as in no folder.
    func remove(id: String) {
        guard let owner else { return }
        owner.folders.removeAll { $0.id == id }
        owner.folderSystemFields[id] = nil
        owner.unconfirmedFolders.remove(id)
        owner.save()
    }

    func removeAll() {
        guard let owner else { return }
        owner.folders = []
        owner.folderSystemFields = [:]
        owner.unconfirmedFolders = []
        owner.save()
    }

    var unsentIDs: [String] {
        guard let owner else { return [] }
        return owner.folders.map(\.id).filter { owner.folderSystemFields[$0] == nil || owner.unconfirmedFolders.contains($0) }
    }
}
