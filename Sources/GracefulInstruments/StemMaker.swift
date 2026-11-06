import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Splits a song into stems (vocals, drums, bass, other...) with the Demucs model, running offline
/// in a local Python install under ~/Music/Graceful Instruments/stemmaker. Jobs run one at a time at low priority.
final class StemMaker: ObservableObject {
    static weak var shared: StemMaker?

    struct Job: Identifiable {
        let id = UUID()
        var title: String
        var itemID: UUID
        var sixStems: Bool
        var best: Bool
        var progress: Double = 0
        var status = "Waiting"
        var state: State = .queued
        var resultID: UUID?
        enum State { case queued, running, done, failed, cancelled }
    }

    @Published var jobs: [Job] = []
    @Published var installing = false
    @Published var installStep = ""
    @Published var installed = false

    weak var model: AppModel?
    private var process: Process?
    private var runningID: UUID?

    var root: URL { Paths.base.appendingPathComponent("stemmaker", isDirectory: true) }
    var python: URL { root.appendingPathComponent("python/bin/python3") }
    var scripts: URL? { Bundle.main.resourceURL?.appendingPathComponent("StemMaker") }

    init() {
        StemMaker.shared = self
        refreshInstalled()
    }

    func refreshInstalled() {
        installed = FileManager.default.fileExists(atPath: root.appendingPathComponent("installed").path)
            && FileManager.default.isExecutableFile(atPath: python.path)
    }

    // MARK: install
    func install() {
        guard !installing, let script = scripts?.appendingPathComponent("install.sh") else { return }
        installing = true
        installStep = "Starting…"
        var lastError = ""
        run(URL(fileURLWithPath: "/bin/bash"), [script.path], onLine: { [weak self] line in
            if line.hasPrefix("STEP: ") { self?.installStep = String(line.dropFirst(6)) }
            if line.hasPrefix("ERROR") { lastError = line }
        }, done: { [weak self] code in
            guard let self = self else { return }
            self.installing = false
            self.refreshInstalled()
            if code != 0 || !self.installed {
                self.installStep = lastError.isEmpty ? "Install failed. Check the internet connection and try again." : lastError
            }
        })
    }

    // MARK: jobs
    func enqueue(_ itemID: UUID, sixStems: Bool, best: Bool = false) {
        guard let item = model?.items.first(where: { $0.id == itemID }) else { return }
        jobs.insert(Job(title: item.title + (best ? " (best quality)" : ""), itemID: itemID, sixStems: sixStems, best: best), at: 0)
        startNext()
    }

    func cancel(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        if runningID == id { process?.terminate() }
        jobs[i].state = .cancelled
        jobs[i].status = "Cancelled"
    }

    func cancelAll() {
        process?.terminate()
    }

    func clearFinished() {
        jobs.removeAll { $0.state == .done || $0.state == .failed || $0.state == .cancelled }
    }

    private func startNext() {
        guard runningID == nil, installed, let script = scripts?.appendingPathComponent("separate.py"),
              let i = jobs.lastIndex(where: { $0.state == .queued }),
              let item = model?.items.first(where: { $0.id == jobs[i].itemID }),
              let stem = item.stems.first(where: { !$0.inEarsOnly }) ?? item.stems.first else { return }
        let job = jobs[i]
        runningID = job.id
        jobs[i].state = .running
        jobs[i].status = "Preparing audio"
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("gi-stems-\(job.id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let input = work.appendingPathComponent("input.wav")
        let outDir = work.appendingPathComponent("out", isDirectory: true)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            do {
                let audio = try AudioLoader.load(Paths.audio.appendingPathComponent(stem.file))
                try AudioLoader.writeWAV(audio, url: input)
            } catch {
                DispatchQueue.main.async { self.finish(job.id, error: "Could not read the audio file.", work: work) }
                return
            }
            DispatchQueue.main.async {
                self.update(job.id) { $0.status = "Loading the model" }
                // Best quality: the fine-tuned 4-stem model (about 4x slower), or two passes of the 6-stem one.
                let modelName = job.sixStems ? "htdemucs_6s" : (job.best ? "htdemucs_ft" : "htdemucs")
                let shifts = job.sixStems && job.best ? "2" : "1"
                var stems: [String] = []
                var gain: Float = 1
                var lastError = ""
                // `nice` keeps playback smooth while the split runs.
                self.run(URL(fileURLWithPath: "/usr/bin/nice"),
                         ["-n", "15", self.python.path, script.path, input.path, outDir.path, modelName, shifts],
                         onLine: { line in
                    if line.hasPrefix("PROGRESS "), let p = Double(line.dropFirst(9)) {
                        self.update(job.id) { $0.progress = p / 100; $0.status = "Separating… \(Int(p))%" }
                    } else if line.hasPrefix("GAIN "), let g = Float(line.dropFirst(5)) {
                        gain = g
                    } else if line.hasPrefix("DONE ") {
                        stems = line.dropFirst(5).split(separator: ",").map(String.init)
                    } else if line.contains("Error") || line.hasPrefix("ERROR") {
                        lastError = line
                    }
                }, done: { code in
                    if code == 0 && !stems.isEmpty {
                        self.addResult(job, item: item, stems: stems, gain: gain, outDir: outDir, work: work)
                    } else {
                        let cancelled = self.jobs.first { $0.id == job.id }?.state == .cancelled
                        self.finish(job.id, error: cancelled ? nil : (lastError.isEmpty ? "Separation failed." : lastError), work: work)
                    }
                })
            }
        }
    }

    private func addResult(_ job: Job, item: LibraryItem, stems: [String], gain: Float, outDir: URL, work: URL) {
        var result = LibraryItem(title: "\(item.title) (stems)", kind: .stems)
        let order = ["vocals", "drums", "bass", "guitar", "piano", "other"]
        for name in stems.sorted(by: { (order.firstIndex(of: $0) ?? 9) < (order.firstIndex(of: $1) ?? 9) }) {
            let src = outDir.appendingPathComponent("\(name).flac")
            let file = "\(UUID().uuidString).flac"
            do {
                try FileManager.default.moveItem(at: src, to: Paths.audio.appendingPathComponent(file))
                result.stems.append(Stem(name: name == "other" ? "Other (keys, pads…)" : name.capitalized, file: file, volume: gain))
            } catch { continue }
        }
        guard !result.stems.isEmpty else { finish(job.id, error: "No stems were written.", work: work); return }
        // The stems line up sample-for-sample with the original, so its tempo and beat grid carry over.
        result.bpm = item.bpm
        result.beatOffset = item.beatOffset
        result.timeSig = item.timeSig
        result.category = item.category
        result.duration = item.duration
        result.markers = item.markers
        result.analyzed = item.analyzed
        model?.addItem(result)
        update(job.id) { $0.resultID = result.id }
        finish(job.id, error: nil, work: work)
    }

    private func finish(_ id: UUID, error: String?, work: URL) {
        try? FileManager.default.removeItem(at: work)
        update(id) { j in
            if j.state == .cancelled { return }
            if let e = error { j.state = .failed; j.status = e } else { j.state = .done; j.progress = 1; j.status = "Done" }
        }
        process = nil
        runningID = nil
        startNext()
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
    }

    private func run(_ exe: URL, _ args: [String], onLine: @escaping (String) -> Void, done: @escaping (Int32) -> Void) {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        // The output buffer is only touched on this one queue (the read and exit handlers run on different threads).
        let q = DispatchQueue(label: "gi.process-output")
        var buffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            q.async {
                buffer.append(chunk)
                while let nl = buffer.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                    let lineData = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                        DispatchQueue.main.async { onLine(line) }
                    }
                }
            }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            let status = proc.terminationStatus
            q.async {
                let tail = String(data: buffer + rest, encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    for l in tail.split(whereSeparator: \.isNewline) { onLine(String(l)) }
                    done(status)
                }
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            DispatchQueue.main.async { onLine("ERROR: \(error.localizedDescription)"); done(-1) }
        }
    }
}

// MARK: - Screen

struct StemMakerView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var maker: StemMaker
    @State private var sixStems = false
    @State private var best = true
    @State private var picking = false
    @State private var dropTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Stem Maker").font(.system(size: 17, weight: .bold))
                Caption("Splits a song into separate parts so you can mute the vocals for a backing track, play just the drums, and so on. Runs on this Mac, no internet needed.")

                if !maker.installed {
                    Card("Setup (one time)") {
                        Caption("Downloads the separation engine (about 1.5 GB). Needs internet once.")
                        HStack {
                            Button(maker.installing ? "Installing…" : "Install Stem Maker") { maker.install() }
                                .big(.primary).disabled(maker.installing)
                            if maker.installing { ProgressView().scaleEffect(0.5) }
                        }
                        if !maker.installStep.isEmpty { Caption(maker.installStep) }
                    }
                } else {
                    Card("Split a song") {
                        Picker("", selection: $sixStems) {
                            Text("4 parts: vocals, drums, bass, other").tag(false)
                            Text("6 parts: adds guitar and piano").tag(true)
                        }
                        .pickerStyle(RadioGroupPickerStyle())
                        .labelsHidden()
                        Picker("", selection: $best) {
                            Text("Best quality (takes about 4× the song's length to process)").tag(true)
                            Text("Quick (takes about the song's length)").tag(false)
                        }
                        .pickerStyle(RadioGroupPickerStyle())
                        .labelsHidden()
                        if let cur = model.current, cur.kind == .song || cur.kind == .loop {
                            Button(action: { maker.enqueue(cur.id, sixStems: sixStems, best: best) }) {
                                IconLabel(systemName: "wand.and.stars", title: "Split \"\(cur.title)\"").frame(maxWidth: .infinity)
                            }
                            .big(.primary, height: Size.big, fullWidth: true)
                        }
                        Button(action: { picking = true }) { IconLabel(systemName: "music.note.list", title: "Choose from Library…").frame(maxWidth: .infinity) }
                            .big(fullWidth: true)
                        dropZone
                        Caption("Best quality on a 5-minute song takes about 25 minutes on this MacBook, so start it during the week and keep the app open. For long loop videos, use Save as Loop first and split the short loop. The stems always add back up to the original, so muting the vocals leaves the instruments untouched.")
                    }
                }

                if !maker.jobs.isEmpty {
                    Card("Jobs") {
                        ForEach(maker.jobs) { job in jobRow(job) }
                        if maker.jobs.contains(where: { $0.state != .queued && $0.state != .running }) {
                            Button("Clear finished") { maker.clearFinished() }.big(height: Size.small)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Stem Maker")
        .sheet(isPresented: $picking) {
            PickOneSheet(title: "Choose a song to split") { id in
                picking = false
                if let id = id { maker.enqueue(id, sixStems: sixStems, best: best) }
            }
            .environmentObject(model)
        }
    }

    var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.and.arrow.down").font(.system(size: 22))
            Text("Or drop an audio file here").font(.caption).lineLimit(1)
        }
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, minHeight: 70)
        .background(RoundedRectangle(cornerRadius: 8).stroke(dropTargeted ? Color.accentColor : Color(NSColor.separatorColor),
                                                             style: StrokeStyle(lineWidth: 2, dash: [5])))
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            loadURLs(providers) { urls in
                // The original goes into the library too (so its tempo is found), then gets split.
                for u in urls {
                    // A song already in the library is split from there instead of being imported twice.
                    let ids = model.existingItem(sameAudioAs: u).map { [$0.id] } ?? model.importFiles([u])
                    for id in ids { maker.enqueue(id, sixStems: sixStems, best: best) }
                }
            }
            return true
        }
    }

    func jobRow(_ job: StemMaker.Job) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: job.state == .done ? "checkmark.circle.fill" : job.state == .failed ? "xmark.octagon.fill"
                      : job.state == .cancelled ? "minus.circle" : "waveform")
                    .foregroundColor(job.state == .done ? .green : job.state == .failed ? .red : .secondary)
                Text(job.title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if job.state == .queued || job.state == .running {
                    Button("Cancel") { maker.cancel(job.id) }.buttonStyle(BorderlessButtonStyle())
                } else if let r = job.resultID {
                    Button("Open") { model.open(r) }.buttonStyle(BorderlessButtonStyle())
                }
            }
            if job.state == .running { ProgressView(value: job.progress) }
            Text(job.status).font(.caption).foregroundColor(.secondary).lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

/// Library picker for a single item.
struct PickOneSheet: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let done: (UUID?) -> Void
    @State private var filter = LibraryFilter()
    @State private var picked: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            FilterBar(filter: $filter)
            List(selection: $picked) {
                ForEach(filter.apply(model.items, model: model, kinds: [.song, .loop])) { item in
                    ItemRow(item: item, category: model.category(of: item), analyzing: false, loaded: false, loading: false)
                        .tag(item.id)
                }
            }
            .frame(height: 340)
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Split") { done(picked) }.disabled(picked == nil).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 480)
    }
}
