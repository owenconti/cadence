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
        /// The song, for ⇧↩ (add to a playlist) and its right-click menu.
        var track: TrackItem?

        func matches(_ query: String) -> Bool {
            query.isEmpty || title.localizedCaseInsensitiveContains(query) || keywords.localizedCaseInsensitiveContains(query)
        }
    }

    var isPresented = false
    var query = ""
    var entries: [Entry] = []
    var selection = 0
    /// While set, the palette lists playlists to add this song to.
    private(set) var addingToPlaylist: TrackItem?
    /// The search to go back to from choosing a playlist.
    @ObservationIgnored private var previousQuery: String?

    func present() {
        query = ""
        selection = 0
        addingToPlaylist = nil
        previousQuery = nil
        isPresented = true
    }

    func dismiss() {
        isPresented = false
        addingToPlaylist = nil
        previousQuery = nil
    }

    /// Lists the playlists `track` can be added to; Esc goes back to the
    /// search it came from, if any.
    func choosePlaylist(for track: TrackItem) {
        previousQuery = isPresented ? query : nil
        addingToPlaylist = track
        query = ""
        selection = 0
        isPresented = true
    }

    /// Esc: from choosing a playlist back to the search, otherwise closes.
    func back() {
        guard addingToPlaylist != nil, let previous = previousQuery else { return dismiss() }
        addingToPlaylist = nil
        previousQuery = nil
        query = previous
    }

    func move(_ delta: Int) {
        guard !entries.isEmpty else { return }
        selection = (selection + delta + entries.count) % entries.count
    }

    enum Run { case open, playNext, addToQueue, addToPlaylist }

    func runSelection(_ run: Run = .open) {
        guard entries.indices.contains(selection) else { return }
        let entry = entries[selection]
        if run == .addToPlaylist {
            if let track = entry.track { choosePlaylist(for: track) }
            return
        }
        let action: (@MainActor () -> Void)? = switch run {
        case .open: entry.action
        case .playNext: entry.playNext
        case .addToQueue: entry.addToQueue
        case .addToPlaylist: nil
        }
        guard let action else { return }
        dismiss()
        action()
    }
}
