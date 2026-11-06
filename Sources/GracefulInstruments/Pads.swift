import Foundation

/// Held pads for prayer, ministration and altar calls.
enum PadSound: String, CaseIterable, Identifiable, Codable {
    case warm, shimmer, organ, strings
    var id: String { rawValue }
    var label: String {
        switch self {
        case .warm: return "Warm pad"
        case .shimmer: return "Shimmer"
        case .organ: return "Gospel organ"
        case .strings: return "Strings"
        }
    }
}

/// Which notes the pad holds. Open (root and fifth) sits under major and minor songs alike.
enum PadChord: String, CaseIterable, Identifiable, Codable {
    case open, major, minor
    var id: String { rawValue }
    var label: String {
        switch self {
        case .open: return "Root + 5th"
        case .major: return "Major"
        case .minor: return "Minor"
        }
    }
}

/// The audio thread's side of the pad: a seamless loop, a crossfade to the next key, and a fade in/out.
final class PadState {
    var incoming: AudioData?
    var incomingGen = 0
    private var gen = 0
    private var cur: AudioData?
    private var old: AudioData?
    private var pos = 0, oldPos = 0
    private var xf: Float = 1
    var xfStep: Float = Float(1 / (2.5 * AudioData.sampleRate))
    var gain: Float = 0
    var target: Float = 0
    var rampStep: Float = Float(1 / (3 * AudioData.sampleRate))
    var mono = false
    var active: Bool { gain > 0 || target > 0 }

    func render(n: Int, outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>) {
        if gen != incomingGen {
            gen = incomingGen
            if gain > 0, let c = cur { old = c; oldPos = pos; xf = 0 } else { old = nil; xf = 1 }
            cur = incoming
            pos = 0
        }
        guard let c = cur, gain > 0 || target > 0 else {
            outL.initialize(repeating: 0, count: n); outR.initialize(repeating: 0, count: n); return
        }
        let o = old
        for i in 0..<n {
            if gain < target { gain = min(target, gain + rampStep) } else if gain > target { gain = max(target, gain - rampStep) }
            var l = c.l[pos], r = c.r[pos]
            pos += 1; if pos >= c.frames { pos = 0 }
            if let o = o, xf < 1 {
                // Equal-power crossfade between the two keys.
                let a = sin(xf * .pi / 2), b = cos(xf * .pi / 2)
                l = l * a + o.l[oldPos] * b
                r = r * a + o.r[oldPos] * b
                oldPos += 1; if oldPos >= o.frames { oldPos = 0 }
                xf += xfStep
                if xf >= 1 { xf = 1 }
            }
            if mono { let m = (l + r) * 0.5; l = m; r = m }
            outL[i] = l * gain; outR[i] = r * gain
        }
        if xf >= 1 { old = nil }
    }
}

/// Renders pad loops (about 20 s, seamless) in any key.
enum PadSynth {
    static let loopSeconds = 20.0

    static func voicing(key: Int, chord: PadChord) -> [Int] {
        let r = 41 + Notes.wrap(key - 5) // root between F2 and E3
        switch chord {
        case .open: return [r, r + 7, r + 12, r + 19, r + 24]
        case .major: return [r, r + 7, r + 12, r + 16, r + 19, r + 24]
        case .minor: return [r, r + 7, r + 12, r + 15, r + 19, r + 24]
        }
    }

    static func hz(_ midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }

    static func render(sound: PadSound, key: Int, chord: PadChord) -> AudioData {
        let sr = AudioData.sampleRate
        let loopN = Int(loopSeconds * sr)
        let xN = Int(4 * sr)       // crossfade that makes the loop seamless
        let pre = Int(3 * sr)      // lets the reverb fill up before the loop starts
        let total = pre + loopN + xN
        var L = [Float](repeating: 0, count: total), R = L
        let notes = voicing(key: key, chord: chord).map(Double.init)
        var rng = SystemRandomNumberGenerator()
        func rand() -> Double { Double.random(in: 0..<1, using: &rng) }

        func saw(_ freq: Double, _ gain: Float, pan: Float, filterHz: Double, into: Bool = true) {
            // Band-limited (PolyBLEP) saw, then a gentle two-pole low-pass that breathes slowly.
            let dt = freq / sr
            var ph = rand()
            var y1: Double = 0, y2: Double = 0
            let lfoRate = 1 / (loopSeconds / 2), lfoPh = rand() * 2 * .pi
            let gl = gain * (1 - pan) * 0.5 + gain * 0.25, gr = gain * (1 + pan) * 0.5 + gain * 0.25
            for i in 0..<total {
                var v = 2 * ph - 1
                if ph < dt { let t = ph / dt; v -= t + t - t * t - 1 }
                else if ph > 1 - dt { let t = (ph - 1) / dt; v -= t * t + t + t + 1 }
                ph += dt; if ph >= 1 { ph -= 1 }
                let fc = filterHz * (1 + 0.35 * sin(2 * .pi * lfoRate * Double(i) / sr + lfoPh))
                let a = 1 - exp(-2 * .pi * fc / sr)
                y1 += a * (v - y1); y2 += a * (y1 - y2)
                let s = Float(y2)
                L[i] += s * gl; R[i] += s * gr
            }
        }
        func sine(_ freq: Double, _ gain: Float, pan: Float, swell: Double = 0, vibrato: Double = 0, vibRate: Double = 5) {
            var ph = rand()
            let swPh = rand() * 2 * .pi
            let gl = gain * (1 - pan) * 0.5 + gain * 0.25, gr = gain * (1 + pan) * 0.5 + gain * 0.25
            for i in 0..<total {
                let t = Double(i) / sr
                let f = freq * (1 + vibrato * sin(2 * .pi * vibRate * t))
                ph += f / sr; if ph >= 1 { ph -= 1 }
                let env = 1 - swell * 0.5 * (1 + sin(2 * .pi * t / (loopSeconds / 2) + swPh))
                let s = Float(sin(2 * .pi * ph) * env)
                L[i] += s * gl; R[i] += s * gr
            }
        }

        switch sound {
        case .warm:
            for (k, m) in notes.enumerated() {
                let g: Float = k == 0 ? 0.16 : 0.11
                for v in 0..<5 {
                    let cents = Double(v - 2) * 6 + (rand() - 0.5) * 3
                    saw(hz(m + cents / 100), g / 2.2, pan: Float(v - 2) / 2.5, filterHz: 900 + Double(k) * 120)
                }
            }
            sine(hz(notes[0] - 12), 0.22, pan: 0)
        case .shimmer:
            for (k, m) in notes.enumerated() {
                sine(hz(m + 12), 0.10, pan: Float(k % 2 == 0 ? -0.6 : 0.6), swell: 0.6)
                sine(hz(m + 24) * 1.001, 0.04, pan: Float(k % 2 == 0 ? 0.7 : -0.7), swell: 0.8)
            }
            for v in 0..<3 { saw(hz(notes[0] + Double(v - 1) * 0.08), 0.07, pan: Float(v - 1) * 0.6, filterHz: 500) }
            sine(hz(notes[0]), 0.16, pan: 0)
        case .organ:
            // Drawbars 16', 8', 5 1/3', 4', 2' with a slow rotating-speaker wobble.
            let bars: [(Double, Float)] = [(0.5, 0.8), (1, 1), (1.5, 0.7), (2, 0.5), (4, 0.25)]
            for (k, m) in notes.enumerated() where k < 5 {
                for (h, g) in bars {
                    sine(hz(m) * h, g * 0.045, pan: Float(k % 2 == 0 ? -0.4 : 0.4), vibrato: 0.0025, vibRate: 0.8 + rand() * 0.2)
                }
            }
        case .strings:
            for (k, m) in notes.enumerated() where k > 0 {
                for v in 0..<4 {
                    let cents = Double(v) * 5 - 7.5 + (rand() - 0.5) * 4
                    saw(hz(m + cents / 100), 0.05, pan: Float(v) / 1.5 - 1, filterHz: 1800 + Double(k) * 200)
                }
            }
            for v in 0..<2 { saw(hz(notes[0] + Double(v) * 0.06 - 0.03), 0.06, pan: Float(v) - 0.5, filterHz: 700) }
        }

        // Hall reverb (8 feedback delay lines), long and dark.
        let wet: Float = sound == .shimmer ? 0.75 : (sound == .organ ? 0.35 : 0.5)
        Reverb.hall(&L, &R, wet: wet, decay: sound == .shimmer ? 0.92 : 0.86)

        // Make the loop seamless: the end crossfades into the start.
        let out = AudioData(frames: loopN)
        var peak: Float = 0
        for i in 0..<loopN {
            var l = L[pre + i], r = R[pre + i]
            if i < xN {
                let t = Float(i) / Float(xN)
                let a = sin(t * .pi / 2), b = cos(t * .pi / 2)
                l = l * a + L[pre + loopN + i] * b
                r = r * a + R[pre + loopN + i] * b
            }
            out.l[i] = l; out.r[i] = r
            peak = max(peak, abs(l), abs(r))
        }
        let g = peak > 0 ? 0.5 / peak : 0
        for i in 0..<loopN { out.l[i] *= g; out.r[i] *= g }
        return out
    }
}

enum Reverb {
    /// A smooth feedback-delay-network hall. `decay` is the per-trip feedback (0.6 room ... 0.93 very long).
    static func hall(_ L: inout [Float], _ R: inout [Float], wet: Float, decay: Float) {
        let sr = AudioData.sampleRate
        let lens = [1433, 1601, 1867, 2053, 2251, 2399, 2617, 2903].map { Int(Double($0) * sr / 44100 * 1.6) }
        let total = lens.reduce(0, +)
        let mem = UnsafeMutablePointer<Float>.allocate(capacity: total)
        mem.initialize(repeating: 0, count: total)
        defer { mem.deallocate() }
        var base = [Int](repeating: 0, count: 8)
        for k in 1..<8 { base[k] = base[k - 1] + lens[k - 1] }
        var idx = [Int](repeating: 0, count: 8)
        var damp = [Float](repeating: 0, count: 8)
        var o = [Float](repeating: 0, count: 8)
        let n = L.count
        let pre = Int(0.02 * sr)
        var preL = [Float](repeating: 0, count: pre), preR = preL
        var pi = 0
        let s: Float = 0.35355339 * decay // 1/sqrt(8), times the feedback
        for i in 0..<n {
            let inL = preL[pi] * 0.35, inR = preR[pi] * 0.35
            preL[pi] = L[i]; preR[pi] = R[i]
            pi += 1; if pi >= pre { pi = 0 }
            for k in 0..<8 { o[k] = mem[base[k] + idx[k]] }
            // Hadamard mix keeps the energy spread evenly between the lines.
            let a0 = o[0] + o[1], a1 = o[0] - o[1], a2 = o[2] + o[3], a3 = o[2] - o[3]
            let a4 = o[4] + o[5], a5 = o[4] - o[5], a6 = o[6] + o[7], a7 = o[6] - o[7]
            let b0 = a0 + a2, b1 = a1 + a3, b2 = a0 - a2, b3 = a1 - a3
            let b4 = a4 + a6, b5 = a5 + a7, b6 = a4 - a6, b7 = a5 - a7
            let m0 = b0 + b4, m1 = b1 + b5, m2 = b2 + b6, m3 = b3 + b7
            let m4 = b0 - b4, m5 = b1 - b5, m6 = b2 - b6, m7 = b3 - b7
            @inline(__always) func feed(_ k: Int, _ m: Float, _ x: Float) {
                damp[k] += 0.45 * (m * s + x - damp[k]) // high frequencies die away first
                mem[base[k] + idx[k]] = damp[k]
                idx[k] += 1; if idx[k] >= lens[k] { idx[k] = 0 }
            }
            feed(0, m0, inL); feed(1, m1, inR); feed(2, m2, inL); feed(3, m3, inR)
            feed(4, m4, inL); feed(5, m5, inR); feed(6, m6, inL); feed(7, m7, inR)
            let wl = o[0] + o[2] + o[4] + o[6], wr = o[1] + o[3] + o[5] + o[7]
            L[i] = L[i] * (1 - wet * 0.5) + wl * wet * 0.5
            R[i] = R[i] * (1 - wet * 0.5) + wr * wet * 0.5
        }
    }
}

/// The pad's controls. Pads play on their own, under whatever else is playing, and keep going between songs.
final class PadController: ObservableObject {
    @Published var on = false
    @Published var key = 8 { didSet { if key != oldValue { save(); if on { refresh() } } } }
    @Published var sound: PadSound = .warm { didSet { if sound != oldValue { save(); if on { refresh() } } } }
    @Published var chord: PadChord = .open { didSet { if chord != oldValue { save(); if on { refresh() } } } }
    @Published var volume: Float = 0.7 { didSet { apply(); save() } }
    @Published var route: Route = .right { didSet { apply(); save() } }
    @Published var fadeIn: Double = 4 { didSet { save() } }
    @Published var fadeOut: Double = 6 { didSet { save() } }
    @Published var rendering = false

    private let engine: AudioEngine
    private let queue = DispatchQueue(label: "gi.pad", qos: .userInitiated)
    private var cache: [String: AudioData] = [:]
    private var order: [String] = []
    private var wanted = ""

    init(engine: AudioEngine) {
        self.engine = engine
        let d = UserDefaults.standard
        if d.object(forKey: "padKey") != nil { key = d.integer(forKey: "padKey") }
        if let s = d.string(forKey: "padSound").flatMap(PadSound.init(rawValue:)) { sound = s }
        if let c = d.string(forKey: "padChord").flatMap(PadChord.init(rawValue:)) { chord = c }
        if d.object(forKey: "padVolume") != nil { volume = d.float(forKey: "padVolume") }
        if let r = d.string(forKey: "padRoute").flatMap(Route.init(rawValue:)) { route = r }
        if d.object(forKey: "padFadeIn") != nil { fadeIn = d.double(forKey: "padFadeIn") }
        if d.object(forKey: "padFadeOut") != nil { fadeOut = d.double(forKey: "padFadeOut") }
        apply()
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(key, forKey: "padKey"); d.set(sound.rawValue, forKey: "padSound"); d.set(chord.rawValue, forKey: "padChord")
        d.set(volume, forKey: "padVolume"); d.set(route.rawValue, forKey: "padRoute")
        d.set(fadeIn, forKey: "padFadeIn"); d.set(fadeOut, forKey: "padFadeOut")
    }

    private func apply() { engine.setPad(volume: volume, route: route) }

    var keyName: String { MusicKey(tonic: key, minor: chord == .minor).name }

    func toggle() { on ? stop() : start() }

    func start() {
        on = true
        refresh()
    }

    func stop() {
        on = false
        wanted = ""
        engine.padStop(fadeOut: fadeOut)
    }

    /// Play in this key (crossfades if already playing).
    func play(key k: Int) {
        key = k
        if !on { start() }
    }

    private func refresh() {
        let id = "\(sound.rawValue)-\(chord.rawValue)-\(key)"
        wanted = id
        if let d = cache[id] { engine.padPlay(d, fadeIn: fadeIn); return }
        rendering = true
        let s = sound, c = chord, k = key
        queue.async { [weak self] in
            let d = PadSynth.render(sound: s, key: k, chord: c)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.rendering = false
                self.cache[id] = d
                self.order.removeAll { $0 == id }
                self.order.append(id)
                if self.order.count > 8 { self.cache.removeValue(forKey: self.order.removeFirst()) }
                if self.on && self.wanted == id { self.engine.padPlay(d, fadeIn: self.fadeIn) }
            }
        }
    }

    /// Renders the next and previous keys in the background so key changes are instant.
    func warmUp() {
        let s = sound, c = chord
        for k in [key, Notes.wrap(key + 1), Notes.wrap(key - 1), Notes.wrap(key + 2)] {
            let id = "\(s.rawValue)-\(c.rawValue)-\(k)"
            guard cache[id] == nil else { continue }
            queue.async { [weak self] in
                let d = PadSynth.render(sound: s, key: k, chord: c)
                DispatchQueue.main.async {
                    guard let self = self, self.cache[id] == nil else { return }
                    self.cache[id] = d
                    self.order.append(id)
                    if self.order.count > 8 { self.cache.removeValue(forKey: self.order.removeFirst()) }
                }
            }
        }
    }
}
