import AppKit
import Observation

/// Notices when there's a newer build to restart into, so the UI can offer
/// Restart app: one `scripts/bundle.sh` put in place of this one, or a release
/// Sparkle has downloaded (`Updater`). Relaunches into it on request.
@MainActor
@Observable
final class AppUpdate {
    /// A newer build has replaced this one's executable since launch.
    private(set) var isReady = false
    private(set) var isRestarting = false

    @ObservationIgnored private let launched = AppUpdate.stamp()
    @ObservationIgnored private var timer: Timer?

    init() {
        Updater.shared?.onChange = { [weak self] in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        var ready = Updater.shared?.pendingVersion != nil
        if let now = Self.stamp(), let launched, now > launched { ready = true }
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
        // A downloaded release: Sparkle installs it and relaunches.
        if Updater.shared?.installNow() == true { return }
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

/// What a restart carries from the old copy to the new one, beyond the queue
/// (which `PlaybackStore` keeps on disk): where you were, and whether music
/// should keep playing.
struct Handoff: Codable {
    var section: String
    var windowFrame: CGRect?
    var keepPlaying: Bool
    var savedAt = Date()

    private static let key = "cadence.handoff"

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
}
