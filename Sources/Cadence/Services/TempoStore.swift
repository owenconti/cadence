import Foundation
import Observation
import os

/// Where a song's tempo comes from: the key it's saved under (its Apple Music
/// catalog ID where it has one, so it's the same song whichever list it's
/// played from) and either a preview to measure or a tempo already known.
struct TempoSource: Sendable {
    var key: String
    var preview: URL?
    var knownBPM: Double?
}

/// Each song's tempo, measured once from its preview, and the speed the user
/// chose for it, which it then always plays at. On disk in Application
/// Support, so both last; per bundle ID, so check copies keep their own.
@MainActor
@Observable
final class TempoStore {
    struct Entry: Codable, Equatable {
        /// Measured beats per minute; nil if it couldn't be measured.
        var bpm: Double?
        /// The user's speed for the song (1 is as recorded); nil if unchanged.
        var rate: Double?
        /// Set once it's been measured, or found to have nothing to measure.
        var measured = false
    }

    static let rates = 0.5...2.0

    private(set) var entries: [String: Entry] = [:]
    /// Song ID → the key its tempo is saved under.
    private(set) var keys: [String: String] = [:]
    /// Songs (by ID) being looked up or measured now.
    private(set) var measuring: Set<String> = []
    /// Where songs' tempos come from; set when the library changes.
    @ObservationIgnored var provider: (any MusicProvider)?
    /// Called when a song's speed changes, so it takes effect at once.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    @ObservationIgnored private let file: URL
    @ObservationIgnored private var inFlight: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let writer = DispatchQueue(label: "com.owenconti.cadence.tempo", qos: .utility)
    private static let log = Logger(subsystem: "com.owenconti.cadence", category: "tempo")

    private struct Saved: Codable {
        var entries: [String: Entry]
        var keys: [String: String]
    }

    init(name: String = "song-tempos.json") {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Cadence", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent(name)
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            entries = saved.entries
            keys = saved.keys
        }
    }

    // MARK: Reading

    private func entry(for track: TrackItem) -> Entry? {
        keys[track.id].flatMap { entries[$0] }
    }

    /// The song's measured tempo, as recorded.
    func bpm(for track: TrackItem) -> Double? { entry(for: track)?.bpm }

    /// The speed the song plays at: 1 unless the user changed it.
    func rate(for track: TrackItem) -> Double { entry(for: track)?.rate ?? 1 }

    /// The tempo it plays at, with the user's speed applied.
    func playingBPM(for track: TrackItem) -> Double? { bpm(for: track).map { $0 * rate(for: track) } }

    func isAdjusted(_ track: TrackItem) -> Bool { abs(rate(for: track) - 1) > 0.0005 }

    /// Whether its tempo is still being worked out.
    func isMeasuring(_ track: TrackItem) -> Bool {
        measuring.contains(track.id) || (keys[track.id] == nil && provider != nil)
    }

    // MARK: Changing

    /// One step faster (`steps` > 0) or slower: a beat per minute when the
    /// tempo is known, else 2%.
    func nudge(_ track: TrackItem, by steps: Int) {
        let rate = rate(for: track)
        let next: Double
        if let bpm = bpm(for: track), bpm > 0 {
            // Lands on whole beats per minute, so +1 then −1 comes back.
            let target = ((bpm * rate).rounded() + Double(steps))
            next = target / bpm
        } else {
            next = ((rate * 50).rounded() + Double(steps)) / 50
        }
        setRate(next, for: track)
    }

    func setRate(_ rate: Double, for track: TrackItem) {
        guard let key = keys[track.id] else { return }
        let clamped = min(max(rate, Self.rates.lowerBound), Self.rates.upperBound)
        var entry = entries[key] ?? Entry()
        entry.rate = abs(clamped - 1) < 0.0005 ? nil : clamped
        guard entry != entries[key] else { return }
        entries[key] = entry
        save()
        onChange?()
    }

    func reset(_ track: TrackItem) { setRate(1, for: track) }

    /// Finds where `track`'s tempo is kept and measures it if that's never
    /// been done. Cheap to call again; work already under way is shared.
    func prepare(_ track: TrackItem) {
        if let key = keys[track.id], entries[key]?.measured == true { return }
        guard inFlight[track.id] == nil, let provider else { return }
        measuring.insert(track.id)
        inFlight[track.id] = Task { [weak self] in
            defer {
                self?.inFlight[track.id] = nil
                self?.measuring.remove(track.id)
            }
            let source = await provider.tempoSource(for: track)
            guard let self, self.provider === provider else { return }
            if self.keys[track.id] != source.key {
                self.keys[track.id] = source.key
                self.save()
                // A saved speed under that key applies now.
                self.onChange?()
            }
            if self.entries[source.key]?.measured == true { return }
            var bpm = source.knownBPM
            if bpm == nil, let preview = source.preview {
                do {
                    let estimate = try await TempoDetector.estimate(previewURL: preview)
                    bpm = estimate?.bpm
                } catch {
                    // Offline, say: try again the next time it plays.
                    Self.log.error("couldn't measure \(track.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return
                }
            }
            guard self.provider === provider else { return }
            var entry = self.entries[source.key] ?? Entry()
            entry.bpm = bpm.map { ($0 * 10).rounded() / 10 }
            entry.measured = true
            self.entries[source.key] = entry
            self.save()
            Self.log.info("\(track.title, privacy: .public): \(bpm.map { String(format: "%.1f BPM", $0) } ?? "no tempo", privacy: .public)")
        }
    }

    private func save() {
        let saved = Saved(entries: entries, keys: keys), file = file
        writer.async {
            guard let data = try? JSONEncoder().encode(saved) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }
}
