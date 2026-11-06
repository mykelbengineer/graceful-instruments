import SwiftUI
import AppKit

/// Command-line modes (the app quits when done):
///   --selftest                 audio, timing, chords and edge-case checks (exit 1 on any failure)
///   --harmonytest, --bench     chord tests only / speed check
///   --keybench [-v]            Key Finder accuracy on synthetic singing
///   --analyze file... [--chords]  tempo (and key/chords) of audio files
///   --groovewav <dir>, --groovetime  write example grooves / time them
///   --import path... [--stems] add files to the library without the window
///   --make-stems "title" [--six]  split a library song
///   --snapshot <dir> [w h]     draw each screen to PNG (GI_LIBRARY_DIR for a test library)
///   --memtest [rounds]         load every song repeatedly and print memory use
/// GUI launch options: --open "title" [--autoplay], --section tracks|loops|grooves|stemsList|keys|pads|remote|midi|metronome|downloads|stems|service
enum DevTools {
    /// Returns an exit code when a command-line mode ran, nil to start the app normally.
    static func run(_ args: [String]) -> Int32? {
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let a = args
            let w = i + 3 < a.count ? Double(a[i + 2]) ?? 1240 : 1240, h = i + 3 < a.count ? Double(a[i + 3]) ?? 760 : 760
            Snapshot.run(a[i + 1], width: CGFloat(w), height: CGFloat(h)); return 0
        }
        if let i = args.firstIndex(of: "--memtest") {
            let a = args
            MemTest.run(rounds: i + 1 < a.count ? Int(a[i + 1]) ?? 3 : 3); return 0
        }
        if args.contains("--bench") { SelfTest.bench(); return 0 }
        if let i = args.firstIndex(of: "--groovewav"), i + 1 < args.count {
            // Writes a few grooves (two times round) as WAV files to listen to.
            for id in ["worship44", "highlife", "afrobeat", "reggae", "makossa", "worship68"] {
                let st = GrooveStyle.find(id)!
                let d = DrumSynth.render(st, bpm: st.defaultBPM)
                let two = AudioData(frames: d.frames * 2)
                for k in 0..<2 { (two.l + k * d.frames).update(from: d.l, count: d.frames); (two.r + k * d.frames).update(from: d.r, count: d.frames) }
                let url = URL(fileURLWithPath: args[i + 1]).appendingPathComponent("\(st.name.replacingOccurrences(of: "/", with: "-")).wav")
                try? AudioLoader.writeWAV(two, url: url)
                print(url.path)
            }
            return 0
        }
        if args.contains("--groovetime") {
            for id in ["worship44", "afrobeat", "highlife"] {
                let st = GrooveStyle.find(id)!
                let t0 = Date(); _ = DrumSynth.renderParts(st, bpm: st.defaultBPM)
                print(String(format: "%@: %.2f s", st.name, Date().timeIntervalSince(t0)))
            }
            return 0
        }
        if let i = args.firstIndex(of: "--keybench") {
            KeyBench.run(args[(i + 1)...].filter { !$0.hasPrefix("-") })
            return 0
        }
        if args.contains("--harmonytest") { SelfTest.harmonyTests(); return SelfTest.failures == 0 ? 0 : 1 }
        if args.contains("--selftest") {
            SelfTest.run()
            return SelfTest.failures == 0 ? 0 : 1
        }
        if let i = args.firstIndex(of: "--analyze"), i + 1 < args.count {
            SelfTest.analyze(Array(args[(i + 1)...]))
            return 0
        }
        if let i = args.firstIndex(of: "--import"), i + 1 < args.count {
            // Headless import for setting up a machine over SSH. Quit the app first.
            let model = AppModel(engine: AudioEngine(offline: true))
            let paths = args[(i + 1)...].map { URL(fileURLWithPath: $0) }
            let ids = model.importAny(paths, forceStems: args.contains("--stems"))
            print("imported \(ids.count), finding tempos...")
            while !model.analyzing.isEmpty { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
            model.saveNow()
            for it in model.items where ids.contains(it.id) {
                print(String(format: "%6.1f BPM  %@  %@", it.bpm ?? 0, it.timeSig.rawValue, it.title))
                if it.kind == .stems { print("        stems: " + it.stems.map { $0.name + ($0.inEarsOnly ? " [in-ears]" : "") }.joined(separator: ", ")) }
            }
            return 0
        }
        if let i = args.firstIndex(of: "--make-stems"), i + 1 < args.count {
            // Headless split of one library item (quit the app first): --make-stems "part of title" [--six]
            let model = AppModel(engine: AudioEngine(offline: true))
            let maker = StemMaker()
            maker.model = model
            guard maker.installed,
                  let item = model.items.first(where: { $0.title.localizedCaseInsensitiveContains(args[i + 1]) && $0.kind != .stems })
            else { print("not installed or no match"); return 1 }
            print("splitting \(item.title)")
            maker.enqueue(item.id, sixStems: args.contains("--six"))
            var last = ""
            while maker.jobs.contains(where: { $0.state == .queued || $0.state == .running }) {
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                let s = maker.jobs.first?.status ?? ""
                if s != last { print(s); last = s }
            }
            model.saveNow()
            if let r = maker.jobs.first?.resultID, let it = model.items.first(where: { $0.id == r }) {
                print("added \(it.title): \(it.stems.map(\.name).joined(separator: ", ")), \(it.bpm.map { formatBPM($0) } ?? "?") BPM")
                return 0
            }
            print("failed: \(maker.jobs.first?.status ?? "")")
            return 1
        }
        if let i = args.firstIndex(of: "--counttest"), i + 1 < args.count {
            CountTest.run(title: args[i + 1], bars: i + 2 < args.count ? Int(args[i + 2]) ?? 1 : 1)
            return 0
        }
        return nil
    }
}

/// --counttest "title" [bars]: presses Play on a library song with a count-in, the way the app does, and prints
/// the left/right level every quarter second (uses this Mac's saved settings; changes nothing on disk).
enum CountTest {
    static func run(title: String, bars: Int) {
        let model = AppModel(engine: AudioEngine(offline: true))
        guard let it = model.items.first(where: { $0.title.localizedCaseInsensitiveContains(title) }) else { print("no match"); return }
        model.open(it.id)
        while model.loadingID != nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let bpm = model.current?.playingBPM ?? 0
        print("\(it.title): \(it.kind.label), \(formatBPM(bpm)) BPM, count route \(model.countRoute.rawValue), music route \(model.musicRoute.rawValue)")
        model.engine.st.countVoice = true
        model.engine.play(from: 0, countInBars: bars) // what model.play() calls when Count-in is on
        let seconds = 60 / max(bpm, 1) * Double(model.current?.timeSig.beatsPerBar ?? 4) * Double(bars) + 2
        let (l, r) = SelfTest.render(model.engine, seconds: seconds)
        let w = Int(AudioData.sampleRate / 4)
        var i = 0
        while i + w <= l.count {
            print(String(format: "%5.2f s  L %.4f  R %.4f", Double(i) / AudioData.sampleRate, SelfTest.rms(l[i..<(i + w)]), SelfTest.rms(r[i..<(i + w)])))
            i += w
        }
    }
}

/// Draws each screen to a PNG without showing a window: --snapshot <folder> [width height].
/// Used to check layouts over SSH or while the screen is locked.
enum Snapshot {
    static func run(_ dir: String, width: CGFloat, height: CGFloat) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        if ProcessInfo.processInfo.environment["GI_SNAP_DARK"] == nil { NSApp.appearance = NSAppearance(named: .aqua) }
        let model = AppModel(engine: AudioEngine(offline: true))
        let dl = Downloader(), sm = StemMaker()
        dl.model = model; sm.model = model
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let song = model.items.first { $0.kind == .song && $0.chords != nil && $0.lyrics != nil }
            ?? model.items.first { $0.kind == .song } ?? model.items.first
        let groove = model.items.first { $0.kind == .groove }
        let service = model.setlists.first

        let only = ProcessInfo.processInfo.environment["GI_SNAP_ONLY"]
        func shot(_ name: String, _ section: SidebarSection?, current: LibraryItem?, tab: PlayerTab = .controls) {
            if let o = only, !name.hasPrefix(o) { return }
            UserDefaults.standard.set(tab.rawValue, forKey: "playerTab")
            model.current = current
            if current != nil {
                var fake: [Float] = []
                for i in 0..<800 {
                    let x = Double(i)
                    let v: Double = 0.35 + 0.3 * abs(sin(x * 0.05)) + 0.2 * abs(sin(x * 1.7))
                    fake.append(Float(v))
                }
                model.waveImage = AppModel.drawWave(fake)
            }
            let root = ContentView(startSection: section)
                .environmentObject(model).environmentObject(dl).environmentObject(sm)
                .frame(width: width, height: height)
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let win = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            win.contentView = host
            win.setFrameOrigin(NSPoint(x: 0, y: 0))
            win.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            let url = out.appendingPathComponent("\(name).png")
            host.layoutSubtreeIfNeeded()
            host.display()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print(url.path)
            win.orderOut(nil)
        }

        shot("01-library-sound", .all, current: song)
        shot("02-loop", .tracks, current: song, tab: .loop)
        shot("03-cues", .loops, current: song, tab: .cues)
        shot("04-chords", .all, current: song, tab: .chords)
        shot("05-lyrics", .all, current: song, tab: .lyrics)
        if let s = service { shot("06-service-groove", .service(s.id), current: groove ?? song) }
        shot("07-keyfinder", .keyFinder, current: song)
        shot("08-pads", .pads, current: nil)
        shot("09-remote", .remote, current: nil)
        shot("10-midi", .midi, current: nil)
        shot("11-metronome", .metronome, current: nil)
        shot("12-download", .downloads, current: nil)
        shot("13-stemmaker", .stemMaker, current: nil)
        shot("14-grooves", .grooves, current: groove)
    }
}

/// --memtest [rounds]: loads every song in the library one after another, several rounds, and prints memory use.
/// Memory should level off (the decoded-audio cache is capped), not keep climbing.
enum MemTest {
    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }

    static func run(rounds: Int) {
        let model = AppModel(engine: AudioEngine(offline: true))
        let ids = model.items.filter { $0.kind != .metronome }.map(\.id)
        print(String(format: "start: %.0f MB, %d items", residentMB(), ids.count))
        for r in 1...rounds {
            for id in ids {
                model.open(id)
                let t0 = Date()
                while model.loadingID != nil && Date().timeIntervalSince(t0) < 60 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(4)) // let replaced audio be released
            print(String(format: "after round %d: %.0f MB", r, residentMB()))
        }
    }
}
