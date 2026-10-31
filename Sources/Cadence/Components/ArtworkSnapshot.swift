import AppKit
import MusicKit
import SwiftUI

/// Draws MusicKit artwork into an image. Library artwork is a
/// musicKit://artwork/transient handle that only MusicKit's `ArtworkImage`
/// can load, so it's drawn by one in a small offscreen window and read back
/// once the picture has arrived. Also tells whether a handle loads at all,
/// which `make artwork` relies on.
@MainActor
enum ArtworkSnapshot {
    /// The artwork as an image, or nil if nothing drew within `timeout`.
    static func image(_ artwork: Artwork, size: CGFloat = 600, timeout: Duration = .seconds(8)) async -> NSImage? {
        let window = SnapshotWindow(size: size)
        window.contentView = NSHostingView(rootView:
            ArtworkImage(artwork, width: size, height: size)
                .frame(width: size, height: size)
                .background(backdrop)
        )
        window.orderFrontRegardless()
        defer { window.close() }

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            guard let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            if sentinelShare(rep) < 0.5 {
                let image = NSImage(size: NSSize(width: size, height: size))
                image.addRepresentation(rep)
                return image
            }
        }
        return nil
    }

    /// Whether `ArtworkView`, as the app shows it, gets past its placeholder:
    /// drawn next to a placeholder-only copy until most of it differs.
    static func viewDraws(_ source: ArtworkSource, size: CGFloat, circular: Bool, timeout: Duration = .seconds(15)) async -> Bool {
        func window<V: View>(_ view: V) -> SnapshotWindow {
            let window = SnapshotWindow(size: size)
            window.contentView = NSHostingView(rootView: view.frame(width: size, height: size))
            window.orderFrontRegardless()
            return window
        }
        let real = window(ArtworkView(source: source, circular: circular))
        let placeholder = window(ArtworkView(source: source, circular: circular, placeholderOnly: true))
        defer { real.close(); placeholder.close() }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(150))
            guard let a = capture(real), let b = capture(placeholder) else { continue }
            if share(of: a, matching: b) < 0.5 { return true }
        }
        return false
    }

    private static func capture(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// How much of `a` matches `b`, from a 12×12 grid of the middle (corners
    /// are clipped away in both).
    private static func share(of a: NSBitmapImageRep, matching b: NSBitmapImageRep) -> Double {
        var same = 0
        for i in 0..<12 {
            for j in 0..<12 {
                let x = a.pixelsWide * (4 + i) / 20, y = a.pixelsHigh * (4 + j) / 20
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(p.redComponent - q.redComponent) < 0.03, abs(p.greenComponent - q.greenComponent) < 0.03,
                   abs(p.blueComponent - q.blueComponent) < 0.03 { same += 1 }
            }
        }
        return Double(same) / 144
    }

    private static let backdrop = Color(red: 1, green: 0, blue: 1)

    /// The backdrop as it comes out of a render (color matching shifts it),
    /// measured once from a window with nothing else in it.
    private static let backdropPixel: NSColor? = {
        let window = SnapshotWindow(size: 8)
        window.contentView = NSHostingView(rootView: backdrop.frame(width: 8, height: 8))
        defer { window.close() }
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB)
    }()

    /// How much of the image is still the backdrop, from a 12×12 grid.
    private static func sentinelShare(_ rep: NSBitmapImageRep) -> Double {
        guard let ref = backdropPixel else { return 1 }
        var hits = 0, total = 0
        for i in 0..<12 {
            for j in 0..<12 {
                let x = (rep.pixelsWide * (2 * i + 1)) / 24, y = (rep.pixelsHigh * (2 * j + 1)) / 24
                total += 1
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - ref.redComponent) < 0.04, abs(c.greenComponent - ref.greenComponent) < 0.04,
                   abs(c.blueComponent - ref.blueComponent) < 0.04 { hits += 1 }
            }
        }
        return Double(hits) / Double(total)
    }
}

/// Far off every screen, never key, and skipped by window lookups
/// (`NSApp.appWindow`).
final class SnapshotWindow: NSWindow {
    init(size: CGFloat) {
        super.init(contentRect: NSRect(x: -40_000, y: -40_000, width: size, height: size),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        hasShadow = false
        collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension NSApplication {
    /// The app's own visible window, ignoring artwork snapshot windows.
    var appWindow: NSWindow? {
        windows.first { $0.isVisible && !($0 is SnapshotWindow) }
    }
}
