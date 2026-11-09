import CloudKit
import Foundation
import os

/// Cadence's own data (not Apple Music's), synced between the user's devices
/// through their private iCloud database. Nothing signs in: CloudKit uses the
/// Apple ID the device is signed into, and each person only ever sees their
/// own records.
///
/// Everything lives in one record zone, "Cadence", kept in step by
/// `CKSyncEngine`, which saves local edits when it can and fetches other
/// devices' edits on launch and on return to the app. Features plug in with
/// `register(_:)`: a `CloudRecordKind` names a record type and turns its
/// values into records and back. Record names are "<type>/<id>", so a pending
/// change finds its kind again.
///
/// Only copies signed with the iCloud entitlement can use CloudKit (any other
/// copy would crash on touching it). The signing scripts add the container to
/// Info.plist (`CadenceCloudContainer`) exactly when they sign with it, so
/// check copies, the simulator and the demo library leave this `.off`.
@MainActor
@Observable
final class CloudStore {
    enum Status: Equatable {
        /// This copy isn't signed for iCloud, or runs on the demo library.
        case off
        case starting
        /// No Apple ID signed in to iCloud, or iCloud Drive is off for the app.
        case noAccount
        case syncing
        case synced(Date)
        case failed(String)
    }

    private(set) var status: Status = .off

    static let zoneID = CKRecordZone.ID(zoneName: "Cadence", ownerName: CKCurrentUserDefaultName)
    nonisolated static let containerKey = "CadenceCloudContainer"
    nonisolated private static let log = Logger(subsystem: "com.owenconti.cadence", category: "cloud")

    /// The container this copy was signed for, if any.
    nonisolated static var containerIdentifier: String? {
        Bundle.main.object(forInfoDictionaryKey: containerKey) as? String
    }

    @ObservationIgnored private var engine: CKSyncEngine?
    @ObservationIgnored private var bridge: Bridge?
    @ObservationIgnored private var kinds: [String: any CloudRecordKind] = [:]
    @ObservationIgnored private let stateFile: URL

    /// `directory` keeps the sync state; by default the app's own, per bundle
    /// ID beside the saved queue (the audit passes one of its own).
    init(directory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = directory ?? support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Cadence", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stateFile = directory.appendingPathComponent("cloud-sync-state.json")
    }

    // MARK: Features

    /// Hooks up one kind of record. Register before `start()` so the first
    /// fetch reaches it.
    func register(_ kind: any CloudRecordKind) {
        kinds[kind.recordType] = kind
    }

    /// Queues a save of `id` (of `kind`); the engine asks the kind for the
    /// record when it sends, so several edits in a row send once.
    func saved(_ id: String, of kind: any CloudRecordKind) {
        queue(.saveRecord(Self.recordID(kind.recordType, id)))
    }

    func deleted(_ id: String, of kind: any CloudRecordKind) {
        queue(.deleteRecord(Self.recordID(kind.recordType, id)))
    }

    /// Changes made before the engine is running wait here.
    @ObservationIgnored private var waiting: [CKSyncEngine.PendingRecordZoneChange] = []

    private func queue(_ change: CKSyncEngine.PendingRecordZoneChange) {
        if let engine { engine.state.add(pendingRecordZoneChanges: [change]) } else if status != .off { waiting.append(change) }
    }

    static func recordID(_ type: String, _ id: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(type)/\(id)", zoneID: zoneID)
    }

    private func kind(of recordID: CKRecord.ID) -> (any CloudRecordKind, String)? {
        let parts = recordID.recordName.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let kind = kinds[String(parts[0])] else { return nil }
        return (kind, String(parts[1]))
    }

    // MARK: Lifecycle

    /// Starts syncing, if this copy is signed for iCloud. Safe to call again.
    func start() {
        guard engine == nil, let identifier = Self.containerIdentifier else { return }
        status = .starting
        let container = CKContainer(identifier: identifier)
        Task {
            do {
                switch try await container.accountStatus() {
                case .available: break
                default:
                    status = .noAccount
                    Self.log.notice("iCloud account unavailable")
                    return
                }
            } catch {
                status = .failed(error.localizedDescription)
                return
            }
            let bridge = Bridge(store: self)
            var configuration = CKSyncEngine.Configuration(
                database: container.privateCloudDatabase,
                stateSerialization: loadState(),
                delegate: bridge
            )
            // No push entitlement yet: fetch on launch and on return to the app.
            configuration.automaticallySync = true
            self.bridge = bridge
            let engine = CKSyncEngine(configuration)
            self.engine = engine
            // Make sure the zone exists; a no-op once it does.
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            // What iCloud has never had, and what changed meanwhile.
            for kind in kinds.values {
                engine.state.add(pendingRecordZoneChanges: kind.unsentIDs.map { .saveRecord(Self.recordID(kind.recordType, $0)) })
            }
            engine.state.add(pendingRecordZoneChanges: waiting)
            waiting = []
            await sync()
        }
    }

    /// Sends pending edits and fetches everyone else's.
    func sync() async {
        guard let engine, status != .syncing else { return }
        status = .syncing
        unsaved = nil
        do {
            do {
                try await engine.sendChanges()
            } catch let error as CKError where error.code == .partialFailure && unsaved == nil {
                // Every failed save was sorted out (a clash, a missing zone)
                // and queued again: send those now.
                try await engine.sendChanges()
            }
            try await engine.fetchChanges()
            if let unsaved {
                status = .failed(unsaved)
            } else {
                status = .synced(Date())
            }
        } catch {
            status = .failed(unsaved ?? error.localizedDescription)
            Self.log.error("sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Why a record couldn't be saved during this sync, if one couldn't.
    @ObservationIgnored private var unsaved: String?

    /// Whether a sync can be asked for (the Sync Now button).
    var canSync: Bool { engine != nil && status != .syncing }

    // MARK: Engine events

    private func loadState() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: stateFile) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    fileprivate func handle(_ event: CKSyncEngine.Event) {
        switch event {
        case .stateUpdate(let update):
            if let data = try? JSONEncoder().encode(update.stateSerialization) {
                try? data.write(to: stateFile, options: .atomic)
            }
        case .accountChange(let change):
            switch change.changeType {
            case .signIn: status = .syncing
            case .signOut, .switchAccounts:
                // Another person's data mustn't linger.
                for kind in kinds.values { kind.removeAll() }
                try? FileManager.default.removeItem(at: stateFile)
                status = .noAccount
            @unknown default: break
            }
        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications {
                if let (kind, id) = kind(of: modification.record.recordID) {
                    kind.apply(modification.record, id: id)
                }
            }
            for deletion in changes.deletions {
                if let (kind, id) = kind(of: deletion.recordID) { kind.remove(id: id) }
            }
        case .fetchedDatabaseChanges(let changes):
            if changes.deletions.contains(where: { $0.zoneID == Self.zoneID }) {
                for kind in kinds.values { kind.removeAll() }
            }
        case .sentRecordZoneChanges(let sent):
            // Each save's new change tag, so the next save of it replaces it
            // rather than clashing with it.
            for record in sent.savedRecords {
                if let (kind, id) = kind(of: record.recordID) { kind.saved(record, id: id) }
            }
            for failure in sent.failedRecordSaves {
                let recordID = failure.record.recordID
                switch failure.error.code {
                case .serverRecordChanged:
                    // iCloud's copy changed since this device last saw it:
                    // ours is newer, so it's saved over theirs.
                    if let server = failure.error.serverRecord, let (kind, id) = kind(of: recordID) {
                        kind.saved(server, id: id)
                        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                    }
                case .zoneNotFound, .userDeletedZone:
                    if let (kind, id) = kind(of: recordID) { kind.saved(nil, id: id) }
                    engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                    engine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                case .unknownItem:
                    // Gone from iCloud: saved afresh.
                    if let (kind, id) = kind(of: recordID) { kind.saved(nil, id: id) }
                    engine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                default:
                    // Left unsent: the next launch sends it again (`unsentIDs`).
                    unsaved = failure.error.localizedDescription
                    if status != .syncing { status = .failed(failure.error.localizedDescription) }
                    Self.log.error("couldn't save \(recordID.recordName, privacy: .public): \(failure.error.localizedDescription, privacy: .public)")
                }
            }
        default:
            break
        }
    }

    fileprivate func batch(_ context: CKSyncEngine.SendChangesContext) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let engine else { return nil }
        let pending = engine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        // Records are built here, on the main actor with the features' values;
        // the batch only looks them up.
        var records: [CKRecord.ID: CKRecord] = [:]
        for case .saveRecord(let recordID) in pending {
            if let (kind, id) = kind(of: recordID), let record = kind.record(for: id, recordID: recordID) {
                records[recordID] = record
            } else {
                // Gone locally since it was queued.
                engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            }
        }
        let ready = pending.filter {
            if case .saveRecord(let recordID) = $0 { return records[recordID] != nil }
            return true
        }
        guard !ready.isEmpty else { return nil }
        let built = records
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: ready) { built[$0] }
    }

    /// The engine's delegate, off the main actor; everything it hears goes to
    /// the store.
    private final class Bridge: CKSyncEngineDelegate, @unchecked Sendable {
        weak var store: CloudStore?
        init(store: CloudStore) { self.store = store }

        func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
            await store?.handle(event)
        }

        func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
            await store?.batch(context)
        }
    }
}

/// One kind of record Cadence keeps in iCloud. The feature owns the values;
/// this turns them into records and back.
@MainActor
protocol CloudRecordKind: AnyObject {
    /// The CloudKit record type, e.g. "Playlist". Also the record name prefix.
    var recordType: String { get }
    /// The record to send for `id`, or nil if it no longer exists. Start from
    /// the last record seen for it (keeps CloudKit's change tag) when there is one.
    func record(for id: String, recordID: CKRecord.ID) -> CKRecord?
    /// A record arrived from iCloud (another device's edit, or the server's copy).
    func apply(_ record: CKRecord, id: String)
    func remove(id: String)
    /// The iCloud account changed or the zone was deleted.
    func removeAll()
    /// Records iCloud has never had, sent when syncing starts.
    var unsentIDs: [String] { get }
    /// iCloud's latest copy of a record (its change tag; not its values,
    /// which may be older than this device's), or nil to forget it.
    func saved(_ record: CKRecord?, id: String)
}
