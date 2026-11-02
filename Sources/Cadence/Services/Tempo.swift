#if os(macOS)
import Accelerate
import AVFoundation
import Foundation
import MusicKit
import Observation
import os

/// Each song's tempo, estimated once from its 30-second Apple Music preview
/// (the stream itself is protected and can't be read) and kept on disk.
@MainActor
@Observable
final class TempoStore {
    /// Beats per minute by song ID.
    private(set) var bpm: [String: Double]
    @ObservationIgnored private var inFlight: Set<String> = []
    /// Songs with no preview or no clear beat, so they aren't tried again this launch.
    @ObservationIgnored private var failed: Set<String> = []
    @ObservationIgnored private let file: URL
    nonisolated private static let log = Logger(subsystem: "com.owenconti.cadence", category: "tempo")

    init() {
        // Per bundle ID, as PlaybackStore does, so check copies keep their own.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Cadence", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("tempo.json")
        bpm = (try? JSONDecoder().decode([String: Double].self, from: Data(contentsOf: file))) ?? [:]
    }

    /// Estimates the song's tempo unless it's known, being worked out, or already failed.
    func measure(_ track: TrackItem) {
        let id = track.id
        guard let song = track.song, bpm[id] == nil, !inFlight.contains(id), !failed.contains(id) else { return }
        inFlight.insert(id)
        Task {
            let result = await Self.estimate(song)
            inFlight.remove(id)
            guard let result else { failed.insert(id); return }
            bpm[id] = result
            let snapshot = bpm, file = file
            Task.detached(priority: .utility) { try? JSONEncoder().encode(snapshot).write(to: file, options: .atomic) }
        }
    }

    private nonisolated static func estimate(_ song: Song) async -> Double? {
        guard let url = await previewURL(for: song) else {
            log.info("no preview for \(song.title, privacy: .public)")
            return nil
        }
        do {
            let (download, _) = try await URLSession.shared.download(from: url)
            defer { try? FileManager.default.removeItem(at: download) }
            // AVAudioFile goes by the extension.
            let clip = download.deletingPathExtension().appendingPathExtension(url.pathExtension.isEmpty ? "m4a" : url.pathExtension)
            try FileManager.default.moveItem(at: download, to: clip)
            defer { try? FileManager.default.removeItem(at: clip) }
            let tempo = try await Task.detached(priority: .utility) { try TempoEstimator.bpm(ofFile: clip) }.value
            log.info("\(song.title, privacy: .public): \(tempo.map { String(format: "%.1f", $0) } ?? "no beat", privacy: .public) BPM")
            return tempo
        } catch {
            log.error("tempo of \(song.title, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Library songs carry no previews; their catalog twin, by title and artist, does.
    private nonisolated static func previewURL(for song: Song) async -> URL? {
        if let url = song.previewAssets?.first?.url { return url }
        var request = MusicCatalogSearchRequest(term: "\(song.title) \(song.artistName)", types: [Song.self])
        request.limit = 10
        guard let found = try? await request.response().songs else { return nil }
        let same = { (a: String, b: String) in a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        let match = found.first { same($0.title, song.title) && same($0.artistName, song.artistName) }
            ?? found.first { same($0.title, song.title) }
        return match?.previewAssets?.first?.url
    }
}

/// Tempo from audio: a spectral-flux onset envelope, autocorrelated. Each
/// beat length scores by how well it and its multiples repeat, with a
/// preference for tempos near 120 BPM to settle half- and double-time.
/// On a dozen previews of known tempo it gets 9 right and 2 at half or double.
enum TempoEstimator {
    static let frameSize = 1024
    static let hop = 512

    static func bpm(ofFile url: URL) throws -> Double? {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { return nil }
        let count = Int(buffer.frameLength)
        var mono = [Float](repeating: 0, count: count)
        for c in 0..<Int(format.channelCount) {
            vDSP.add(mono, UnsafeBufferPointer(start: channels[c], count: count), result: &mono)
        }
        return bpm(of: mono, sampleRate: format.sampleRate)
    }

    static func bpm(of samples: [Float], sampleRate: Double) -> Double? {
        let envelope = onsetEnvelope(samples)
        guard envelope.count > 64 else { return nil }
        let framesPerSecond = sampleRate / Double(hop)

        // Beat lengths between 200 and 50 BPM, autocorrelated out to four beats.
        let minLag = max(1, Int((framesPerSecond * 60 / 200).rounded(.down)))
        let maxLag = min(envelope.count / 5, Int((framesPerSecond * 60 / 50).rounded(.up)))
        guard maxLag > minLag + 2 else { return nil }
        var correlation = [Double](repeating: 0, count: 4 * maxLag + 2)
        for lag in minLag...(4 * maxLag + 1) {
            var sum: Float = 0
            envelope.withUnsafeBufferPointer { e in
                vDSP_dotpr(e.baseAddress!, 1, e.baseAddress! + lag, 1, &sum, vDSP_Length(envelope.count - lag))
            }
            correlation[lag] = Double(sum) / Double(envelope.count - lag)
        }

        // A beat that repeats over two, three and four beats too, times a
        // log-normal prior around 120 BPM, about an octave wide.
        func weighted(_ lag: Int) -> Double {
            let bpm = framesPerSecond * 60 / Double(lag)
            let octaves = log2(bpm / 120)
            let comb = correlation[lag] + correlation[2 * lag] / 2 + correlation[3 * lag] / 3 + correlation[4 * lag] / 4
            return comb * exp(-0.5 * octaves * octaves / 0.9)
        }
        guard let best = (minLag...maxLag).max(by: { weighted($0) < weighted($1) }), correlation[best] > 0 else { return nil }

        // Parabolic interpolation between neighbouring lags for a finer tempo.
        var lag = Double(best)
        if best > minLag, best < maxLag {
            let (a, b, c) = (correlation[best - 1], correlation[best], correlation[best + 1])
            let denominator = a - 2 * b + c
            if denominator != 0 { lag += 0.5 * (a - c) / denominator }
        }
        return framesPerSecond * 60 / lag
    }

    /// How much new energy each frame brings: the summed rise in log
    /// magnitude across the spectrum, less its local average.
    static func onsetEnvelope(_ samples: [Float]) -> [Float] {
        let log2n = vDSP_Length(log2(Double(frameSize)))
        guard samples.count > frameSize, let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else { return [] }
        let bins = frameSize / 2
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: frameSize, isHalfWindow: false)
        var previous = [Float](repeating: 0, count: bins)
        var flux: [Float] = []
        var real = [Float](repeating: 0, count: bins), imaginary = [Float](repeating: 0, count: bins)
        var start = 0
        while start + frameSize <= samples.count {
            let frame = vDSP.multiply(samples[start..<(start + frameSize)], window)
            var magnitudes = [Float](repeating: 0, count: bins)
            real.withUnsafeMutableBufferPointer { r in
                imaginary.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    frame.withUnsafeBytes { raw in
                        vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(bins))
                    }
                    fft.forward(input: split, output: &split)
                    vDSP.absolute(split, result: &magnitudes)
                }
            }
            // log(1 + C·|X|) compresses loud and quiet passages alike.
            magnitudes = magnitudes.map { log1p(100 * $0) }
            let rise = vDSP.subtract(magnitudes, previous)
            flux.append(vDSP.sum(vDSP.clip(rise, to: 0...Float.greatestFiniteMagnitude)))
            previous = magnitudes
            start += hop
        }
        // Subtract a ~0.5 s moving average and keep what rises above it.
        let half = 21
        var envelope = [Float](repeating: 0, count: flux.count)
        for i in flux.indices {
            let range = max(0, i - half)...min(flux.count - 1, i + half)
            let mean = flux[range].reduce(0, +) / Float(range.count)
            envelope[i] = max(0, flux[i] - mean)
        }
        return envelope
    }
}
#endif
