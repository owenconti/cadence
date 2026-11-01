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
            // Each menu's items are a view of their own, so SwiftUI refreshes
            // their titles. Items aren't disabled by state: AppKit can match a
            // shortcut against a menu that hasn't refreshed yet (a disabled
            // Now Playing ignored ⇧⌘F while music played), and every action
            // here is harmless when there's nothing to do.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) { AppMenuItems(model: model) }
            CommandGroup(replacing: .sidebar) { ViewMenuItems(model: model) }
            CommandMenu("Go") { GoMenuItems(model: model) }
            CommandMenu("Playback") { PlaybackMenuItems(model: model) }
        }
    }
}

private struct AppMenuItems: View {
    let model: AppModel

    var body: some View {
        Button(model.update.isReady ? "Restart to Update" : "Restart Cadence") { model.restartApp() }
            .keyboardShortcut("r", modifiers: [.command, .option])
        if let updater = Updater.shared {
            Button("Check for Updates…") { updater.checkNow() }
        }
    }
}

private struct ViewMenuItems: View {
    let model: AppModel

    var body: some View {
        Button(model.sidebarHidden ? "Show Sidebar" : "Hide Sidebar") { model.toggleSidebar() }
            .keyboardShortcut("b")
        Button(model.nowPlayingMode ? "Leave Now Playing" : "Now Playing") { model.toggleNowPlayingMode() }
            .keyboardShortcut("f", modifiers: [.command, .shift])
        Button("Reset Panel Widths") { model.resetPanelWidths() }
        Divider()
    }
}

private struct GoMenuItems: View {
    let model: AppModel

    var body: some View {
        Button("Search…") { model.palette.present() }
            .keyboardShortcut("k")
        Divider()
        ForEach(Array(SidebarSection.allCases.enumerated()), id: \.element) { i, section in
            Button(section.title) { model.select(section) }
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
        }
        Button("Back") { model.back() }
            .keyboardShortcut("[")
    }
}

private struct PlaybackMenuItems: View {
    let model: AppModel

    var body: some View {
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable rather than a bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
