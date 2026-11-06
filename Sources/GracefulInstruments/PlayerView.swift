import SwiftUI
import AppKit

// MARK: - Layout building blocks (one label column, one control height, everything on one line)

enum UI {
    static let labelWidth: CGFloat = 110
    static let gap: CGFloat = 8
}

/// A rounded panel with an optional small heading.
struct Card<Content: View>: View {
    var title: String?
    var icon: String?
    let content: Content
    init(_ title: String? = nil, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let t = title { CardTitle(title: t, systemImage: icon) }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(NSColor.separatorColor), lineWidth: 1))
    }
}

/// Label on the left in a fixed column, controls on the right.
struct FieldRow<Content: View>: View {
    let label: String
    let content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }
    var body: some View {
        HStack(alignment: .center, spacing: UI.gap) {
            Text(label).foregroundColor(.secondary).lineLimit(1)
                .frame(width: UI.labelWidth, alignment: .leading)
            content
        }
        .frame(maxWidth: .infinity, minHeight: Size.medium, alignment: .leading)
    }
}

/// "Send to: Left | Both | Right"
struct RoutePicker: View {
    @Binding var route: Route
    var showLabel = true
    var body: some View {
        HStack(spacing: 6) {
            if showLabel { Text("Send to").foregroundColor(.secondary).lineLimit(1) }
            Segments(Route.allCases.map { ($0, $0.label) }, selection: $route).frame(width: 200)
        }
        .help("Left = in-ears, Right = house (with the church split in Settings)")
    }
}

/// Content that starts at the control column, under a FieldRow label.
struct Indented<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        HStack(spacing: UI.gap) {
            Color.clear.frame(width: UI.labelWidth, height: 1)
            content
        }
    }
}

struct Caption: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.caption).foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

func openSettings() {
    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
}

// MARK: - Player

struct PlayerView: View {
    @EnvironmentObject var model: AppModel
    @State private var savingLoop = false
    @State private var loopName = ""
    @State private var markMode = false
    @State private var bpmText = ""
    @State private var addBars = 16
    @State private var savingPortion = false
    @State private var portionName = ""
    @AppStorage("playerTab") private var tab = PlayerTab.controls.rawValue

    /// Grooves have no chords or words and always loop, so they get fewer tabs.
    static func tabs(for item: LibraryItem) -> [PlayerTab] {
        item.kind == .groove ? [.controls, .cues] : PlayerTab.allCases
    }

    var body: some View {
        if let item = model.current, item.kind == .metronome {
            MetronomePanel()
        } else if let item = model.current {
            let available = Self.tabs(for: item)
            let shown = PlayerTab(rawValue: tab).flatMap { available.contains($0) ? $0 : nil } ?? .controls
            VStack(alignment: .leading, spacing: 10) {
                header(item)
                WaveformView(item: item).frame(height: 92)
                TransportBar(item: item)
                QuickToggles(pads: model.pads, item: item)
                Segments(available.map { ($0, $0.label) },
                         selection: Binding(get: { shown }, set: { tab = $0.rawValue }), height: 32, fontSize: 13)
                Group {
                    switch shown {
                    case .controls: scroll { soundTab(item) }
                    case .loop: scroll { loopTab(item) }
                    case .cues: scroll { cuesTab(item) }
                    case .chords: ChordsPanel(item: item)
                    case .lyrics: LyricsPanel(item: item)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .sheet(isPresented: $savingLoop) {
                NamePrompt(title: "Save loop", name: $loopName) { ok in
                    if ok && !loopName.isEmpty { model.saveCurrentAsLoop(named: loopName) }
                    savingLoop = false
                }
            }
        } else {
            EmptyState(systemImage: "music.quarternote.3", title: "Nothing loaded",
                       message: "Click the play button next to a song, loop or groove to load it here. On a service day, pick the service on the left.")
        }
    }

    func scroll<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
        }
    }

    // MARK: header
    func header(_ item: LibraryItem) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 21, weight: .bold)).lineLimit(1).truncationMode(.tail)
                HStack(spacing: 6) {
                    if let pos = model.entryPosition {
                        Text(pos).foregroundColor(.accentColor)
                        Text("·")
                    }
                    Text(item.kind.label)
                    if let c = model.category(of: item) { Text("·"); Text(c.label) }
                    Text("·"); Text(item.timeSig.rawValue)
                    if let b = item.bpm { Text("·"); Text("original \(formatBPM(b)) BPM") }
                    if let k = model.playingKey { Text("·"); Text("key \(k.name)") }
                    if model.analyzing.contains(item.id) { Text("·"); Text("finding tempo…") }
                }
                .font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if model.previousInSetlist() != nil {
                SquareButton(systemName: "backward.end.fill", size: Size.big, help: "Previous song in the service (B)") { model.playPrevious() }
            }
            if let next = model.nextInSetlist() {
                Button(action: { model.playNext() }) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("NEXT  (N)").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                            Text(next.item.title).lineLimit(1).truncationMode(.tail)
                        }
                        Image(systemName: "forward.end.fill")
                    }
                    .frame(maxWidth: 200, alignment: .leading)
                }
                .big(height: Size.big)
                .help("Load the next song in the service (N)")
            }
            SquareButton(systemName: "gearshape", size: Size.big, help: "Output and volume settings (⌘,)") { openSettings() }
        }
    }

    // MARK: sound tab
    @ViewBuilder func soundTab(_ item: LibraryItem) -> some View {
        tempoCard(item)
        if item.kind == .groove { grooveCard(item) }
        clickCard(item)
        countInCard
        Card("Music", icon: "speaker.wave.2.fill") {
            FieldRow("Send to") { RoutePicker(route: $model.musicRoute, showLabel: false) }
            FieldRow("Volume") {
                Slider(value: Binding(get: { Double(model.musicVol) }, set: { model.musicVol = Float($0) }), in: 0...1.25)
                Text("\(Int((model.musicVol * 100).rounded()))%").font(.caption).foregroundColor(.secondary).frame(width: 40, alignment: .trailing)
            }
        }
        if item.stems.count > 1 { stemsCard(item) }
    }

    func tempoCard(_ item: LibraryItem) -> some View {
        Card("Tempo and key", icon: "speedometer") {
            FieldRow("Tempo") {
                SquareButton(systemName: "minus", help: "Slower (−)") { model.nudgeTempo(-1) }
                Group {
                    if let pb = item.playingBPM { Text("\(formatBPM(pb)) BPM") } else { Text("\(Int((item.rate * 100).rounded()))%") }
                }
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(width: 104)
                SquareButton(systemName: "plus", help: "Faster (+)") { model.nudgeTempo(1) }
                Slider(value: Binding(get: { item.rate }, set: { v in model.update { $0.rate = (v * 200).rounded() / 200 } }),
                       in: 0.5...1.6)
                    .frame(minWidth: 80)
                Button("Reset") { model.update { $0.rate = 1 } }.big().disabled(item.rate == 1)
            }
            FieldRow("Key") {
                SquareButton(systemName: "minus", help: "Key down a semitone") { model.update { $0.semitones = max(-7, $0.semitones - 1) } }
                Text(keyText(item))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(width: 104)
                SquareButton(systemName: "plus", help: "Key up a semitone") { model.update { $0.semitones = min(7, $0.semitones + 1) } }
                Spacer(minLength: 0)
                Button("Reset") { model.update { $0.semitones = 0 } }.big().disabled(item.semitones == 0)
            }
        }
    }

    func keyText(_ item: LibraryItem) -> String {
        let shift = String(format: "%+d", item.semitones)
        if let k = model.playingKey { return item.semitones == 0 ? "\(k.name) (original)" : "\(k.name) (\(shift))" }
        if item.semitones == 0 { return "Original" }
        return "\(shift) semitone\(abs(item.semitones) == 1 ? "" : "s")"
    }

    // MARK: groove parts
    func grooveCard(_ item: LibraryItem) -> some View {
        Card("Groove", icon: "music.note") {
            FieldRow("Style") {
                Picker("", selection: Binding(get: { item.grooveStyle ?? "" }, set: { id in
                    if let g = GrooveStyle.find(id) { model.changeGrooveStyle(g) }
                })) {
                    ForEach(GrooveStyle.all) { g in Text("\(g.name)  (\(g.timeSig.rawValue))").tag(g.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
            }
            if let note = GrooveStyle.find(item.grooveStyle)?.note, !note.isEmpty { Indented { Caption(note) } }
            ForEach(GroovePart.allCases) { part in
                let level = item.grooveLevel(part)
                HStack(spacing: UI.gap) {
                    ToggleTile(title: part.label, systemImage: level > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill",
                               isOn: level > 0, height: Size.small, help: "Switch \(part.label.lowercased()) on or off") {
                        model.update { $0.grooveLevels = ($0.grooveLevels ?? [:]).merging([part.rawValue: level > 0 ? 0 : 0.8]) { $1 } }
                    }
                    .frame(width: 170)
                    Slider(value: Binding(get: { Double(level) }, set: { v in
                        model.update { $0.grooveLevels = ($0.grooveLevels ?? [:]).merging([part.rawValue: Float(v)]) { $1 } }
                    }), in: 0...1.4)
                    .disabled(level == 0)
                }
            }
            Caption("Real recorded drums and percussion. Switch parts on or off and set their level while it plays. The bell starts off.")
        }
    }

    // MARK: click
    func clickCard(_ item: LibraryItem) -> some View {
        Card {
            HStack(spacing: UI.gap) {
                Toggle("", isOn: $model.clickOn).toggleStyle(SwitchToggleStyle()).labelsHidden()
                CardTitle(title: "Click", systemImage: "metronome")
                Spacer(minLength: 4)
                RoutePicker(route: $model.clickRoute)
            }
            FieldRow("Time") {
                Segments(TimeSig.allCases.map { ($0, $0.rawValue) },
                         selection: Binding(get: { item.timeSig }, set: { v in model.update { $0.timeSig = v } }))
                    .frame(maxWidth: 260)
                    .disabled(item.kind == .groove)
            }
            FieldRow("Volume") {
                Slider(value: Binding(get: { Double(model.clickVol) }, set: { model.clickVol = Float($0) }), in: 0...1.25)
                Text("\(Int((model.clickVol * 100).rounded()))%").font(.caption).foregroundColor(.secondary).frame(width: 40, alignment: .trailing)
            }
            if item.kind != .groove {
                FieldRow("Track tempo") {
                    TextField(item.bpm.map(formatBPM) ?? "?", text: $bpmText, onCommit: {
                        if let v = Double(bpmText), v > 20, v < 300 { model.update { $0.bpm = v } }
                        bpmText = ""
                    })
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 60)
                    Text("BPM").foregroundColor(.secondary)
                    Button("Tap") { model.tapTempo() }.big().help("Tap along with the music (or press T)")
                    Button("½×") { model.update { if let b = $0.bpm, b / 2 >= 20 { $0.bpm = b / 2 } } }.big().disabled(item.bpm == nil)
                        .help("The detected tempo is twice too fast")
                    Button("2×") { model.update { if let b = $0.bpm, b * 2 <= 300 { $0.bpm = b * 2 } } }.big().disabled(item.bpm == nil)
                        .help("The detected tempo is half what it should be")
                }
                FieldRow("Beat one") {
                    Button("Set beat 1 here") { model.setBeatOneHere() }.big()
                        .help("While it plays, press this exactly on beat one of a bar")
                    SquareButton(systemName: "arrow.left", help: "Move beat one earlier by one beat") { model.nudgeBeat(-1) }
                    SquareButton(systemName: "arrow.right", help: "Move beat one later by one beat") { model.nudgeBeat(1) }
                }
                .disabled(item.bpm == nil)
                Indented { Caption("If the click doesn't match the music, fix the tempo first (Tap, ½×, 2×), then press \"Set beat 1 here\" on a downbeat.") }
            }
        }
    }

    // MARK: count-in
    var countInCard: some View {
        Card {
            HStack(spacing: UI.gap) {
                Toggle("", isOn: Binding(get: { model.countInBars > 0 }, set: { model.countInBars = $0 ? 1 : 0 }))
                    .toggleStyle(SwitchToggleStyle()).labelsHidden()
                CardTitle(title: "Count-in", systemImage: "timer")
                Spacer(minLength: 4)
                Text("Plays where the click goes: \(model.clickRoute.label)").foregroundColor(.secondary).lineLimit(1)
            }
            if model.countInBars > 0 {
                FieldRow("Length") {
                    Segments([(1, "1 bar"), (2, "2 bars")], selection: $model.countInBars).frame(width: 170)
                    Toggle("Speak the count", isOn: $model.countVoice).padding(.leading, 8)
                }
            } else {
                Caption("Plays one or two bars of click before the music starts, so the band comes in together. Turn it on, then press Play.")
            }
        }
    }

    // MARK: loop tab
    func loopTab(_ item: LibraryItem) -> some View {
        let regions = item.regions ?? []
        return Group {
            Card {
                HStack(spacing: UI.gap) {
                    ToggleTile(title: item.loopOn ? "Loop on" : "Loop off", systemImage: "repeat", isOn: item.loopOn,
                               height: Size.big, help: "Loop on or off (L)") { model.toggleLoop() }
                        .frame(width: 150)
                    VStack(alignment: .leading, spacing: 2) {
                        if let s = item.loopStart, let e = item.loopEnd {
                            Text("\(formatTime(s)) to \(formatTime(e))").font(.system(size: 17, weight: .semibold, design: .rounded)).lineLimit(1)
                            if let bar = item.barSeconds {
                                Text("\(Int(((e - s) / bar).rounded())) bars").font(.caption).foregroundColor(.secondary).lineLimit(1)
                            }
                        } else {
                            Text("No loop set").foregroundColor(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                FieldRow("In / Out") {
                    Button("Set In  (I)") { model.setIn() }.big().help("Loop starts at the playhead (snapped to the bar)")
                    Button("Set Out  (O)") { model.setOut() }.big().help("Loop ends at the playhead and jumps back to In")
                    Button("Whole song") { model.update { $0.loopStart = 0; $0.loopEnd = $0.duration; $0.loopOn = true } }.big()
                }
                FieldRow("Quick loop") {
                    ForEach([2, 4, 8, 16], id: \.self) { n in
                        Button("\(n) bars") { model.loopBars(n) }.big(fullWidth: true)
                            .help("Loop \(n) bars from the start of the bar that's playing")
                    }
                }
                FieldRow("") { Toggle("Snap to bars", isOn: $model.snapToBars).disabled(item.bpm == nil) }
                Caption("You can also drag across the waveform to loop that part.")
            }
            Card("Saved portions", icon: "bookmark.fill") {
                HStack(spacing: UI.gap) {
                    Button(action: { portionName = "Portion \(regions.count + 1)"; savingPortion = true }) {
                        IconLabel(systemName: "plus", title: "Save This Portion…")
                    }
                    .big().disabled(item.loopStart == nil)
                    Button(action: { loopName = "\(item.title) loop"; savingLoop = true }) {
                        IconLabel(systemName: "square.and.arrow.down", title: "Save as Loop…")
                    }
                    .big().disabled(item.loopStart == nil)
                    .help("Saves the looped part as its own item in the library")
                }
                if regions.isEmpty {
                    Caption("Save the parts you loop often (the chorus, a vamp) and they show up here as buttons. While playing, a portion switches in at the next bar.")
                }
                ForEach(0..<(regions.count + 2) / 3, id: \.self) { row in
                    HStack(spacing: UI.gap) {
                        ForEach(regions[(row * 3)..<min(row * 3 + 3, regions.count)]) { r in
                            let active = item.loopOn && item.loopStart == r.start && item.loopEnd == r.end
                            Button(action: { model.activatePortion(r) }) {
                                IconLabel(systemName: active ? "repeat.circle.fill" : "repeat", title: r.name)
                                    .frame(maxWidth: .infinity)
                            }
                            .big(active ? .primary : .normal, fullWidth: true)
                            .help("\(formatTime(r.start)) to \(formatTime(r.end)). Click to loop it. Right-click to delete.")
                            .contextMenu { Button("Delete \"\(r.name)\"") { model.deletePortion(r.id) } }
                        }
                        ForEach(0..<(3 - min(3, regions.count - row * 3)), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                    }
                }
            }
            Card("Loop tools", icon: "wand.and.stars") {
                FieldRow("Pattern") {
                    Button("Find Repeating Pattern") { model.findPattern() }.big()
                        .disabled(item.bpm == nil || model.loopToolBusy)
                    if model.loopToolBusy { ProgressView().scaleEffect(0.5).frame(width: 16, height: 16) }
                }
                FieldRow("Make longer") {
                    Segments([(8, "+8"), (16, "+16"), (32, "+32"), (64, "+64")], selection: $addBars).frame(width: 170)
                    Text("bars").foregroundColor(.secondary)
                    Button("Save Longer Copy") { model.makeLonger(addBars: addBars) }.big()
                        .disabled(item.loopStart == nil || model.loopToolBusy)
                }
                Caption("Find Repeating Pattern loops the section that repeats most cleanly. Save Longer Copy repeats the looped section to add that many bars, then the song carries on as before. The copy appears in the library; the original is untouched.")
            }
        }
        .sheet(isPresented: $savingPortion) {
            NamePrompt(title: "Name this portion", name: $portionName) { ok in
                if ok && !portionName.isEmpty { model.savePortion(named: portionName) }
                savingPortion = false
            }
        }
    }

    // MARK: cues tab
    static let cueButtons: [String] = ["intro", "verse", "prechorus", "chorus", "bridge", "instrumental", "build", "down",
                                        "break", "allin", "hits", "acapella", "again", "lasttime", "tag", "vamp",
                                        "worship", "turnaround", "keychange", "hold", "drumsonly", "slowdown", "outro", "ending"]

    @ViewBuilder func cuesTab(_ item: LibraryItem) -> some View {
        Card {
            HStack(spacing: UI.gap) {
                ToggleTile(title: model.cuesOn ? "Cues on" : "Cues off", systemImage: "text.bubble.fill", isOn: model.cuesOn,
                           height: Size.big, help: "Spoken cues on or off") { model.cuesOn.toggle() }
                    .frame(width: 150)
                Spacer(minLength: 4)
                RoutePicker(route: $model.cueRoute)
            }
            FieldRow("Button does") {
                Segments([(false, "Speak now"), (true, "Add to timeline")], selection: $markMode).frame(width: 260)
            }
            // Plain rows of buttons: a lazy grid here took seconds to lay out on Big Sur.
            ForEach(0..<(Self.cueButtons.count + 3) / 4, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(Self.cueButtons[(row * 4)..<min(row * 4 + 4, Self.cueButtons.count)], id: \.self) { key in
                        Button(action: { if markMode { model.addMarker(key) } else { model.cue(key) } }) {
                            Text(AudioEngine.cueLabels[key] ?? key).frame(maxWidth: .infinity)
                        }
                        .big(fullWidth: true)
                    }
                }
            }
            .disabled(!model.cuesOn && !markMode)
            Caption(markMode
                    ? "Each button saves that cue at the playhead. It is spoken before that point every time the song plays."
                    : model.cuesOn
                        ? "Cues are spoken on the next beat, into the in-ears. Keys 1 to 0: Verse, Pre-Chorus, Chorus, Bridge, Build, Down, Again, Last time, Ending, Instrumental."
                        : "Turn Cues on to speak them into the in-ears.")
        }
        if !item.markers.isEmpty {
            Card("Cues on the timeline", icon: "text.badge.checkmark") {
                ForEach(item.markers) { m in
                    HStack(spacing: UI.gap) {
                        Text(formatTime(m.time)).font(.system(size: 13, design: .monospaced)).foregroundColor(.secondary).frame(width: 50, alignment: .leading)
                        Text(AudioEngine.cueLabels[m.cue] ?? m.cue).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                        SquareButton(systemName: "arrow.uturn.left", size: Size.small, help: "Jump to a bar before this cue") {
                            model.seek(to: max(0, m.time - (item.barSeconds ?? 2)))
                        }
                        SquareButton(systemName: "trash", size: Size.small, help: "Remove this cue") { model.removeMarker(m.id) }
                    }
                }
                FieldRow("Spoken") {
                    Segments([(0.5, "2 beats early"), (1.0, "1 bar early"), (2.0, "2 bars early")], selection: $model.cueLeadBars)
                        .frame(maxWidth: 320)
                }
            }
        }
    }

    // MARK: stems
    func stemsCard(_ item: LibraryItem) -> some View {
        Card("Stems", icon: "slider.vertical.3") {
            ForEach(Array(item.stems.enumerated()), id: \.element.id) { idx, s in
                HStack(spacing: UI.gap) {
                    Text(s.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
                        .frame(width: 110, alignment: .leading)
                    Button("M") { model.update { $0.stems[idx].muted.toggle() } }
                        .big(s.muted ? .danger : .normal, height: Size.small).help("Mute")
                    Button("S") { model.update { $0.stems[idx].solo.toggle() } }
                        .big(s.solo ? .warning : .normal, height: Size.small).help("Solo")
                    Slider(value: Binding(get: { Double(s.volume) }, set: { v in model.update { $0.stems[idx].volume = Float(v) } }),
                           in: 0...max(1.5, Double(s.volume)))
                    Toggle("In-ears", isOn: Binding(get: { s.inEarsOnly }, set: { v in model.update { $0.stems[idx].inEarsOnly = v } }))
                        .fixedSize()
                        .help("Send this stem to the in-ear side only (click, guide vocals)")
                }
            }
        }
    }
}

/// The big on/off switches for what changes most during a service.
struct QuickToggles: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var pads: PadController
    let item: LibraryItem

    var body: some View {
        HStack(spacing: 8) {
            if item.kind != .groove {
                ToggleTile(title: "Loop", systemImage: "repeat", isOn: item.loopOn, help: "Loop on or off (L)") { model.toggleLoop() }
            }
            ToggleTile(title: "Click", systemImage: "metronome", isOn: model.clickOn, help: "Click on or off (K)") { model.clickOn.toggle() }
            ToggleTile(title: "Count-in", systemImage: "timer", isOn: model.countInBars > 0,
                       help: "Count in before the music starts") { model.countInBars = model.countInBars > 0 ? 0 : 1 }
            ToggleTile(title: "Cues", systemImage: "text.bubble", isOn: model.cuesOn, help: "Spoken cues on or off") { model.cuesOn.toggle() }
            ToggleTile(title: pads.on ? "Pad \(pads.keyName)" : "Pad", systemImage: "waveform", isOn: pads.on, onKind: .success,
                       help: pads.on ? "The pad is playing. Click to fade it out (P)" : "Start the pad in \(pads.keyName) (P). Change it under Pads.") { pads.toggle() }
        }
    }
}

/// What the player column shows while the metronome is loaded.
struct MetronomePanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var clock = AppModelHolder.clock
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "metronome.fill").font(.system(size: 40)).foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(formatBPM(model.metroBPM)).font(.system(size: 64, weight: .bold, design: .rounded))
                Text("BPM").foregroundColor(.secondary)
            }
            Text("\(model.metroTimeSig.rawValue) · \(model.clickSound.label) · sent \(model.clickRoute.label.lowercased())")
                .foregroundColor(.secondary).lineLimit(1)
            BeatDots(beats: model.metroTimeSig.beatsPerBar, bpm: model.metroBPM, active: clock.playing)
            Button(action: { model.toggleMetronome() }) {
                IconLabel(systemName: clock.playing ? "stop.fill" : "play.fill", title: clock.playing ? "Stop" : "Start", iconSize: 17)
                    .frame(width: 140)
            }
            .big(clock.playing ? .danger : .primary, height: Size.big, fontSize: 16)
            .help("Start / stop (Space)")
            Text("Change tempo, meter and sound under Metronome on the left.").font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Where each sound goes").font(.headline)
                FieldRow("Quick setup") {
                    Button("Church split") { model.presetSplit() }.big(model.isSplitPreset ? .primary : .normal)
                        .help("Music right (house), click, count-in and cues left (in-ears)")
                    Button("Everything on both sides") { model.presetBoth() }.big()
                        .help("For practice or headphones")
                }
                FieldRow("Music") { RoutePicker(route: $model.musicRoute) }
                FieldRow("Click, count-in") { RoutePicker(route: $model.clickRoute) }
                FieldRow("Cues") { RoutePicker(route: $model.cueRoute) }
                FieldRow("In-ear stems") { RoutePicker(route: $model.stemRoute) }
                Caption("Church split: at the board, send the LEFT channel to the in-ear mixes only, never to the house. The RIGHT channel carries the music in mono for the house and the in-ears. A sound sent to one side is mono; music sent to Both stays stereo.")
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Volume").font(.headline)
                volumeRow("Music", $model.musicVol)
                volumeRow("Click", $model.clickVol)
                volumeRow("Cues", $model.cueVol)
                volumeRow("In-ear stems", $model.inEarVol)
            }
            Divider()
            FieldRow("Worship is") {
                SquareButton(systemName: "minus", size: Size.small) { model.worshipMaxBPM = max(50, model.worshipMaxBPM - 1) }
                Text("up to \(Int(model.worshipMaxBPM)) BPM").lineLimit(1).frame(width: 96)
                SquareButton(systemName: "plus", size: Size.small) { model.worshipMaxBPM = min(160, model.worshipMaxBPM + 1) }
                Text("(faster = Praise)").foregroundColor(.secondary).lineLimit(1)
            }
            Divider()
            FieldRow("Fade out") {
                Segments([(3.0, "3 s"), (6.0, "6 s"), (10.0, "10 s"), (15.0, "15 s")], selection: $model.fadeSeconds).frame(width: 240)
            }
            Divider()
            ShortcutList()
        }
        .padding(20)
        .frame(width: 560)
    }

    func volumeRow(_ name: String, _ v: Binding<Float>) -> some View {
        FieldRow(name) {
            Slider(value: Binding(get: { Double(v.wrappedValue) }, set: { v.wrappedValue = Float($0) }), in: 0...1.25)
                .frame(width: 260)
            Text("\(Int((v.wrappedValue * 100).rounded()))%").font(.caption).foregroundColor(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

// MARK: - Transport

struct TransportBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var clock: PlaybackClock
    let item: LibraryItem

    init(item: LibraryItem) {
        self.item = item
        _clock = ObservedObject(wrappedValue: AppModelHolder.clock)
    }

    var barBeat: String? {
        guard item.kind != .groove, let beat = item.beatSeconds else { return nil }
        let beats = (clock.position - item.beatOffset) / beat
        guard beats >= 0 else { return nil }
        let bpb = Double(item.timeSig.beatsPerBar)
        return "Bar \(Int(beats / bpb) + 1) · Beat \(Int(beats.truncatingRemainder(dividingBy: bpb)) + 1)"
    }

    var body: some View {
        HStack(alignment: .center, spacing: UI.gap) {
            SquareButton(systemName: "backward.end.fill", size: Size.big, help: "Stop and go back to the start (S)") { model.stop() }
            SquareButton(systemName: "backward.fill", size: Size.big, help: "Back one bar ([)") { model.jumpBars(-1) }
            Button(action: { model.togglePlay() }) {
                IconLabel(systemName: clock.playing ? "pause.fill" : "play.fill", title: clock.playing ? "Pause" : "Play", iconSize: 17)
                    .frame(width: 96)
            }
            .big(.primary, height: Size.big, fontSize: 16)
            .help("Play / pause (Space)")
            SquareButton(systemName: "forward.fill", size: Size.big, help: "Forward one bar (])") { model.jumpBars(1) }
            Button(action: { model.fadeOut() }) {
                IconLabel(systemName: "speaker.wave.1.fill", title: "Fade").frame(width: 64)
            }
            .big(height: Size.big, fontSize: 14)
            .disabled(!clock.playing)
            .help("Fade out and stop (F)")
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(formatTime(clock.position)) / \(formatTime(item.duration))")
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(barBeat ?? " ").font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
        }
    }
}

/// Lets small views reach the shared clock without making the whole player redraw on every tick.
enum AppModelHolder {
    static var clock = PlaybackClock()
}

// MARK: - Waveform

struct WaveformView: View {
    @EnvironmentObject var model: AppModel
    let item: LibraryItem
    @State private var dragStart: CGFloat?
    @State private var dragNow: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let dur = max(item.duration, 0.01)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor))
                if let s = item.loopStart, let e = item.loopEnd, item.loopOn || item.kind == .groove {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.2))
                        .frame(width: max(1, CGFloat((e - s) / dur) * w), height: h)
                        .offset(x: CGFloat(s / dur) * w)
                }
                if let img = model.waveImage {
                    Image(nsImage: img).resizable().frame(width: w, height: h)
                }
                ForEach(model.cuesOn ? item.markers : []) { m in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(AudioEngine.cueLabels[m.cue] ?? m.cue)
                            .font(.system(size: 9, weight: .semibold)).lineLimit(1).padding(.horizontal, 3)
                            .background(Color.orange).foregroundColor(.white).cornerRadius(2)
                        Rectangle().fill(Color.orange).frame(width: 1.5)
                    }
                    .frame(height: h, alignment: .top)
                    .offset(x: CGFloat(m.time / dur) * w)
                }
                if let a = dragStart, let b = dragNow, abs(b - a) > 4 {
                    Rectangle().fill(Color.yellow.opacity(0.25))
                        .frame(width: abs(b - a), height: h).offset(x: min(a, b))
                }
                Playhead(duration: dur, width: w, height: h)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if dragStart == nil { dragStart = v.startLocation.x }
                    dragNow = v.location.x
                }
                .onEnded { v in
                    let a = min(max(v.startLocation.x, 0), w), b = min(max(v.location.x, 0), w)
                    if abs(b - a) < 4 || item.kind == .groove {
                        model.seek(to: Double(a / w) * dur)
                    } else {
                        model.setLoopRegion(Double(min(a, b) / w) * dur, Double(max(a, b) / w) * dur)
                    }
                    dragStart = nil; dragNow = nil
                })
        }
    }
}

struct Playhead: View {
    @ObservedObject var clock: PlaybackClock = AppModelHolder.clock
    let duration: Double
    let width: CGFloat
    let height: CGFloat
    var body: some View {
        Rectangle().fill(Color.red)
            .frame(width: 2, height: height)
            .offset(x: CGFloat(clock.position / duration) * width - 1)
    }
}

/// The single-key shortcuts, laid out as a two-column cheat sheet.
struct ShortcutList: View {
    static let keys: [(String, String)] = [
        ("Space", "Play / pause"), ("S", "Stop"), ("F", "Fade out"), ("L", "Loop on/off"),
        ("K", "Click on/off"), ("P", "Pad on/off"), ("N / B", "Next / previous song"), ("[  ]", "Back / forward a bar"),
        ("+  −", "Tempo up / down"), ("T", "Tap tempo"), ("I  O", "Loop in / out"), ("1 to 0", "Spoken cues")]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keyboard shortcuts").font(.headline)
            HStack(alignment: .top, spacing: 24) {
                ForEach(0..<2, id: \.self) { col in
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(Self.keys.enumerated()).filter { $0.offset % 2 == col }, id: \.offset) { _, k in
                            HStack(spacing: 8) {
                                Text(k.0).font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .frame(width: 58, alignment: .leading)
                                Text(k.1).foregroundColor(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }
}
