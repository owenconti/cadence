import SwiftUI

/// Hot reloading for development via InjectionIII (see `scripts/dev.sh`).
///
/// InjectionIII recompiles a saved file and swaps the new code into the
/// running app. Views call `HotReload.observe()` so they redraw when that
/// happens, and `hotReloadable()` type-erases their body so an edit that
/// changes a view's structure still fits. Both are no-ops in release builds.
@MainActor
enum HotReload {
    static func observe() {
        #if DEBUG
        _ = Counter.shared.generation
        #endif
    }

    /// Loads InjectionIII's bundle when the app is launched by `scripts/dev.sh`.
    static func start() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["CADENCE_HOT_RELOAD"] != nil else { return }
        // Sources/Cadence/App/HotReload.swift → project root.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // InjectionIII reports through print(); flush it straight to build/dev.log.
        setvbuf(stdout, nil, _IONBF, 0)
        setenv("INJECTION_STANDALONE", "1", 1)
        setenv("INJECTION_PROJECT_ROOT", root.path, 1)
        setenv("INJECTION_DIRECTORIES", root.appendingPathComponent("Sources").path, 1)
        _ = Counter.shared
        Bundle(path: "/Applications/InjectionIII.app/Contents/Resources/macOSInjection.bundle")?.load()
        #endif
    }

    #if DEBUG
    @Observable
    final class Counter {
        static let shared = Counter()
        private(set) var generation = 0

        private init() {
            NotificationCenter.default.addObserver(
                forName: Notification.Name("INJECTION_BUNDLE_NOTIFICATION"), object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    Counter.shared.generation += 1
                    NSLog("Cadence: hot reload #%d applied", Counter.shared.generation)
                }
            }
        }
    }
    #endif
}

extension View {
    @ViewBuilder
    func hotReloadable() -> some View {
        #if DEBUG
        AnyView(self)
        #else
        self
        #endif
    }
}
