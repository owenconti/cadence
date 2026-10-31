import AppKit
import Observation

/// Notices when `scripts/bundle.sh` has put a newer build in place of this one,
/// so the UI can offer Restart app, and relaunches into it on request.
@MainActor
@Observable
final class AppUpdate {
    /// A newer build has replaced this one's executable since launch.
    private(set) var isReady = false
    private(set) var isRestarting = false

    @ObservationIgnored private let launched = AppUpdate.stamp()
    @ObservationIgnored private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        guard let now = Self.stamp(), let launched else { return }
        let ready = now > launched
        if ready != isReady { isReady = ready }
    }

    private static func stamp() -> Date? {
        guard let path = Bundle.main.executablePath else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Opens a fresh copy of whatever build is on disk now, then quits this one.
    /// Saves `handoff` first so the new copy carries on where this one was.
    func relaunch(saving handoff: Handoff) {
        guard !isRestarting else { return }
        isRestarting = true
        handoff.save()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.environment = RunMode.environment
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if error == nil {
                    NSApp.terminate(nil)
                } else {
                    Handoff.clear()
                    self.isRestarting = false
                }
            }
        }
    }
}

/// What a restart carries from the old copy to the new one: where you were and
/// what was playing, so music resumes after a brief pause.
struct Handoff: Codable {
    var section: String
    var trackIDs: [String]
    var index: Int?
    var position: TimeInterval
    var isPlaying: Bool
    var windowFrame: CGRect?
    var savedAt = Date()

    /// Check copies keep theirs apart from the user's app.
    private static let key = RunMode.current == .check ? "cadence.handoff.check" : "cadence.handoff"

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Reads and clears a recent handoff; stale ones are ignored.
    static func take() -> Handoff? {
        defer { clear() }
        guard let data = UserDefaults.standard.data(forKey: key),
              let handoff = try? JSONDecoder().decode(Handoff.self, from: data),
              Date().timeIntervalSince(handoff.savedAt) < 120 else { return nil }
        return handoff
    }

    /// Where playback should pick up, counting the time the restart took.
    var resumePosition: TimeInterval {
        isPlaying ? position + Date().timeIntervalSince(savedAt) : position
    }
}
