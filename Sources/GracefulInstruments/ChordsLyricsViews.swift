import SwiftUI
import AppKit

enum PlayerTab: String, CaseIterable, Identifiable {
    case controls, loop, cues, chords, lyrics
    var id: String { rawValue }
    var label: String {
        switch self {
        case .controls: return "Tempo & Sound"
        case .loop: return "Loop"
        case .cues: return "Cues"
        case .chords: return "Chords"
        case .lyrics: return "Lyrics"
        }
    }
}

// MARK: - Chords

struct ChordsPanel: View {
    @EnvironmentObject var model: AppModel
    let item: LibraryItem
    @AppStorage("chordNumbers") private var numbers = false
    @AppStorage("chordSimple") private var simple = false

    struct Bar: Identifiable, Equatable {
        let id: Int
        let start: Double
        let text: String
        let repeatOfPrevious: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let chart = item.chords {
                header(chart)
                ScrollView {
                    LiveChart(bars: bars(chart), firstBar: firstBar, barLen: item.barSeconds ?? 2) { t in model.seek(to: t) }
                        .padding(.bottom, 8)
                }
            } else if model.chordsBusy.contains(item.id) {
                HStack(spacing: 8) { ProgressView().scaleEffect(0.6); Text("Working out the key and chords…").foregroundColor(.secondary) }
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No chord chart yet").font(.headline)
                    Button(action: { model.queueChords(item.id) }) { IconLabel(systemName: "pianokeys", title: "Find Key and Chords") }
                        .big(.primary).disabled(item.kind == .groove)
                    Caption("The app listens to the track (leaving out vocals and drums when it has stems) and writes out the chords bar by bar. Set the track's tempo first for a cleaner chart.")
                }
                Spacer()
            }
        }
    }

    func header(_ chart: ChordChart) -> some View {
        let playing = chart.key.transposed(item.semitones)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Key").foregroundColor(.secondary)
                Text(playing.longName).font(.system(size: 17, weight: .bold)).lineLimit(1)
                if item.semitones != 0 {
                    Text("(original \(chart.key.name), \(item.semitones > 0 ? "+" : "")\(item.semitones))")
                        .foregroundColor(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Segments([(false, "Chords"), (true, "Numbers")], selection: $numbers).frame(width: 160)
                Button(action: { simple.toggle() }) { Text("Simple") }.big(simple ? .primary : .normal, height: 30)
                    .help("Show plain major and minor chords only")
                SquareButton(systemName: "arrow.clockwise", size: 30, help: "Work out the chords again (after fixing the tempo or beat one)") { model.queueChords(item.id) }
                    .disabled(model.chordsBusy.contains(item.id))
            }
            Caption("Worked out by ear from the recording: check it against what you hear. Click a bar to jump there.")
        }
    }

    func label(_ s: ChordSeg, _ chart: ChordChart) -> String {
        let key = chart.key.transposed(item.semitones)
        if numbers { return s.number(in: chart.key, simple: simple) }
        return s.symbol(transpose: item.semitones, flats: key.usesFlats, simple: simple)
    }

    func bars(_ chart: ChordChart) -> [Bar] {
        let barLen = item.barSeconds ?? 2
        let beat = item.beatSeconds ?? 0.5
        var first = item.bpm != nil ? item.beatOffset.truncatingRemainder(dividingBy: barLen) : 0
        if first > 0.05 { first -= barLen }
        var out: [Bar] = []
        var t = max(first, -barLen)
        var prev = ""
        var i = 0
        while t < item.duration - 0.05 {
            let a = t, b = t + barLen
            var names: [String] = []
            for s in chart.segs where s.end > a + beat * 0.4 && s.start < b - beat * 0.4 {
                let n = label(s, chart)
                if names.last != n { names.append(n) }
            }
            let text = names.isEmpty ? "" : names.prefix(3).joined(separator: "  ")
            out.append(Bar(id: i, start: max(0, a), text: text, repeatOfPrevious: text == prev && !text.isEmpty))
            prev = text
            t += barLen; i += 1
        }
        return out
    }

    var firstBar: Double {
        let barLen = item.barSeconds ?? 2
        var first = item.bpm != nil ? item.beatOffset.truncatingRemainder(dividingBy: barLen) : 0
        if first > 0.05 { first -= barLen }
        return max(first, -barLen)
    }
}

/// Only this follows the playhead; the chart itself is worked out once.
struct LiveChart: View {
    @ObservedObject var clock = AppModelHolder.clock
    let bars: [ChordsPanel.Bar]
    let firstBar: Double
    let barLen: Double
    let seek: (Double) -> Void
    var body: some View {
        ChartGrid(bars: bars, current: Int(floor((clock.position - firstBar) / barLen)), seek: seek).equatable()
    }
}

struct ChartGrid: View, Equatable {
    let bars: [ChordsPanel.Bar]
    let current: Int
    let seek: (Double) -> Void

    static func == (a: ChartGrid, b: ChartGrid) -> Bool { a.bars == b.bars && a.current == b.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<(bars.count + 3) / 4, id: \.self) { row in
                HStack(spacing: 4) {
                    Text("\(row * 4 + 1)").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                        .frame(width: 26, alignment: .trailing)
                    ForEach(bars[(row * 4)..<min(row * 4 + 4, bars.count)]) { bar in
                        BarCell(bar: bar, current: bar.id == current)
                            .onTapGesture { seek(bar.start) }
                    }
                    if row * 4 + 4 > bars.count { Spacer() }
                }
            }
        }
    }
}

struct BarCell: View, Equatable {
    let bar: ChordsPanel.Bar
    let current: Bool
    var body: some View {
        Text(bar.text.isEmpty ? " " : bar.text)
            .font(.system(size: 15, weight: current ? .bold : .semibold))
            .foregroundColor(current ? .white : (bar.repeatOfPrevious ? .secondary : .primary))
            .lineLimit(1).minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 6).fill(current ? Color.accentColor : Color(NSColor.controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor), lineWidth: 1))
            .contentShape(Rectangle())
    }
}

// MARK: - Lyrics

struct LyricsPanel: View {
    @EnvironmentObject var model: AppModel
    let item: LibraryItem
    @State private var finding = false
    @AppStorage("lyricsSize") private var size: Double = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let ly = item.lyrics {
                HStack(spacing: 8) {
                    Text(ly.matchTitle ?? ly.source).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
                    Text("· \(ly.isTimed ? "timed" : "words only") · \(ly.source)").font(.caption).foregroundColor(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    if ly.isTimed {
                        SquareButton(systemName: "minus", size: 30, help: "Lyrics too late: show them earlier") { model.nudgeLyrics(-0.5) }
                        Text(String(format: "%+.1f s", ly.offset)).font(.caption).frame(width: 42)
                        SquareButton(systemName: "plus", size: 30, help: "Lyrics too early: show them later") { model.nudgeLyrics(0.5) }
                    }
                    SquareButton(systemName: "textformat.size", size: 30, help: "Bigger or smaller text") { size = size >= 26 ? 14 : size + 4 }
                    Button(action: { exportPDF(ly) }) { IconLabel(systemName: "square.and.arrow.up", title: "PDF") }
                        .big(height: 30)
                        .help("Save the lyrics as a PDF in the Lyrics Export folder on the Desktop, to share on WhatsApp")
                    Button("Change…") { finding = true }.big(height: 30)
                }
                if ly.isTimed, let lines = ly.lines {
                    LiveLyrics(lyrics: ly, lines: lines, size: size) { t in model.seek(to: max(0, t + ly.offset - 0.3)) }
                } else {
                    ScrollView {
                        Text(ly.plain).font(.system(size: CGFloat(size))).frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No lyrics yet").font(.headline)
                    Button(action: { finding = true }) { IconLabel(systemName: "text.magnifyingglass", title: "Find Lyrics…") }.big(.primary)
                    Caption("Searches a free lyrics library for this song and shows the versions whose length matches this recording first. Timed lyrics scroll along with the music.")
                }
                Spacer()
            }
        }
        .sheet(isPresented: $finding) {
            FindLyricsSheet(item: item) { finding = false }.environmentObject(model)
        }
        .onAppear { if CommandLine.arguments.contains("--findlyrics") { finding = true } }
    }

    func exportPDF(_ ly: Lyrics) {
        var details: [String] = []
        if let k = model.playingKey, model.current?.id == item.id { details.append("Key \(k.name)") }
        else if let k = item.chords?.key { details.append("Key \(k.transposed(item.semitones).name)") }
        if let b = item.playingBPM { details.append("\(formatBPM(b)) BPM") }
        details.append(item.timeSig.rawValue)
        let artist = item.artist ?? ly.matchTitle?.components(separatedBy: " - ").dropFirst().first
        do {
            let url = try LyricsPDF.export(title: item.title, artist: artist, details: details.joined(separator: "  ·  "), lyrics: ly.plain)
            model.status = "Saved \(url.lastPathComponent) in Lyrics Export"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            model.lastError = "Could not save the PDF: \(error.localizedDescription)"
        }
    }
}

/// Only this part follows the playhead, so the rest of the panel (and the Find Lyrics window) stays still.
struct LiveLyrics: View {
    @ObservedObject var clock = AppModelHolder.clock
    let lyrics: Lyrics
    let lines: [LyricLine]
    let size: Double
    let seek: (Double) -> Void
    var body: some View {
        TimedLyrics(lines: lines, current: lyrics.lineIndex(at: clock.position), size: size, seek: seek).equatable()
    }
}

struct TimedLyrics: View, Equatable {
    let lines: [LyricLine]
    let current: Int?
    let size: Double
    let seek: (Double) -> Void
    static func == (a: TimedLyrics, b: TimedLyrics) -> Bool { a.current == b.current && a.size == b.size && a.lines == b.lines }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                        Text(l.text.isEmpty ? "♪" : l.text)
                            .font(.system(size: CGFloat(i == current ? size + 4 : size), weight: i == current ? .bold : .regular))
                            .foregroundColor(i == current ? .primary : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .id(i)
                            .contentShape(Rectangle())
                            .onTapGesture { seek(l.time) }
                    }
                }
                .padding(.vertical, 60)
            }
            .onChange(of: current) { c in
                if let c = c { withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(c, anchor: .center) } }
            }
        }
    }
}

struct FindLyricsSheet: View {
    @EnvironmentObject var model: AppModel
    let item: LibraryItem
    let done: () -> Void
    @State private var query = ""
    @State private var results: [LyricsFinder.Result] = []
    @State private var picked: Int?
    @State private var searching = false
    @State private var error = ""
    @State private var pasting = false
    @State private var pasted = ""
    @State private var captionsBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Lyrics for \"\(item.title)\"").font(.headline).lineLimit(1).frame(width: 588, alignment: .leading)
            HStack(spacing: 6) {
                TextField("Song title and artist", text: $query, onCommit: search).textFieldStyle(RoundedBorderTextFieldStyle())
                Button("Search", action: search).disabled(query.isEmpty || searching)
                ProgressView().scaleEffect(0.5).frame(width: 16, height: 16).opacity(searching ? 1 : 0)
            }
            if pasting {
                Text("Paste or type the words (one line per line):").foregroundColor(.secondary)
                TextEditor(text: $pasted).font(.system(size: 13)).frame(height: 296)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(NSColor.separatorColor)))
            } else {
                HStack(alignment: .top, spacing: 10) {
                    List(selection: $picked) {
                        ForEach(results) { r in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.track).lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(r.artist).lineLimit(1)
                                    Text(formatTime(r.duration))
                                    if item.duration > 0 && r.lengthGap < 4 { Text("same length").foregroundColor(.green) }
                                    if r.synced != nil { Text("timed").foregroundColor(.accentColor) }
                                }
                                .font(.caption).foregroundColor(.secondary)
                            }
                            .tag(r.id)
                        }
                    }
                    .frame(width: 260, height: 320)
                    ScrollView {
                        Text(results.first { $0.id == picked }?.plain ?? (error.isEmpty ? "Pick a result to see its words." : error))
                            .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: 300, height: 320)
                }
            }
            HStack(spacing: 8) {
                Button(pasting ? "Back to search" : "Paste my own…") { pasting.toggle() }
                if item.sourceURL != nil {
                    Button("Use YouTube captions") { captions() }.disabled(captionsBusy)
                        .help("The captions on the YouTube video it was downloaded from (timed, but may have mistakes)")
                    ProgressView().scaleEffect(0.5).frame(width: 16, height: 16).opacity(captionsBusy ? 1 : 0)
                }
                if item.lyrics != nil { Button("Remove lyrics") { model.setLyrics(nil, for: item.id); done() } }
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Use These") { use() }.keyboardShortcut(.defaultAction)
                    .disabled(pasting ? pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : picked == nil)
            }
            Text("Lyrics come from LRCLIB, a free community lyrics library. For the band's own practice; for projecting to the church, use your licensed lyrics.")
                .font(.caption).foregroundColor(.secondary).lineLimit(2).frame(width: 588, height: 30, alignment: .topLeading)
        }
        .padding(16)
        .frame(width: 620, height: 520)
        .onAppear {
            query = [item.artist ?? "", LyricsFinder.searchText(item.title)].filter { !$0.isEmpty }.joined(separator: " ")
            pasted = item.lyrics?.plain ?? ""
            search()
        }
    }

    func search() {
        guard !query.isEmpty else { return }
        searching = true; error = ""
        LyricsFinder.search(query, duration: item.duration > 0 && item.kind != .loop ? item.duration : nil) { r, err in
            searching = false
            results = r
            picked = r.first?.id
            if let e = err { error = e } else if r.isEmpty { error = "Nothing found. Try fewer words, for example just the song title." }
        }
    }

    func captions() {
        guard let link = item.sourceURL, let dl = Downloader.shared else { return }
        captionsBusy = true
        dl.captions(for: link) { lines in
            captionsBusy = false
            guard lines.count > 3 else { error = "That video has no usable captions."; return }
            model.setLyrics(Lyrics(plain: lines.map(\.text).joined(separator: "\n"), lines: lines, source: "YouTube captions",
                                   matchTitle: item.title), for: item.id)
            done()
        }
    }

    func use() {
        if pasting {
            model.setLyrics(Lyrics(plain: pasted, lines: nil, source: "Pasted"), for: item.id)
        } else if let r = results.first(where: { $0.id == picked }) {
            model.setLyrics(LyricsFinder.lyrics(from: r), for: item.id)
        }
        done()
    }
}
