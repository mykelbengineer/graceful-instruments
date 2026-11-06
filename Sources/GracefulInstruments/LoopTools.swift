import Foundation
import Accelerate

/// A named section of a track that can be looped (e.g. "Verse groove", "Chorus vamp").
struct LoopRegion: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var start: Double
    var end: Double
}

/// Finds the repeating pattern in a track and builds longer copies of it.
enum LoopTools {
    struct Pattern {
        var start: Double   // seconds
        var bars: Int
        var score: Double   // 0...1, how alike the repeats are
    }

    /// Per-step feature vectors (12 chroma bins for chords + 4 band energies for drums), 16 steps per bar.
    private static func features(_ d: AudioData, barSamples: Double, firstBar: Double, bars: Int) -> (vecs: [[Float]], energy: [Float]) {
        let steps = 16
        let n = 4096, half = n / 2, log2n = vDSP_Length(12)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return ([], []) }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let sr = AudioData.sampleRate
        // Pitch class and band for each FFT bin.
        var pc = [Int](repeating: -1, count: half), band = [Int](repeating: -1, count: half)
        for k in 1..<half {
            let f = Double(k) * sr / Double(n)
            if f >= 55 && f <= 2000 {
                var p = Int((12 * log2(f / 440)).rounded()) % 12
                if p < 0 { p += 12 }
                pc[k] = p
            }
            band[k] = f < 150 ? 0 : f < 600 ? 1 : f < 2500 ? 2 : f < 8000 ? 3 : -1
        }
        var buf = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        var mag = [Float](repeating: 0, count: half)
        var vecs: [[Float]] = []
        var energy: [Float] = []
        vecs.reserveCapacity(bars * steps)
        for i in 0..<(bars * steps) {
            let center = Int(firstBar + Double(i) * barSamples / Double(steps))
            let start = center - half
            for j in 0..<n {
                let idx = start + j
                buf[j] = (idx >= 0 && idx < d.frames) ? (d.l[idx] + d.r[idx]) * 0.5 * window[j] : 0
            }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    buf.withUnsafeBufferPointer { bp in
                        bp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(half))
                }
            }
            var chroma = [Float](repeating: 0, count: 12), bands = [Float](repeating: 0, count: 4)
            var total: Float = 0
            for k in 1..<half {
                let m = mag[k]
                if pc[k] >= 0 { chroma[pc[k]] += m }
                if band[k] >= 0 { bands[band[k]] += m * m }
                total += m * m
            }
            func unit(_ v: [Float]) -> [Float] {
                let s = sqrt(v.reduce(0) { $0 + $1 * $1 })
                return s > 0 ? v.map { $0 / s } : v
            }
            let b = unit(bands.map { log1p($0) })
            vecs.append(unit(unit(chroma).map { $0 * 0.75 } + b.map { $0 * 0.66 }))
            energy.append(total)
        }
        return (vecs, energy)
    }

    /// Looks for the section that repeats most exactly (1, 2, 4, 8 or 16 bars) on the track's bar grid.
    static func findPattern(_ d: AudioData, bpm: Double, offset: Double, timeSig: TimeSig, maxSeconds: Double = 300) -> Pattern? {
        let sr = AudioData.sampleRate
        let barSamples = 60 / bpm * Double(timeSig.beatsPerBar) * sr
        guard barSamples > 0 else { return nil }
        let first = offset * sr
        let usable = min(Double(d.frames), maxSeconds * sr) - first
        let bars = Int(usable / barSamples)
        guard bars >= 2 else { return nil }
        let (v, e) = features(d, barSamples: barSamples, firstBar: first, bars: bars)
        let steps = 16
        // Bar loudness, to skip silent stretches (silence looks like a perfect repeat).
        var barEnergy = [Float](repeating: 0, count: bars)
        for b in 0..<bars { barEnergy[b] = e[(b * steps)..<((b + 1) * steps)].reduce(0, +) }
        let sorted = barEnergy.sorted()
        let floor = sorted[sorted.count / 2] * 0.15

        func sim(_ a: Int, _ b: Int, _ len: Int) -> Double {
            var s: Float = 0
            for k in 0..<len { for j in 0..<v[a + k].count { s += v[a + k][j] * v[b + k][j] } }
            return Double(s) / Double(len)
        }
        // How alike bar b is to bar b+p, averaged over the whole track (a bar-level autocorrelation).
        // Averaging matters: a fill every 4th bar makes the 1-bar lag worse overall even if some stretches match.
        var lagScore: [Int: Double] = [:]
        for p in [1, 2, 4, 8, 16] where p * 2 <= bars {
            var total = 0.0, count = 0
            for b in 0..<(bars - p) where barEnergy[b] >= floor && barEnergy[b + p] >= floor {
                total += sim(b * steps, (b + p) * steps, steps); count += 1
            }
            if count > 0 { lagScore[p] = total / Double(count) }
        }
        guard let top = lagScore.values.max() else { return nil }
        // The shortest length that repeats about as well as the best one is the real pattern.
        guard let p = [1, 2, 4, 8, 16].first(where: { (lagScore[$0] ?? -1) >= top - 0.01 }) else { return nil }
        // Start where that pattern repeats most cleanly (skipping silence).
        var bestStart = 0, bestScore = -1.0
        for s in 0...(bars - 2 * p) {
            if barEnergy[s..<(s + 2 * p)].contains(where: { $0 < floor }) { continue }
            let score = sim(s * steps, (s + p) * steps, p * steps)
            if score > bestScore { bestScore = score; bestStart = s }
        }
        guard bestScore > 0 else { return nil }
        return Pattern(start: offset + Double(bestStart) * barSamples / sr, bars: p, score: bestScore)
    }

    /// The original with the loop region repeated `copies` extra times, joined like the live loop (10 ms crossfade).
    /// Safe for stems shorter than the loop: anything past a stem's end is silence.
    static func extend(_ d: AudioData, loopStart a0: Int, loopEnd b0: Int, copies: Int) -> AudioData {
        let a = max(0, a0), b = max(a, b0)
        let len = b - a
        let reps = len > 0 ? max(0, copies) : 0
        let total = max(d.frames, b) + reps * len
        let out = AudioData(frames: total)
        // Copies `count` samples from d starting at `src` to out at `dst`; past the end of d stays silent.
        func put(_ dst: Int, _ src: Int, _ count: Int) {
            let n = min(count, d.frames - src, out.frames - dst)
            guard n > 0, src >= 0, dst >= 0 else { return }
            (out.l + dst).update(from: d.l + src, count: n)
            (out.r + dst).update(from: d.r + src, count: n)
        }
        let xf = RenderState.xfade
        put(0, 0, b)
        var pos = b
        for _ in 0..<reps {
            put(pos, a, len)
            if a >= xf {
                for j in 0..<xf {
                    let o = pos - xf + j, src = a - xf + j
                    guard o >= 0, o < out.frames, src < d.frames else { continue }
                    let t = Float(j) / Float(xf)
                    out.l[o] = out.l[o] * (1 - t) + d.l[src] * t
                    out.r[o] = out.r[o] * (1 - t) + d.r[src] * t
                }
            }
            pos += len
        }
        put(pos, b, d.frames - b)
        return out
    }
}
