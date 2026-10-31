import AppKit
import SwiftUI

@main
struct CadenceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        // Always open the main window. Saved window state can come back with no
        // window at all, and Restart app carries the window's frame itself.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
    }

    var body: some Scene {
        WindowGroup("Cadence") {
            RootView()
                .environment(model)
            #if DEBUG
                .onAppear { SnapshotTour.runIfRequested(model) }
            #endif
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1380, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button(model.update.isReady ? "Restart to Update" : "Restart Cadence") { model.restartApp() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .sidebar) {
                Button(model.sidebarHidden ? "Show Sidebar" : "Hide Sidebar") { model.toggleSidebar() }
                    .keyboardShortcut("b")
                Button(model.nowPlayingMode ? "Leave Now Playing" : "Now Playing") { model.toggleNowPlayingMode() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(model.player.current == nil)
                Divider()
            }
            CommandMenu("Go") {
                Button("Search…") { model.palette.present() }
                    .keyboardShortcut("k")
                Divider()
                ForEach(Array(SidebarSection.allCases.enumerated()), id: \.element) { i, section in
                    Button(section.title) { model.select(section) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
                Button("Back") { model.back() }
                    .keyboardShortcut("[")
                    .disabled(model.stack.isEmpty)
            }
            CommandMenu("Playback") {
                Button(model.player.isPlaying ? "Pause" : "Play") { model.player.toggle() }
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Next Track") { model.player.next() }
                    .keyboardShortcut(.rightArrow)
                Button("Previous Track") { model.player.previous() }
                    .keyboardShortcut(.leftArrow)
                Divider()
                Toggle("Shuffle", isOn: Binding(get: { model.player.isShuffled }, set: { model.player.setShuffle($0) }))
                    .keyboardShortcut("s")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable rather than a bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
