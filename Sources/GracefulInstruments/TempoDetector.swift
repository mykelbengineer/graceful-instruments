import Foundation
import Accelerate

struct TempoResult {
    var bpm: Double
    var offset: Double // seconds to the first downbeat
}

/// Onset-autocorrelation tempo finder. Good on loops and backing tracks with clear drums;
/// the player also offers tap tempo, half/double and "beat 1 is here" to fix anything it misses.
enum TempoDetector {
    static let hop = 256
    static let frame = 1024
    static let dsRate = 11025.0
    static var fps: Double { dsRate / Double(hop) }
    /// Time from a frame's start to the moment its flux peak represents (measured with --selftest).
    static var onsetDelay = Double(frame / 2) / dsRate + 0.019

    /// Spectral-flux onset envelopes: full band (for tempo) and low band (for finding beat one).
    static func onsetEnvelopes(_ d: AudioData, maxSeconds: Double = 150) -> (all: [Float], low: [Float]) {
        let factor = 4
        let srcFrames = min(d.frames, Int(maxSeconds * AudioData.sampleRate))
        let n = srcFrames / factor
        guard n > frame * 2 else { return ([], []) }
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var s: Float = 0
            let b = i * factor
            for k in 0..<factor { s += d.l[b + k] + d.r[b + k] }
            x[i] = s / Float(factor * 2)
        }
        let log2n = vDSP_Length(10)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return ([], []) }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: frame)
        vDSP_hann_window(&window, vDSP_Length(frame), Int32(vDSP_HANN_NORM))
        let half = frame / 2
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        var buf = [Float](repeating: 0, count: frame)
        var mag = [Float](repeating: 0, count: half)
        var prev = [Float](repeating: 0, count: half)
        let frames = (n - frame) / hop
        var all = [Float](repeating: 0, count: frames)
        var low = [Float](repeating: 0, count: frames)
        let lowBins = 14 // up to ~150 Hz
        for f in 0..<frames {
            x.withUnsafeBufferPointer { xp in
                vDSP_vmul(xp.baseAddress! + f * hop, 1, window, 1, &buf, 1, vDSP_Length(frame))
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
            var sAll: Float = 0, sLow: Float = 0
            for k in 1..<half {
                let v = log1pf(mag[k] * 10)
                let dlt = v - prev[k]
                if dlt > 0 { sAll += dlt; if k <= lowBins { sLow += dlt } }
                prev[k] = v
            }
            all[f] = sAll; low[f] = sLow
        }
        return (normalize(all), normalize(low))
    }

    /// Removes the slow trend and keeps only the rises.
    private static func normalize(_ e: [Float]) -> [Float] {
        let w = 16
        var out = [Float](repeating: 0, count: e.count)
        var acc: Float = 0
        for i in 0..<e.count {
            acc += e[i]
            if i >= w { acc -= e[i - w] }
            let mean = acc / Float(min(i + 1, w))
            out[i] = max(0, e[i] - mean)
        }
        var mx: Float = 0
        vDSP_maxv(out, 1, &mx, vDSP_Length(out.count))
        if mx > 0 { var s = 1 / mx; vDSP_vsmul(out, 1, &s, &out, 1, vDSP_Length(out.count)) }
        return out
    }

    private static func autocorr(_ e: [Float], _ lag: Int) -> Double {
        guard lag < e.count else { return 0 }
        var s: Float = 0
        e.withUnsafeBufferPointer { p in
            vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &s, vDSP_Length(e.count - lag))
        }
        return Double(s) / Double(e.count - lag)
    }

    static func detect(_ d: AudioData, timeSig: TimeSig, hintBPM: Double? = nil) -> TempoResult? {
        let (env, low) = onsetEnvelopes(d)
        guard env.count > 200 else { return nil }
        let fps = self.fps
        var period: Double
        if let h = hintBPM, h > 0 {
            period = 60 * fps / h
        } else {
            // Search 55...190 BPM with a gentle preference around 100.
            let minLag = Int(60 * fps / 190), maxLag = Int(60 * fps / 55) + 1
            var r = [Double](repeating: 0, count: maxLag * 2 + 2)
            // A light blur so sharp hits still line up when the beat falls between frames.
            var smooth = env
            for i in 1..<(env.count - 1) { smooth[i] = 0.25 * env[i - 1] + 0.5 * env[i] + 0.25 * env[i + 1] }
            for lag in minLag...(maxLag * 2 + 1) { r[lag] = autocorr(smooth, lag) }
            var best = minLag; var bestScore = -1.0
            var scores = [Double](repeating: 0, count: maxLag + 1)
            for lag in minLag...maxLag {
                let bpm = 60 * fps / Double(lag)
                let w = exp(-0.5 * pow(log2(bpm / 100) / 0.9, 2))
                let s = w * (r[lag] + 0.5 * r[lag * 2])
                scores[lag] = s
                if s > bestScore { bestScore = s; best = lag }
            }
            period = Double(best)
            if best > minLag && best < maxLag {
                let a = scores[best - 1], b = scores[best], c = scores[best + 1]
                let den = a - 2 * b + c
                if den != 0 { period += 0.5 * (a - c) / den }
            }
            // Refine with a long comb so small errors don't drift over minutes.
            period = refine(env, period)
        }
        let bpm = 60 * fps / period

        // Beat phase: where a comb at this period collects the most onset energy.
        var bestPhase = 0.0; var bestSum: Float = -1
        var phase = 0.0
        while phase < period {
            var s: Float = 0
            var t = phase
            while Int(t) + 1 < env.count {
                let i = Int(t.rounded())
                if i < env.count { s += env[i] }
                t += period
            }
            if s > bestSum { bestSum = s; bestPhase = phase }
            phase += 0.25
        }
        // Beat one: the beat (mod bar) with the strongest low-end (kick) energy.
        let bpb = timeSig.beatsPerBar
        var bestBeat = 0; var bestLow: Float = -1
        for b in 0..<bpb {
            var s: Float = 0
            var t = bestPhase + Double(b) * period
            while Int(t.rounded()) < low.count {
                s += low[Int(t.rounded())]
                t += period * Double(bpb)
            }
            if s > bestLow { bestLow = s; bestBeat = b }
        }
        let frameCenter = onsetDelay
        var offset = (bestPhase + Double(bestBeat) * period) / fps + frameCenter
        let barSec = 60 / bpm * Double(bpb)
        offset = offset.truncatingRemainder(dividingBy: barSec)
        return TempoResult(bpm: (bpm * 100).rounded() / 100, offset: offset)
    }

    private static func refine(_ env: [Float], _ p0: Double) -> Double {
        var best = p0; var bestS: Float = -1
        var p = p0 * 0.985
        while p <= p0 * 1.015 {
            var s: Float = 0
            // sum over a comb of many beats, best phase
            var ph = 0.0
            var localBest: Float = 0
            while ph < p {
                var acc: Float = 0
                var t = ph
                while Int(t.rounded()) < env.count { acc += env[Int(t.rounded())]; t += p }
                localBest = max(localBest, acc)
                ph += 0.5
            }
            s = localBest
            if s > bestS { bestS = s; best = p }
            p += p0 * 0.0002
        }
        return best
    }

    /// Reads tempo and meter hints from names like "AFRICAN PRAISE LOOP 2 (TEMPO_BPM 138)" or "6-8 Worship Loop".
    static func hints(fromTitle title: String) -> (bpm: Double?, timeSig: TimeSig?) {
        let t = title.uppercased()
        var bpm: Double?
        let patterns = [#"(\d{2,3}(?:\.\d+)?)\s*-?\s*BPM"#, #"BPM[\s_:\-]*(\d{2,3}(?:\.\d+)?)"#]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p),
               let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
               let r = Range(m.range(at: 1), in: t), let v = Double(t[r]), v >= 40, v <= 220 {
                bpm = v; break
            }
        }
        if bpm == nil, let re = try? NSRegularExpression(pattern: #"^\s*(\d{2,3})\s+(?:[A-Z]+\s+)*(WORSHIP|PRAISE|LOOP|GROOVE|BEAT|DRUM|PERCUSSIVE|HIGHLIFE|AFRO)"#),
           let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
           let r = Range(m.range(at: 1), in: t), let v = Double(t[r]), v >= 50, v <= 200 {
            bpm = v
        }
        var sig: TimeSig?
        if t.range(of: #"\b12\s*[/\-]\s*8\b"#, options: .regularExpression) != nil { sig = .twelveEight }
        else if t.range(of: #"\b6\s*[/\-]\s*8\b"#, options: .regularExpression) != nil { sig = .sixEight }
        else if t.range(of: #"\b3\s*[/\- ]\s*4\b"#, options: .regularExpression) != nil || t.contains("WALTZ") { sig = .threeFour }
        return (bpm, sig)
    }
}
