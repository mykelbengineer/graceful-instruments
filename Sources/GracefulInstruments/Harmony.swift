import Foundation
import Accelerate

// MARK: - Notes and keys

enum Notes {
    static let sharps = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    static let flats = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
    static func name(_ pc: Int, flats useFlats: Bool) -> String {
        let p = ((pc % 12) + 12) % 12
        return useFlats ? flats[p] : sharps[p]
    }
    static func wrap(_ x: Int) -> Int { ((x % 12) + 12) % 12 }
}

/// A key such as Ab major or F# minor.
struct MusicKey: Codable, Hashable {
    var tonic: Int   // 0 = C
    var minor: Bool

    /// The major key with the same notes (Am -> C).
    var relativeMajor: Int { minor ? Notes.wrap(tonic + 3) : tonic }
    /// Spelling the way church musicians say it: Db, Eb, F, Ab, Bb but F#; Cm, Dm, Ebm, Fm, Gm, Bbm.
    var usesFlats: Bool { minor ? [0, 2, 3, 5, 7, 10].contains(tonic) : [1, 3, 5, 8, 10].contains(tonic) }
    var name: String { Notes.name(tonic, flats: usesFlats) + (minor ? "m" : "") }
    var longName: String { Notes.name(tonic, flats: usesFlats) + (minor ? " minor" : " major") }
    func transposed(_ s: Int) -> MusicKey { MusicKey(tonic: Notes.wrap(tonic + s), minor: minor) }

    /// The 7 notes of the key (relative major scale).
    var scale: [Int] { [0, 2, 4, 5, 7, 9, 11].map { Notes.wrap(relativeMajor + $0) } }

    /// Semitones to move a track in `self` so it lands in `target` (closest way, -6...+6).
    func shift(to target: MusicKey) -> Int {
        var d = Notes.wrap(target.relativeMajor - relativeMajor)
        if d > 6 { d -= 12 }
        return d
    }
}

enum ChordQuality: String, Codable, CaseIterable {
    case maj, min, dom7, maj7, min7, sus4, dim
    var intervals: [Int] {
        switch self {
        case .maj: return [0, 4, 7]
        case .min: return [0, 3, 7]
        case .dom7: return [0, 4, 7, 10]
        case .maj7: return [0, 4, 7, 11]
        case .min7: return [0, 3, 7, 10]
        case .sus4: return [0, 5, 7]
        case .dim: return [0, 3, 6]
        }
    }
    var suffix: String {
        switch self {
        case .maj: return ""
        case .min: return "m"
        case .dom7: return "7"
        case .maj7: return "maj7"
        case .min7: return "m7"
        case .sus4: return "sus"
        case .dim: return "dim"
        }
    }
    var simple: ChordQuality {
        switch self {
        case .maj, .dom7, .maj7, .sus4: return .maj
        case .min, .min7, .dim: return .min
        }
    }
    var isMinor: Bool { simple == .min }
}

/// One chord over a stretch of the track (times are in the track's own seconds).
struct ChordSeg: Codable, Hashable {
    var start: Double
    var end: Double
    var root: Int          // -1 = no chord
    var quality: ChordQuality
    var bass: Int?         // slash bass, when it isn't the root

    func symbol(transpose t: Int, flats: Bool, simple: Bool) -> String {
        guard root >= 0 else { return "N.C." }
        let q = simple ? quality.simple : quality
        var s = Notes.name(root + t, flats: flats) + q.suffix
        if let b = bass { s += "/" + Notes.name(b + t, flats: flats) }
        return s
    }

    /// Nashville number relative to the key's major tonic: 1, 4, 5/7, 6m, b7.
    func number(in key: MusicKey, simple: Bool) -> String {
        guard root >= 0 else { return "N.C." }
        let deg = ["1", "b2", "2", "b3", "3", "4", "#4", "5", "b6", "6", "b7", "7"]
        let q = simple ? quality.simple : quality
        var s = deg[Notes.wrap(root - key.relativeMajor)] + q.suffix
        if let b = bass { s += "/" + deg[Notes.wrap(b - key.relativeMajor)] }
        return s
    }
}

struct ChordChart: Codable, Hashable {
    var key: MusicKey
    var segs: [ChordSeg]
    var version = 1
    static let current = 3
}

// MARK: - Pitch-class analysis

/// Turns audio into "how much of each of the 12 notes" over time.
struct ChromaAnalyzer {
    let sr: Double
    let n: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var re: [Float], im: [Float], mag: [Float], buf: [Float]
    private var avg: [Float]

    init(sampleRate: Double, fftSize: Int) {
        sr = sampleRate
        n = fftSize
        log2n = vDSP_Length(log2(Double(fftSize)).rounded())
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        re = [Float](repeating: 0, count: n / 2); im = re; mag = re; avg = re
        buf = [Float](repeating: 0, count: n)
    }

    func destroy() { vDSP_destroy_fftsetup(setup) }

    struct Peak { var midi: Float; var weight: Float }

    /// Spectral peaks of one frame, as fractional MIDI note numbers (A4 = 69) with a loudness weight.
    /// `fill` writes n samples into the buffer it is given.
    mutating func peaks(minMidi: Float = 26, maxMidi: Float = 98, fill: (UnsafeMutablePointer<Float>) -> Void) -> (peaks: [Peak], energy: Float) {
        let half = n / 2
        buf.withUnsafeMutableBufferPointer { fill($0.baseAddress!) }
        vDSP_vmul(buf, 1, window, 1, &buf, 1, vDSP_Length(n))
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
        var energy: Float = 0
        vDSP_svesq(mag, 1, &energy, vDSP_Length(half))
        let binHz = sr / Double(n)
        let k0 = max(2, Int(440 * pow(2, (Double(minMidi) - 69) / 12) / binHz))
        let k1 = min(half - 2, Int(440 * pow(2, (Double(maxMidi) - 69) / 12) / binHz) + 1)
        guard k1 > k0 + 4 else { return ([], energy) }
        var top: Float = 0
        for k in k0...k1 { top = max(top, mag[k]) }
        guard top > 1e-6 else { return ([], energy) }
        // Local average (about a semitone wide at low notes) so only real tonal peaks count, not broadband noise and drums.
        let w = 12
        var cum = [Float](repeating: 0, count: half + 1)
        for k in 0..<half { cum[k + 1] = cum[k] + mag[k] }
        var out: [Peak] = []
        out.reserveCapacity(64)
        for k in k0...k1 {
            let lo = max(0, k - w), hi = min(half, k + w + 1)
            let local = (cum[hi] - cum[lo]) / Float(hi - lo)
            let m = mag[k]
            guard m > mag[k - 1], m >= mag[k + 1], m > top * 0.01, m > local * 1.8 else { continue }
            let a = log(mag[k - 1] + 1e-9), b = log(m + 1e-9), c = log(mag[k + 1] + 1e-9)
            let den = a - 2 * b + c
            let p: Float = den != 0 ? 0.5 * (a - c) / den : 0
            let f = (Double(k) + Double(max(-0.5, min(0.5, p)))) * binHz
            guard f > 20 else { continue }
            let midi = Float(69 + 12 * log2(f / 440))
            out.append(Peak(midi: midi, weight: log(1 + 40 * m / top)))
        }
        return (out, energy)
    }
}

enum Harmony {
    // Albrecht & Shanahan key profiles (pop and hymn corpora).
    static let majorProfile: [Float] = [0.238, 0.006, 0.111, 0.006, 0.137, 0.094, 0.016, 0.214, 0.009, 0.080, 0.008, 0.081]
    static let minorProfile: [Float] = [0.220, 0.006, 0.104, 0.123, 0.019, 0.103, 0.012, 0.214, 0.062, 0.022, 0.061, 0.052]

    static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let n = Float(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var num: Float = 0, da: Float = 0, db: Float = 0
        for i in 0..<a.count {
            let x = a[i] - ma, y = b[i] - mb
            num += x * y; da += x * x; db += y * y
        }
        return da > 0 && db > 0 ? num / sqrt(da * db) : 0
    }

    /// All 24 keys scored against a 12-note profile, best first.
    static func rankKeys(_ chroma: [Float]) -> [(key: MusicKey, score: Float)] {
        var r: [(MusicKey, Float)] = []
        for t in 0..<12 {
            let rot = (0..<12).map { chroma[Notes.wrap($0 + t)] }
            r.append((MusicKey(tonic: t, minor: false), correlation(rot, majorProfile)))
            r.append((MusicKey(tonic: t, minor: true), correlation(rot, minorProfile)))
        }
        return r.sorted { $0.1 > $1.1 }
    }

    struct Frames {
        var treble: [[Float]] = []   // 12 per frame
        var bass: [[Float]] = []
        var energy: [Float] = []
        var hop: Double = 0          // seconds per frame
        var tuning: Float = 0        // semitones the recording is off A440
    }

    /// Pitch-class frames for a whole track.
    static func frames(_ d: AudioData, maxSeconds: Double = 720) -> Frames {
        let sr = AudioData.sampleRate
        let n = 16384, hopN = 2048
        var an = ChromaAnalyzer(sampleRate: sr, fftSize: n)
        defer { an.destroy() }
        let total = min(d.frames, Int(maxSeconds * sr))
        let count = total >= n ? (total - n) / hopN + 1 : 0
        var allPeaks: [[ChromaAnalyzer.Peak]] = []
        var energy: [Float] = []
        allPeaks.reserveCapacity(count)
        for f in 0..<count {
            let start = f * hopN
            let (p, e) = an.peaks { b in
                for j in 0..<n { b[j] = (d.l[start + j] + d.r[start + j]) * 0.5 }
            }
            allPeaks.append(p)
            energy.append(e)
        }
        // How far the recording sits from A440 (many YouTube uploads are slightly sharp or flat).
        var sx: Float = 0, sy: Float = 0
        for ps in allPeaks { for p in ps {
            let dev = p.midi - p.midi.rounded()
            sx += cos(dev * 2 * .pi) * p.weight; sy += sin(dev * 2 * .pi) * p.weight
        } }
        let tuning = atan2(sy, sx) / (2 * .pi)
        var out = Frames()
        out.hop = Double(hopN) / sr
        out.tuning = tuning
        out.energy = energy
        for ps in allPeaks {
            var t = [Float](repeating: 0, count: 12), b = [Float](repeating: 0, count: 12)
            for p in ps {
                let m = p.midi - tuning
                let r = m.rounded()
                let dev = abs(m - r)
                guard dev < 0.4 else { continue }
                let w = p.weight * (1 - dev * 2)
                let pc = Notes.wrap(Int(r))
                if r >= 48 && r <= 96 { t[pc] += w }
                if r >= 28 && r <= 55 { b[pc] += w }
            }
            out.treble.append(t)
            out.bass.append(b)
        }
        return out
    }

    // MARK: chords

    static let qualityPenalty: [ChordQuality: Float] = [.maj: 0, .min: 0, .dom7: 0.08, .maj7: 0.1, .min7: 0.08, .sus4: 0.08, .dim: 0.12]

    struct Candidate { var root: Int; var q: ChordQuality }
    static let candidates: [Candidate] = (0..<12).flatMap { r in ChordQuality.allCases.map { Candidate(root: r, q: $0) } }

    static func templates() -> [[Float]] {
        candidates.map { c in
            var t = [Float](repeating: 0, count: 12)
            for (i, iv) in c.q.intervals.enumerated() {
                t[Notes.wrap(c.root + iv)] = i == 0 ? 1 : (i == 3 ? 0.6 : 0.85)
            }
            let s = sqrt(t.reduce(0) { $0 + $1 * $1 })
            return t.map { $0 / s }
        }
    }

    static func unit(_ v: [Float]) -> [Float] {
        let s = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return s > 0 ? v.map { $0 / s } : v
    }

    /// Key, then chords beat by beat, using the track's beat grid when it has one.
    static func analyze(_ d: AudioData, bpm: Double?, offset: Double, beatsPerBar: Int) -> ChordChart? {
        let fr = frames(d)
        guard !fr.treble.isEmpty else { return nil }
        let duration = Double(d.frames) / AudioData.sampleRate

        // 1. Rough key from the overall note balance.
        var sum = [Float](repeating: 0, count: 12)
        for i in fr.treble.indices { for k in 0..<12 { sum[k] += fr.treble[i][k] + fr.bass[i][k] * 0.5 } }
        let ranked = rankKeys(sum)
        var key = ranked[0].key

        // 2. Beat segments.
        let beat = bpm.map { 60 / $0 } ?? 0.5
        var bounds: [Double] = []
        var t = bpm != nil ? offset.truncatingRemainder(dividingBy: beat) - beat : 0
        if t < 0 { bounds.append(0); t += beat }
        while t < duration { if t >= 0 { bounds.append(t) }; t += beat }
        bounds.append(duration)
        if bounds.count < 2 { return nil }
        // Beat index within the bar, so changes are easier on beat one.
        func beatInBar(_ time: Double) -> Int {
            guard bpm != nil else { return 0 }
            let b = Int(((time - offset) / beat).rounded())
            return ((b % beatsPerBar) + beatsPerBar) % beatsPerBar
        }

        var segT: [[Float]] = [], segB: [[Float]] = [], segE: [Float] = []
        for s in 0..<(bounds.count - 1) {
            let f0 = Int(bounds[s] / fr.hop + 0.5), f1 = max(f0 + 1, Int(bounds[s + 1] / fr.hop + 0.5))
            var tt = [Float](repeating: 0, count: 12), bb = tt
            var e: Float = 0
            var c = 0
            for f in min(f0, fr.treble.count)..<min(f1, fr.treble.count) {
                for k in 0..<12 { tt[k] += fr.treble[f][k]; bb[k] += fr.bass[f][k] }
                e += fr.energy[f]; c += 1
            }
            segT.append(tt); segB.append(bb); segE.append(c > 0 ? e / Float(c) : 0)
        }
        let sortedE = segE.sorted()
        let quiet = sortedE[sortedE.count / 2] * 0.02

        let temps = templates()
        let nC = candidates.count
        let states = nC + 1 // last = no chord

        // A note that rings through the whole song (a drone, a pedal, a bass note bleeding up) says nothing
        // about the chord: take out part of the song-wide average so the changes stand out.
        // Each note's steady background level (its median over the song), measured on beats scaled to the same loudness.
        let scaled: [[Float]] = segT.map { t in let m = t.reduce(0, +); return m > 0 ? t.map { $0 / m } : t }
        var median = [Float](repeating: 0, count: 12)
        let loud = segT.indices.filter { segE[$0] >= quiet }
        if !loud.isEmpty {
            for k in 0..<12 {
                let v = loud.map { scaled[$0][k] }.sorted()
                median[k] = v[v.count / 2]
            }
        }
        // A note that takes a big share of almost every beat (a click, drone or pedal that never stops)
        // can't tell us the chord: take its steady level out. Ordinary chord notes are left alone.
        var meanT = [Float](repeating: 0, count: 12)
        for s in loud { let u = unit(segT[s]); for k in 0..<12 { meanT[k] += u[k] } }
        if !loud.isEmpty { meanT = meanT.map { $0 / Float(loud.count) } }
        let drone = (0..<12).map { median[$0] > 0.26 }
        let whitened: [[Float]] = scaled.map { t in
            let u = unit(t)
            let norm = max(1e-6, sqrt(t.reduce(0) { $0 + $1 * $1 }))
            return unit((0..<12).map { k in
                drone[k] ? max(0, t[k] - 0.9 * median[k]) / norm : max(0, u[k] - 0.6 * meanT[k])
            })
        }

        func run(key: MusicKey) -> [Int] {
            let diatonic = Set(key.scale)
            // Emission scores.
            var em = [[Float]](repeating: [Float](repeating: 0, count: states), count: segT.count)
            for s in segT.indices {
                let tc = whitened[s]
                let bc = unit(segB[s])
                let silent = segE[s] < quiet || tc.allSatisfy { $0 == 0 }
                // How clearly this beat sounds like any chord at all (drum-heavy beats say little).
                var clarity: Float = 0
                for ci in 0..<nC { var d: Float = 0; for k in 0..<12 { d += tc[k] * temps[ci][k] }; clarity = max(clarity, d) }
                let trust: Float = min(1, max(0.25, (clarity - 0.45) / 0.3))
                for (ci, c) in candidates.enumerated() {
                    var sc: Float = 0
                    for k in 0..<12 { sc += tc[k] * temps[ci][k] }
                    sc -= qualityPenalty[c.q] ?? 0
                    sc += bc[c.root] * 0.25  // root in the bass
                    // Chords that belong to the key are far more likely in church songs.
                    let tones = c.q.intervals.map { Notes.wrap(c.root + $0) }
                    let inKey = tones.filter { diatonic.contains($0) }.count
                    if inKey == tones.count { sc += 0.08 } else if inKey < tones.count - 1 { sc -= 0.06 }
                    em[s][ci] = silent ? -1 : sc * trust
                }
                em[s][nC] = silent ? 1 : 0.15
            }
            // Viterbi: staying is cheap, changing costs more off the downbeat.
            let k: Float = 14
            var score = em[0].map { $0 * k }
            var back = [[Int32]](repeating: [Int32](repeating: 0, count: states), count: segT.count)
            for s in 1..<segT.count {
                let pos = beatInBar(bounds[s])
                // Chords mostly change on beat one, sometimes halfway through the bar, rarely anywhere else.
                let change: Float = pos == 0 ? 1.6 : (beatsPerBar == 4 && pos == 2 ? 3.5 : 8)
                var best: Float = -.infinity, bestI = 0
                for i in 0..<states where score[i] > best { best = score[i]; bestI = i }
                var next = [Float](repeating: 0, count: states)
                for j in 0..<states {
                    let stay = score[j]
                    let move = best - change
                    if stay >= move || bestI == j { next[j] = stay; back[s][j] = Int32(j) }
                    else { next[j] = move; back[s][j] = Int32(bestI) }
                    next[j] += em[s][j] * k
                }
                score = next
            }
            var path = [Int](repeating: 0, count: segT.count)
            var bi = 0
            for i in 0..<states where score[i] > score[bi] { bi = i }
            path[segT.count - 1] = bi
            for s in stride(from: segT.count - 1, to: 0, by: -1) { path[s - 1] = Int(back[s][path[s]]) }
            return path
        }

        var path = run(key: key)
        if ProcessInfo.processInfo.environment["GI_CHORD_DEBUG"] != nil {
            print("frames \(fr.treble.count) hop \(fr.hop) tuning \(fr.tuning) segs \(segT.count) quiet \(quiet) key \(key.longName)")
            for s in stride(from: 0, to: min(segT.count, 400), by: 8) {
                let tc = whitened[s]
                let top = tc.indices.sorted { tc[$0] > tc[$1] }.prefix(4).map { Notes.name($0, flats: true) + String(format: "%.2f", tc[$0]) }
                let st = path[s]
                print(String(format: "%6.1fs e=%.2g ", bounds[s], segE[s]) + top.joined(separator: " ") + "  -> " + (st < nC ? Notes.name(candidates[st].root, flats: true) + candidates[st].q.suffix : "N"))
            }
        }

        // 3. Re-check the key with the chords: the tonic chord and the key's own chords should dominate.
        func keyScore(_ k: MusicKey, _ p: [Int]) -> Float {
            let dia = Set(k.scale)
            var inKey: Float = 0, tonic: Float = 0, total: Float = 0
            func isTonic(_ c: Candidate) -> Bool { c.root == k.tonic && (c.q.isMinor == k.minor) && c.q != .sus4 }
            for st in p where st < nC {
                let c = candidates[st]
                total += 1
                if c.q.intervals.allSatisfy({ dia.contains(Notes.wrap(c.root + $0)) }) { inKey += 1 }
                if isTonic(c) { tonic += 1 }
            }
            guard total > 0 else { return 0 }
            // Songs start and end on the 1: look at the first and last few chords.
            let chords = p.filter { $0 < nC }
            let edge = min(8, chords.count)
            let firstHome = Float(chords.prefix(edge).filter { isTonic(candidates[$0]) }.count) / Float(max(1, edge))
            let lastHome = Float(chords.suffix(edge).filter { isTonic(candidates[$0]) }.count) / Float(max(1, edge))
            let endsHome: Float = chords.last.map { isTonic(candidates[$0]) } == true ? 1 : 0
            // Coming home: the 5 or the 4 moving to the 1.
            var arrivals: Float = 0, changes: Float = 0
            var prev = -1
            for st in chords where st != prev {
                if prev >= 0 {
                    changes += 1
                    let a = candidates[prev], b = candidates[st]
                    let step = Notes.wrap(a.root - k.tonic)
                    if isTonic(b) && (step == 7 || step == 5 || step == 10) { arrivals += 1 }
                }
                prev = st
            }
            let cadence = changes > 0 ? arrivals / changes : 0
            return inKey / total * 1.5 + tonic / total * 0.8 + firstHome * 0.3 + lastHome * 0.5 + endsHome * 0.4 + cadence * 1.2
        }
        // Twice: the second pass reads chords that were found with the better key in mind.
        for _ in 0..<2 {
            var bestK = key, bestS: Float = -.infinity
            for cand in ranked {
                let s = keyScore(cand.key, path) + cand.score * 0.4
                if ProcessInfo.processInfo.environment["GI_CHORD_DEBUG"] != nil && s > 0.9 {
                    print("  key \(cand.key.name): \(keyScore(cand.key, path)) + \(cand.score)")
                }
                if s > bestS { bestS = s; bestK = cand.key }
            }
            if bestK == key { break }
            key = bestK
            path = run(key: key)
        }

        // 4. Merge beats into chord segments and add slash basses that hold for the whole chord.
        var segs: [ChordSeg] = []
        var s = 0
        while s < path.count {
            var e = s
            while e + 1 < path.count && path[e + 1] == path[s] { e += 1 }
            let st = path[s]
            var seg = ChordSeg(start: bounds[s], end: bounds[e + 1], root: -1, quality: .maj, bass: nil)
            if st < nC {
                let c = candidates[st]
                seg.root = c.root; seg.quality = c.q
                var bb = [Float](repeating: 0, count: 12)
                for i in s...e { for k in 0..<12 { bb[k] += segB[i][k] } }
                let total = bb.reduce(0, +)
                if total > 0, let top = bb.indices.max(by: { bb[$0] < bb[$1] }), top != c.root,
                   bb[top] > total * 0.3, bb[top] > bb[c.root] * 1.6,
                   c.q.intervals.dropFirst().map({ Notes.wrap(c.root + $0) }).contains(top) {
                    seg.bass = top
                }
            }
            segs.append(seg)
            s = e + 1
        }
        return ChordChart(key: key, segs: segs, version: ChordChart.current)
    }
}
