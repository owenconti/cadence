import AVFoundation
import Accelerate

/// Estimates a song's tempo from its audio. Apple Music's streams are
/// protected, so this reads a song's 30-second preview instead.
///
/// The method: an onset-strength envelope from log-spectral flux (how much
/// louder each frequency band got since the last frame), then that
/// envelope's autocorrelation, whose strongest lag between 60 and 200 BPM is
/// the beat period. A log-normal prior around 120 BPM breaks ties between a
/// tempo and its half or double. Plain AVFoundation and Accelerate, so it
/// runs the same on macOS and iOS.
enum TempoDetector {
    struct Estimate: Sendable {
        var bpm: Double
        /// How far the winning peak stands above the rest, 0–1. Below about
        /// 0.1 the music has no clear beat.
        var confidence: Double
    }

    static let sampleRate = 22_050.0
    static let frameSize = 1024
    static let hop = 256 // ≈ 86 envelope frames a second

    /// Downloads a preview and estimates its tempo.
    static func estimate(previewURL: URL) async throws -> Estimate? {
        let (file, _) = try await URLSession.shared.download(from: previewURL)
        let local = file.deletingPathExtension().appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: local)
        try FileManager.default.moveItem(at: file, to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        return try await Task.detached(priority: .utility) {
            try estimate(fileURL: local)
        }.value
    }

    static func estimate(fileURL: URL) throws -> Estimate? {
        estimate(samples: try decodeMono(fileURL))
    }

    /// The file's audio, mixed to mono at `sampleRate`.
    static func decodeMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target)
        else { return [] }
        let chunk: AVAudioFrameCount = 16_384
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * sampleRate / file.processingFormat.sampleRate))
        var finished = false
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: chunk) else { break }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if finished { inputStatus.pointee = .endOfStream; return nil }
                guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else {
                    inputStatus.pointee = .endOfStream; return nil
                }
                do { try file.read(into: input, frameCount: chunk) } catch { finished = true }
                if input.frameLength == 0 { finished = true; inputStatus.pointee = .endOfStream; return nil }
                inputStatus.pointee = .haveData
                return input
            }
            if let error { throw error }
            if let data = out.floatChannelData, out.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
            }
            if status == .endOfStream || status == .error || (out.frameLength == 0 && finished) { break }
        }
        return samples
    }

    static func estimate(samples: [Float]) -> Estimate? {
        let envelope = onsetEnvelope(samples)
        guard envelope.count > 400 else { return nil } // under ~5 seconds
        return tempo(of: envelope)
    }

    /// Log-magnitude spectral flux, one value per hop.
    static func onsetEnvelope(_ samples: [Float]) -> [Float] {
        let n = frameSize
        let half = n / 2
        guard samples.count > n,
              let dft = try? vDSP.DiscreteFourierTransform(previous: nil, count: n, direction: .forward, transformType: .complexReal, ofType: Float.self)
        else { return [] }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        let frames = (samples.count - n) / hop + 1
        var previous = [Float](repeating: 0, count: half)
        var envelope = [Float](repeating: 0, count: frames)
        var frame = [Float](repeating: 0, count: n)
        var evenIn = [Float](repeating: 0, count: half), oddIn = [Float](repeating: 0, count: half)
        var real = [Float](repeating: 0, count: half), imag = [Float](repeating: 0, count: half)
        var magnitude = [Float](repeating: 0, count: half)
        for f in 0..<frames {
            samples.withUnsafeBufferPointer { all in
                vDSP.multiply(UnsafeBufferPointer(rebasing: all[(f * hop)..<(f * hop + n)]), window, result: &frame)
            }
            for i in 0..<half { evenIn[i] = frame[2 * i]; oddIn[i] = frame[2 * i + 1] }
            dft.transform(inputReal: evenIn, inputImaginary: oddIn, outputReal: &real, outputImaginary: &imag)
            real[0] = 0; imag[0] = 0 // DC, and the packed Nyquist term
            for i in 0..<half { magnitude[i] = log1pf(10 * sqrtf(real[i] * real[i] + imag[i] * imag[i])) }
            var flux: Float = 0
            for i in 1..<half { flux += max(0, magnitude[i] - previous[i]) }
            envelope[f] = f == 0 ? 0 : flux
            swap(&previous, &magnitude)
        }
        // Remove the slow trend (a ~0.5 s moving average) so loudness swells
        // don't read as beats, and keep only the rises.
        let span = 43
        var detrended = envelope
        var sum: Float = 0
        for i in 0..<envelope.count {
            sum += envelope[i]
            if i >= span { sum -= envelope[i - span] }
            detrended[i] = max(0, envelope[i] - sum / Float(min(i + 1, span)))
        }
        return detrended
    }

    static func tempo(of envelope: [Float]) -> Estimate? {
        let fps = sampleRate / Double(hop)
        let minLag = Int((fps * 60 / 200).rounded(.down))
        let maxLag = Int((fps * 60 / 60).rounded(.up))
        guard envelope.count > maxLag * 2 else { return nil }
        let mean = vDSP.mean(envelope)
        let centered = vDSP.add(-mean, envelope)
        let energy = vDSP.dot(centered, centered)
        guard energy > 0 else { return nil }
        var scores = [Double](repeating: 0, count: maxLag + 2)
        centered.withUnsafeBufferPointer { e in
            for lag in max(1, minLag - 1)...(maxLag + 1) {
                let count = e.count - lag
                let a = UnsafeBufferPointer(rebasing: e[0..<count])
                let b = UnsafeBufferPointer(rebasing: e[lag..<(lag + count)])
                scores[lag] = Double(vDSP.dot(a, b)) / Double(energy)
            }
        }
        // Weight by a log-normal prior around 120 BPM (σ = 1 octave).
        func weight(_ lag: Double) -> Double {
            let bpm = 60 * fps / lag
            let octaves = log2(bpm / 120)
            return exp(-0.5 * octaves * octaves)
        }
        var best = minLag
        var bestScore = -Double.infinity
        for lag in minLag...maxLag {
            // Also credit the next beat (2× lag) so the period wins over off-beats.
            let reinforced = scores[lag] + 0.5 * (lag * 2 < scores.count ? scores[lag * 2] : autocorr(centered, lag * 2, energy))
            let s = reinforced * weight(Double(lag))
            if s > bestScore { bestScore = s; best = lag }
        }
        // Refine to a fractional lag from the raw peak's neighbours.
        var lag = Double(best)
        let l = scores[best - 1], c = scores[best], r = scores[best + 1]
        let denominator = l - 2 * c + r
        if denominator < 0 { lag += max(-0.5, min(0.5, 0.5 * (l - r) / denominator)) }
        let others = (minLag...maxLag).filter { abs($0 - best) > 3 }.map { scores[$0] }
        let runnerUp = others.max() ?? 0
        let confidence = max(0, min(1, (c - runnerUp) / max(c, 1e-9) + 0.5 * c))
        return Estimate(bpm: 60 * fps / lag, confidence: confidence)
    }

    private static func autocorr(_ e: [Float], _ lag: Int, _ energy: Float) -> Double {
        guard lag < e.count else { return 0 }
        var sum: Float = 0
        for i in 0..<(e.count - lag) { sum += e[i] * e[i + lag] }
        return Double(sum / energy)
    }
}
