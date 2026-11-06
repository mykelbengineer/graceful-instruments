import AVFoundation
import Accelerate

/// One stem as the audio thread sees it.
final class RStem {
    let data: AudioData
    var gain: Float
    var cue: Bool
    init(data: AudioData, gain: Float, cue: Bool) { self.data = data; self.gain = gain; self.cue = cue }
}

/// Timeline cue markers, frozen for the audio thread.
final class RMarkers {
    let count: Int
    let pos: UnsafeMutablePointer<Double>
    let cue: UnsafeMutablePointer<Int32>
    init(_ items: [(Double, Int32)]) {
        count = items.count
        pos = .allocate(capacity: max(count, 1))
        cue = .allocate(capacity: max(count, 1))
        for (i, it) in items.enumerated() { pos[i] = it.0; cue[i] = it.1 }
    }
    deinit { pos.deallocate(); cue.deallocate() }
}

/// Metronome voices. Each has an accent (beat one), a beat and a quieter subdivision sound.
enum ClickSound: String, CaseIterable, Identifiable, Codable {
    case classic, woodblock, cowbell, stick, hihat, kickHat, beep
    var id: String { rawValue }
    var label: String {
        switch self {
        case .classic: return "Classic"
        case .woodblock: return "Woodblock"
        case .cowbell: return "Cowbell"
        case .stick: return "Stick"
        case .hihat: return "Hi-hat"
        case .kickHat: return "Kick & hat"
        case .beep: return "Beep"
        }
    }
}

/// Which side of the headphone jack a sound goes to.
enum Route: String, CaseIterable, Identifiable, Codable {
    case left, both, right
    var id: String { rawValue }
    var label: String {
        switch self {
        case .left: return "Left"
        case .both: return "Both"
        case .right: return "Right"
        }
    }
    var gains: (Float, Float) {
        switch self {
        case .left: return (1, 0)
        case .both: return (1, 1)
        case .right: return (0, 1)
        }
    }
    var pan: Float {
        switch self {
        case .left: return -1
        case .both: return 0
        case .right: return 1
        }
    }
}

/// Everything the audio thread reads. Plain stored properties, written from the main thread.
/// Word-sized reads/writes are effectively atomic on Intel and Apple Silicon, which is enough here.
final class RenderState {
    static let sr = AudioData.sampleRate
    static let xfade = 441 // 10 ms loop crossfade

    var stems: [RStem] = []
    var markers = RMarkers([])
    var length: Double = 0

    var playing = false
    var finished = false
    var posH: Double = 0, posC: Double = 0
    var holdH: Double = 0, holdC: Double = 0
    var clickPos: Double = 0
    var countInStart: Double = 0, countInEnd: Double = -1

    var loopOn = false
    // Each player keeps its own loop bounds so a "switch at the next bar" lands in the same musical
    // place for the music (which reads ahead) and the click (which lags behind it).
    var lsH: Double = 0, leH: Double = 0, lsC: Double = 0, leC: Double = 0, lsK: Double = 0, leK: Double = 0
    var jumpGen = 0, genH = 0, genC = 0, genK = 0
    var jumpAt: Double = 0, jumpTo: Double = 0, jumpLS: Double = 0, jumpLE: Double = 0
    var jumpPending: Bool { min(genH, genC, genK) < jumpGen }
    var rate: Double = 1
    var monoHouse = true

    var fadeGain: Float = 1
    var fadeStep: Float = 0

    var clickOn = false
    // Per-sound routing (left/right gain) for metronome click, count-in and spoken cues.
    var clickL: Float = 1, clickR: Float = 0
    var countL: Float = 1, countR: Float = 0
    var cueL: Float = 1, cueR: Float = 0
    var clickIsCount = false
    var clickSets: [[AudioData]] = []
    var clickSet = 0
    var accentOn = true
    var compound = false
    var voiceIsCount = false
    var clickVol: Float = 0.8
    var cueVol: Float = 1
    var bpm: Double = 0
    var offset: Double = 0 // first downbeat, in source samples
    var beatsPerBar = 4
    var clicksPerBeat = 1
    var countVoice = true
    var markerLead: Double = 0 // source samples

    var voices: [AudioData] = []
    var curVoice = -1, voicePos = 0
    var pendingCue = -1
    var curClick = -1, clickIdx = 0

    // MARK: music (house or in-ear stems), source domain
    @inline(__always)
    private func mix(_ stems: [RStem], cue: Bool, _ idx: Int, _ l: inout Float, _ r: inout Float) {
        for s in stems where s.cue == cue && s.gain > 0 && idx >= 0 && idx < s.data.frames {
            l += s.data.l[idx] * s.gain
            r += s.data.r[idx] * s.gain
        }
    }

    func renderMusic(cue: Bool, n: Int, outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>) {
        guard playing else {
            outL.initialize(repeating: 0, count: n); outR.initialize(repeating: 0, count: n); return
        }
        let stems = self.stems
        var pos = cue ? posC : posH
        var hold = cue ? holdC : holdH
        var ls = cue ? lsC : lsH, le = cue ? leC : leH
        var gen = cue ? genC : genH
        let len = length
        let xf = Double(RenderState.xfade)
        var loop = loopOn && le - ls > xf * 2
        var canXf = ls >= xf
        let g = fadeGain
        let mono = cue || monoHouse
        for i in 0..<n {
            if hold > 0 {
                hold -= 1; outL[i] = 0; outR[i] = 0; continue
            }
            if gen < jumpGen && pos >= jumpAt {
                pos = jumpTo + (pos - jumpAt)
                ls = jumpLS; le = jumpLE; gen = jumpGen
                loop = loopOn && le - ls > xf * 2
                canXf = ls >= xf
            }
            if loop && pos >= le { pos = ls + (pos - le) }
            var l: Float = 0, r: Float = 0
            let idx = Int(pos)
            if !loop && pos >= len {
                outL[i] = 0; outR[i] = 0; continue
            }
            mix(stems, cue: cue, idx, &l, &r)
            if loop && canXf && pos >= le - xf {
                let into = pos - (le - xf)
                let t = Float(into / xf)
                var l2: Float = 0, r2: Float = 0
                mix(stems, cue: cue, Int(ls - xf + into), &l2, &r2)
                l = l * (1 - t) + l2 * t
                r = r * (1 - t) + r2 * t
            }
            if mono { let m = (l + r) * 0.5; l = m; r = m }
            outL[i] = l * g; outR[i] = r * g
            pos += 1
        }
        if cue { posC = pos; holdC = hold; lsC = ls; leC = le; genC = gen }
        else { posH = pos; holdH = hold; lsH = ls; leH = le; genH = gen }
    }

    // MARK: click + spoken cues, output domain
    private func startVoice(_ i: Int, count: Bool = false) {
        guard i >= 0 && i < voices.count else { return }
        curVoice = i; voicePos = 0; voiceIsCount = count
    }

    func renderClick(n: Int, outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>) {
        let tickLen = bpm > 0 ? 60 * RenderState.sr / bpm / Double(clicksPerBeat) : 0
        let countsPerBar = beatsPerBar * clicksPerBeat
        var loop = loopOn && leK - lsK > Double(RenderState.xfade * 2)
        for i in 0..<n {
            var oClick: Float = 0, oCount: Float = 0, oCue: Float = 0
            if playing {
                let prev = clickPos
                var cur = prev + rate
                var wrapped = false
                if genK < jumpGen && cur >= jumpAt {
                    cur = jumpTo + (cur - jumpAt); wrapped = true
                    lsK = jumpLS; leK = jumpLE; genK = jumpGen
                    loop = loopOn && leK - lsK > Double(RenderState.xfade * 2)
                } else if loop && cur >= leK && prev >= countInEnd {
                    cur = lsK + (cur - leK); wrapped = true
                }
                let p0 = wrapped ? cur - rate : prev
                let inCount = cur < countInEnd && cur >= countInStart - 1
                if tickLen > 0 {
                    let kp = floor((p0 - offset) / tickLen)
                    let kc = floor((cur - offset) / tickLen)
                    if kc > kp {
                        let tick = Int(kc)
                        var inBar = tick % countsPerBar
                        if inBar < 0 { inBar += countsPerBar }
                        let onBeat = inBar % clicksPerBeat == 0
                        let type = (inBar == 0 && accentOn) ? 0 : (onBeat ? 1 : 2)
                        if clickOn || inCount { curClick = type; clickIdx = 0; clickIsCount = inCount }
                        if inCount && countVoice {
                            // Slow 6/8 counts every eighth (1-6); otherwise count the main beats only.
                            if compound && countsPerBar <= 8 && tickLen / RenderState.sr >= 0.26 {
                                startVoice(inBar, count: true)
                            } else if onBeat {
                                startVoice(inBar / clicksPerBeat, count: true)
                            }
                        }
                        if pendingCue >= 0 && onBeat { startVoice(pendingCue); pendingCue = -1 }
                    }
                } else if pendingCue >= 0 {
                    startVoice(pendingCue); pendingCue = -1
                }
                let m = markers
                for k in 0..<m.count {
                    let trig = m.pos[k] - markerLead
                    if p0 < trig && cur >= trig { startVoice(Int(m.cue[k])) }
                }
                clickPos = cur
                if fadeStep > 0 {
                    fadeGain -= fadeStep
                    if fadeGain <= 0 { fadeGain = 0; fadeStep = 0; playing = false; finished = true }
                }
                if !loop && cur >= length { playing = false; finished = true }
            } else if pendingCue >= 0 {
                startVoice(pendingCue); pendingCue = -1
            }
            if curClick >= 0 {
                // Bounds checked before reading: the click sound can change while one is sounding.
                let set = clickSets[clickSet]
                if curClick < set.count, clickIdx < set[curClick].frames {
                    let c = set[curClick]
                    let x = c.l[clickIdx] * clickVol
                    if clickIsCount { oCount += x } else { oClick += x }
                    clickIdx += 1
                    if clickIdx >= c.frames { curClick = -1 }
                } else {
                    curClick = -1
                }
            }
            if curVoice >= 0 {
                if curVoice < voices.count, voicePos < voices[curVoice].frames {
                    let v = voices[curVoice]
                    let x = v.l[voicePos] * cueVol
                    if voiceIsCount { oCount += x } else { oCue += x }
                    voicePos += 1
                    if voicePos >= v.frames { curVoice = -1 }
                } else {
                    curVoice = -1
                }
            }
            outL[i] = oClick * clickL + oCount * countL + oCue * cueL
            outR[i] = oClick * clickR + oCount * countR + oCue * cueR
        }
    }
}

/// The audio graph:
///   house stems -> TimePitch -> houseMix -> main mixer (right side in split mode)
///   in-ear stems -> TimePitch -> cueMix -> main mixer (left side in split mode)
///   click + spoken cues ----------------> main mixer (left side in split mode)
final class AudioEngine {
    let engine = AVAudioEngine()
    let st = RenderState()
    private let houseTP = AVAudioUnitTimePitch()
    private let cueTP = AVAudioUnitTimePitch()
    private let houseMix = AVAudioMixerNode()
    private let cueMix = AVAudioMixerNode()
    private var houseSrc: AVAudioSourceNode!
    private var cueSrc: AVAudioSourceNode!
    private var clickSrc: AVAudioSourceNode!
    private var padSrc: AVAudioSourceNode!
    private let padMix = AVAudioMixerNode()
    let pad = PadState()
    private var padKeep: [AudioData] = []
    private var configObserver: NSObjectProtocol?
    private var lastRestart = Date.distantPast
    let offline: Bool

    static let cueKeys: [String] = ["1", "2", "3", "4", "5", "6", "7", "8",
        "intro", "verse", "verse1", "verse2", "prechorus", "chorus", "bridge", "instrumental", "tag", "outro",
        "ending", "turnaround", "build", "down", "break", "allin", "hits", "acapella", "again", "lasttime",
        "keychange", "worship", "hold", "vamp", "drumsonly", "slowdown", "speedup"]
    static let cueLabels: [String: String] = [
        "intro": "Intro", "verse": "Verse", "verse1": "Verse 1", "verse2": "Verse 2", "prechorus": "Pre-Chorus",
        "chorus": "Chorus", "bridge": "Bridge", "instrumental": "Instrumental", "tag": "Tag", "outro": "Outro",
        "ending": "Ending", "turnaround": "Turnaround", "build": "Build", "down": "Bring it down", "break": "Break",
        "allin": "All in", "hits": "Hits", "acapella": "A cappella", "again": "Again", "lasttime": "Last time",
        "keychange": "Key change", "worship": "Worship", "hold": "Hold", "vamp": "Vamp", "drumsonly": "Drums only",
        "slowdown": "Slow down", "speedup": "Speed up"]
    static func cueIndex(_ key: String) -> Int32 { Int32(cueKeys.firstIndex(of: key) ?? -1) }

    init(offline: Bool = false, cueDir: URL? = nil) {
        self.offline = offline
        let stereo = AVAudioFormat(standardFormatWithSampleRate: AudioData.sampleRate, channels: 2)!
        let mono = AVAudioFormat(standardFormatWithSampleRate: AudioData.sampleRate, channels: 1)!
        let s = st

        houseSrc = AVAudioSourceNode(format: stereo) { _, _, frameCount, abl in
            let b = UnsafeMutableAudioBufferListPointer(abl)
            s.renderMusic(cue: false, n: Int(frameCount),
                          outL: b[0].mData!.assumingMemoryBound(to: Float.self),
                          outR: b[1].mData!.assumingMemoryBound(to: Float.self))
            return noErr
        }
        cueSrc = AVAudioSourceNode(format: stereo) { _, _, frameCount, abl in
            let b = UnsafeMutableAudioBufferListPointer(abl)
            s.renderMusic(cue: true, n: Int(frameCount),
                          outL: b[0].mData!.assumingMemoryBound(to: Float.self),
                          outR: b[1].mData!.assumingMemoryBound(to: Float.self))
            return noErr
        }
        clickSrc = AVAudioSourceNode(format: stereo) { _, _, frameCount, abl in
            let b = UnsafeMutableAudioBufferListPointer(abl)
            s.renderClick(n: Int(frameCount),
                          outL: b[0].mData!.assumingMemoryBound(to: Float.self),
                          outR: b[1].mData!.assumingMemoryBound(to: Float.self))
            return noErr
        }

        let ps = pad
        padSrc = AVAudioSourceNode(format: stereo) { _, _, frameCount, abl in
            let b = UnsafeMutableAudioBufferListPointer(abl)
            ps.render(n: Int(frameCount),
                      outL: b[0].mData!.assumingMemoryBound(to: Float.self),
                      outR: b[1].mData!.assumingMemoryBound(to: Float.self))
            return noErr
        }

        st.clickSets = ClickSound.allCases.map { AudioEngine.makeClicks($0) }
        let dir = cueDir ?? Bundle.main.resourceURL?.appendingPathComponent("Cues")
        st.voices = AudioEngine.cueKeys.map { key in
            guard let dir = dir else { return AudioData(frames: 1, stereo: false) }
            return AudioLoader.loadMono(dir.appendingPathComponent("\(key).wav"))
        }

        houseTP.overlap = 12
        cueTP.overlap = 12
        for n in [houseSrc!, cueSrc!, clickSrc!, padSrc!, houseTP, cueTP, houseMix, cueMix, padMix] as [AVAudioNode] { engine.attach(n) }

        if offline {
            try? engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: 4096)
        }
        let main = engine.mainMixerNode
        engine.connect(houseSrc, to: houseTP, format: stereo)
        engine.connect(houseTP, to: houseMix, format: stereo)
        engine.connect(houseMix, to: main, format: stereo)
        engine.connect(cueSrc, to: cueTP, format: stereo)
        engine.connect(cueTP, to: cueMix, format: stereo)
        engine.connect(cueMix, to: main, format: mono)
        engine.connect(clickSrc, to: main, format: stereo)
        engine.connect(padSrc, to: padMix, format: stereo)
        engine.connect(padMix, to: main, format: stereo)
        if !offline {
            engine.connect(main, to: engine.outputNode, format: nil)
        }
        setSplit()
    }

    func start() throws {
        engine.prepare()
        try engine.start()
        guard !offline, configObserver == nil else { return }
        // Plugging in or unplugging an output (HDMI, USB, Bluetooth) or a sample-rate change stops the engine.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: engine, queue: .main) { [weak self] _ in
            self?.restartIfStopped(force: true)
        }
    }

    /// Starts the engine again after the output changed. Playback carries on from where it was.
    /// Returns false while it still can't start (it is retried from the model's timer).
    @discardableResult
    func restartIfStopped(force: Bool = false) -> Bool {
        guard !offline else { return true }
        if engine.isRunning && !force { return true }
        guard force || Date().timeIntervalSince(lastRestart) > 2 else { return false }
        lastRestart = Date()
        let main = engine.mainMixerNode
        engine.disconnectNodeOutput(main)
        engine.connect(main, to: engine.outputNode, format: nil)
        engine.prepare()
        do { try engine.start(); return true } catch { return false }
    }

    /// Keeps something the audio thread may still be reading alive for a few seconds after it is replaced.
    private func retire(_ old: Any) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withExtendedLifetime(old) {} }
    }

    /// TimePitch adds a small delay to the music; the click is delayed by the same amount.
    var latencySamples: Double { houseTP.bypass ? 0 : max(houseTP.latency, 0) * RenderState.sr }

    /// At the original tempo and key the time/pitch processor is switched off, so the audio plays untouched.
    private func updateBypass() {
        let off = st.rate == 1 && houseTP.pitch == 0
        guard off != houseTP.bypass else { return }
        let before = latencySamples
        houseTP.bypass = off
        cueTP.bypass = off
        st.clickPos += (before - latencySamples) * st.rate // keep the click lined up
    }

    // MARK: loading
    func load(stems: [RStem], length: Int) {
        st.playing = false
        let old = st.stems
        st.stems = stems
        retire(old)
        st.length = Double(length)
        st.posH = 0; st.posC = 0; st.clickPos = 0; st.holdH = 0; st.holdC = 0
        st.finished = false
        st.fadeGain = 1; st.fadeStep = 0
    }

    func updateGains(_ gains: [(Float, Bool)]) {
        // Read the array once and change the stems through it: writing st.stems[i] here would copy the array
        // (the audio thread holds a reference) and swap it under the audio thread.
        let cur = st.stems
        for (i, g) in gains.enumerated() where i < cur.count {
            cur[i].gain = g.0
            cur[i].cue = g.1
        }
    }

    func setMarkers(_ items: [(Double, Int32)]) {
        let old = st.markers
        st.markers = RMarkers(items.map { ($0.0 * RenderState.sr, $0.1) })
        retire(old)
    }

    // MARK: transport
    var isPlaying: Bool { st.playing }

    /// Current musical position in seconds (what you hear, not what has been read ahead).
    var position: Double {
        var p = st.posH
        if st.holdH <= 0 { p -= latencySamples * st.rate }
        return max(0, min(p, st.length)) / RenderState.sr
    }

    func play(from seconds: Double, countInBars: Int) {
        var start = max(0, seconds * RenderState.sr)
        st.finished = false
        st.fadeGain = 1; st.fadeStep = 0
        var countLen: Double = 0
        if countInBars > 0 && st.bpm > 0 {
            let beat = 60 * RenderState.sr / st.bpm
            let bar = beat * Double(st.beatsPerBar)
            // Start from the top of the bar we are in, so the count lands on beat one.
            let barStart = st.offset + floor((start - st.offset) / bar) * bar
            if start - barStart < beat * 0.5 {
                start = max(0, barStart)
            } else if barStart + bar - start < beat * 0.5 {
                start = barStart + bar
            }
            countLen = bar * Double(countInBars)
        }
        let lat = latencySamples * st.rate
        cancelJump()
        st.posH = start; st.posC = start
        st.holdH = countLen; st.holdC = countLen
        st.countInEnd = countLen > 0 ? start : -1
        st.countInStart = start - countLen
        st.clickPos = start - countLen - lat
        st.playing = true
    }

    func pause() { st.playing = false }

    /// While playing, moves to a new loop region at the next bar line (or at the end of the current loop).
    /// Returns false when it can't be timed musically; the caller then just seeks.
    func queueLoopJump(start: Double, end: Double) -> Bool {
        guard st.playing, st.bpm > 0, st.holdH <= 0 else { return false }
        let sr = RenderState.sr
        if !st.loopOn {
            // Not looping yet: make sure stale bounds can't wrap anything before the switch.
            st.lsH = 0; st.leH = st.length; st.lsC = 0; st.leC = st.length; st.lsK = 0; st.leK = st.length
        }
        let bar = 60 * sr / st.bpm * Double(st.beatsPerBar)
        let lead = latencySamples * st.rate + 4096
        var at = st.offset + ceil((st.posH + lead - st.offset) / bar) * bar
        if st.loopOn && st.leH > st.posH && at > st.leH { at = st.leH }
        st.jumpAt = at
        st.jumpTo = start * sr
        st.jumpLS = start * sr
        st.jumpLE = end * sr
        st.jumpGen += 1
        return true
    }

    private func cancelJump() { st.genH = st.jumpGen; st.genC = st.jumpGen; st.genK = st.jumpGen }

    func seek(to seconds: Double) {
        let p = max(0, min(seconds * RenderState.sr, st.length))
        let lat = latencySamples * st.rate
        cancelJump()
        st.holdH = 0; st.holdC = 0; st.countInEnd = -1
        st.posH = p; st.posC = p; st.clickPos = p - lat
        st.finished = false
    }

    func fadeOut(seconds: Double) {
        guard st.playing else { return }
        st.fadeStep = Float(1.0 / max(0.1, seconds) / RenderState.sr)
    }

    func cue(_ key: String) {
        let i = Int(AudioEngine.cueIndex(key))
        if i >= 0 { st.pendingCue = i }
    }

    // MARK: settings
    func setRate(_ r: Double) {
        let r = min(max(r, 0.25), 2.0)
        houseTP.rate = Float(r); cueTP.rate = Float(r)
        st.rate = r
        updateBypass()
    }

    func setOverlap(_ o: Float) { houseTP.overlap = o; cueTP.overlap = o }

    func setSemitones(_ s: Int) {
        houseTP.pitch = Float(s * 100); cueTP.pitch = Float(s * 100)
        updateBypass()
    }

    func setLoop(on: Bool, start: Double, end: Double) {
        let a = start * RenderState.sr, b = end * RenderState.sr
        st.loopOn = on && end > start
        // Leave the bounds alone if a bar-line switch to this same region is still on its way.
        if st.jumpPending && abs(a - st.jumpLS) < 1 && abs(b - st.jumpLE) < 1 { return }
        st.lsH = a; st.leH = b; st.lsC = a; st.leC = b; st.lsK = a; st.leK = b
    }

    /// `subdivision` (1 = beats, 2 = eighths, 3 = triplets, 4 = sixteenths) applies to 4/4 and 3/4; 6/8 and 12/8 always click eighths.
    func setGrid(bpm: Double?, offset: Double, timeSig: TimeSig, subdivision: Int = 1) {
        st.bpm = bpm ?? 0
        st.offset = offset * RenderState.sr
        st.beatsPerBar = timeSig.beatsPerBar
        st.compound = timeSig.compound
        st.clicksPerBeat = timeSig.compound ? timeSig.clicksPerBeat : max(1, subdivision)
    }

    func setClickSound(_ s: ClickSound, accent: Bool) {
        st.clickSet = ClickSound.allCases.firstIndex(of: s) ?? 0
        st.accentOn = accent
    }

    func setMarkerLead(bars: Double) {
        if st.bpm > 0 {
            st.markerLead = bars * Double(st.beatsPerBar) * 60 * RenderState.sr / st.bpm
        } else {
            st.markerLead = 2 * RenderState.sr
        }
    }

    /// Routes each sound to the left side, the right side or both.
    func setRoutes(music: Route, click: Route, count: Route, cues: Route, stems: Route) {
        st.monoHouse = music != .both
        houseMix.pan = music.pan
        cueMix.pan = stems.pan
        clickSrc.pan = 0
        (st.clickL, st.clickR) = click.gains
        (st.countL, st.countR) = count.gains
        (st.cueL, st.cueR) = cues.gains
    }

    /// The church setup: music to the house on the right, everything for the band on the left.
    func setSplit() { setRoutes(music: .right, click: .left, count: .left, cues: .left, stems: .left) }
    func setAllBoth() { setRoutes(music: .both, click: .both, count: .both, cues: .both, stems: .both) }

    func setVolumes(music: Float, inEars: Float, click: Float, cues: Float) {
        houseMix.outputVolume = music
        cueMix.outputVolume = inEars
        st.clickVol = click
        st.cueVol = cues
    }

    // MARK: pad
    /// Starts (or crossfades to) a pad loop.
    func padPlay(_ d: AudioData, fadeIn: Double) {
        padKeep.append(d)
        if padKeep.count > 4 { padKeep.removeFirst() } // freed here, never on the audio thread
        pad.rampStep = Float(1 / (max(0.05, fadeIn) * RenderState.sr))
        pad.incoming = d
        pad.incomingGen += 1
        pad.target = 1
    }

    func padStop(fadeOut: Double) {
        pad.rampStep = Float(1 / (max(0.05, fadeOut) * RenderState.sr))
        pad.target = 0
    }

    func setPad(volume: Float, route: Route) {
        padMix.outputVolume = volume
        padMix.pan = route.pan
        pad.mono = route != .both
    }

    // MARK: click sounds
    static func makeClicks(_ sound: ClickSound) -> [AudioData] {
        let sr = RenderState.sr
        func mono(_ x: [Float], _ gain: Float) -> AudioData {
            let d = AudioData(frames: x.count, stereo: false)
            var peak: Float = 0
            for v in x { peak = max(peak, abs(v)) }
            let g = peak > 0 ? gain / peak : 0
            for i in 0..<x.count { d.l[i] = x[i] * g }
            return d
        }
        func synth(_ ms: Double, _ f: (Double) -> Double) -> [Float] {
            let n = Int(ms / 1000 * sr)
            return (0..<n).map { Float(f(Double($0) / sr)) }
        }
        func tone(_ freq: Double, _ ms: Double) -> [Float] {
            synth(ms) { t in (sin(2 * .pi * freq * t) * 0.8 + sin(2 * .pi * freq * 2.01 * t) * 0.2) * exp(-t * 1000 / (ms / 4.5)) }
        }
        func wood(_ freq: Double) -> [Float] {
            synth(70) { t in (sin(2 * .pi * freq * t) + 0.5 * sin(2 * .pi * freq * 2.7 * t)) * exp(-t * 85) }
        }
        func bell(_ freq: Double) -> [Float] {
            synth(220) { t in
                let sq = { (f: Double) in sin(2 * .pi * f * t) > 0 ? 1.0 : -1.0 }
                return (sq(freq) + sq(freq * 1.48)) * 0.5 * exp(-t * 14)
            }
        }
        func beep(_ freq: Double) -> [Float] {
            synth(45) { t in (sin(2 * .pi * freq * t) > 0 ? 1.0 : -1.0) * (t < 0.04 ? 1 : 0) * min(1, (0.045 - t) * 400) }
        }
        switch sound {
        case .classic: return [mono(tone(1760, 60), 0.9), mono(tone(1180, 50), 0.7), mono(tone(880, 35), 0.35)]
        case .woodblock: return [mono(wood(1250), 0.9), mono(wood(880), 0.7), mono(wood(700), 0.35)]
        case .cowbell: return [mono(bell(800), 0.85), mono(bell(560), 0.65), mono(bell(560), 0.3)]
        case .stick:
            let rim = DrumSynth.sound(.rim)
            return [mono(rim, 1.0), mono(rim, 0.7), mono(rim, 0.35)]
        case .hihat:
            return [mono(DrumSynth.sound(.openHat), 0.8), mono(DrumSynth.sound(.hat), 0.7), mono(DrumSynth.sound(.hat), 0.35)]
        case .kickHat:
            return [mono(DrumSynth.sound(.kick), 1.0), mono(DrumSynth.sound(.hat), 0.7), mono(DrumSynth.sound(.shaker), 0.35)]
        case .beep: return [mono(beep(1500), 0.6), mono(beep(1000), 0.5), mono(beep(800), 0.25)]
        }
    }
}
