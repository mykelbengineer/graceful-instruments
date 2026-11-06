import Foundation
import AVFoundation
import Accelerate

/// Listens through the microphone and works out the key someone is singing or playing in.
final class KeyListener: ObservableObject {
    static let shared = KeyListener()

    @Published var listening = false
    @Published var key: MusicKey?
    @Published var runnerUp: MusicKey?
    @Published var sure: Double = 0          // 0...1
    @Published var notes = [Float](repeating: 0, count: 12)
    @Published var nowNote: Int?
    @Published var level: Float = 0
    @Published var heard: Double = 0         // seconds of sound so far
    @Published var message = ""

    private var engine: AVAudioEngine?
    private let queue = DispatchQueue(label: "gi.keylistener", qos: .userInitiated)
    private var analyzer: ChromaAnalyzer?
    private var analyzerSR: Double = 0
    private var ring = [Float](repeating: 0, count: 8192)
    private var ringFill = 0
    /// Heard notes in 10-cent steps (120 per octave), so the singer's own tuning can be found.
    private var acc = [Float](repeating: 0, count: 120)
    /// The last few seconds only, to notice when the leader has moved to another song or key.
    private var racc = [Float](repeating: 0, count: 120)
    private var recentVoiced = 0.0
    private var silent = 0.0
    private var disagree = 0.0
    private var sinceCheck = 0.0
    private var newSong = false
    /// Tallies started at each of the last few breaths: "what if a new song began here?"
    private var since: [(acc: [Float], voiced: Double, agree: Double)] = []
    static let memory = Double(ProcessInfo.processInfo.environment["GI_KF_HL"] ?? "") ?? 12      // seconds
    static let recentMemory = Double(ProcessInfo.processInfo.environment["GI_KF_RHL"] ?? "") ?? 3.5
    static let pauseIsNewSong = 7.0
    static let switchMargin = Float(ProcessInfo.processInfo.environment["GI_KF_SM"] ?? "") ?? 0.06
    static let switchAfter = Double(ProcessInfo.processInfo.environment["GI_KF_SA"] ?? "") ?? 1
    private var recent: [[Float]] = []
    private var prevTop = -1
    private var wasVoiced = false
    private var short = [Float](repeating: 0, count: 12)
    private var noiseFloor: Float = 1e-4
    private var voiced = 0.0
    private var lastPublish = Date.distantPast

    func toggle() { listening ? stop() : start() }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: begin()
        case .notDetermined:
            message = "Allow the microphone in the box that appears."
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async {
                    if ok { self.begin() } else { self.message = "Microphone access was turned down. Turn it on in System Preferences > Security & Privacy > Privacy > Microphone." }
                }
            }
        default:
            message = "Microphone access is off. Turn it on in System Preferences > Security & Privacy > Privacy > Microphone."
        }
    }

    private func begin() {
        guard engine == nil else { return }
        let e = AVAudioEngine()
        let input = e.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            message = "No microphone found."
            return
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in
            guard let self = self, let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            let copy = Array(UnsafeBufferPointer(start: ch, count: n))
            let sr = fmt.sampleRate
            self.queue.async { self.process(copy, sr: sr) }
        }
        do {
            e.prepare()
            try e.start()
            engine = e
            listening = true
            message = ""
        } catch {
            input.removeTap(onBus: 0)
            message = "The microphone could not start: \(error.localizedDescription)"
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        listening = false
        level = 0
        nowNote = nil
    }

    /// Forget what was heard, for the next song.
    func reset() {
        queue.async {
            self.acc = [Float](repeating: 0, count: 120)
            self.racc = self.acc
            self.short = [Float](repeating: 0, count: 12)
            self.recent = []
            self.voiced = 0; self.recentVoiced = 0; self.disagree = 0; self.since = []
        }
        key = nil; runnerUp = nil; sure = 0; heard = 0; nowNote = nil
        notes = [Float](repeating: 0, count: 12)
    }

    /// Feeds samples (also used by the self-test with a file).
    func process(_ x: [Float], sr: Double, publish: Bool = true) {
        if analyzer == nil || analyzerSR != sr {
            analyzer?.destroy()
            // About 170 ms windows: long enough for low voices, short enough to follow a melody.
            analyzer = ChromaAnalyzer(sampleRate: sr, fftSize: sr > 60000 ? 16384 : 8192)
            analyzerSR = sr
            ring = [Float](repeating: 0, count: analyzer!.n)
            ringFill = 0
        }
        let n = ring.count
        let hop = n / 2
        var i = 0
        while i < x.count {
            let take = min(x.count - i, n - ringFill)
            if ringFill + take <= n {
                ring.replaceSubrange(ringFill..<(ringFill + take), with: x[i..<(i + take)])
                ringFill += take
            }
            i += take
            if ringFill == n {
                analyzeFrame(sr: sr, hopSeconds: Double(hop) / sr)
                ring.replaceSubrange(0..<(n - hop), with: ring[hop..<n])
                ringFill = n - hop
            }
        }
        if publish && Date().timeIntervalSince(lastPublish) > 0.15 {
            lastPublish = Date()
            publishResult()
        }
    }

    private var lastRMS: Float = 0
    static var endWeight: Float = Float(ProcessInfo.processInfo.environment["GI_KF_END"] ?? "") ?? 3 // phrase-ending notes count this much extra
    static var slideWeight: Float = Float(ProcessInfo.processInfo.environment["GI_KF_SLIDE"] ?? "") ?? 0.1 // notes heard while sliding count this much

    private func analyzeFrame(sr: Double, hopSeconds: Double) {
        guard var an = analyzer else { return }
        var ms: Float = 0
        for v in ring { ms += v * v }
        let rms = sqrt(ms / Float(ring.count))
        lastRMS = rms
        // Track the room's background level and only listen when something louder is happening.
        noiseFloor = rms < noiseFloor ? rms : noiseFloor * 1.002
        noiseFloor = max(noiseFloor, 1e-5)
        let r = ring
        let (peaks, _) = an.peaks(minMidi: 36, maxMidi: 96) { b in for j in 0..<r.count { b[j] = r[j] } }
        analyzer = an
        let decayShort: Float = 0.6
        for k in 0..<12 { short[k] *= decayShort }
        let fade = Float(pow(0.5, hopSeconds / KeyListener.memory))         // older singing fades (half in ~12 s)
        let rfade = Float(pow(0.5, hopSeconds / KeyListener.recentMemory))
        guard rms > noiseFloor * 3, rms > 0.002, !peaks.isEmpty else {
            // End of a phrase: the last held note is very often the home note, so count it again.
            if wasVoiced && !recent.isEmpty {
                for f in recent { for b in 0..<120 {
                    acc[b] += f[b] * KeyListener.endWeight; racc[b] += f[b] * KeyListener.endWeight
                    for j in since.indices { since[j].acc[b] += f[b] * KeyListener.endWeight }
                } }
            }
            if wasVoiced {
                since.append(([Float](repeating: 0, count: 120), 0, 0))
                if since.count > 4 { since.removeFirst() }
            }
            recent = []; wasVoiced = false; prevTop = -1
            silent += hopSeconds
            return
        }
        // A long pause means a new song: start fresh.
        if silent >= KeyListener.pauseIsNewSong && voiced > 0 {
            acc = [Float](repeating: 0, count: 120); racc = acc
            voiced = 0; recentVoiced = 0; disagree = 0; newSong = true; since = []
        }
        silent = 0
        var fine = [Float](repeating: 0, count: 120)
        func add(_ midi: Float, _ w: Float) {
            let pos = midi * 10
            let lo = Int(floor(pos)), t = pos - floor(pos)
            fine[((lo % 120) + 120) % 120] += w * (1 - t)
            fine[(((lo + 1) % 120) + 120) % 120] += w * t
        }
        // A single voice: follow the note actually sung (its fundamental). Counting every overtone
        // would add the fifth above each note and pull the answer towards the wrong key.
        if KeyListener.useYIN, let f0 = KeyListener.yin(r, sr: sr) {
            add(Float(69 + 12 * log2(f0 / 440)), 1)
        } else {
            for p in peaks { add(p.midi, p.weight) }
        }
        let s = fine.reduce(0, +)
        guard s > 0 else { return }
        for b in 0..<120 { fine[b] /= s }
        // Held notes count fully; slides between notes count less.
        let top = fine.indices.max { fine[$0] < fine[$1] } ?? 0
        var d = abs(top - prevTop) % 120
        d = min(d, 120 - d)
        let steady: Float = prevTop < 0 || d <= 3 ? 1 : KeyListener.slideWeight
        prevTop = top
        for b in 0..<120 {
            acc[b] = acc[b] * fade + fine[b] * steady
            racc[b] = racc[b] * rfade + fine[b] * steady
        }
        for j in since.indices {
            for b in 0..<120 { since[j].acc[b] += fine[b] * steady }
            since[j].voiced += hopSeconds
        }
        let near = Notes.wrap(Int((Float(top) / 10).rounded()))
        short[near] += 1
        recent.append(fine.map { $0 * steady })
        if recent.count > 4 { recent.removeFirst() }
        wasVoiced = true
        voiced += hopSeconds
        recentVoiced += hopSeconds
        // Twice a second: did a new song start at one of the last breaths? If singing since then clearly
        // points to another key (not just the relative major/minor), follow it.
        sinceCheck += hopSeconds
        if sinceCheck >= 0.5 && voiced >= 3 {
            let step = sinceCheck
            sinceCheck = 0
            let longBest = KeyListener.ranked(KeyListener.fold(acc).notes)[0].key
            var adopt: Int?
            for j in since.indices where since[j].voiced >= KeyListener.switchAfter + 1 {
                let r = KeyListener.ranked(KeyListener.fold(since[j].acc).notes)
                let rival = r.dropFirst().first { $0.key.relativeMajor != r[0].key.relativeMajor } ?? r[1]
                if r[0].key.relativeMajor != longBest.relativeMajor && r[0].score - rival.score >= KeyListener.switchMargin {
                    since[j].agree += step
                    if since[j].agree >= KeyListener.switchAfter && adopt == nil { adopt = j }
                } else {
                    since[j].agree = 0
                }
            }
            if let j = adopt {
                acc = since[j].acc
                voiced = since[j].voiced
                since.removeAll()
            }
        }
    }

    /// Current best key (used by the bench test).
    func estimate() -> MusicKey? {
        guard voiced >= 1.8, acc.reduce(0, +) > 0 else { return nil }
        return KeyListener.ranked(KeyListener.fold(acc).notes)[0].key
    }

    /// Folds the fine histogram into 12 notes, centred on the singer's own tuning.
    static func fold(_ acc: [Float]) -> (notes: [Float], tuning: Float) {
        var sx: Float = 0, sy: Float = 0
        for b in 0..<120 {
            let ang = Float(b % 10) / 10 * 2 * .pi
            sx += cos(ang) * acc[b]; sy += sin(ang) * acc[b]
        }
        let tuning = atan2(sy, sx) / (2 * .pi) // semitones, -0.5...0.5
        var c = [Float](repeating: 0, count: 12)
        for b in 0..<120 {
            let m = Float(b) / 10 - tuning
            c[Notes.wrap(Int(m.rounded()))] += acc[b]
        }
        return (c, tuning)
    }

    /// Best key, leaning slightly to major (most church songs are major) and to the note phrases end on.
    static let useYIN = ProcessInfo.processInfo.environment["GI_KF_YIN"] != "0"
    static let profile = ProcessInfo.processInfo.environment["GI_KF_PROFILE"] ?? "aarden"

    static func ranked(_ notes: [Float]) -> [(key: MusicKey, score: Float)] {
        let (maj, min): ([Float], [Float])
        switch profile {
        case "albrecht": (maj, min) = (Harmony.majorProfile, Harmony.minorProfile)
        case "temperley": (maj, min) = ([0.748, 0.060, 0.488, 0.082, 0.670, 0.460, 0.096, 0.715, 0.104, 0.366, 0.057, 0.400],
                                        [0.712, 0.084, 0.474, 0.618, 0.049, 0.460, 0.105, 0.747, 0.404, 0.067, 0.133, 0.330])
        case "krumhansl": (maj, min) = ([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88],
                                        [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])
        default: // Aarden-Essen: made from thousands of sung folk melodies
            (maj, min) = ([17.7661, 0.145624, 14.9265, 0.160186, 19.8049, 11.3587, 0.291248, 22.062, 0.145624, 8.15494, 0.232998, 4.95122],
                          [18.2648, 0.737619, 14.0499, 16.8599, 0.702494, 14.4362, 0.702494, 18.6161, 4.56621, 1.93186, 7.37619, 1.75623])
        }
        var r: [(key: MusicKey, score: Float)] = []
        for t in 0..<12 {
            let rot = (0..<12).map { notes[Notes.wrap($0 + t)] }
            r.append((MusicKey(tonic: t, minor: false), Harmony.correlation(rot, maj) + KeyListener.majorLean))
            r.append((MusicKey(tonic: t, minor: true), Harmony.correlation(rot, min)))
        }
        return r.sorted { $0.score > $1.score }
    }
    static let majorLean = Float(ProcessInfo.processInfo.environment["GI_KF_MAJ"] ?? "") ?? 0.03

    /// YIN pitch tracker (de Cheveigné & Kawahara 2002) on the newest part of the buffer. Nil when it isn't one clear note.
    static func yin(_ x: [Float], sr: Double) -> Double? {
        let tauMin = Int(sr / 1000), tauMax = Int(sr / 65)
        let w = Int(sr * 0.03)
        let start = x.count - w - tauMax
        guard start >= 0 else { return nil }
        var d = [Float](repeating: 0, count: tauMax + 1)
        x.withUnsafeBufferPointer { b in
            let p = b.baseAddress! + start
            var e0: Float = 0
            vDSP_svesq(p, 1, &e0, vDSP_Length(w))
            var et: Float = e0
            for tau in 1...tauMax {
                // energy of the shifted window, updated as it slides
                et += p[tau + w - 1] * p[tau + w - 1] - p[tau - 1] * p[tau - 1]
                var cross: Float = 0
                vDSP_dotpr(p, 1, p + tau, 1, &cross, vDSP_Length(w))
                d[tau] = max(0, e0 + et - 2 * cross)
            }
        }
        // Cumulative mean normalised difference.
        var running: Float = 0
        var cm = [Float](repeating: 1, count: tauMax + 1)
        for tau in 1...tauMax {
            running += d[tau]
            cm[tau] = running > 0 ? d[tau] * Float(tau) / running : 1
        }
        var tau = tauMin
        while tau < tauMax {
            if cm[tau] < 0.15 {
                while tau + 1 < tauMax && cm[tau + 1] < cm[tau] { tau += 1 }
                break
            }
            tau += 1
        }
        guard tau < tauMax, cm[tau] < 0.2 else { return nil }
        // Parabolic interpolation around the dip.
        let a = cm[tau - 1], b = cm[tau], c = cm[tau + 1]
        let den = a - 2 * b + c
        let shift = den != 0 ? 0.5 * (a - c) / den : 0
        return sr / (Double(tau) + Double(max(-0.5, min(0.5, shift))))
    }

    private func publishResult() {
        let a = KeyListener.fold(acc).notes, sh = short, v = voiced, lvl = lastRMS
        let fresh = newSong
        newSong = false
        var result: (MusicKey, MusicKey, Double)?
        if v >= 1.8, a.reduce(0, +) > 0 {
            let ranked = KeyListener.ranked(a)
            let best = ranked[0]
            // Runner-up that isn't just the relative major/minor of the best.
            let second = ranked.dropFirst().first { $0.key.relativeMajor != best.key.relativeMajor } ?? ranked[1]
            let margin = Double(best.score - second.score)
            let sure = min(1, max(0, margin / 0.25)) * min(1, v / 5)
            let alt = ranked[1]
            result = (best.key, alt.key, sure)
        }
        let top = a.max() ?? 0
        let norm = top > 0 ? a.map { $0 / top } : a
        var now: Int?
        if let m = sh.max(), m > 0.5, let idx = sh.firstIndex(of: m) { now = idx }
        DispatchQueue.main.async {
            self.level = min(1, lvl * 8)
            self.heard = v
            self.notes = norm
            self.nowNote = now
            if fresh { self.key = nil; self.runnerUp = nil; self.sure = 0 }
            if let r = result { self.key = r.0; self.runnerUp = r.1; self.sure = r.2 }
        }
    }

    /// Offline check: the key heard after feeding a whole file.
    static func keyOf(_ d: AudioData) -> MusicKey? {
        let k = KeyListener()
        let chunk = 2048
        var i = 0
        while i < d.frames {
            let n = min(chunk, d.frames - i)
            k.process((0..<n).map { (d.l[i + $0] + d.r[i + $0]) * 0.5 }, sr: AudioData.sampleRate, publish: false)
            i += n
        }
        // Flush a phrase that runs to the end of the recording.
        k.process([Float](repeating: 0, count: 8192), sr: AudioData.sampleRate, publish: false)
        guard k.acc.reduce(0, +) > 0 else { return nil }
        let f = fold(k.acc)
        let r = ranked(f.notes)
        if ProcessInfo.processInfo.environment["GI_CHORD_DEBUG"] != nil {
            print(String(format: "tuning %+.0f cents: ", f.tuning * 100) + r.prefix(5).map { "\($0.key.name) \(String(format: "%.3f", $0.score))" }.joined(separator: ", "))
        }
        return r[0].key
    }
}
