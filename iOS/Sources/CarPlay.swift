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
    private var collection: (tracks: [TrackItem], source: QueueSource, template: CPListTemplate, page: Int)?

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
        showSongs(collection.tracks, from: collection.source, in: collection.template, page: collection.page)
    }

    /// Rebuilds the tabs whenever what they show changes (the library loading,
    /// connecting, playlists arriving), keeping the selected tab.
    private func watch() {
        withObservationTracking {
            _ = model.phase
            _ = model.playlists
            _ = model.myPlaylists
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
            let item = CPListItem(text: "Trending now", detailText: "What everyone's playing this week", image: CarArtwork.symbol("chart.line.uptrend.xyaxis"))
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
        func item(_ playlist: PlaylistItem) -> CPListItem {
            let size = model.size(of: playlist)
            return listItem(playlist.name, size.map { "\($0) songs" } ?? playlist.curator, artwork: model.artwork(for: playlist)) { [weak self] in
                self?.openCollection(.playlist(playlist))
            }
        }
        let mine = model.myPlaylists.map(item)
        let items = model.sortedPlaylists(by: .recent).map(item)
        var sections: [CPListSection] = []
        if !mine.isEmpty { sections.append(CPListSection(items: mine, header: "My Playlists", sectionIndexTitle: nil)) }
        if !items.isEmpty { sections.append(CPListSection(items: items, header: mine.isEmpty ? nil : "Apple Music", sectionIndexTitle: nil)) }
        return sections
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
            load = { [model] in try await model.tracks(in: playlist) }
        }
        let template = CPListTemplate(title: item.title, sections: [])
        template.emptyViewSubtitleVariants = ["Loading…"]
        interface?.pushTemplate(template, animated: false, completion: nil)
        Task {
            let tracks: [TrackItem]
            do { tracks = try await load() }
            catch {
                template.emptyViewSubtitleVariants = ["Couldn't load the songs"]
                return
            }
            guard self.interface?.templates.contains(where: { $0 === template }) == true else { return }
            self.showSongs(tracks, from: source, in: template)
        }
    }

    /// Previous precedes the songs; Next follows them, within 12 total rows.
    /// Play/Shuffle stay outside the row budget and always use all tracks.
    private func showSongs(_ tracks: [TrackItem], from source: QueueSource,
                           in template: CPListTemplate, page number: Int = 0) {
        template.trailingNavigationBarButtons = tracks.isEmpty ? [] : [
            CPBarButton(title: "Play") { [weak self] _ in self?.start(tracks, at: 0, shuffled: false, from: source) },
            CPBarButton(title: "Shuffle") { [weak self] _ in self?.start(tracks, at: 0, shuffled: true, from: source) }
        ]
        let page = CarPlaySongPage(count: tracks.count, number: number)
        collection = (tracks, source, template, page.number)
        let restricted = sessionConfiguration?.limitedUserInterfaces.contains(.lists) == true
        var rows: [CPListItem] = []
        func navigation(_ title: String, to destination: Int, symbol: String) -> CPListItem {
            let target = CarPlaySongPage(count: tracks.count, number: destination)
            let row = CPListItem(text: title,
                                 detailText: "Songs \(target.range.lowerBound + 1)–\(target.range.upperBound) of \(tracks.count)",
                                 image: CarArtwork.symbol(symbol))
            row.handler = { [weak self, weak template] _, done in
                guard let self, let template else { return done() }
                self.changePage(tracks, from: source, replacing: template, page: destination, completion: done)
            }
            return row
        }
        if let previous = page.previous { rows.append(navigation("Previous", to: previous, symbol: "chevron.left")) }
        for index in page.range {
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
            row.userInfo = index
            rows.append(row)
        }
        if let next = page.next { rows.append(navigation("Next", to: next, symbol: "chevron.right")) }
        template.emptyViewSubtitleVariants = ["No songs in this collection"]
        let header = tracks.isEmpty ? nil : "Songs \(page.range.lowerBound + 1)–\(page.range.upperBound) of \(tracks.count)"
        template.updateSections([CPListSection(items: rows, header: header, sectionIndexTitle: nil)])
        Logger(subsystem: "com.owenconti.cadence", category: "CarPlay").notice("Collection \(template.title ?? "", privacy: .public): loaded=\(tracks.count) page=\(page.number + 1) songStart=\(page.range.lowerBound) songs=\(page.range.count) submitted=\(rows.count) retained=\(template.itemCount) maxItems=\(CPListTemplate.maximumItemCount) maxSections=\(CPListTemplate.maximumSectionCount) restricted=\(restricted)")
    }

    /// A fresh list resets CarPlay's scroll offset. Replace the current level,
    /// without animations or an ever-growing history of playlist pages.
    private func changePage(_ tracks: [TrackItem], from source: QueueSource,
                            replacing template: CPListTemplate, page: Int,
                            completion: @escaping () -> Void) {
        guard let interface else {
            showSongs(tracks, from: source, in: template, page: page)
            completion()
            return
        }
        guard interface.topTemplate === template else { return completion() }
        let previousCollection = collection
        let replacement = CPListTemplate(title: template.title, sections: [])
        showSongs(tracks, from: source, in: replacement, page: page)
        interface.popTemplate(animated: false) { [weak self] success, _ in
            guard let self, self.interface === interface else { return completion() }
            guard success else {
                self.collection = previousCollection
                completion()
                return
            }
            interface.pushTemplate(replacement, animated: false) { [weak self] success, _ in
                guard let self, self.interface === interface else { return completion() }
                guard !success else { return completion() }
                self.collection = previousCollection
                interface.pushTemplate(template, animated: false) { _, _ in completion() }
            }
        }
    }

    #if DEBUG
    /// Exercises the real template renderer and selection handlers on iOS,
    /// independently of a vehicle. This does not simulate vehicle restrictions.
    static func runPageChecksIfRequested() {
        guard ProcessInfo.processInfo.environment["CADENCE_CARPLAY_PAGE_CHECKS"] == "1" else { return }
        Task { @MainActor in
            enum Failure: Error { case check(String) }
            func require(_ condition: Bool, _ message: String) throws {
                if !condition { throw Failure.check(message) }
            }
            var report: [String: Any] = [:]
            do {
                let model = CadencePhoneApp.model
                for _ in 0..<100 where model.phase != .ready { try await Task.sleep(for: .milliseconds(100)) }
                try require(!model.provider.isLive && model.phase == .ready, "Checks require the demo library")
                let provider = DemoProvider()
                guard let playlist = try await provider.playlists().first(where: { $0.name == "All Songs" }) else { throw Failure.check("Missing fixture") }
                let all = try await provider.tracks(in: playlist)
                let symbolChecks = try CarArtwork.checkSymbols()
                let loader = CarArtwork()
                var loadedArtwork: UIImage?
                loader.load(all[0].artwork) { loadedArtwork = $0 }
                for _ in 0..<50 where loadedArtwork == nil { try await Task.sleep(for: .milliseconds(100)) }
                try require(loadedArtwork != nil && loadedArtwork?.renderingMode != .alwaysTemplate, "Real artwork was converted into a template")
                if let loadedArtwork { try CarArtwork.checkColoredArtwork(loadedArtwork) }
                let delegate = CarPlaySceneDelegate()
                var checkedPages = 0
                var checkedSelections = 0
                for count in [0, 1, 9, 10, 11, 19, 20, 21, 80] {
                    let tracks = Array(all.prefix(count))
                    let template = CPListTemplate(title: "Page regression", sections: [])
                    delegate.showSongs(tracks, from: .playlist(playlist), in: template)
                    var visited: [Int] = []
                    var number = 0
                    while true {
                        let page = CarPlaySongPage(count: count, number: number)
                        let rows = template.sections.flatMap { $0.items }.compactMap { $0 as? CPListItem }
                        try require(template.itemCount == page.rowCount && rows.count <= 12, "Native row budget: \(count)/\(number)")
                        try require(template.trailingNavigationBarButtons.compactMap(\.title) == (tracks.isEmpty ? [] : ["Play", "Shuffle"]), "Page playback actions")
                        let indices = rows.compactMap { $0.userInfo as? Int }
                        try require(indices == Array(page.range), "Native song indices")
                        let actualOrder = rows.map { row in
                            if let index = row.userInfo as? Int { return "song:\(index)" }
                            return row.text ?? ""
                        }
                        let expectedOrder = (page.previous == nil ? [] : ["Previous"])
                            + page.range.map { "song:\($0)" }
                            + (page.next == nil ? [] : ["Next"])
                        try require(actualOrder == expectedOrder, "Previous/song/Next placement")
                        visited += indices
                        checkedPages += 1
                        if let song = rows.last(where: { $0.userInfo is Int }), let index = song.userInfo as? Int {
                            var done = false
                            song.handler?(song) { done = true }
                            try require(done && model.player.index == index, "Selection/completion at \(index)")
                            try require(model.player.queue.map(\.id) == tracks.map(\.id), "Selection must retain the full queue")
                            checkedSelections += 1
                        }
                        guard page.next != nil, let next = rows.first(where: { $0.text == "Next" }) else { break }
                        let queueBefore = model.player.queue.map(\.id), indexBefore = model.player.index
                        var done = false
                        next.handler?(next) { done = true }
                        try require(done, "Next completion")
                        try require(model.player.queue.map(\.id) == queueBefore && model.player.index == indexBefore, "Next changed playback")
                        number += 1
                    }
                    try require(visited == Array(0..<count), "Native traversal skipped/duplicated songs")
                    while number > 0 {
                        let rows = template.sections.flatMap { $0.items }.compactMap { $0 as? CPListItem }
                        guard let previous = rows.first, previous.text == "Previous" else { throw Failure.check("Missing Previous") }
                        let queueBefore = model.player.queue.map(\.id), indexBefore = model.player.index
                        var done = false
                        previous.handler?(previous) { done = true }
                        try require(model.player.queue.map(\.id) == queueBefore && model.player.index == indexBefore, "Previous changed playback")
                        number -= 1
                        let indices = template.sections.flatMap { $0.items }.compactMap { ($0 as? CPListItem)?.userInfo as? Int }
                        try require(done && indices == Array(CarPlaySongPage(count: count, number: number).range), "Previous destination/completion")
                    }
                }
                model.player.setPlaying(false)
                report = ["status": "PASS", "nativePages": checkedPages, "fullQueueSelections": checkedSelections,
                          "counts": [0, 1, 9, 10, 11, 19, 20, 21, 80], "vehicleRestrictionSimulated": false,
                          "symbolChecks": symbolChecks, "realArtworkColorsPreserved": true]
            } catch { report = ["status": "FAIL", "error": String(describing: error)] }
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("carplay-page-checks.json")
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url, options: .atomic) }
            print("CarPlay page checks: \(report)")
        }
    }
    #endif

    private func start(_ tracks: [TrackItem], at index: Int, shuffled: Bool, from source: QueueSource) {
        Logger(subsystem: "com.owenconti.cadence", category: "CarPlay").notice("Playback queue=\(tracks.count) index=\(index) shuffled=\(shuffled)")
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
    /// CPListItem images are artwork, not text. A template-only glyph stays
    /// white on CarPlay's pale selected row. Supply display-ready light/dark
    /// variants with an internal contrast surface, independent of row focus.
    private static var symbolAssets: [String: UIImageAsset] = [:]

    static func symbol(_ name: String) -> UIImage? {
        if let asset = symbolAssets[name] { return asset.image(with: symbolTraits(style: .dark, scale: 2)) }
        guard let glyph = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)) else { return nil }
        let asset = UIImageAsset()
        for style in [UIUserInterfaceStyle.light, .dark] {
            for scale in [CGFloat(1), 2, 3] {
                let traits = symbolTraits(style: style, scale: scale)
                let format = UIGraphicsImageRendererFormat()
                format.scale = scale
                let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32), format: format).image { _ in
                    UIColor.systemGray5.resolvedColor(with: traits).setFill()
                    UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 32, height: 32)).fill()
                    let ratio = min(20 / glyph.size.width, 20 / glyph.size.height)
                    let size = CGSize(width: glyph.size.width * ratio, height: glyph.size.height * ratio)
                    glyph.withTintColor(style == .dark ? .white : .black, renderingMode: .alwaysOriginal)
                        .draw(in: CGRect(x: (32 - size.width) / 2, y: (32 - size.height) / 2, width: size.width, height: size.height))
                }
                asset.register(image.withRenderingMode(.alwaysOriginal), with: traits)
            }
        }
        symbolAssets[name] = asset
        return asset.image(with: symbolTraits(style: .dark, scale: 2))
    }

    private static func symbolTraits(style: UIUserInterfaceStyle, scale: CGFloat) -> UITraitCollection {
        UITraitCollection(traitsFrom: [UITraitCollection(userInterfaceStyle: style),
            UITraitCollection(displayScale: scale), UITraitCollection(userInterfaceIdiom: .carPlay)])
    }

    #if DEBUG
    private enum ImageCheckError: Error { case failed(String) }

    private static func pixels(_ image: UIImage) throws -> (width: Int, data: [UInt8]) {
        guard let cgImage = image.cgImage else { throw ImageCheckError.failed("No image pixels") }
        let width = cgImage.width, height = cgImage.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let success = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { throw ImageCheckError.failed("Could not inspect pixels") }
        return (width, data)
    }

    static func checkSymbols() throws -> [String: Any] {
        func luminance(_ data: [UInt8], _ offset: Int) -> Double {
            let values = (0..<3).map { channel -> Double in
                let value = Double(data[offset + channel]) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
        }
        var minimumContrast = Double.greatestFiniteMagnitude
        var variants = 0
        for name in ["chevron.left", "chevron.right", "chart.line.uptrend.xyaxis", "music.note"] {
            guard let image = symbol(name), let asset = image.imageAsset else { throw ImageCheckError.failed("Missing adaptive symbol \(name)") }
            var backgrounds: [Double] = []
            for style in [UIUserInterfaceStyle.light, .dark] {
                for scale in [CGFloat(1), 2, 3] {
                    let variant = asset.image(with: symbolTraits(style: style, scale: scale))
                    guard variant.scale == scale, variant.size == CGSize(width: 32, height: 32),
                          variant.renderingMode == .alwaysOriginal else { throw ImageCheckError.failed("Invalid style/scale/rendering mode") }
                    let (width, data) = try pixels(variant)
                    let backgroundOffset = (Int(3 * scale) * width + Int(16 * scale)) * 4
                    guard data[backgroundOffset + 3] == 255 else { throw ImageCheckError.failed("Badge must protect contrast on selected rows") }
                    let background = luminance(data, backgroundOffset)
                    var foreground = background
                    for y in Int(6 * scale)..<Int(26 * scale) {
                        for x in Int(6 * scale)..<Int(26 * scale) {
                            let offset = (y * width + x) * 4
                            guard data[offset + 3] == 255 else { continue }
                            let value = luminance(data, offset)
                            foreground = style == .dark ? max(foreground, value) : min(foreground, value)
                        }
                    }
                    let contrast = (max(background, foreground) + 0.05) / (min(background, foreground) + 0.05)
                    guard contrast >= 7 else { throw ImageCheckError.failed("Low symbol contrast: \(name), \(style), \(scale)") }
                    minimumContrast = min(minimumContrast, contrast)
                    if scale == 2 { backgrounds.append(background) }
                    variants += 1
                }
            }
            guard backgrounds.count == 2, backgrounds[0] > backgrounds[1] else { throw ImageCheckError.failed("Light/dark variants did not adapt") }
        }
        return ["variants": variants, "scales": [1, 2, 3], "styles": ["light", "dark"],
                "minimumGlyphBadgeContrast": minimumContrast, "opaqueBadgeProtectsSelectedState": true,
                "lightHostVisuallyVerified": false]
    }

    static func checkColoredArtwork(_ image: UIImage) throws {
        let (_, data) = try pixels(image)
        var colored = false
        for offset in stride(from: 0, to: data.count, by: 4) {
            let red = Int(data[offset]), blue = Int(data[offset + 2])
            if data[offset + 3] > 200 && abs(red - blue) > 20 {
                colored = true
                break
            }
        }
        guard colored else { throw ImageCheckError.failed("Real artwork lost its colors") }
    }
    #endif

    static let placeholder = symbol("music.note")
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
