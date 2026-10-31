import Observation
import SwiftUI

/// State for the ⌘K command palette. Entries are rebuilt by the palette view
/// as the query changes; keyboard navigation is routed here from `AppModel`.
@MainActor
@Observable
final class PaletteModel {
    struct Entry: Identifiable {
        let id: String
        var group: String
        var title: String
        var subtitle: String?
        var symbol: String?
        var artwork: ArtworkSource?
        var circular = false
        var hint: String?
        /// Extra words the query also matches, beyond the title.
        var keywords = ""
        var action: @MainActor () -> Void
        /// Songs: ⌘↩ plays it next, ⌥↩ adds it to the queue.
        var playNext: (@MainActor () -> Void)?
        var addToQueue: (@MainActor () -> Void)?

        func matches(_ query: String) -> Bool {
            query.isEmpty || title.localizedCaseInsensitiveContains(query) || keywords.localizedCaseInsensitiveContains(query)
        }
    }

    var isPresented = false
    var query = ""
    var entries: [Entry] = []
    var selection = 0

    func present() {
        query = ""
        selection = 0
        isPresented = true
    }

    func dismiss() {
        isPresented = false
    }

    func move(_ delta: Int) {
        guard !entries.isEmpty else { return }
        selection = (selection + delta + entries.count) % entries.count
    }

    enum Run { case open, playNext, addToQueue }

    func runSelection(_ run: Run = .open) {
        guard entries.indices.contains(selection) else { return }
        let entry = entries[selection]
        let action: (@MainActor () -> Void)? = switch run {
        case .open: entry.action
        case .playNext: entry.playNext
        case .addToQueue: entry.addToQueue
        }
        guard let action else { return }
        dismiss()
        action()
    }
}
