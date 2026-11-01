import AppKit
import Sparkle

/// Updates for copies people download (`make release`): Sparkle checks the
/// GitHub feed and downloads a new version quietly; the sidebar then shows
/// Update ready and Restart app installs it, carrying on where it was.
/// Otherwise it installs when the app quits. Other copies (yours, rebuilt by
/// `make update`; check copies) have no feed and no updater.
@MainActor
final class Updater: NSObject {
    static let shared: Updater? =
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil && RunMode.current == .normal ? Updater() : nil

    /// The downloaded version waiting to install, if any.
    private(set) var pendingVersion: String? { didSet { onChange?() } }
    var onChange: (() -> Void)?
    private var installBlock: (() -> Void)?
    private var controller: SPUStandardUpdaterController?

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    /// Installs the downloaded update now: Sparkle quits, replaces and
    /// relaunches the app. False when nothing is waiting.
    func installNow() -> Bool {
        guard let installBlock else { return false }
        installBlock()
        return true
    }

    /// Check for Updates…: Sparkle says whether there's a newer version (and
    /// offers it) or that this one is the latest.
    func checkNow() {
        controller?.checkForUpdates(nil)
    }
}

extension Updater: SPUUpdaterDelegate {
    /// A downloaded update waits for the app to quit; keep Sparkle's handle so
    /// Restart app can install it at once.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            installBlock = immediateInstallHandler
            pendingVersion = version
        }
        return true
    }
}
