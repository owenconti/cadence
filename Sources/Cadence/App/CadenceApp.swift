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
        WindowGroup("Cadence", id: "main") {
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
            CommandGroup(replacing: .newItem) { FileMenuItems(model: model) }
            CommandGroup(before: .windowList) { WindowMenuItems() }
            CommandGroup(after: .appInfo) { AppMenuItems(model: model) }
            CommandGroup(replacing: .sidebar) { ViewMenuItems(model: model) }
            CommandMenu("Go") { GoMenuItems(model: model) }
            CommandMenu("Playback") { PlaybackMenuItems(model: model) }
        }
    }
}

/// ⌘N makes a playlist. ⌘W closes the window; the app keeps running, and playing.
private struct FileMenuItems: View {
    let model: AppModel

    var body: some View {
        Button("New Playlist…") { if model.phase == .ready { model.playlistPrompt = .create(with: nil) } }
            .keyboardShortcut("n")
        Divider()
        Button("Close Window") { NSApp.appWindow?.performClose(nil) }
            .keyboardShortcut("w")
    }
}

/// ⌘0 brings the window back (or to the front), as in Music. Clicking the
/// Dock icon does too.
private struct WindowMenuItems: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Cadence") { CadenceWindow.show(openWindow) }
            .keyboardShortcut("0")
        Divider()
    }
}

/// The one main window.
@MainActor
enum CadenceWindow {
    /// Fronts the window, or opens it again if it was closed.
    static func show(_ openWindow: OpenWindowAction) {
        if let window = NSApp.appWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        // A check copy stays in the background, out of the user's way.
        if RunMode.current != .check { NSApp.activate() }
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
        if let track = model.player.current {
            Menu("Add Current Song to Playlist") {
                Button("New Playlist…") { model.playlistPrompt = .create(with: track) }
                if !model.addablePlaylists.isEmpty {
                    Divider()
                    ForEach(model.addablePlaylists) { playlist in
                        Button(playlist.name) { model.add(track, to: playlist) }
                    }
                }
            }
        }
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

    /// Closing the window (⌘W) leaves the app running and the music playing;
    /// the Dock icon or ⌘0 brings the window back, ⌘Q quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
