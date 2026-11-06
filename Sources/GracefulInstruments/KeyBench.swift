import Foundation

/// `--keybench [files...]`: sings known melodies in every key with a synthetic voice (slides, vibrato,
/// off-pitch singing, room echo) and checks what the Key Finder hears. Optional files are "<path>=<key>".
enum KeyBench {
    static let seconds = Double(ProcessInfo.processInfo.environment["GI_KB_SECONDS"] ?? "") ?? 10
    struct Melody { let name: String; let minor: Bool; let notes: [(Int, Double)] } // semitones from the tonic, beats

    static func m(_ name: String, minor: Bool = false, _ pairs: [Double]) -> Melody {
        var n: [(Int, Double)] = []
        var i = 0
        while i + 1 < pairs.count { n.append((Int(pairs[i]), pairs[i + 1])); i += 2 }
        return Melody(name: name, minor: minor, notes: n)
    }

    static let melodies: [Melody] = [
        m("Amazing Grace", [-5, 1, 0, 2, 4, 0.5, 0, 0.5, 4, 2, 2, 1, 0, 2, -3, 1, -5, 2, -5, 1, 0, 2, 4, 0.5, 0, 0.5, 4, 2, 2, 1, 7, 3, -1, 1,
                            4, 0.5, 7, 0.5, 7, 0.5, 4, 0.5, 7, 2, 4, 1, 0, 2, -3, 1, -5, 2, -5, 1, 0, 2, 4, 0.5, 0, 0.5, 4, 2, 2, 1, 0, 3]),
        m("Joy to the World", [12, 2, 11, 1.5, 9, 0.5, 7, 3, 5, 1, 4, 2, 2, 2, 0, 3, 7, 1, 9, 3, 9, 1, 11, 3, 11, 1, 12, 3, 12, 1, 12, 1, 11, 1, 9, 1, 7, 1, 7, 1.5, 5, 0.5, 4, 1, 0, 2]),
        m("Happy Birthday", [-5, 0.75, -5, 0.25, -3, 1, -5, 1, 0, 1, -1, 2, -5, 0.75, -5, 0.25, -3, 1, -5, 1, 2, 1, 0, 2,
                             -5, 0.75, -5, 0.25, 7, 1, 4, 1, 0, 1, -1, 1, -3, 2, 5, 0.75, 5, 0.25, 4, 1, 0, 1, 2, 1, 0, 2]),
        m("Ode to Joy", [4, 1, 4, 1, 5, 1, 7, 1, 7, 1, 5, 1, 4, 1, 2, 1, 0, 1, 0, 1, 2, 1, 4, 1, 4, 1.5, 2, 0.5, 2, 2,
                         4, 1, 4, 1, 5, 1, 7, 1, 7, 1, 5, 1, 4, 1, 2, 1, 0, 1, 0, 1, 2, 1, 4, 1, 2, 1.5, 0, 0.5, 0, 2]),
        m("Silent Night", [7, 1.5, 9, 0.5, 7, 1, 4, 3, 7, 1.5, 9, 0.5, 7, 1, 4, 3, 14, 2, 14, 1, 11, 3, 12, 2, 12, 1, 7, 3,
                           9, 2, 9, 1, 12, 1.5, 11, 0.5, 9, 1, 7, 1.5, 9, 0.5, 7, 1, 4, 3]),
        m("What a Friend", [7, 1.5, 7, 0.5, 9, 1, 7, 1, 4, 2, 0, 2, 0, 1.5, -3, 0.5, -5, 1, 0, 1, 4, 3, 7, 1.5, 7, 0.5, 9, 1, 7, 1, 4, 2, 0, 2, 2, 1.5, 2, 0.5, 4, 1, 2, 1, 0, 3]),
        m("Praise call (pentatonic)", [0, 0.5, 2, 0.5, 4, 1, 4, 0.5, 2, 0.5, 0, 1, 7, 1, 9, 0.5, 7, 0.5, 4, 1, 2, 1, 0, 2,
                                       4, 0.5, 4, 0.5, 7, 1, 9, 1, 7, 0.5, 4, 0.5, 2, 1, 0, 0.5, -3, 0.5, 0, 2]),
        m("Greensleeves", minor: true, [0, 1, 3, 2, 5, 1, 7, 1.5, 8, 0.5, 7, 1, 5, 2, 2, 1, -2, 1.5, 0, 0.5, 2, 1, 3, 2, 0, 1, 0, 1.5, -1, 0.5, 0, 1, 2, 2, -1, 1, -5, 2,
                                        0, 1, 3, 2, 5, 1, 7, 1.5, 8, 0.5, 7, 1, 5, 2, 2, 1, -2, 1.5, 0, 0.5, 2, 1, 3, 1.5, 2, 0.5, 0, 1, -1, 1.5, -3, 0.5, -1, 1, 0, 3]),
        m("Minor lament", minor: true, [0, 1, 3, 1, 7, 2, 5, 1, 3, 1, 2, 2, 0, 1, 2, 1, 3, 1, 5, 1, 3, 2, 2, 1, -1, 1, 0, 3, 7, 1, 8, 1, 7, 1, 5, 1, 3, 2, 2, 1, 0, 3]),
    ]

    struct Rng {
        var s: UInt64
        mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) }
        mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
    }

    /// A rough singing voice: harmonics shaped by vowel formants, scoops into notes, vibrato, drift.
    static func sing(_ mel: Melody, key: Int, female: Bool, bpm: Double, seconds: Double, seed: UInt64) -> AudioData {
        let sr = AudioData.sampleRate
        var rng = Rng(s: seed)
        let total = Int(seconds * sr)
        let out = AudioData(frames: total)
        let base = Double((female ? 57 : 45) + Notes.wrap(key - 9)) // tonic between A2-G#3 (men) or A3-G#4 (women)
        let tuning = rng.range(-0.45, 0.45)                          // the whole performance sharp or flat
        let vowels: [[Double]] = [[700, 1220, 2600], [400, 2000, 2550], [300, 870, 2240], [530, 1840, 2480], [570, 840, 2410]]
        var t = 0.0, ph = 0.0
        var idx = 0, i = 0
        var notes = mel.notes
        while Double(notes.map { $0.1 }.reduce(0, +)) * 60 / bpm < seconds + 2 { notes += mel.notes }
        while idx < total && i < notes.count {
            let (semi, beats) = notes[i]
            let dur = beats * 60 / bpm
            let n = Int(dur * sr)
            let detune = rng.range(-0.25, 0.25)
            let scoop = rng.next() < 0.6 ? rng.range(-1.2, -0.3) : 0
            let target = base + Double(semi) + tuning + detune
            let prev = i > 0 ? base + Double(notes[i - 1].0) + tuning : target
            let vowel = vowels[Int(rng.next() * Double(vowels.count)) % vowels.count]
            let breath = (i % 8 == 7) ? min(0.35, dur * 0.4) : 0.03
            let vibDepth = rng.range(0.15, 0.4), vibRate = rng.range(4.8, 6.2)
            for k in 0..<n where idx + k < total {
                let tt = Double(k) / sr
                var midi = target
                if tt < 0.08 { midi = target + (scoop != 0 ? scoop : (prev - target) * 0.6) * (1 - tt / 0.08) } // slide in
                if tt > 0.2 { midi += vibDepth * sin(2 * .pi * vibRate * tt) * min(1, (tt - 0.2) * 3) }
                let f0 = 440 * pow(2, (midi - 69) / 12)
                ph += f0 / sr
                if ph > 1e6 { ph -= 1e6 }
                var v = 0.0
                var h = 1
                while Double(h) * f0 < 5000 {
                    let f = Double(h) * f0
                    var g = 1 / Double(h)
                    var fm = 0.0
                    for (j, F) in vowel.enumerated() { let bw = 80.0 + Double(j) * 40; fm += 1 / (1 + pow((f - F) / bw, 2)) * [1, 0.6, 0.3][j] }
                    g *= 0.15 + fm
                    v += sin(2 * .pi * ph * Double(h)) * g
                    h += 1
                }
                let env = min(1, tt / 0.03) * min(1, max(0, (dur - breath - tt) / 0.05))
                out.l[idx + k] = Float(v * env * 0.08)
            }
            idx += n; t += dur; i += 1
        }
        var L = Array(UnsafeBufferPointer(start: out.l, count: total)), R = L
        Reverb.hall(&L, &R, wet: 0.35, decay: 0.7)
        var noise = Rng(s: seed ^ 0xABCD)
        for k in 0..<total { let x = L[k] + Float(noise.range(-0.004, 0.004)); out.l[k] = x; out.r[k] = x }
        return out
    }

    static func run(_ files: [String]) {
        var total = 0, right = 0, related = 0
        var byMelody: [String: (Int, Int)] = [:]
        let t0 = Date()
        for (mi, mel) in melodies.enumerated() {
            for key in 0..<12 {
                let female = (key + mi) % 2 == 0
                let bpm = [72.0, 90, 104, 120][(key + mi) % 4]
                let d = sing(mel, key: key, female: female, bpm: bpm, seconds: KeyBench.seconds, seed: UInt64(mi * 100 + key + 1))
                let want = MusicKey(tonic: key, minor: mel.minor)
                let got = KeyListener.keyOf(d)
                total += 1
                if got == want { right += 1 } else if got?.relativeMajor == want.relativeMajor { related += 1 }
                var b = byMelody[mel.name] ?? (0, 0); b.1 += 1; if got == want { b.0 += 1 }; byMelody[mel.name] = b
                if got != want && CommandLine.arguments.contains("-v") {
                    print("  miss \(mel.name) in \(want.name): heard \(got?.name ?? "nothing")")
                }
            }
        }
        for mel in melodies { let b = byMelody[mel.name]!; print(String(format: "%-26@ %2d / %d", mel.name as NSString, b.0, b.1)) }
        print(String(format: "sung melodies, %.0f s each: %d / %d right (%.0f%%), %d more were the relative major/minor  [%.1f s]",
                     seconds, right, total, Double(right) / Double(total) * 100, related, Date().timeIntervalSince(t0)))
        // Key changes: one song, a short breath, then another song in another key. How long until it follows?
        var times: [Double] = []
        var never = 0
        var freshTimes: [Double] = []
        var freshNever = 0
        for c in 0..<24 {
            let a = melodies[c % melodies.count], b = melodies[(c * 5 + 3) % melodies.count]
            let k1 = (c * 7) % 12, k2 = (c * 7 + 2 + c % 9) % 12
            let first = sing(a, key: k1, female: c % 2 == 0, bpm: 96, seconds: 20, seed: UInt64(500 + c))
            let second = sing(b, key: k2, female: c % 2 == 0, bpm: 88, seconds: 20, seed: UInt64(900 + c))
            let want = MusicKey(tonic: k2, minor: b.minor)
            let kl = KeyListener()
            func feed(_ x: [Float]) {
                var i = 0
                while i < x.count { let n = min(2048, x.count - i); kl.process(Array(x[i..<(i + n)]), sr: AudioData.sampleRate, publish: false); i += n }
            }
            feed(Array(UnsafeBufferPointer(start: first.l, count: first.frames)))
            feed([Float](repeating: 0, count: Int(1.2 * AudioData.sampleRate)))
            var firstRight: Double?
            let half = Int(0.5 * AudioData.sampleRate)
            var t = 0.0, pos = 0
            while pos < second.frames {
                let n = min(half, second.frames - pos)
                feed(Array(UnsafeBufferPointer(start: second.l + pos, count: n)))
                pos += n; t += 0.5
                if kl.estimate() == want { if firstRight == nil { firstRight = t } } else { firstRight = nil }
            }
            if let f = firstRight { times.append(f) } else { never += 1 }
            // Same second song, heard fresh (as if New song was pressed).
            let fresh = KeyListener()
            var fr: Double?
            var t2 = 0.0, p2 = 0
            while p2 < second.frames {
                let n = min(half, second.frames - p2)
                let chunk = Array(UnsafeBufferPointer(start: second.l + p2, count: n))
                var i = 0
                while i < chunk.count { let m = min(2048, chunk.count - i); fresh.process(Array(chunk[i..<(i + m)]), sr: AudioData.sampleRate, publish: false); i += m }
                p2 += n; t2 += 0.5
                if fresh.estimate() == want { if fr == nil { fr = t2 } } else { fr = nil }
            }
            if let f = fr { freshTimes.append(f) } else { freshNever += 1 }
        }
        freshTimes.sort()
        if !freshTimes.isEmpty {
            print(String(format: "same songs heard fresh: %.1f s typically, %d of 24 within 6 s, %d never", freshTimes[freshTimes.count / 2], freshTimes.filter { $0 <= 6 }.count, freshNever))
        }
        times.sort()
        if !times.isEmpty {
            print(String(format: "key change (1 s breath between songs): follows in %.1f s typically (median), %d of 24 within 6 s, %d never",
                         times[times.count / 2], times.filter { $0 <= 6 }.count, never))
        }
        for f in files {
            let parts = f.components(separatedBy: "=")
            guard parts.count == 2, let d = try? AudioLoader.load(URL(fileURLWithPath: parts[0])) else { continue }
            let got = KeyListener.keyOf(d)
            print("file \((parts[0] as NSString).lastPathComponent): want \(parts[1]), heard \(got?.name ?? "nothing")")
        }
    }
}
