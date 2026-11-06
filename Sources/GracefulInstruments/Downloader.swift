import Foundation

/// Downloads audio from a YouTube link with yt-dlp, then imports it into the library.
/// yt-dlp lives in ~/Music/Graceful Instruments/bin so the app can update it without admin rights.
final class Downloader: ObservableObject {
    struct Job: Identifiable {
        let id = UUID()
        var url: String
        var title: String = ""
        var artist: String = ""
        var progress: Double = 0
        var state: State = .running
        var message = ""
        enum State { case running, done, failed }
    }

    @Published var jobs: [Job] = []
    @Published var updating = false
    @Published var updateMessage = ""

    weak var model: AppModel?
    static weak var shared: Downloader?
    init() { Downloader.shared = self }

    var ytdlp: URL { Paths.bin.appendingPathComponent("yt-dlp") }
    var deno: URL { Paths.bin.appendingPathComponent("deno") }
    var installed: Bool { FileManager.default.isExecutableFile(atPath: ytdlp.path) }

    func download(_ link: String) {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }
        guard installed else {
            jobs.insert(Job(url: link, state: .failed, message: "The downloader is not installed yet. Click \"Update downloader\"."), at: 0)
            return
        }
        // The same video downloaded again would only make a second copy.
        if let m = model, let vid = Downloader.videoID(link),
           let have = m.items.first(where: { $0.sourceURL.flatMap(Downloader.videoID) == vid }) {
            jobs.insert(Job(url: link, title: have.title, state: .done, message: "Already in the library as \"\(have.title)\""), at: 0)
            return
        }
        let job = Job(url: link, title: link)
        jobs.insert(job, at: 0)
        let id = job.id
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gi-dl-\(id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        var args = ["-f", "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/best[ext=mp4]",
                    "--no-playlist", "--newline", "--no-mtime", "--no-part",
                    "-o", tmp.appendingPathComponent("%(title).150B.%(ext)s").path,
                    "--print", "after_move:GI_FILE:%(filepath)s",
                    "--print", "before_dl:GI_TITLE:%(title)s",
                    "--print", "before_dl:GI_ARTIST:%(artist,creator)s"]
        if FileManager.default.isExecutableFile(atPath: deno.path) {
            args += ["--js-runtimes", "deno:\(deno.path)"]
        }
        args.append(link)

        run(args, onLine: { [weak self] line in
            guard let self = self, let i = self.jobs.firstIndex(where: { $0.id == id }) else { return }
            if line.hasPrefix("GI_ARTIST:") {
                let a = String(line.dropFirst(10))
                self.jobs[i].artist = a == "NA" ? "" : a
            } else if line.hasPrefix("GI_TITLE:") {
                self.jobs[i].title = String(line.dropFirst(9))
            } else if line.hasPrefix("GI_FILE:") {
                self.jobs[i].message = String(line.dropFirst(8))
            } else if line.contains("[download]"), let r = line.range(of: #"(\d+(\.\d+)?)%"#, options: .regularExpression) {
                self.jobs[i].progress = (Double(line[r].dropLast()) ?? 0) / 100
            } else if line.hasPrefix("ERROR") {
                self.jobs[i].message = line
            }
        }, done: { [weak self] code in
            guard let self = self, let i = self.jobs.firstIndex(where: { $0.id == id }) else { return }
            let path = self.jobs[i].message
            if code == 0, !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                let title = self.jobs[i].title
                if let have = self.model?.existingItem(sameAudioAs: URL(fileURLWithPath: path)) {
                    self.jobs[i].state = .done
                    self.jobs[i].progress = 1
                    self.jobs[i].message = "Already in the library as \"\(have.title)\""
                    try? FileManager.default.removeItem(at: tmp)
                    return
                }
                let added = self.model?.importFiles([URL(fileURLWithPath: path)], title: title, move: true) ?? []
                self.jobs[i].state = added.isEmpty ? .failed : .done
                self.jobs[i].progress = 1
                self.jobs[i].message = added.isEmpty ? "Downloaded but could not import" : "Added to library"
                if let model = self.model {
                    let artist = self.jobs[i].artist
                    for id in added {
                        if let k = model.items.firstIndex(where: { $0.id == id }) {
                            model.items[k].sourceURL = link
                            if !artist.isEmpty { model.items[k].artist = artist }
                        }
                        model.autoFindLyrics(id)
                    }
                    model.scheduleSave()
                }
            } else {
                self.jobs[i].state = .failed
                if self.jobs[i].message.isEmpty || !self.jobs[i].message.hasPrefix("ERROR") {
                    self.jobs[i].message = "Download failed. Check the link and the internet connection, or update the downloader."
                }
            }
            try? FileManager.default.removeItem(at: tmp)
        })
    }

    /// The YouTube video id in a link (watch?v=, youtu.be/, shorts/), so two spellings of one link match.
    static func videoID(_ link: String) -> String? {
        guard let c = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        if let v = c.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty { return v }
        let parts = c.path.split(separator: "/").map(String.init)
        if c.host?.contains("youtu.be") == true { return parts.first }
        if let i = parts.firstIndex(where: { $0 == "shorts" || $0 == "embed" || $0 == "live" }), i + 1 < parts.count { return parts[i + 1] }
        return nil
    }

    /// Downloads a video's English captions (made by the uploader if there are any, otherwise YouTube's automatic ones).
    func captions(for link: String, completion: @escaping ([LyricLine]) -> Void) {
        guard installed else { completion([]); return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gi-subs-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        var args = ["--skip-download", "--no-playlist", "--write-subs", "--write-auto-subs", "--sub-langs", "en,en-US,en-GB,en.*",
                    "--sub-format", "vtt", "-o", tmp.appendingPathComponent("subs").path]
        if FileManager.default.isExecutableFile(atPath: deno.path) { args += ["--js-runtimes", "deno:\(deno.path)"] }
        args.append(link)
        run(args, onLine: { _ in }, done: { _ in
            let files = ((try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "vtt" }
                .sorted { $0.lastPathComponent.count < $1.lastPathComponent.count } // "subs.en.vtt" before "subs.en-orig.vtt"
            var lines: [LyricLine] = []
            for f in files {
                if let text = try? String(contentsOf: f, encoding: .utf8) {
                    lines = LyricsFinder.parseVTT(text)
                    if lines.count > 4 { break }
                }
            }
            try? FileManager.default.removeItem(at: tmp)
            completion(lines)
        })
    }

    /// Installs or updates yt-dlp from its official GitHub releases.
    func update() {
        updating = true
        updateMessage = "Updating downloader..."
        let url = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
        URLSession.shared.downloadTask(with: url) { [weak self] tmp, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.updating = false
                guard let tmp = tmp, err == nil, (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    self.updateMessage = "Update failed: \(err?.localizedDescription ?? "no internet?")"
                    return
                }
                Paths.ensure()
                try? FileManager.default.removeItem(at: self.ytdlp)
                do {
                    try FileManager.default.moveItem(at: tmp, to: self.ytdlp)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: self.ytdlp.path)
                    self.run(["--version"], onLine: { v in self.updateMessage = "Downloader ready (version \(v))" }, done: { _ in })
                } catch {
                    self.updateMessage = "Update failed: \(error.localizedDescription)"
                }
            }
        }.resume()
    }

    private func run(_ args: [String], onLine: @escaping (String) -> Void, done: @escaping (Int32) -> Void) {
        let p = Process()
        p.executableURL = ytdlp
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(Paths.bin.path):/usr/bin:/bin:/usr/sbin:/sbin"
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
        do { try p.run() } catch {
            DispatchQueue.main.async { onLine("ERROR: \(error.localizedDescription)"); done(-1) }
        }
    }
}
