import Foundation
import AVFoundation
import Combine
import AppKit
import Accelerate

/// Position updates live here so only the playhead and clock redraw 20 times a second.
final class PlaybackClock: ObservableObject {
    @Published var position: Double = 0
    @Published var playing = false
}

final class AppModel: ObservableObject {
    @Published var items: [LibraryItem] = []
    @Published var setlists: [Setlist] = []
    @Published var current: LibraryItem?
    @Published var loadingID: UUID?
    @Published var peaks: [Float] = []
    @Published var analyzing: Set<UUID> = []
    @Published var status = ""
    @Published var activeSetlist: UUID?
    @Published var lastError: String?

    // Settings, remembered between launches.
    // Where each sound goes. Defaults match the church board: music right (house), band sounds left (in-ears).
    @Published var musicRoute: Route = .right { didSet { applyRoutes() } }
    @Published var clickRoute: Route = .left { didSet { applyRoutes() } }
    @Published var countRoute: Route = .left { didSet { applyRoutes() } }
    @Published var cueRoute: Route = .left { didSet { applyRoutes() } }
    @Published var stemRoute: Route = .left { didSet { applyRoutes() } }
    @Published var clickOn = false { didSet { engine.st.clickOn = clickOn || current?.kind == .metronome; saveSettings() } }
    @Published var clickSound: ClickSound = .classic { didSet { applyClickSound(); saveSettings() } }
    @Published var accentOn = true { didSet { applyClickSound(); saveSettings() } }
    /// 1 = beats, 2 = eighths, 3 = triplets, 4 = sixteenths (4/4 and 3/4 only).
    @Published var subdivision = 1 { didSet { applyToEngine(); saveSettings() } }
    @Published var metroBPM: Double = 72 { didSet { if current?.kind == .metronome { applyToEngine() }; saveSettings() } }
    @Published var metroTimeSig: TimeSig = .fourFour { didSet { if current?.kind == .metronome { applyToEngine() }; saveSettings() } }
    /// Library filter: tracks at or under this tempo count as Worship, faster ones as Praise.
    @Published var worshipMaxBPM: Double = 90 { didSet { saveSettings() } }
    /// The service entry that is loaded, when a song was opened from a service.
    @Published var currentEntry: UUID?
    @Published var countInBars = 0 { didSet { saveSettings() } }
    @Published var countVoice = false { didSet { engine.st.countVoice = countVoice; saveSettings() } }
    /// Spoken cues are opt-in: when off, timeline cues stay silent and the 1-0 keys do nothing.
    @Published var cuesOn = false { didSet { applyToEngine(); saveSettings() } }
    @Published var waveImage: NSImage?
    @Published var musicVol: Float = 1 { didSet { applyVolumes() } }
    @Published var inEarVol: Float = 1 { didSet { applyVolumes() } }
    @Published var clickVol: Float = 0.7 { didSet { applyVolumes() } }
    @Published var cueVol: Float = 1 { didSet { applyVolumes() } }
    @Published var cueLeadBars: Double = 1 { didSet { engine.setMarkerLead(bars: cueLeadBars); saveSettings() } }
    @Published var snapToBars = true { didSet { saveSettings() } }
    @Published var fadeSeconds: Double = 6 { didSet { saveSettings() } }

    let clock = AppModelHolder.clock
    let engine: AudioEngine
    let pads: PadController
    @Published var chordsBusy: Set<UUID> = []
    let chordQueue = DispatchQueue(label: "gi.chords", qos: .utility)
    private var timer: Timer?
    private var audioLost = false
    private var saveWork: DispatchWorkItem?
    private let analysisQueue = DispatchQueue(label: "gi.analysis", qos: .utility)
    private let loadQueue = DispatchQueue(label: "gi.load", qos: .userInitiated)
    private let cacheLock = NSLock()
    private var cache: [String: AudioData] = [:]
    private var cacheOrder: [String] = []
    private var taps: [Date] = []
    private var renderedGrooveBPM: Double = 0
    private var loadingSettings = false
    private var libraryLocked = false
    private var backedUp = false
    private var saveFailed = false

    init(engine: AudioEngine = AudioEngine()) {
        self.engine = engine
        self.pads = PadController(engine: engine)
        Paths.ensure()
        DispatchQueue.global(qos: .background).async { AppModel.sweepTemp() }
        loadLibrary()
        loadSettings()
        do { try engine.start() } catch { lastError = "Audio could not start: \(error.localizedDescription)" }
        applyVolumes()
        applyRoutes()
        applyClickSound()
        engine.st.clickOn = clickOn
        engine.st.countVoice = countVoice
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in self?.tick() }
        for item in items where !item.analyzed && item.kind != .groove { queueAnalysis(item.id) }
        // Chords and key for anything that doesn't have them yet (one at a time, in the background).
        if !engine.offline {
            for item in items where item.analyzed && (item.chords?.version ?? 0) < ChordChart.current && item.kind != .groove { queueChords(item.id, background: true) }
            startTools()
        }
        if let today = setlists.first(where: { $0.date.map { Calendar.current.isDateInToday($0) } ?? false }) {
            activeSetlist = today.id
        }
    }

    // MARK: persistence
    static let floatStrings = (inf: "inf", negInf: "-inf", nan: "nan")

    private func loadLibrary() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Paths.libraryJSON.path) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        dec.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: Self.floatStrings.inf,
                                                                    negativeInfinity: Self.floatStrings.negInf, nan: Self.floatStrings.nan)
        do {
            let lib = try dec.decode(LibraryFile.self, from: Data(contentsOf: Paths.libraryJSON))
            items = lib.items
            setlists = lib.setlists
        } catch {
            // Never start from an empty library and then save over the real one.
            let stamp = Int(Date().timeIntervalSince1970)
            let keep = Paths.libraryJSON.deletingLastPathComponent().appendingPathComponent("library-unreadable-\(stamp).json")
            try? fm.copyItem(at: Paths.libraryJSON, to: keep)
            if let data = try? Data(contentsOf: Self.backupURL), let lib = try? dec.decode(LibraryFile.self, from: data) {
                items = lib.items
                setlists = lib.setlists
                lastError = "The library file couldn't be read, so the last backup was opened instead. The unreadable file was kept as \(keep.lastPathComponent)."
            } else {
                libraryLocked = true
                lastError = "The library file couldn't be read (\(error.localizedDescription)). Nothing will be saved until this is fixed, so no songs are lost. The file was copied to \(keep.lastPathComponent)."
            }
        }
    }

    static var backupURL: URL { Paths.libraryJSON.deletingLastPathComponent().appendingPathComponent("library-backup.json") }

    func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    func saveNow() {
        guard !libraryLocked else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: Self.floatStrings.inf,
                                                                  negativeInfinity: Self.floatStrings.negInf, nan: Self.floatStrings.nan)
        do {
            let data = try enc.encode(LibraryFile(items: items, setlists: setlists))
            // Once per launch, keep the previous good file as a backup before the first write.
            if !backedUp, FileManager.default.fileExists(atPath: Paths.libraryJSON.path) {
                try? FileManager.default.removeItem(at: Self.backupURL)
                try? FileManager.default.copyItem(at: Paths.libraryJSON, to: Self.backupURL)
                backedUp = true
            }
            try data.write(to: Paths.libraryJSON, options: .atomic)
            saveFailed = false
        } catch {
            if !saveFailed { lastError = "Couldn't save the library: \(error.localizedDescription)" }
            saveFailed = true
        }
    }

    private func loadSettings() {
        loadingSettings = true
        let d = UserDefaults.standard
        func route(_ k: String) -> Route? { d.string(forKey: k).flatMap(Route.init(rawValue:)) }
        if let r = route("musicRoute") { musicRoute = r }
        if let r = route("clickRoute") { clickRoute = r }
        if let r = route("countRoute") { countRoute = r }
        if let r = route("cueRoute") { cueRoute = r }
        if let r = route("stemRoute") { stemRoute = r }
        clickOn = d.bool(forKey: "clickOn")
        if d.object(forKey: "countInBars") != nil { countInBars = d.integer(forKey: "countInBars") }
        if d.object(forKey: "countVoice") != nil { countVoice = d.bool(forKey: "countVoice") }
        cuesOn = d.bool(forKey: "cuesOn")
        if let c = d.string(forKey: "clickSound").flatMap(ClickSound.init(rawValue:)) { clickSound = c }
        if d.object(forKey: "accentOn") != nil { accentOn = d.bool(forKey: "accentOn") }
        if d.object(forKey: "subdivision") != nil { subdivision = max(1, d.integer(forKey: "subdivision")) }
        if d.object(forKey: "metroBPM") != nil { metroBPM = d.double(forKey: "metroBPM") }
        if let t = d.string(forKey: "metroTimeSig").flatMap(TimeSig.init(rawValue:)) { metroTimeSig = t }
        if d.object(forKey: "worshipMaxBPM") != nil { worshipMaxBPM = d.double(forKey: "worshipMaxBPM") }
        if d.object(forKey: "musicVol") != nil { musicVol = d.float(forKey: "musicVol") }
        if d.object(forKey: "inEarVol") != nil { inEarVol = d.float(forKey: "inEarVol") }
        if d.object(forKey: "clickVol") != nil { clickVol = d.float(forKey: "clickVol") }
        if d.object(forKey: "cueVol") != nil { cueVol = d.float(forKey: "cueVol") }
        if d.object(forKey: "cueLeadBars") != nil { cueLeadBars = d.double(forKey: "cueLeadBars") }
        if d.object(forKey: "snapToBars") != nil { snapToBars = d.bool(forKey: "snapToBars") }
        if d.object(forKey: "fadeSeconds") != nil { fadeSeconds = d.double(forKey: "fadeSeconds") }
        loadingSettings = false
    }

    private func saveSettings() {
        guard !loadingSettings else { return }
        let d = UserDefaults.standard
        d.set(musicRoute.rawValue, forKey: "musicRoute")
        d.set(clickRoute.rawValue, forKey: "clickRoute")
        d.set(countRoute.rawValue, forKey: "countRoute")
        d.set(cueRoute.rawValue, forKey: "cueRoute")
        d.set(stemRoute.rawValue, forKey: "stemRoute")
        d.set(clickOn, forKey: "clickOn")
        d.set(countInBars, forKey: "countInBars")
        d.set(countVoice, forKey: "countVoice")
        d.set(cuesOn, forKey: "cuesOn")
        d.set(clickSound.rawValue, forKey: "clickSound")
        d.set(accentOn, forKey: "accentOn")
        d.set(subdivision, forKey: "subdivision")
        d.set(metroBPM, forKey: "metroBPM")
        d.set(metroTimeSig.rawValue, forKey: "metroTimeSig")
        d.set(worshipMaxBPM, forKey: "worshipMaxBPM")
        d.set(musicVol, forKey: "musicVol")
        d.set(inEarVol, forKey: "inEarVol")
        d.set(clickVol, forKey: "clickVol")
        d.set(cueVol, forKey: "cueVol")
        d.set(cueLeadBars, forKey: "cueLeadBars")
        d.set(snapToBars, forKey: "snapToBars")
        d.set(fadeSeconds, forKey: "fadeSeconds")
    }

    private func applyClickSound() { engine.setClickSound(clickSound, accent: accentOn) }

    private func applyRoutes() {
        engine.setRoutes(music: musicRoute, click: clickRoute, count: countRoute, cues: cueRoute, stems: stemRoute)
        saveSettings()
    }

    /// Church board setup: music to the house (right), click, count-in and cues to the in-ears (left).
    func presetSplit() {
        musicRoute = .right; clickRoute = .left; countRoute = .left; cueRoute = .left; stemRoute = .left
    }

    /// Practice / headphones: everything on both sides.
    func presetBoth() {
        musicRoute = .both; clickRoute = .both; countRoute = .both; cueRoute = .both; stemRoute = .both
    }

    var isSplitPreset: Bool {
        musicRoute == .right && clickRoute == .left && countRoute == .left && cueRoute == .left && stemRoute == .left
    }

    private func applyVolumes() {
        engine.setVolumes(music: musicVol, inEars: inEarVol, click: clickVol, cues: cueVol)
        saveSettings()
    }

    // MARK: import
    func importFiles(_ urls: [URL], title: String? = nil, move: Bool = false) -> [UUID] {
        var files: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while let f = e?.nextObject() as? URL { if AudioLoader.isAudio(f) { files.append(f) } }
            } else if AudioLoader.isAudio(u) {
                files.append(u)
            }
        }
        var added: [UUID] = []
        var skipped: [String] = []
        for f in files.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            // The same file imported again would only make a second copy.
            if let dup = existingItem(sameAudioAs: f) {
                skipped.append(dup.title)
                if move { try? FileManager.default.removeItem(at: f) }
                continue
            }
            guard let name = storeFile(f, move: move) else { continue }
            let rawTitle = title ?? f.deletingPathExtension().lastPathComponent
            let hints = TempoDetector.hints(fromTitle: rawTitle)
            var item = LibraryItem(title: TitleCleaner.clean(rawTitle), kind: .song)
            item.stems = [Stem(name: "Track", file: name)]
            item.timeSig = hints.timeSig ?? .fourFour
            item.bpm = hints.bpm
            item.duration = Self.quickDuration(Paths.audio.appendingPathComponent(name))
            items.append(item)
            added.append(item.id)
            queueAnalysis(item.id)
        }
        if !skipped.isEmpty {
            status = "Already in the library: \(skipped.joined(separator: ", "))" + (added.isEmpty ? "" : ". Imported \(added.count) new.")
        } else {
            status = added.isEmpty ? "No audio files found" : "Imported \(added.count) file\(added.count == 1 ? "" : "s")"
        }
        scheduleSave()
        return added
    }

    /// A library track whose stored audio is byte-for-byte the same file (same size, same first 256 KB).
    func existingItem(sameAudioAs url: URL) -> LibraryItem? {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 0 else { return nil }
        func head(_ u: URL) -> Data? {
            guard let h = try? FileHandle(forReadingFrom: u) else { return nil }
            defer { try? h.close() }
            return h.readData(ofLength: 262_144)
        }
        var mine: Data?
        for it in items where it.kind != .groove {
            for s in it.stems {
                let p = Paths.audio.appendingPathComponent(s.file)
                guard (try? fm.attributesOfItem(atPath: p.path))?[.size] as? Int == size else { continue }
                if mine == nil { mine = head(url) }
                if let a = mine, a == head(p) { return it }
            }
        }
        return nil
    }

    /// Removes temporary folders left behind if the app was quit during a download, zip import or stem split.
    static func sweepTemp() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let old = Date().addingTimeInterval(-6 * 3600)
        for u in (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where u.lastPathComponent.hasPrefix("gi-") {
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if d < old { try? fm.removeItem(at: u) }
        }
    }

    static let stemWords = ["click", "guide", "cue", "count", "talkback", "drum", "kick", "snare", "tom", "hat", "overhead",
                            "cymbal", "perc", "tamb", "shaker", "bass", "sub", "808", "key", "piano", "rhodes", "organ", "synth",
                            "pad", "string", "brass", "horn", "guitar", "gtr", "eg", "ag", "vocal", "vox", "bgv", "bv", "choir",
                            "lead", "harmony", "loop", "track", "aux", "fx", "sfx", "arp"]
    static let inEarWords = ["click", "guide", "cue", "count", "talkback"]

    /// One way in for anything dropped or chosen: audio files, folders, zip downloads (with nested folders).
    /// A folder holding several stem-like files (Click, Drums, Bass, Keys…) becomes one Stems item;
    /// loose files become tracks. `forceStems` treats every multi-file folder as a stem pack.
    @discardableResult
    func importAny(_ urls: [URL], forceStems: Bool = false) -> [UUID] {
        let fm = FileManager.default
        var added: [UUID] = []
        var temps: [URL] = []
        var loose: [URL] = []
        var packs = 0
        func walk(_ dir: URL) {
            guard let list = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            let files = list.filter { AudioLoader.isAudio($0) && !$0.lastPathComponent.hasPrefix("._") }
            let dirs = list.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && $0.lastPathComponent != "__MACOSX" }
            let stemLike = files.filter { f in
                let n = f.deletingPathExtension().lastPathComponent.lowercased()
                return AppModel.stemWords.contains { n.contains($0) }
            }
            if files.count >= 2 && (forceStems || stemLike.count >= 2) {
                if let id = importStemFiles(files, folder: dir) { added.append(id); packs += 1 }
            } else {
                loose.append(contentsOf: files)
            }
            dirs.forEach(walk)
        }
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                walk(u)
            } else if u.pathExtension.lowercased() == "zip" {
                let tmp = fm.temporaryDirectory.appendingPathComponent("gi-zip-\(UUID().uuidString)", isDirectory: true)
                temps.append(tmp)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-x", "-k", u.path, tmp.path]
                try? p.run(); p.waitUntilExit()
                if p.terminationStatus == 0 {
                    // Name the top level after the zip, so a pack sitting at the zip's root gets the zip's name.
                    let named = tmp.appendingPathComponent(u.deletingPathExtension().lastPathComponent, isDirectory: true)
                    let top = (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                    if top.contains(where: { AudioLoader.isAudio($0) }) {
                        try? fm.createDirectory(at: named, withIntermediateDirectories: true)
                        for f in top where f.lastPathComponent != "__MACOSX" { try? fm.moveItem(at: f, to: named.appendingPathComponent(f.lastPathComponent)) }
                    }
                    walk(tmp)
                } else {
                    lastError = "Could not open \(u.lastPathComponent)."
                }
            } else if AudioLoader.isAudio(u) {
                loose.append(u)
            }
        }
        if !loose.isEmpty { added += importFiles(loose) }
        temps.forEach { try? fm.removeItem(at: $0) }
        if packs > 0 {
            status = "Imported \(packs) stem pack\(packs == 1 ? "" : "s")" + (loose.isEmpty ? "" : " and \(loose.count) track\(loose.count == 1 ? "" : "s")")
        }
        return added
    }


    private func importStemFiles(_ files: [URL], folder: URL) -> UUID? {
        let names = files.map { $0.deletingPathExtension().lastPathComponent }
        // Vendors prefix every file with the song name ("Way Maker - Click"); drop the shared part.
        var prefix = names.first ?? ""
        for n in names.dropFirst() { while !n.hasPrefix(prefix) { prefix.removeLast() } }
        // Only cut at a separator, never in the middle of a word ("Way Maker - Bass" vs "Way Maker - Bells").
        let seps = CharacterSet(charactersIn: " _-–.")
        if let last = prefix.unicodeScalars.lastIndex(where: { seps.contains($0) }) {
            prefix = String(prefix.unicodeScalars[...last])
        } else {
            prefix = ""
        }
        func stemName(_ n: String) -> String {
            var s = prefix.count >= 3 && n.count > prefix.count ? String(n.dropFirst(prefix.count)) : n
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: " _-–.").union(.whitespaces))
            return s.isEmpty ? n : s
        }
        // Folder title, or the shared prefix when the folder is generic ("Stems", "WAV", "MultiTracks").
        let generic = ["stems", "wav", "wavs", "mp3", "audio", "multitracks", "multitrack", "tracks", "files"]
        var title = folder.lastPathComponent
        if generic.contains(title.lowercased()) {
            title = folder.deletingLastPathComponent().lastPathComponent
        }
        var item = LibraryItem(title: TitleCleaner.clean(title), kind: .stems)
        // Click and guide first, then the band in a familiar order.
        let order = ["click", "cue", "guide", "count", "drum", "kick", "snare", "perc", "bass", "key", "piano", "organ", "synth",
                     "pad", "guitar", "gtr", "string", "vocal", "vox", "bgv", "choir"]
        func rank(_ u: URL) -> Int {
            let n = u.lastPathComponent.lowercased()
            return order.firstIndex { n.contains($0) } ?? order.count
        }
        let sorted = files.sorted { rank($0) != rank($1) ? rank($0) < rank($1)
            : $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for f in sorted {
            guard let stored = storeFile(f, move: false) else { continue }
            let n = stemName(f.deletingPathExtension().lastPathComponent)
            let lower = n.lowercased()
            item.stems.append(Stem(name: n, file: stored, inEarsOnly: AppModel.inEarWords.contains { lower.contains($0) }))
        }
        guard !item.stems.isEmpty else { return nil }
        let hints = TempoDetector.hints(fromTitle: title + " " + folder.lastPathComponent)
        item.bpm = hints.bpm
        item.timeSig = hints.timeSig ?? .fourFour
        item.duration = item.stems.map { Self.quickDuration(Paths.audio.appendingPathComponent($0.file)) }.max() ?? 0
        items.append(item)
        queueAnalysis(item.id)
        scheduleSave()
        return item.id
    }

    private func storeFile(_ src: URL, move: Bool) -> String? {
        let ext = src.pathExtension.isEmpty ? "mp3" : src.pathExtension.lowercased()
        let name = "\(UUID().uuidString).\(ext == "mpeg" ? "mp3" : ext)"
        let dst = Paths.audio.appendingPathComponent(name)
        do {
            if move { try FileManager.default.moveItem(at: src, to: dst) }
            else { try FileManager.default.copyItem(at: src, to: dst) }
            return name
        } catch {
            lastError = "Could not import \(src.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

    static func quickDuration(_ url: URL) -> Double {
        guard let f = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(f.length) / f.fileFormat.sampleRate
    }

    /// Switches a loaded groove to another style (keeps its tempo and part mix).
    func changeGrooveStyle(_ style: GrooveStyle) {
        guard let it = current, it.kind == .groove else { return }
        let wasPlaying = engine.isPlaying
        update { $0.grooveStyle = style.id; $0.timeSig = style.timeSig; $0.title = style.name }
        open(it.id, autoplay: wasPlaying)
    }

    func addGroove(_ style: GrooveStyle) -> UUID {
        var item = LibraryItem(title: style.name, kind: .groove)
        item.grooveStyle = style.id
        item.bpm = style.defaultBPM
        item.timeSig = style.timeSig
        item.analyzed = true
        item.loopOn = true
        items.append(item)
        scheduleSave()
        return item.id
    }

    // MARK: analysis
    func queueAnalysis(_ id: UUID, force: Bool = false) {
        guard let item = items.first(where: { $0.id == id }), item.kind != .groove else { return }
        analyzing.insert(id)
        analysisQueue.async { [weak self] in
            guard let self = self else { return }
            let clickStem = item.stems.first { $0.name.lowercased().contains("click") }
            let sources = clickStem.map { [$0] } ?? item.stems.filter { !$0.inEarsOnly }
            let datas = sources.compactMap { try? AudioLoader.load(Paths.audio.appendingPathComponent($0.file), maxSeconds: 150) }
            guard !datas.isEmpty else {
                DispatchQueue.main.async { self.analyzing.remove(id) }
                return
            }
            let mix = datas.count == 1 ? datas[0] : AudioData.monoMix(datas)
            let duration = item.stems.map { Self.quickDuration(Paths.audio.appendingPathComponent($0.file)) }.max() ?? 0
            let hint = force ? nil : item.bpm
            let result = TempoDetector.detect(mix, timeSig: item.timeSig, hintBPM: hint)
            DispatchQueue.main.async {
                self.analyzing.remove(id)
                guard let i = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[i].duration = duration
                if let r = result {
                    self.items[i].bpm = r.bpm
                    self.items[i].beatOffset = r.offset
                }
                self.items[i].analyzed = true
                if self.items[i].chords == nil && !self.engine.offline { self.queueChords(id, background: true) }
                if self.current?.id == id {
                    self.current?.bpm = self.items[i].bpm
                    self.current?.beatOffset = self.items[i].beatOffset
                    self.current?.duration = duration
                    self.applyToEngine()
                }
                self.scheduleSave()
            }
        }
    }

    // MARK: open / play
    private func cachedLoad(_ file: String) -> AudioData? {
        cacheLock.lock()
        if let d = cache[file] { cacheLock.unlock(); return d }
        cacheLock.unlock()
        guard let d = try? AudioLoader.load(Paths.audio.appendingPathComponent(file)) else { return nil }
        cacheLock.lock()
        cache[file] = d
        cacheOrder.removeAll { $0 == file }
        cacheOrder.append(file)
        // Keep at most ~1.2 GB of decoded audio around (this Mac has 8 GB).
        var total = cache.values.reduce(0) { $0 + $1.bytes }
        while total > 1_200_000_000 && cacheOrder.count > 1 {
            let k = cacheOrder.removeFirst()
            total -= cache[k]?.bytes ?? 0
            cache.removeValue(forKey: k)
        }
        cacheLock.unlock()
        return d
    }

    /// Decodes upcoming setlist items in the background so "Next" is instant.
    func preload(_ item: LibraryItem) {
        guard item.kind != .groove else { return }
        loadQueue.async { [weak self] in for s in item.stems { _ = self?.cachedLoad(s.file) } }
    }

    func open(_ id: UUID, autoplay: Bool = false, entry: UUID? = nil) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        currentEntry = entry
        engine.pause()
        clock.playing = false
        loadingID = id
        loadQueue.async { [weak self] in
            guard let self = self else { return }
            var datas: [AudioData] = []
            var missing: [String] = []
            var grooveBPM: Double = 0
            if item.kind == .groove, let style = GrooveStyle.find(item.grooveStyle) {
                grooveBPM = item.bpm ?? style.defaultBPM
                let parts = DrumSynth.renderParts(style, bpm: grooveBPM)
                datas = GroovePart.allCases.map { parts[$0]! }
            } else {
                // Keep one entry per stem (silence for a missing file) so the others keep their own
                // volume and left/right routing.
                for s in item.stems {
                    if let d = self.cachedLoad(s.file) { datas.append(d) } else { datas.append(AudioData(frames: 1)); missing.append(s.name) }
                }
                if missing.count == item.stems.count { datas = [] }
            }
            let bins = 1400
            var peaks = [Float](repeating: 0, count: bins)
            let maxFrames = datas.map(\.frames).max() ?? 1
            if item.kind == .groove, let first = datas.first {
                // Waveform of the whole groove at its current mix.
                let mixed = AudioData(frames: first.frames)
                for (k, d) in datas.enumerated() {
                    var g = item.grooveLevel(GroovePart.allCases[k])
                    vDSP_vsma(d.l, 1, &g, mixed.l, 1, mixed.l, 1, vDSP_Length(d.frames))
                    vDSP_vsma(d.r, 1, &g, mixed.r, 1, mixed.r, 1, vDSP_Length(d.frames))
                }
                peaks = mixed.peaks(bins: bins)
            }
            for (k, d) in datas.enumerated() where k < item.stems.count {
                if item.stems[k].inEarsOnly { continue }
                let p = d.peaks(bins: max(1, Int(Double(bins) * Double(d.frames) / Double(maxFrames))))
                for i in 0..<min(p.count, bins) { peaks[i] = max(peaks[i], p[i]) }
            }
            DispatchQueue.main.async {
                guard self.loadingID == id else { return }
                self.loadingID = nil
                guard !datas.isEmpty else {
                    self.lastError = "Could not load \"\(item.title)\". The audio file may be missing."
                    return
                }
                var it = self.items.first(where: { $0.id == id }) ?? item
                if let e = self.entry(entry) { it = e.apply(to: it) }
                let rstems: [RStem]
                if it.kind == .groove {
                    rstems = datas.map { RStem(data: $0, gain: 1, cue: false) }
                    self.renderedGrooveBPM = grooveBPM
                    it.duration = datas[0].duration
                    it.loopStart = 0; it.loopEnd = datas[0].duration; it.loopOn = true
                } else {
                    rstems = zip(datas, it.stems).map { RStem(data: $0.0, gain: 1, cue: $0.1.inEarsOnly) }
                }
                self.engine.load(stems: rstems, length: maxFrames)
                self.current = it
                self.peaks = peaks
                self.waveImage = AppModel.drawWave(peaks)
                self.applyToEngine()
                let start = it.kind == .loop ? (it.loopStart ?? 0) : 0
                self.engine.seek(to: start)
                self.clock.position = start
                if autoplay { self.play() }
                if let next = self.nextInSetlist() { self.preload(next.item) }
                if !missing.isEmpty {
                    self.lastError = "Some parts of \"\(item.title)\" are missing and will be silent: \(missing.joined(separator: ", "))."
                }
            }
        }
    }

    /// Loads the stand-alone metronome (no track; the click plays on its own).
    func openMetronome() {
        engine.pause()
        clock.playing = false
        currentEntry = nil
        loadingID = nil
        var m = LibraryItem(title: "Metronome", kind: .metronome)
        m.duration = 4 * 3600
        engine.load(stems: [], length: Int(m.duration * AudioData.sampleRate))
        current = m
        peaks = []
        waveImage = nil
        applyToEngine()
        engine.seek(to: 0)
        clock.position = 0
    }

    func toggleMetronome() {
        if current?.kind != .metronome { openMetronome() }
        if engine.isPlaying { pause() } else { engine.seek(to: 0); play() }
    }

    /// Worship / Praise by tempo unless tagged by hand.
    func category(of item: LibraryItem) -> Category? {
        if let c = item.category { return c }
        guard item.kind != .metronome, let b = item.playingBPM else { return nil }
        return b <= worshipMaxBPM ? .worship : .praise
    }

    func setCategory(_ c: Category?, for ids: [UUID]) {
        for i in items.indices where ids.contains(items[i].id) { items[i].category = c }
        if let cur = current, ids.contains(cur.id) { current?.category = c }
        scheduleSave()
    }

    /// Pushes the current item's settings into the audio engine.
    func applyToEngine() {
        guard let it = current else { return }
        engine.st.clickOn = clickOn || it.kind == .metronome
        if it.kind == .metronome {
            engine.setRate(1)
            engine.setSemitones(0)
            engine.setGrid(bpm: metroBPM, offset: 0, timeSig: metroTimeSig, subdivision: subdivision)
            engine.setLoop(on: false, start: 0, end: 0)
            engine.setMarkers([])
            return
        }
        if it.kind == .groove {
            engine.setRate(it.rate * (it.bpm ?? renderedGrooveBPM) / max(renderedGrooveBPM, 1))
            engine.setGrid(bpm: renderedGrooveBPM, offset: 0, timeSig: it.timeSig, subdivision: subdivision)
        } else {
            engine.setRate(it.rate)
            engine.setGrid(bpm: it.bpm, offset: it.beatOffset, timeSig: it.timeSig, subdivision: subdivision)
        }
        engine.setSemitones(it.semitones)
        engine.setLoop(on: it.loopOn, start: it.loopStart ?? 0, end: it.loopEnd ?? it.duration)
        if it.kind == .groove {
            engine.updateGains(GroovePart.allCases.map { (it.grooveLevel($0), false) })
            engine.setMarkers([])
            return
        }
        let anySolo = it.stems.contains { $0.solo }
        engine.updateGains(it.stems.map { s in
            let g: Float = s.muted ? 0 : (anySolo && !s.solo ? 0 : s.volume)
            return (g, s.inEarsOnly)
        })
        engine.setMarkers(cuesOn ? it.markers.map { ($0.time, AudioEngine.cueIndex($0.cue)) } : [])
        engine.setMarkerLead(bars: cueLeadBars)
    }

    /// Edits the loaded item, pushes it to the engine and saves.
    func update(_ change: (inout LibraryItem) -> Void) {
        guard var it = current, it.kind != .metronome else { return }
        change(&it)
        current = it
        if let i = items.firstIndex(where: { $0.id == it.id }) {
            if let eid = currentEntry, let path = entryPath(eid) {
                let (s, sec, e) = path
                // Opened from a service: tempo, key and loop belong to this service only.
                setlists[s].sections[sec].entries[e].rate = it.rate
                setlists[s].sections[sec].entries[e].semitones = it.semitones
                setlists[s].sections[sec].entries[e].loopOn = it.loopOn
                setlists[s].sections[sec].entries[e].loopStart = it.loopStart
                setlists[s].sections[sec].entries[e].loopEnd = it.loopEnd
                var base = it
                base.rate = items[i].rate
                base.semitones = items[i].semitones
                base.loopOn = items[i].loopOn
                base.loopStart = items[i].loopStart
                base.loopEnd = items[i].loopEnd
                items[i] = base
            } else {
                items[i] = it
            }
        }
        applyToEngine()
        scheduleSave()
    }

    func play() {
        guard current != nil else { return }
        var from = clock.position
        if let it = current, it.loopOn, let ls = it.loopStart, let le = it.loopEnd, from >= le - 0.05 { from = ls }
        if let it = current, !it.loopOn, from >= it.duration - 0.05 { from = 0 }
        let canCount = current?.bpm != nil && current?.kind != .metronome
        engine.play(from: from, countInBars: canCount ? countInBars : 0)
        clock.playing = true
    }

    func pause() {
        engine.pause()
        clock.playing = false
        refreshGroove()
    }

    func togglePlay() { engine.isPlaying ? pause() : play() }

    func stop() {
        pause()
        let start = (current?.loopOn == true ? current?.loopStart : nil) ?? 0
        seek(to: start)
    }

    func seek(to t: Double) {
        engine.seek(to: t)
        clock.position = engine.position
    }

    func jumpBars(_ n: Int) {
        guard let it = current else { return }
        let bar = it.barSeconds ?? 4
        seek(to: max(0, min(it.duration, clock.position + Double(n) * bar)))
    }

    func fadeOut() { engine.fadeOut(seconds: fadeSeconds) }

    func cue(_ key: String) { if cuesOn { engine.cue(key) } }

    private func tick() {
        // Audio watchdog: if the output stopped (device change, sleep), start it again.
        if !engine.offline && !engine.engine.isRunning {
            if engine.restartIfStopped() {
                if audioLost { status = "Audio output is back"; audioLost = false }
            } else if !audioLost {
                audioLost = true
                status = "Audio output stopped. Trying to reconnect…"
            }
        }
        let p = engine.position
        if abs(p - clock.position) > 0.01 { clock.position = p }
        if engine.st.finished {
            engine.st.finished = false
            clock.playing = false
            if engine.st.fadeGain <= 0 { engine.st.fadeGain = 1 }
        }
        if clock.playing != engine.isPlaying { clock.playing = engine.isPlaying }
    }

    func refreshGroove() {
        // Grooves are re-synthesized at the new tempo once stopped, so they stay crisp.
        guard let it = current, it.kind == .groove, currentEntry == nil, let bpm = it.bpm else { return }
        let target = bpm * it.rate
        if abs(target - renderedGrooveBPM) > 0.01 {
            let pos = clock.position / max(it.duration, 0.01)
            update { $0.bpm = (target * 10).rounded() / 10; $0.rate = 1 }
            open(it.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self, let d = self.current?.duration else { return }
                self.seek(to: pos * d)
            }
        }
    }

    /// Draws the waveform once into a bitmap; redrawing it as vector shapes every tick was too slow on the 2015 MacBook.
    static func drawWave(_ peaks: [Float]) -> NSImage? {
        let w = 1400, h = 200
        guard !peaks.isEmpty, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor)
        let mid = CGFloat(h) / 2
        let top = max(peaks.max() ?? 1, 0.05) // scale so quiet tracks still fill the view
        for x in 0..<w {
            let i0 = x * peaks.count / w, i1 = max(i0 + 1, (x + 1) * peaks.count / w)
            var m: Float = 0
            for i in i0..<min(i1, peaks.count) { m = max(m, peaks[i]) }
            let hh = max(0.5, CGFloat(min(m / top, 1)) * mid * 0.95)
            ctx.fill(CGRect(x: CGFloat(x), y: mid - hh, width: 1, height: hh * 2))
        }
        guard let img = ctx.makeImage() else { return nil }
        return NSImage(cgImage: img, size: NSSize(width: w, height: h))
    }

    // MARK: tempo tools
    /// Changes the playing tempo by whole BPM when the tempo is known, otherwise by 1%.
    func nudgeTempo(_ delta: Double) {
        update { it in
            if let bpm = it.bpm, bpm > 0 {
                let target = (bpm * it.rate).rounded() + delta
                it.rate = min(max(target / bpm, 0.5), 1.6)
            } else {
                it.rate = min(max(((it.rate * 100).rounded() + delta) / 100, 0.5), 1.6)
            }
        }
    }

    func tapTempo() {
        let now = Date()
        if let last = taps.last, now.timeIntervalSince(last) > 2 { taps.removeAll() }
        taps.append(now)
        if taps.count > 8 { taps.removeFirst() }
        guard taps.count >= 3 else { return }
        let intervals = zip(taps.dropFirst(), taps).map { $0.timeIntervalSince($1) }
        let avg = intervals.reduce(0, +) / Double(intervals.count)
        // Taps are on the music as heard, so convert back to the track's own tempo.
        let heard = 60 / avg
        guard heard.isFinite, heard >= 30, heard <= 300 else { return }
        update { it in
            let r = it.kind == .groove ? 1 : it.rate
            it.bpm = ((heard / r) * 10).rounded() / 10
        }
    }

    func setBeatOneHere() {
        update { it in
            guard let bar = it.barSeconds else { return }
            it.beatOffset = clock.position.truncatingRemainder(dividingBy: bar)
        }
    }

    func nudgeBeat(_ beats: Double) {
        update { it in
            guard let beat = it.beatSeconds, let bar = it.barSeconds else { return }
            var o = (it.beatOffset + beats * beat).truncatingRemainder(dividingBy: bar)
            if o < 0 { o += bar }
            it.beatOffset = o
        }
    }

    // MARK: loops
    func setLoopRegion(_ a: Double, _ b: Double) {
        update { it in
            var s = min(a, b), e = max(a, b)
            if snapToBars, let bar = it.barSeconds {
                s = it.beatOffset + ((s - it.beatOffset) / bar).rounded() * bar
                e = it.beatOffset + ((e - it.beatOffset) / bar).rounded() * bar
                if e <= s { e = s + bar }
                s = max(0, s)
            }
            it.loopStart = s; it.loopEnd = min(e, it.duration); it.loopOn = true
        }
    }

    func loopBars(_ n: Int) {
        guard let it = current else { return }
        let bar = it.barSeconds ?? 2
        var s = clock.position
        if let b = it.barSeconds { s = it.beatOffset + floor((s - it.beatOffset) / b) * b; s = max(0, s) }
        let saved = snapToBars
        snapToBars = false
        setLoopRegion(s, s + bar * Double(n))
        snapToBars = saved
    }

    /// Saves the looped section as its own small lossless file (plus a little lead-in for the seamless crossfade).
    func saveCurrentAsLoop(named name: String) {
        guard let it = current, it.kind != .groove, let ls = it.loopStart, let le = it.loopEnd, le > ls else { return }
        status = "Saving loop \"\(name)\"..."
        loadQueue.async { [weak self] in
            guard let self = self else { return }
            let sr = AudioData.sampleRate
            let a = Int(ls * sr), b = Int(le * sr)
            let pre = min(a, RenderState.xfade * 2)
            let first = a - pre
            var stems: [Stem] = []
            var failed = false
            for st in it.stems {
                guard let d = self.cachedLoad(st.file) else { failed = true; continue }
                let file = "\(UUID().uuidString).m4a"
                do {
                    try AudioLoader.writeLossless(d, from: first, to: b, url: Paths.audio.appendingPathComponent(file))
                    var ns = st; ns.id = UUID(); ns.file = file
                    stems.append(ns)
                } catch { failed = true }
            }
            DispatchQueue.main.async {
                guard !stems.isEmpty else { self.lastError = "Could not save the loop."; self.status = ""; return }
                let shift = Double(first) / sr
                var loop = it
                loop.id = UUID()
                loop.kind = it.kind == .stems ? .stems : .loop
                loop.title = name
                loop.stems = stems
                loop.loopStart = Double(pre) / sr
                loop.loopEnd = Double(pre) / sr + (le - ls)
                loop.loopOn = true
                loop.duration = Double(b - first) / sr
                if let bar = it.barSeconds {
                    var o = (it.beatOffset - shift).truncatingRemainder(dividingBy: bar)
                    if o < 0 { o += bar }
                    loop.beatOffset = o
                }
                loop.markers = it.markers.filter { $0.time >= ls && $0.time <= le }.map { var m = $0; m.id = UUID(); m.time -= shift; return m }
                loop.added = Date()
                loop.analyzed = true
                self.items.append(loop)
                self.status = failed ? "Saved loop \"\(name)\" (some stems could not be saved)" : "Saved loop \"\(name)\""
                self.scheduleSave()
            }
        }
    }

    // MARK: in / out and saved portions
    private func snapped(_ t: Double) -> Double {
        guard snapToBars, let it = current, let bar = it.barSeconds else { return t }
        return max(0, it.beatOffset + ((t - it.beatOffset) / bar).rounded() * bar)
    }

    /// Marks where the loop starts (I key). Uses the playhead, snapped to the nearest bar.
    func setIn() {
        let t = snapped(clock.position)
        update { it in
            let bar = it.barSeconds ?? 2
            it.loopStart = t
            if (it.loopEnd ?? 0) <= t + 0.05 { it.loopEnd = min(it.duration, t + bar * 4) }
            it.loopOn = true
        }
    }

    /// Marks where the loop ends (O key); playback jumps back to In from here.
    func setOut() {
        let t = snapped(clock.position)
        update { it in
            let bar = it.barSeconds ?? 2
            if (it.loopStart ?? .infinity) >= t - 0.05 { it.loopStart = max(0, t - bar * 4) }
            it.loopEnd = t
            it.loopOn = true
        }
    }

    func savePortion(named name: String) {
        guard let it = current, let s = it.loopStart, let e = it.loopEnd, e > s else { return }
        update { $0.regions = ($0.regions ?? []) + [LoopRegion(name: name, start: s, end: e)] }
        status = "Saved portion \"\(name)\""
    }

    func deletePortion(_ id: UUID) { update { $0.regions?.removeAll { $0.id == id } } }

    /// Loops a saved portion. While playing it switches at the next bar line so it stays in time.
    func activatePortion(_ r: LoopRegion) {
        let jumped = engine.isPlaying && engine.queueLoopJump(start: r.start, end: r.end)
        update { $0.loopStart = r.start; $0.loopEnd = r.end; $0.loopOn = true }
        if !jumped { seek(to: r.start) }
    }

    // MARK: find pattern / make longer
    @Published var loopToolBusy = false

    private func mixForAnalysis(_ it: LibraryItem) -> AudioData? {
        let datas = it.stems.filter { !$0.inEarsOnly }.compactMap { cachedLoad($0.file) }
        guard !datas.isEmpty else { return nil }
        return datas.count == 1 ? datas[0] : AudioData.monoMix(datas)
    }

    /// Finds the repeating pattern and sets the loop to it.
    func findPattern() {
        guard let it = current, it.kind != .groove, it.kind != .metronome, let bpm = it.bpm else {
            status = "Set the track's tempo first (Click > Track tempo)."
            return
        }
        loopToolBusy = true
        status = "Looking for the repeating pattern…"
        loadQueue.async { [weak self] in
            guard let self = self else { return }
            let found = self.mixForAnalysis(it).flatMap {
                LoopTools.findPattern($0, bpm: bpm, offset: it.beatOffset, timeSig: it.timeSig)
            }
            DispatchQueue.main.async {
                self.loopToolBusy = false
                guard let p = found, self.current?.id == it.id, let bar = it.barSeconds else {
                    self.status = "No clear repeating pattern found."
                    return
                }
                let end = p.start + Double(p.bars) * bar
                let jumped = self.engine.isPlaying && self.engine.queueLoopJump(start: p.start, end: end)
                self.update { $0.loopStart = p.start; $0.loopEnd = end; $0.loopOn = true }
                if !jumped { self.seek(to: p.start) }
                self.status = "Found a \(p.bars)-bar pattern (\(formatTime(p.start)) to \(formatTime(end)), \(Int(p.score * 100))% alike)"
            }
        }
    }

    /// Saves a copy of the track with the loop section repeated to add about `bars` bars.
    func makeLonger(addBars bars: Int) {
        guard let it = current, it.kind != .groove, it.kind != .metronome,
              let ls = it.loopStart, let le = it.loopEnd, le > ls else { return }
        let sr = AudioData.sampleRate
        let a = Int(ls * sr), b = Int(le * sr)
        let loopBars = max(1, Int(((le - ls) / (it.barSeconds ?? (le - ls))).rounded()))
        let copies = max(1, Int(ceil(Double(bars) / Double(loopBars))))
        let added = Double(copies) * (le - ls)
        loopToolBusy = true
        status = "Making a longer copy…"
        loadQueue.async { [weak self] in
            guard let self = self else { return }
            var stems: [Stem] = []
            for st in it.stems {
                guard let d = self.cachedLoad(st.file) else { continue }
                let longer = LoopTools.extend(d, loopStart: a, loopEnd: min(b, d.frames), copies: copies)
                let file = "\(UUID().uuidString).m4a"
                if (try? AudioLoader.writeLossless(longer, from: 0, to: longer.frames, url: Paths.audio.appendingPathComponent(file))) != nil {
                    var ns = st; ns.id = UUID(); ns.file = file
                    stems.append(ns)
                }
            }
            DispatchQueue.main.async {
                self.loopToolBusy = false
                guard stems.count == it.stems.count else { self.lastError = "Could not make the longer copy."; self.status = ""; return }
                var copy = it
                copy.id = UUID()
                copy.title = "\(it.title) (+\(copies * loopBars) bars)"
                copy.stems = stems
                copy.duration = it.duration + added
                copy.markers = it.markers.map { var m = $0; m.id = UUID(); if m.time >= le { m.time += added }; return m }
                copy.regions = it.regions?.map { var r = $0; r.id = UUID(); if r.start >= le { r.start += added; r.end += added }; return r }
                copy.loopOn = false
                copy.added = Date()
                self.items.append(copy)
                self.status = "Saved \"\(copy.title)\" (\(formatTime(copy.duration)) long)"
                self.scheduleSave()
            }
        }
    }

    // MARK: markers
    func addMarker(_ cue: String) {
        let t = clock.position
        update { $0.markers.append(Marker(time: t, cue: cue)); $0.markers.sort { $0.time < $1.time } }
    }

    func removeMarker(_ id: UUID) { update { $0.markers.removeAll { $0.id == id } } }

    /// Adds a finished item (e.g. from the Stem Maker) to the library.
    func addItem(_ item: LibraryItem) {
        items.append(item)
        status = "Added \"\(item.title)\""
        scheduleSave()
    }

    // MARK: library edits
    func rename(_ id: UUID, to title: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].title = title
        if current?.id == id { current?.title = title }
        scheduleSave()
    }

    func delete(_ ids: Set<UUID>) {
        let removed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        for i in setlists.indices {
            for j in setlists[i].sections.indices { setlists[i].sections[j].entries.removeAll { ids.contains($0.itemID) } }
        }
        let stillUsed = Set(items.flatMap { $0.stems.map(\.file) })
        for f in Set(removed.flatMap { $0.stems.map(\.file) }) where !stillUsed.contains(f) {
            try? FileManager.default.removeItem(at: Paths.audio.appendingPathComponent(f))
        }
        if let c = current, ids.contains(c.id) {
            pause(); current = nil; peaks = []
            engine.load(stems: [], length: 1)
        }
        scheduleSave()
    }

    // MARK: services (setlists)
    func entry(_ id: UUID?) -> SetEntry? {
        guard let id = id, let p = entryPath(id) else { return nil }
        return setlists[p.0].sections[p.1].entries[p.2]
    }

    func entryPath(_ id: UUID) -> (Int, Int, Int)? {
        for (si, sl) in setlists.enumerated() {
            if let loc = sl.locate(id) { return (si, loc.section, loc.entry) }
        }
        return nil
    }

    func newService(date: Date, name: String? = nil) -> UUID {
        let s = Setlist(name: name ?? Setlist.defaultName(for: date), date: date)
        setlists.append(s)
        sortServices()
        scheduleSave()
        return s.id
    }

    /// Copies a service's plan (sections, songs and their per-service settings) to a new date.
    func duplicateService(_ id: UUID, to date: Date) -> UUID? {
        guard let src = setlists.first(where: { $0.id == id }) else { return nil }
        var copy = Setlist(name: Setlist.defaultName(for: date), date: date,
                           sections: src.sections.map { sec in
                               SetSection(name: sec.name, entries: sec.entries.map { var e = $0; e.id = UUID(); return e })
                           })
        copy.id = UUID()
        setlists.append(copy)
        sortServices()
        scheduleSave()
        return copy.id
    }

    private func sortServices() {
        setlists.sort { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
    }

    func add(_ itemIDs: [UUID], to setlistID: UUID, section sectionID: UUID? = nil) {
        guard let i = setlists.firstIndex(where: { $0.id == setlistID }) else { return }
        if setlists[i].sections.isEmpty { setlists[i].sections = [SetSection(name: "Songs")] }
        let si = sectionID.flatMap { sid in setlists[i].sections.firstIndex { $0.id == sid } } ?? 0
        setlists[i].sections[si].entries.append(contentsOf: itemIDs.map { SetEntry(itemID: $0) })
        scheduleSave()
    }

    func removeEntries(_ setlistID: UUID, section: UUID, at offsets: IndexSet) {
        guard let i = setlists.firstIndex(where: { $0.id == setlistID }),
              let si = setlists[i].sections.firstIndex(where: { $0.id == section }) else { return }
        setlists[i].sections[si].entries.remove(atOffsets: offsets)
        scheduleSave()
    }

    func moveEntries(_ setlistID: UUID, section: UUID, from: IndexSet, to: Int) {
        guard let i = setlists.firstIndex(where: { $0.id == setlistID }),
              let si = setlists[i].sections.firstIndex(where: { $0.id == section }) else { return }
        setlists[i].sections[si].entries.move(fromOffsets: from, toOffset: to)
        scheduleSave()
    }

    /// Clears an entry's own tempo/key/loop so it follows the library item again.
    func resetEntry(_ entryID: UUID) {
        guard let p = entryPath(entryID) else { return }
        let (s, sec, e) = p
        let itemID = setlists[s].sections[sec].entries[e].itemID
        setlists[s].sections[sec].entries[e] = SetEntry(id: entryID, itemID: itemID)
        if currentEntry == entryID, let base = items.first(where: { $0.id == itemID }) {
            current?.rate = base.rate; current?.semitones = base.semitones
            current?.loopOn = base.loopOn; current?.loopStart = base.loopStart; current?.loopEnd = base.loopEnd
            applyToEngine()
        }
        scheduleSave()
    }

    func addSection(_ setlistID: UUID, name: String) {
        guard let i = setlists.firstIndex(where: { $0.id == setlistID }) else { return }
        setlists[i].sections.append(SetSection(name: name))
        scheduleSave()
    }

    func renameSection(_ setlistID: UUID, section: UUID, to name: String) {
        guard let i = setlists.firstIndex(where: { $0.id == setlistID }),
              let si = setlists[i].sections.firstIndex(where: { $0.id == section }) else { return }
        setlists[i].sections[si].name = name
        scheduleSave()
    }

    func removeSection(_ setlistID: UUID, section: UUID) {
        guard let i = setlists.firstIndex(where: { $0.id == setlistID }) else { return }
        setlists[i].sections.removeAll { $0.id == section }
        scheduleSave()
    }

    func moveSection(_ setlistID: UUID, section: UUID, by delta: Int) {
        guard let i = setlists.firstIndex(where: { $0.id == setlistID }),
              let si = setlists[i].sections.firstIndex(where: { $0.id == section }) else { return }
        let to = si + delta
        guard to >= 0, to < setlists[i].sections.count else { return }
        setlists[i].sections.swapAt(si, to)
        scheduleSave()
    }

    func deleteSetlist(_ id: UUID) {
        setlists.removeAll { $0.id == id }
        if activeSetlist == id { activeSetlist = nil }
        scheduleSave()
    }

    func renameSetlist(_ id: UUID, to name: String) {
        guard let i = setlists.firstIndex(where: { $0.id == id }) else { return }
        setlists[i].name = name
        scheduleSave()
    }

    /// Opens a service entry and makes that service the one N / B step through.
    func openEntry(_ entryID: UUID, in setlistID: UUID, autoplay: Bool = false) {
        guard let e = entry(entryID) else { return }
        activeSetlist = setlistID
        open(e.itemID, autoplay: autoplay, entry: entryID)
    }

    private func neighbour(_ step: Int) -> (entry: SetEntry, item: LibraryItem)? {
        guard let sid = activeSetlist, let s = setlists.first(where: { $0.id == sid }) else { return nil }
        let all = s.allEntries
        guard !all.isEmpty else { return nil }
        let idx: Int
        if let cur = currentEntry, let i = all.firstIndex(where: { $0.id == cur }) {
            idx = i + step
        } else {
            idx = step > 0 ? 0 : -1
        }
        guard idx >= 0, idx < all.count, let item = items.first(where: { $0.id == all[idx].itemID }) else { return nil }
        return (all[idx], item)
    }

    func nextInSetlist() -> (entry: SetEntry, item: LibraryItem)? { neighbour(1) }
    func previousInSetlist() -> (entry: SetEntry, item: LibraryItem)? { neighbour(-1) }

    func playNext() { if let n = nextInSetlist(), let sid = activeSetlist { openEntry(n.entry.id, in: sid) } }
    func playPrevious() { if let p = previousInSetlist(), let sid = activeSetlist { openEntry(p.entry.id, in: sid) } }

    /// "Worship · 2 of 5" for the loaded service song.
    var entryPosition: String? {
        guard let eid = currentEntry, let sid = activeSetlist, let s = setlists.first(where: { $0.id == sid }),
              let loc = s.locate(eid) else { return nil }
        return "\(s.sections[loc.section].name) · \(loc.entry + 1) of \(s.sections[loc.section].entries.count)"
    }
}
