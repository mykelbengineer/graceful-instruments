import Foundation
import AVFoundation

/// `GracefulInstruments --selftest` renders the audio graph offline and checks routing, sync and tempo detection.
/// `GracefulInstruments --analyze file...` prints the tempo found for real files.
enum SelfTest {
    static var failures = 0

    static func check(_ ok: Bool, _ msg: String) {
        print((ok ? "PASS  " : "FAIL  ") + msg)
        if !ok { failures += 1 }
    }

    static func render(_ e: AudioEngine, seconds: Double) -> (l: [Float], r: [Float]) {
        let fmt = e.engine.manualRenderingFormat
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4096)!
        var l: [Float] = [], r: [Float] = []
        let total = Int(seconds * fmt.sampleRate)
        while l.count < total {
            let n = AVAudioFrameCount(min(4096, total - l.count))
            guard (try? e.engine.renderOffline(n, to: buf)) == .success else { break }
            let c = buf.floatChannelData!
            l.append(contentsOf: UnsafeBufferPointer(start: c[0], count: Int(buf.frameLength)))
            r.append(contentsOf: UnsafeBufferPointer(start: c[1], count: Int(buf.frameLength)))
        }
        return (l, r)
    }

    static func rms(_ x: ArraySlice<Float>) -> Float {
        guard !x.isEmpty else { return 0 }
        return sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(x.count))
    }

    static func tone(seconds: Double, freq: Double) -> AudioData {
        let n = Int(seconds * AudioData.sampleRate)
        let d = AudioData(frames: n)
        for i in 0..<n { let v = Float(sin(2 * .pi * freq * Double(i) / AudioData.sampleRate) * 0.5); d.l[i] = v; d.r[i] = v }
        return d
    }

    /// Short noise bursts on every beat, like a click track.
    static func pulses(seconds: Double, bpm: Double, offset: Double = 0) -> AudioData {
        let n = Int(seconds * AudioData.sampleRate)
        let d = AudioData(frames: n)
        let beat = 60 / bpm * AudioData.sampleRate
        var t = offset * AudioData.sampleRate
        var seed: UInt32 = 1
        while Int(t) < n {
            for k in 0..<400 where Int(t) + k < n {
                seed = seed &* 1664525 &+ 1013904223
                let v = (Float(seed >> 8) / Float(1 << 24) - 0.5) * exp(-Float(k) / 80)
                d.l[Int(t) + k] = v; d.r[Int(t) + k] = v
            }
            t += beat
        }
        return d
    }

    static func onsets(_ x: [Float], threshold: Float) -> [Int] {
        var out: [Int] = []
        var last = -100000
        for i in 0..<x.count where abs(x[i]) > threshold && i - last > 2000 {
            out.append(i); last = i
        }
        return out
    }

    static func cueDir() -> URL? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidates = [exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Cues"),
                          URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Cues")]
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("1.wav").path) }
    }

    static func makeEngine() -> AudioEngine {
        let e = AudioEngine(offline: true, cueDir: cueDir())
        try! e.start()
        e.setVolumes(music: 1, inEars: 1, click: 1, cues: 1)
        return e
    }

    static func run() {
        print("Graceful Instruments self-test")
        print("cue clips: \(cueDir()?.path ?? "NOT FOUND")")

        // 1. Split routing: music only on the right, click only on the left.
        do {
            let e = makeEngine()
            e.load(stems: [RStem(data: tone(seconds: 4, freq: 440), gain: 1, cue: false)], length: 4 * 44100)
            e.setGrid(bpm: 120, offset: 0, timeSig: .fourFour)
            e.setSplit()
            e.st.clickOn = false
            e.play(from: 0, countInBars: 0)
            let (l, r) = render(e, seconds: 1.5)
            let lr = rms(l[22050...]), rr = rms(r[22050...])
            check(lr < 0.001 && rr > 0.1, String(format: "split mode, music only: left %.4f, right %.4f", lr, rr))

            let e2 = makeEngine()
            e2.load(stems: [RStem(data: tone(seconds: 4, freq: 440), gain: 0, cue: false)], length: 4 * 44100)
            e2.setGrid(bpm: 120, offset: 0, timeSig: .fourFour)
            e2.setSplit()
            e2.st.clickOn = true
            e2.play(from: 0, countInBars: 0)
            let (l2, r2) = render(e2, seconds: 2)
            let a = rms(l2[...]), b = rms(r2[...])
            check(a > 0.01 && b < 0.0005, String(format: "split mode, click only: left %.4f, right %.5f", a, b))

            let e3 = makeEngine()
            e3.load(stems: [RStem(data: tone(seconds: 4, freq: 440), gain: 1, cue: false)], length: 4 * 44100)
            e3.setAllBoth()
            e3.play(from: 0, countInBars: 0)
            let (l3, r3) = render(e3, seconds: 1.5)
            let c = rms(l3[22050...]), d = rms(r3[22050...])
            check(c > 0.1 && d > 0.1 && abs(c - d) < 0.02, String(format: "stereo mode: left %.3f, right %.3f", c, d))

            let e4 = makeEngine()
            e4.load(stems: [RStem(data: tone(seconds: 4, freq: 440), gain: 1, cue: true)], length: 4 * 44100)
            e4.setSplit()
            e4.play(from: 0, countInBars: 0)
            let (l4, r4) = render(e4, seconds: 1.5)
            let f = rms(l4[22050...]), g = rms(r4[22050...])
            check(f > 0.1 && g < 0.001, String(format: "in-ear-only stem goes left: left %.3f, right %.4f", f, g))
        }

        // 1a. At the original tempo and key the audio comes out bit-for-bit untouched.
        do {
            let e = makeEngine()
            let src = tone(seconds: 4, freq: 440)
            e.load(stems: [RStem(data: src, gain: 1, cue: false)], length: 4 * 44100)
            e.setAllBoth()
            e.setRate(1); e.setSemitones(0)
            e.play(from: 0, countInBars: 0)
            let (l, _) = render(e, seconds: 2)
            var worst: Float = 0
            for i in 10000..<80000 { worst = max(worst, abs(l[i] - src.l[i])) }
            check(worst < 1e-5, String(format: "original tempo and key plays untouched (max difference %.7f)", worst))
        }

        // 1b. Each sound can be sent anywhere: click right, count-in left, music both.
        do {
            let e = makeEngine()
            e.load(stems: [RStem(data: tone(seconds: 10, freq: 220), gain: 0, cue: false)], length: 10 * 44100)
            e.setGrid(bpm: 120, offset: 0, timeSig: .fourFour)
            e.setRoutes(music: .both, click: .right, count: .left, cues: .both, stems: .left)
            e.st.clickOn = true
            e.play(from: 0, countInBars: 1)
            let (l, r) = render(e, seconds: 3.5)
            let countL = rms(l[0..<80000]), countR = rms(r[0..<80000])
            let clickL = rms(l[90000...]), clickR = rms(r[90000...])
            check(countL > 0.01 && countR < 0.0005, String(format: "count-in routed left: left %.4f, right %.5f", countL, countR))
            check(clickR > 0.01 && clickL < 0.0005, String(format: "click routed right: left %.5f, right %.4f", clickL, clickR))
        }

        // 2. Click stays locked to the music at several tempos.
        for rate in [1.0, 0.85, 1.2] {
            let e = makeEngine()
            let bpm = 100.0
            e.load(stems: [RStem(data: pulses(seconds: 20, bpm: bpm, offset: 0.25), gain: 1, cue: false)], length: 20 * 44100)
            e.setGrid(bpm: bpm, offset: 0.25, timeSig: .fourFour)
            e.setSplit()
            e.setRate(rate)
            e.st.clickOn = true
            e.play(from: 2.0, countInBars: 0)
            let (l, r) = render(e, seconds: 8)
            let clicks = onsets(l, threshold: 0.05)
            let music = onsets(r, threshold: 0.05)
            var diffs: [Double] = []
            for m in music.dropFirst(2) {
                if let c = clicks.min(by: { abs($0 - m) < abs($1 - m) }) { diffs.append(Double(c - m) / 44.1) }
            }
            let worst = diffs.map(abs).max() ?? 999
            let mean = diffs.isEmpty ? 999 : diffs.reduce(0, +) / Double(diffs.count)
            check(!diffs.isEmpty && worst < 15, String(format: "click sync at %.0f%% speed: %d beats, mean %+.1f ms, worst %.1f ms", rate * 100, diffs.count, mean, worst))
        }

        // 3. Count-in: one bar of clicks, then the music.
        do {
            let e = makeEngine()
            e.load(stems: [RStem(data: tone(seconds: 10, freq: 220), gain: 1, cue: false)], length: 10 * 44100)
            e.setGrid(bpm: 120, offset: 0, timeSig: .fourFour)
            e.setSplit()
            e.st.clickOn = false
            e.play(from: 0, countInBars: 1)
            let (l, r) = render(e, seconds: 3)
            let musicStart = r.firstIndex { abs($0) > 0.05 } ?? -1
            let clicks = onsets(l, threshold: 0.05)
            check(abs(Double(musicStart) / 44100 - 2.0) < 0.06, String(format: "count-in: music starts at %.3f s (want 2.000)", Double(musicStart) / 44100))
            check(clicks.count >= 4, "count-in: \(clicks.count) count clicks/voices on the left")
        }

        // 4. Loop wraps cleanly.
        do {
            let e = makeEngine()
            e.load(stems: [RStem(data: tone(seconds: 6, freq: 330), gain: 1, cue: false)], length: 6 * 44100)
            e.setLoop(on: true, start: 1, end: 2)
            e.setAllBoth()
            e.play(from: 1, countInBars: 0)
            _ = render(e, seconds: 3.5)
            let p = e.st.posH / 44100
            check(p >= 1 && p <= 2, String(format: "loop: position %.2f s stays inside 1-2 s after 3.5 s", p))
        }

        // 5. Grooves render, and the tempo finder agrees with them.
        for style in GrooveStyle.all {
            let d = DrumSynth.render(style, bpm: style.defaultBPM, bars: 16)
            var peak: Float = 0
            for i in 0..<d.frames { peak = max(peak, abs(d.l[i])) }
            let r = TempoDetector.detect(d, timeSig: style.timeSig)
            let found = r?.bpm ?? 0
            let ratio = found / style.defaultBPM
            let ok = [0.5, 1.0, 2.0, 1.5, 0.6667, 3.0, 0.3333, 1.3333, 0.75].contains { abs(ratio - $0) < 0.02 }
            check(peak > 0.1 && peak <= 1.0 && ok, String(format: "groove %@: peak %.2f, tempo found %.1f (made at %.0f)%@",
                                                         style.name, peak, found, style.defaultBPM, abs(ratio - 1) < 0.02 ? "" : " [multiple]"))
        }

        // 6. Tempo from clicks with an offset.
        if CommandLine.arguments.contains("--calibrate") {
            for (bpm, o) in [(73.0, 0.4), (120.0, 0.1), (92.0, 0.33), (138.0, 0.05), (66.0, 0.7)] {
                let r = TempoDetector.detect(pulses(seconds: 40, bpm: bpm, offset: o), timeSig: .fourFour)!
                let beat = 60 / bpm
                var e = r.offset.truncatingRemainder(dividingBy: beat) - o
                while e > beat / 2 { e -= beat }; while e < -beat / 2 { e += beat }
                print(String(format: "calib %.0f BPM: found %.3f, offset error %+.1f ms", bpm, r.bpm, e * 1000))
            }
        }
        do {
            let d = pulses(seconds: 30, bpm: 73, offset: 0.4)
            let r = TempoDetector.detect(d, timeSig: .fourFour)
            check(abs((r?.bpm ?? 0) - 73) < 0.5, String(format: "tempo of 73 BPM pulses: %.2f", r?.bpm ?? 0))
            let beat = 60 / 73.0
            let off = (r?.offset ?? 0).truncatingRemainder(dividingBy: beat)
            var signed = off - 0.4
            if signed > beat / 2 { signed -= beat }
            if signed < -beat / 2 { signed += beat }
            check(abs(signed) < 0.012, String(format: "beat position error %+.0f ms", signed * 1000))
        }

        // 6b. Stand-alone metronome: no track, eighths at 120 BPM = 4 clicks a second.
        do {
            let e = makeEngine()
            e.load(stems: [], length: 3600 * 44100)
            e.setGrid(bpm: 120, offset: 0, timeSig: .fourFour, subdivision: 2)
            e.setAllBoth()
            e.st.clickOn = true
            e.play(from: 0, countInBars: 0)
            let (l, _) = render(e, seconds: 3)
            let n = onsets(l, threshold: 0.02).count
            check(n >= 11 && n <= 13, "metronome alone, 120 BPM eighths: \(n) clicks in 3 s (want 12)")
        }
        for snd in ClickSound.allCases {
            let set = AudioEngine.makeClicks(snd)
            let peaks = set.map { d -> Float in var m: Float = 0; for i in 0..<d.frames { m = max(m, abs(d.l[i])) }; return m }
            check(set.count == 3 && peaks.allSatisfy { $0 > 0.1 && $0 <= 1.0 },
                  "click sound \(snd.label): accent/beat/sub peaks \(peaks.map { String(format: "%.2f", $0) })")
        }

        // 6c. Library file compatibility and per-service settings.
        do {
            let id = UUID()
            let old = #"{"id":"\#(UUID().uuidString)","name":"Old list","items":["\#(id.uuidString)"]}"#
            let sl = try? JSONDecoder().decode(Setlist.self, from: Data(old.utf8))
            check(sl?.sections.count == 1 && sl?.allEntries.first?.itemID == id, "old setlist format reads into one section")

            var item = LibraryItem(title: "Loop", kind: .song)
            item.bpm = 70; item.rate = 1; item.semitones = 0
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            var json = try! JSONSerialization.jsonObject(with: enc.encode(item)) as! [String: Any]
            json.removeValue(forKey: "category")
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            let back = try? dec.decode(LibraryItem.self, from: JSONSerialization.data(withJSONObject: json))
            check(back != nil && back?.category == nil, "library items saved before categories still load")

            var entry = SetEntry(itemID: item.id)
            entry.rate = 72.0 / 70.0; entry.semitones = -2
            let applied = entry.apply(to: item)
            check(abs((applied.playingBPM ?? 0) - 72) < 0.01 && applied.semitones == -2 && item.rate == 1,
                  "service entry plays at 72 BPM, key -2, library item unchanged")
            let svc = Setlist(name: "Sunday", date: Date())
            check(svc.sections.map(\.name) == Setlist.defaultSections, "new service has Worship, Praise, Ministration, Thanksgiving")
        }

        // 6d. Pattern finder, lengthening and switching portions on the bar line.
        do {
            let style = GrooveStyle.find("worship44")!
            let bpm = style.defaultBPM
            func concat(_ parts: [AudioData]) -> AudioData {
                let out = AudioData(frames: parts.reduce(0) { $0 + $1.frames })
                var p = 0
                for d in parts { (out.l + p).update(from: d.l, count: d.frames); (out.r + p).update(from: d.r, count: d.frames); p += d.frames }
                return out
            }
            // Fill every 4th bar -> 4-bar pattern.
            let four = DrumSynth.render(style, bpm: bpm, bars: 4)
            let song4 = concat(Array(repeating: four, count: 6))
            let p4 = LoopTools.findPattern(song4, bpm: bpm, offset: 0, timeSig: .fourFour)
            check(p4?.bars == 4, "pattern finder: groove with a fill every 4 bars -> \(p4?.bars ?? 0) bars (\(Int((p4?.score ?? 0) * 100))% alike)")
            // Same bar every time -> 1-bar pattern.
            let one = DrumSynth.render(style, bpm: bpm, bars: 1)
            let song1 = concat(Array(repeating: one, count: 12))
            let p1 = LoopTools.findPattern(song1, bpm: bpm, offset: 0, timeSig: .fourFour)
            check(p1?.bars == 1, "pattern finder: identical bars -> \(p1?.bars ?? 0) bar")
            // 4-chord progression over a 1-bar drum groove -> 4 bars (chords count, not just drums).
            let chords: [[Double]] = [[261.6, 329.6, 392.0], [220.0, 261.6, 329.6], [174.6, 220.0, 261.6], [196.0, 246.9, 293.7]]
            let barFrames = one.frames
            let prog = AudioData(frames: barFrames * 12)
            for b in 0..<12 {
                for i in 0..<barFrames {
                    let t = Double(i) / 44100
                    var v = 0.0
                    for f in chords[b % 4] { v += sin(2 * .pi * f * t) }
                    let k = b * barFrames + i
                    prog.l[k] = one.l[i] * 0.6 + Float(v * 0.08); prog.r[k] = one.r[i] * 0.6 + Float(v * 0.08)
                }
            }
            let pc = LoopTools.findPattern(prog, bpm: bpm, offset: 0, timeSig: .fourFour)
            check(pc?.bars == 4, "pattern finder: 4 chords over a 1-bar beat -> \(pc?.bars ?? 0) bars")

            let a = 2 * four.frames, b = 3 * four.frames
            let longer = LoopTools.extend(song4, loopStart: a, loopEnd: b, copies: 3)
            let tailSame = (0..<1000).allSatisfy { longer.l[longer.frames - 1 - $0] == song4.l[song4.frames - 1 - $0] }
            check(longer.frames == song4.frames + 3 * (b - a) && tailSame, "lengthen: +3 copies of 4 bars, rest of the song unchanged")

            let e = makeEngine()
            let bar = 60.0 / 120 * 4
            e.load(stems: [RStem(data: tone(seconds: 30, freq: 200), gain: 1, cue: false)], length: 30 * 44100)
            e.setGrid(bpm: 120, offset: 0, timeSig: .fourFour)
            e.setLoop(on: true, start: 0, end: bar)
            e.play(from: 0, countInBars: 0)
            _ = render(e, seconds: 0.5)
            let queued = e.queueLoopJump(start: 4 * bar, end: 5 * bar)
            e.setLoop(on: true, start: 4 * bar, end: 5 * bar)
            _ = render(e, seconds: 1.0)
            let before = e.st.posH / 44100
            _ = render(e, seconds: 2.0)
            let after = e.st.posH / 44100, click = e.st.clickPos / 44100
            check(queued && before < bar && after >= 4 * bar && after < 5 * bar && click >= 4 * bar && click < 5 * bar,
                  String(format: "portion switch waits for the bar line: %.2f s before, then %.2f s (click %.2f s), inside 8-10 s", before, after, click))
        }

        // 7. Title hints.
        let h1 = TempoDetector.hints(fromTitle: "AFRICAN PRAISE LOOP 2 _ Very Fast (TEMPO_BPM 138) with download link [uOwUJHwiuc8]")
        harmonyTests()
        stabilityTests()
        check(h1.bpm == 138, "title hint TEMPO_BPM 138 -> \(h1.bpm.map { String($0) } ?? "nil")")
        let h2 = TempoDetector.hints(fromTitle: "6-8 PERCUSSIVE WORSHIP LOOP 78 BPM")
        check(h2.bpm == 78 && h2.timeSig == .sixEight, "title hint 6-8 78 BPM -> \(String(describing: h2))")
        let h3 = TempoDetector.hints(fromTitle: "3 4  WORSHIP LOOP (80BPM)")
        check(h3.bpm == 80 && h3.timeSig == .threeFour, "title hint 3 4 80BPM -> \(String(describing: h3))")
        check(TitleCleaner.clean("onlymp3.to - Ariaria Drum Loops  Praise-oA7AC3EmfP8-192k-1659939301563") == "Ariaria Drum Loops Praise",
              "title cleanup -> \(TitleCleaner.clean("onlymp3.to - Ariaria Drum Loops  Praise-oA7AC3EmfP8-192k-1659939301563"))")

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    /// Renders 60 s offline with different settings and reports the speed versus real time.
    /// Piano-ish chords with a bass line and a little noise, for testing chord and key detection.
    static func progression(_ chords: [(root: Int, minor: Bool, bass: Int?)], bpm: Double, barsEach: Int, repeats: Int, tuneCents: Double = 0) -> AudioData {
        let sr = AudioData.sampleRate
        let bar = 60 / bpm * 4
        let total = Double(chords.count * barsEach * repeats) * bar
        let d = AudioData(frames: Int(total * sr) + 1)
        func add(_ midi: Double, at t0: Double, dur: Double, gain: Float, harmonics: Int) {
            let f0 = 440 * pow(2, (midi - 69 + tuneCents / 100) / 12)
            let a = Int(t0 * sr), n = Int(dur * sr)
            for i in 0..<n where a + i < d.frames {
                let t = Double(i) / sr
                var v = 0.0
                for h in 1...harmonics { v += sin(2 * .pi * f0 * Double(h) * t) / Double(h * h) }
                let env = Float(min(1, t * 200) * exp(-t * 1.2) * min(1, (dur - t) * 50))
                d.l[a + i] += Float(v) * env * gain
            }
        }
        var t = 0.0
        for _ in 0..<repeats {
            for c in chords {
                for _ in 0..<barsEach {
                    let third = c.minor ? 3 : 4
                    for beat in [0.0, 2.0] {
                        let at = t + beat * bar / 4
                        for iv in [0, third, 7, 12] { add(Double(60 + Notes.wrap(c.root - 0) + iv - (c.root > 6 ? 12 : 0)), at: at, dur: bar / 2, gain: 0.12, harmonics: 6) }
                        add(Double(36 + Notes.wrap(c.bass ?? c.root)), at: at, dur: bar / 2, gain: 0.25, harmonics: 3)
                    }
                    t += bar
                }
            }
        }
        var seed: UInt32 = 7
        for i in 0..<d.frames {
            seed = seed &* 1664525 &+ 1013904223
            d.l[i] += (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.01
            d.r[i] = d.l[i]
        }
        return d
    }

    static func harmonyTests() {
        // I V vi IV in Ab at 80 BPM, 2 bars each.
        let ab = progression([(8, false, nil), (3, false, nil), (5, true, nil), (1, false, nil)], bpm: 80, barsEach: 2, repeats: 3)
        let t0 = Date()
        let chart = Harmony.analyze(ab, bpm: 80, offset: 0, beatsPerBar: 4)
        let dt = Date().timeIntervalSince(t0)
        let names = (chart?.segs ?? []).filter { $0.end - $0.start > 1 }.map { $0.symbol(transpose: 0, flats: true, simple: false) }
        check(chart?.key == MusicKey(tonic: 8, minor: false), "key of I-V-vi-IV in Ab: \(chart?.key.longName ?? "none")")
        check(Array(names.prefix(4)) == ["Ab", "Eb", "Fm", "Db"], "chords: \(names.prefix(8).joined(separator: " ")) (\(String(format: "%.1f", dt)) s for \(Int(ab.duration)) s)")
        let nums = (chart?.segs ?? []).filter { $0.end - $0.start > 1 }.prefix(4).map { $0.number(in: chart!.key, simple: false) }
        check(nums == ["1", "5", "6m", "4"], "numbers: \(nums.joined(separator: " "))")
        let up = (chart?.segs ?? []).first.map { $0.symbol(transpose: 1, flats: false, simple: false) }
        check(up == "A", "Ab up a semitone shows \(up ?? "nil")")

        // G D/F# Em C, recorded a little sharp.
        let g = progression([(7, false, nil), (2, false, 6), (4, true, nil), (0, false, nil)], bpm: 72, barsEach: 2, repeats: 3, tuneCents: 30)
        let c2 = Harmony.analyze(g, bpm: 72, offset: 0, beatsPerBar: 4)
        let n2 = (c2?.segs ?? []).filter { $0.end - $0.start > 1 }.map { $0.symbol(transpose: 0, flats: false, simple: false) }
        check(c2?.key == MusicKey(tonic: 7, minor: false) && Array(n2.prefix(4)) == ["G", "D/F#", "Em", "C"],
              "30 cents sharp, slash bass: \(c2?.key.longName ?? "none"): \(n2.prefix(4).joined(separator: " "))")

        // A sung line in Eb (one note at a time, with vibrato).
        let sr = AudioData.sampleRate
        let melody: [Int] = [63, 67, 70, 68, 67, 65, 63, 58, 63, 65, 67, 68, 70, 72, 70, 67, 65, 63, 63, 70, 67, 65, 63]
        let note = 0.45
        let mel = AudioData(frames: Int(Double(melody.count) * note * sr))
        var ph = 0.0
        for (k, m) in melody.enumerated() {
            let f = 440 * pow(2, (Double(m) - 69) / 12)
            for i in 0..<Int(note * sr) {
                let t = Double(i) / sr
                ph += f * (1 + 0.006 * sin(2 * .pi * 5.5 * t)) / sr
                let v = Float((sin(2 * .pi * ph) + 0.5 * sin(4 * .pi * ph) + 0.25 * sin(6 * .pi * ph)) * 0.2 * min(1, t * 30) * min(1, (note - t) * 30))
                mel.l[k * Int(note * sr) + i] = v; mel.r[k * Int(note * sr) + i] = v
            }
        }
        let heard = KeyListener.keyOf(mel)
        check(heard == MusicKey(tonic: 3, minor: false), "key finder on a sung Eb line: \(heard?.longName ?? "none")")
        check(MusicKey(tonic: 7, minor: false).shift(to: MusicKey(tonic: 8, minor: false)) == 1 &&
              MusicKey(tonic: 2, minor: false).shift(to: MusicKey(tonic: 10, minor: false)) == -4, "track key shift to the singer's key")

        // Lyrics files.
        let lrc = LyricsFinder.parseLRC("[00:12.50] Way maker\n[00:15.00][01:15.00] Miracle worker\n[ar:Sinach]")
        check(lrc.count == 3 && lrc[0].text == "Way maker" && abs(lrc[0].time - 12.5) < 0.001 && lrc[2].time == 75,
              "timed lyrics: \(lrc.count) lines, first at \(lrc.first?.time ?? -1)")
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\n[Music]\n\n00:00:03.000 --> 00:00:05.000\nYou are here\n\n00:00:05.000 --> 00:00:07.000\nYou are here\nmoving in our midst\n"
        let cap = LyricsFinder.parseVTT(vtt)
        check(cap.map(\.text) == ["You are here", "moving in our midst"] && cap.first?.time == 3, "captions: \(cap.map(\.text))")
        let ly = Lyrics(plain: "", lines: lrc, source: "t", offset: 0.5)
        check(ly.lineIndex(at: 12.9) == nil && ly.lineIndex(at: 13.1) == 0 && ly.lineIndex(at: 100) == 2, "current lyric line follows the offset")
        check(LyricsFinder.searchText("SINACH - WAY MAKER (Official Video) [Live] | Worship") == "SINACH - WAY MAKER", "lyrics search text: \(LyricsFinder.searchText("SINACH - WAY MAKER (Official Video) [Live] | Worship"))")

        // Pads: seamless loop, sensible level.
        let t1 = Date()
        let pad = PadSynth.render(sound: .warm, key: 8, chord: .open)
        let pdt = Date().timeIntervalSince(t1)
        var peak: Float = 0
        for i in 0..<pad.frames { peak = max(peak, abs(pad.l[i])) }
        let jump = abs(pad.l[pad.frames - 1] - pad.l[0])
        var step: Float = 0
        for i in 1..<pad.frames { step = max(step, abs(pad.l[i] - pad.l[i - 1])) }
        check(peak > 0.3 && peak <= 0.51 && jump <= step, String(format: "pad loop: peak %.2f, seam jump %.4f (largest normal step %.4f), rendered in %.1f s", peak, jump, step, pdt))
        for s in PadSound.allCases where s != .warm {
            let d = PadSynth.render(sound: s, key: 0, chord: .major)
            var p: Float = 0
            for i in stride(from: 0, to: d.frames, by: 7) { p = max(p, abs(d.l[i])) }
            var st: Float = 0
            for i in 1..<d.frames { st = max(st, abs(d.l[i] - d.l[i - 1])) }
            check(p > 0.2 && p <= 0.51 && abs(d.l[d.frames - 1] - d.l[0]) <= st, String(format: "pad %@: peak %.2f, seamless", s.label, p))
        }
    }

    static func bench() {
        func time(_ label: String, overlap: Float?, rate: Double, cueStems: Bool, click: Bool) {
            let e = makeEngine()
            var stems = [RStem(data: tone(seconds: 70, freq: 220), gain: 1, cue: false)]
            if cueStems { stems.append(RStem(data: tone(seconds: 70, freq: 330), gain: 1, cue: true)) }
            e.load(stems: stems, length: 70 * 44100)
            e.setGrid(bpm: 120, offset: 0, timeSig: .fourFour)
            e.st.clickOn = click
            e.setRate(rate)
            if let o = overlap { e.setOverlap(o) }
            e.play(from: 0, countInBars: 0)
            let t0 = Date()
            _ = render(e, seconds: 60)
            let dt = Date().timeIntervalSince(t0)
            print(String(format: "%@: %.2f s for 60 s of audio = %.1f%% of one core", label, dt, dt / 60 * 100))
        }
        time("default (overlap 12), rate 1.0, click", overlap: nil, rate: 1.0, cueStems: false, click: true)
        time("default, rate 1.1", overlap: nil, rate: 1.1, cueStems: false, click: true)
        time("overlap 8, rate 1.1", overlap: 8, rate: 1.1, cueStems: false, click: true)
        time("overlap 4, rate 1.1", overlap: 4, rate: 1.1, cueStems: false, click: true)
        time("default, rate 1.1, with in-ear stem", overlap: nil, rate: 1.1, cueStems: true, click: true)
    }

    static func analyze(_ paths: [String]) {
        for p in paths {
            let url = URL(fileURLWithPath: p)
            let name = url.deletingPathExtension().lastPathComponent
            let hints = TempoDetector.hints(fromTitle: name)
            let t0 = Date()
            guard let d = try? AudioLoader.load(url) else { print("UNREADABLE  \(name)"); continue }
            let t1 = Date()
            let r = TempoDetector.detect(d, timeSig: hints.timeSig ?? .fourFour)
            let t2 = Date()
            print(String(format: "%6.1f BPM  offset %.2f  (title: %@ %@)  load %.1fs analyze %.1fs  %@",
                         r?.bpm ?? 0, r?.offset ?? 0, hints.bpm.map { String(format: "%.0f", $0) } ?? "-",
                         hints.timeSig?.rawValue ?? "", t1.timeIntervalSince(t0), t2.timeIntervalSince(t1), TitleCleaner.clean(name)))
            if CommandLine.arguments.contains("--chords") {
                let t3 = Date()
                let ts = hints.timeSig ?? .fourFour
                if let c = Harmony.analyze(d, bpm: r?.bpm, offset: r?.offset ?? 0, beatsPerBar: ts.beatsPerBar) {
                    let line = c.segs.prefix(40).map { $0.symbol(transpose: 0, flats: c.key.usesFlats, simple: false) }.joined(separator: " ")
                    print(String(format: "        key %@ (%.1fs): %@", c.key.longName, Date().timeIntervalSince(t3), line))
                }
                if let k = KeyListener.keyOf(d) { print("        listener hears: \(k.longName)") }
            }
        }
    }

    /// Edge cases that used to be able to crash: short audio, stems shorter than a loop, bad tempos.
    static func stabilityTests() {
        // Very short audio through the chord analysis.
        for secs in [0.0, 0.2, 0.37, 0.5] {
            let d = tone(seconds: secs, freq: 440)
            let chart = Harmony.analyze(d, bpm: 120, offset: 0, beatsPerBar: 4)
            check(true, String(format: "chords on %.2f s of audio: no crash (%@)", secs, chart == nil ? "no chart" : "chart"))
        }
        // Make Longer when a stem ends before the loop, and with a reversed loop.
        let short = tone(seconds: 1, freq: 220)
        let sr = Int(AudioData.sampleRate)
        let a = LoopTools.extend(short, loopStart: 2 * sr, loopEnd: 3 * sr, copies: 2)
        check(a.frames == 5 * sr, "make longer with a short stem pads with silence (\(a.frames) frames)")
        let b = LoopTools.extend(short, loopStart: sr / 2, loopEnd: sr / 4, copies: 3)
        check(b.frames == short.frames, "make longer with a backwards loop leaves the audio as it was")
        // Grooves with nonsense tempos.
        if let st = GrooveStyle.find("worship44") {
            for bpm in [0.0, -5, .nan, 5000] {
                let parts = DrumSynth.renderParts(st, bpm: bpm)
                let f = parts.values.first?.frames ?? 0
                check(f > 1000 && f <= Int(AudioData.sampleRate) * 65, "groove at \(bpm) BPM renders a sane length (\(f) frames)")
            }
        }
        // Mono mix loads one file at a time and keeps the real length.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gi-selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u1 = dir.appendingPathComponent("a.wav"), u2 = dir.appendingPathComponent("b.wav")
        try? AudioLoader.writeWAV(tone(seconds: 2, freq: 220), url: u1)
        try? AudioLoader.writeWAV(tone(seconds: 3, freq: 330), url: u2)
        let mix = AudioLoader.loadMonoMix([u1, u2, dir.appendingPathComponent("missing.wav")], maxSeconds: 720)
        check(mix.map { abs($0.duration - 3) < 0.05 } ?? false, "mono mix of stems is as long as the longest (\(mix.map { String(format: "%.2f", $0.duration) } ?? "nil") s)")
        try? FileManager.default.removeItem(at: dir)
        // One YouTube video spelled different ways is recognised as the same download.
        let ids = ["https://www.youtube.com/watch?v=uOwUJHwiuc8", "https://youtu.be/uOwUJHwiuc8?si=x", "https://m.youtube.com/watch?v=uOwUJHwiuc8&t=30",
                   "https://www.youtube.com/shorts/uOwUJHwiuc8"].map { Downloader.videoID($0) }
        check(Set(ids.compactMap { $0 }) == ["uOwUJHwiuc8"] && !ids.contains(nil), "same video, different links -> one id \(ids)")
        // A missing stem keeps the others on their own sides.
        let e = AudioEngine(offline: true)
        try? e.start()
        e.load(stems: [RStem(data: AudioData(frames: 1), gain: 1, cue: false), RStem(data: tone(seconds: 1, freq: 440), gain: 1, cue: true)], length: sr)
        e.updateGains([(1, false), (1, true)])
        check(e.st.stems[1].cue, "stem order is kept when one stem is missing")
    }
}
