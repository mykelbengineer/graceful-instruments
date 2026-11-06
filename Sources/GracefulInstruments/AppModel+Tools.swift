import Foundation
import AppKit

extension AppModel {
    // MARK: chords and key

    /// Works out the key and chords of a library item in the background.
    /// Automatic jobs (background: true) wait while music is playing so they never compete with playback.
    func queueChords(_ id: UUID, background: Bool = false) {
        guard let item = items.first(where: { $0.id == id }), item.kind != .groove, item.kind != .metronome,
              !chordsBusy.contains(id) else { return }
        chordsBusy.insert(id)
        chordQueue.async { [weak self] in
            guard let self = self else { return }
            if background && self.engine.isPlaying {
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                    self.chordsBusy.remove(id)
                    self.queueChords(id, background: true)
                }
                return
            }
            // Leave out vocals, drums and click: chords come from the instruments.
            let skip = ["vocal", "vox", "bgv", "choir", "drum", "kick", "snare", "perc", "click", "guide", "cue", "count"]
            var stems = item.stems.filter { s in !s.inEarsOnly && !skip.contains { s.name.lowercased().contains($0) } }
            if stems.isEmpty { stems = item.stems.filter { !$0.inEarsOnly } }
            if stems.isEmpty { stems = item.stems }
            let urls = stems.map { Paths.audio.appendingPathComponent($0.file) }
            var chart: ChordChart?
            if let mix = AudioLoader.loadMonoMix(urls, maxSeconds: 720) {
                chart = Harmony.analyze(mix, bpm: item.bpm, offset: item.beatOffset, beatsPerBar: item.timeSig.beatsPerBar)
            }
            DispatchQueue.main.async {
                self.chordsBusy.remove(id)
                guard let c = chart, let i = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[i].chords = c
                if self.current?.id == id { self.current?.chords = c }
                self.scheduleSave()
            }
        }
    }

    /// The key the loaded song sounds in right now (after any key change).
    var playingKey: MusicKey? {
        guard let it = current, let k = it.chords?.key else { return nil }
        return k.transposed(it.semitones)
    }

    /// Moves the loaded track into the key the singer started in.
    func matchKey(_ target: MusicKey) {
        guard let it = current, let k = it.chords?.key else { return }
        var s = k.shift(to: target)
        if s > 7 { s -= 12 }
        if s < -7 { s += 12 }
        update { $0.semitones = s }
        status = "Moved \"\(it.title)\" to \(k.transposed(s).longName) (\(s >= 0 ? "+" : "")\(s))"
    }

    // MARK: lyrics

    func setLyrics(_ l: Lyrics?, for id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].lyrics = l
        if current?.id == id { current?.lyrics = l }
        scheduleSave()
    }

    func nudgeLyrics(_ by: Double) {
        guard let it = current, var l = it.lyrics else { return }
        l.offset = ((l.offset + by) * 10).rounded() / 10
        setLyrics(l, for: it.id)
    }

    /// Looks up lyrics for a freshly downloaded song and keeps them if the match is clear.
    func autoFindLyrics(_ id: UUID) {
        guard let it = items.first(where: { $0.id == id }), it.lyrics == nil else { return }
        let q = [it.artist ?? "", LyricsFinder.searchText(it.title)].filter { !$0.isEmpty }.joined(separator: " ")
        LyricsFinder.search(q, duration: it.duration > 0 ? it.duration : nil) { [weak self] results, _ in
            guard let self = self, let best = results.first, best.lengthGap < 4, best.score > 1.2 else { return }
            if self.items.first(where: { $0.id == id })?.lyrics == nil {
                self.setLyrics(LyricsFinder.lyrics(from: best), for: id)
            }
        }
    }

    /// Loop on/off. Turning it on with no loop set loops the whole song (grooves always loop).
    func toggleLoop() {
        guard let it = current, it.kind != .groove, it.kind != .metronome else { return }
        update { it in
            if !it.loopOn, it.loopStart == nil || it.loopEnd == nil || (it.loopEnd ?? 0) <= (it.loopStart ?? 0) {
                it.loopStart = 0; it.loopEnd = it.duration
            }
            it.loopOn.toggle()
        }
    }

    // MARK: keyboard (MIDI) and phone

    func startTools() {
        let midi = MIDIControl.shared
        midi.perform = { [weak self] a in self?.perform(a) }
        midi.start()
        RemoteServer.shared.model = self
        RemoteServer.shared.startIfEnabled()
        pads.warmUp()
    }

    func perform(_ a: MIDIAction) {
        switch a {
        case .playPause: togglePlay()
        case .stop: stop()
        case .fadeOut: fadeOut()
        case .next: playNext()
        case .previous: playPrevious()
        case .loop: toggleLoop()
        case .click: clickOn.toggle()
        case .padToggle: pads.toggle()
        case .padFoundKey:
            if let k = KeyListener.shared.key { pads.chord = k.minor ? .minor : pads.chord == .minor ? .open : pads.chord; pads.play(key: k.tonic) }
            else if let k = playingKey { pads.play(key: k.tonic) }
        case .keyUp: update { $0.semitones = min(7, $0.semitones + 1) }
        case .keyDown: update { $0.semitones = max(-7, $0.semitones - 1) }
        case .tap: tapTempo()
        }
    }
}
