import AppKit
import SwiftUI

@main
struct CadenceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

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
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable rather than a bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        MainActor.assumeIsolated { HotReload.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
