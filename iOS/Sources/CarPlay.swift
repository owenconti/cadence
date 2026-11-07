import CarPlay
import MediaPlayer
import MusicKit
import UIKit
import OSLog

/// Cadence in the car: tabs for what to play (Jump back in and Discover's
/// shelves, your playlists, trending), and the system's Now Playing screen,
/// which `NowPlaying` already feeds. Uses the phone's `AppModel`, so the same
/// library, queue and player.
///
/// The car only shows apps with the CarPlay audio entitlement, which Apple
/// grants on request; until then this runs only in the simulator's CarPlay
/// window (Debug builds carry the entitlement).
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPSessionConfigurationDelegate {
    private var interface: CPInterfaceController?
    private var model: AppModel { CadencePhoneApp.model }
    private let artwork = CarArtwork()
    private var sessionConfiguration: CPSessionConfiguration?
    private var collection: (tracks: [TrackItem], source: QueueSource, template: CPListTemplate)?

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interface: CPInterfaceController) {
        self.interface = interface
        sessionConfiguration = CPSessionConfiguration(delegate: self)
        interface.setRootTemplate(rootTemplate(), animated: false, completion: nil)
        watch()
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interface: CPInterfaceController) {
        self.interface = nil
        sessionConfiguration = nil
        collection = nil
    }

    func sessionConfiguration(_ sessionConfiguration: CPSessionConfiguration,
                              limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface) {
        guard let collection, interface?.templates.contains(where: { $0 === collection.template }) == true else { return }
        showSongs(collection.tracks, from: collection.source, in: collection.template)
    }

    /// Rebuilds the tabs whenever what they show changes (the library loading,
    /// connecting, playlists arriving), keeping the selected tab.
    private func watch() {
        withObservationTracking {
            _ = model.phase
            _ = model.playlists
            _ = model.discoverFeed?.recent.count
            _ = model.providerGeneration
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, let interface = self.interface else { return }
                let selected = (interface.rootTemplate as? CPTabBarTemplate)?.selectedTemplate?.tabTitle
                let root = self.rootTemplate()
                if let tabs = root as? CPTabBarTemplate, let old = interface.rootTemplate as? CPTabBarTemplate,
                   old.templates.count == tabs.templates.count {
                    for (template, fresh) in zip(old.templates, tabs.templates) {
                        if let list = template as? CPListTemplate, let freshList = fresh as? CPListTemplate {
                            list.updateSections(freshList.sections)
                        }
                    }
                } else {
                    interface.setRootTemplate(root, animated: false, completion: nil)
                    if let tabs = root as? CPTabBarTemplate, let index = tabs.templates.firstIndex(where: { $0.tabTitle == selected }) {
                        tabs.select(tabs.templates[index])
                    }
                }
                self.watch()
            }
        }
    }

    // MARK: Templates

    private func rootTemplate() -> CPTemplate {
        guard model.phase == .ready else {
            let message = model.phase == .launching ? "Loading your library…" : "Open Cadence on your iPhone to connect Apple Music."
            let template = CPListTemplate(title: "Cadence", sections: [])
            template.emptyViewTitleVariants = ["Cadence"]
            template.emptyViewSubtitleVariants = [message]
            return template
        }
        let listen = CPListTemplate(title: "Listen Now", sections: listenSections())
        listen.tabTitle = "Listen Now"
        listen.tabImage = UIImage(systemName: "sparkles")
        listen.emptyViewSubtitleVariants = ["Loading…"]

        let playlists = CPListTemplate(title: "Playlists", sections: playlistSections())
        playlists.tabTitle = "Playlists"
        playlists.tabImage = UIImage(systemName: "music.note.list")
        playlists.emptyViewSubtitleVariants = [model.playlistsLoaded ? "No playlists yet" : "Loading…"]

        return CPTabBarTemplate(templates: [listen, playlists])
    }

    private func listenSections() -> [CPListSection] {
        guard let feed = model.discoverFeed else { return [] }
        var sections: [CPListSection] = []
        if !feed.recent.isEmpty {
            sections.append(CPListSection(items: feed.recent.prefix(12).map(shelfItem), header: "Jump back in", sectionIndexTitle: nil))
        }
        for shelf in feed.shelves {
            sections.append(CPListSection(items: shelf.items.prefix(12).map(shelfItem), header: shelf.title, sectionIndexTitle: nil))
        }
        if !feed.trending.isEmpty {
            let item = CPListItem(text: "Trending now", detailText: "What everyone's playing this week", image: UIImage(systemName: "chart.line.uptrend.xyaxis"))
            item.handler = { [weak self] _, done in
                guard let self else { return done() }
                self.model.play(feed.trending, shuffled: false, from: .trending)
                self.showNowPlaying()
                done()
            }
            sections.append(CPListSection(items: [item], header: "Charts", sectionIndexTitle: nil))
        }
        return sections
    }

    private func playlistSections() -> [CPListSection] {
        let items = model.sortedPlaylists(by: .recent).map { playlist in
            let size = model.size(of: playlist)
            return listItem(playlist.name, size.map { "\($0) songs" } ?? playlist.curator, artwork: model.artwork(for: playlist)) { [weak self] in
                self?.openCollection(.playlist(playlist))
            }
        }
        return items.isEmpty ? [] : [CPListSection(items: items)]
    }

    private func shelfItem(_ item: ShelfItem) -> CPListItem {
        listItem(item.title, item.subtitle, artwork: item.artwork) { [weak self] in self?.openCollection(item) }
    }

    /// A playlist or album's songs, with Play and Shuffle on top.
    private func openCollection(_ item: ShelfItem) {
        let source: QueueSource
        let load: () async throws -> [TrackItem]
        switch item {
        case .album(let album):
            source = .album(album)
            load = { [model] in try await model.provider.tracks(in: album) }
        case .playlist(let playlist):
            source = .playlist(playlist)
            load = { [model] in try await model.provider.tracks(in: playlist) }
        }
        let template = CPListTemplate(title: item.title, sections: [])
        template.emptyViewSubtitleVariants = ["Loading…"]
        interface?.pushTemplate(template, animated: false, completion: nil)
        Task {
            guard let tracks = try? await load(), !tracks.isEmpty else {
                template.emptyViewSubtitleVariants = ["Couldn't load the songs"]
                return
            }
            template.trailingNavigationBarButtons = [
                CPBarButton(title: "Play") { [weak self] _ in self?.start(tracks, at: 0, shuffled: false, from: source) },
                CPBarButton(title: "Shuffle") { [weak self] _ in self?.start(tracks, at: 0, shuffled: true, from: source) }
            ]
            self.collection = (tracks, source, template)
            self.showSongs(tracks, from: source, in: template)
        }
    }

    /// One native scrolling list. The system owns scrolling and enforces its
    /// connected vehicle's total item limit; never impose an extra page size.
    private func showSongs(_ tracks: [TrackItem], from source: QueueSource,
                           in template: CPListTemplate) {
        // Apple's CarPlay Developer Guide, “List template”: some vehicles
        // dynamically restrict lists to 12 rows even when a larger maximum
        // was reported earlier. Re-evaluate when the session limits change.
        let restricted = sessionConfiguration?.limitedUserInterfaces.contains(.lists) == true
        let budget = min(CPListTemplate.maximumItemCount, restricted ? 12 : CPListTemplate.maximumItemCount)
        let end = min(tracks.count, max(0, budget))
        var rows: [CPListItem] = []
        for index in 0..<end {
            let track = tracks[index]
            let row = listItem(track.title, track.artistName, artwork: track.artwork) { [weak self] in
                self?.start(tracks, at: index, shuffled: false, from: source)
            }
            // iOS cannot turn MusicKit's private library artwork URLs into
            // UIImages. Resolve an exact catalog match for those handles.
            if case .musicKit(let cover, _) = track.artwork,
               cover.url(width: 80, height: 80)?.scheme?.hasPrefix("http") != true {
                Task { [weak row] in
                    var request = MusicCatalogSearchRequest(term: "\(track.title) \(track.artistName)", types: [Song.self])
                    request.limit = 5
                    if let songs = try? await request.response().songs,
                       let match = songs.first(where: {
                           $0.title.caseInsensitiveCompare(track.title) == .orderedSame &&
                           $0.artistName.caseInsensitiveCompare(track.artistName) == .orderedSame
                       }), let cover = match.artwork {
                        self.artwork.load(ArtworkSource(cover)) { [weak row] in row?.setImage($0) }
                    }
                }
            }
            rows.append(row)
        }
        let header = end < tracks.count ? "CarPlay limit: \(end) of \(tracks.count) songs" : nil
        template.updateSections([CPListSection(items: rows, header: header, sectionIndexTitle: nil)])
        Logger(subsystem: "com.owenconti.cadence", category: "CarPlay").notice("Collection \(template.title ?? "", privacy: .public): loaded=\(tracks.count) submitted=\(rows.count) retained=\(template.itemCount) maxItems=\(CPListTemplate.maximumItemCount) maxSections=\(CPListTemplate.maximumSectionCount) restricted=\(restricted)")
    }

    private func start(_ tracks: [TrackItem], at index: Int, shuffled: Bool, from source: QueueSource) {
        model.play(tracks, startAt: index, shuffled: shuffled, from: source)
        showNowPlaying()
    }

    private func showNowPlaying() {
        guard let interface, interface.topTemplate !== CPNowPlayingTemplate.shared else { return }
        interface.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    private func listItem(_ text: String, _ detail: String?, artwork source: ArtworkSource, action: @escaping @MainActor () -> Void) -> CPListItem {
        let item = CPListItem(text: text, detailText: detail, image: artwork.cached(source) ?? CarArtwork.placeholder)
        item.handler = { _, done in
            action()
            done()
        }
        artwork.load(source) { [weak item] image in item?.setImage(image) }
        return item
    }
}

/// List artwork for the car, loaded once per cover and kept for the session.
@MainActor
final class CarArtwork {
    static let placeholder = UIImage(systemName: "music.note")
    private let images = NSCache<NSString, UIImage>()
    private var keys: [ArtworkSource: NSString] = [:]
    private var waiting: [ArtworkSource: [(UIImage) -> Void]] = [:]

    func cached(_ source: ArtworkSource) -> UIImage? {
        guard let key = keys[source] else { return nil }
        return images.object(forKey: key)
    }

    func load(_ source: ArtworkSource, then apply: @escaping (UIImage) -> Void) {
        if let image = cached(source) { apply(image); return }
        guard source != .none else { return }
        if waiting[source] != nil {
            waiting[source]?.append(apply)
            return
        }
        waiting[source] = [apply]
        Task {
            let image = await NowPlaying.image(for: source)
            let callbacks = waiting.removeValue(forKey: source) ?? []
            guard let image else { return }
            let key = keys[source] ?? UUID().uuidString as NSString
            keys[source] = key
            images.countLimit = 200
            let thumbnail = image.preparingThumbnail(of: CPListItem.maximumImageSize) ?? image
            images.setObject(thumbnail, forKey: key)
            callbacks.forEach { $0(thumbnail) }
        }
    }
}
