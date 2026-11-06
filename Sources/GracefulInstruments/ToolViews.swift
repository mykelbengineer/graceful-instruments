import SwiftUI
import AppKit

/// One octave of piano keys, lit by how much each note has been heard.
struct OctaveView: View {
    let levels: [Float]          // 12 values 0...1, C first
    var highlight: Int? = nil    // tonic
    var now: Int? = nil
    var flats = true

    private let whites = [0, 2, 4, 5, 7, 9, 11]
    private let blacks: [(Int, Int)] = [(1, 0), (3, 1), (6, 3), (8, 4), (10, 5)] // note, white key it sits after

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width / 7, h = geo.size.height
            ZStack(alignment: .topLeading) {
                ForEach(0..<7, id: \.self) { i in
                    let n = whites[i]
                    key(n, black: false)
                        .frame(width: w - 2, height: h)
                        .offset(x: CGFloat(i) * w)
                }
                ForEach(0..<5, id: \.self) { j in
                    let (n, after) = blacks[j]
                    key(n, black: true)
                        .frame(width: w * 0.62, height: h * 0.6)
                        .offset(x: CGFloat(after + 1) * w - w * 0.31 - 1)
                }
            }
        }
    }

    func key(_ n: Int, black: Bool) -> some View {
        let lvl = Double(levels.indices.contains(n) ? levels[n] : 0)
        let base: Color = black ? Color(white: 0.18) : Color(white: 0.96)
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 4).fill(base)
            RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(lvl * 0.85))
            RoundedRectangle(cornerRadius: 4).stroke(n == now ? Color.orange : Color(NSColor.separatorColor), lineWidth: n == now ? 3 : 1)
            Text(Notes.name(n, flats: flats))
                .font(.system(size: black ? 9 : 11, weight: n == highlight ? .bold : .regular))
                .foregroundColor(black || lvl > 0.5 ? .white : .black)
                .padding(.bottom, 4)
        }
    }
}

// MARK: - Key Finder

struct KeyFinderView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var kl = KeyListener.shared
    @ObservedObject var pads: PadController

    init(pads: PadController) { self.pads = pads }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Card {
                    VStack(spacing: 6) {
                        Text(kl.key?.longName ?? (kl.listening ? "Listening…" : "Key Finder"))
                            .font(.system(size: 38, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
                        Text(subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        ProgressView(value: kl.listening ? Double(kl.level) : 0).frame(width: 180)
                    }
                    .frame(maxWidth: .infinity)
                    OctaveView(levels: kl.notes, highlight: kl.key?.tonic, now: kl.nowNote, flats: kl.key?.usesFlats ?? true)
                        .frame(height: 74)
                    HStack(spacing: 8) {
                        Button(action: { kl.toggle() }) {
                            IconLabel(systemName: kl.listening ? "stop.fill" : "mic.fill", title: kl.listening ? "Stop listening" : "Listen")
                                .frame(maxWidth: .infinity)
                        }
                        .big(kl.listening ? .danger : .primary, height: Size.big, fullWidth: true, fontSize: 15)
                        Button(action: { kl.reset() }) { IconLabel(systemName: "arrow.counterclockwise", title: "New song") }
                            .big(height: Size.big, fontSize: 14)
                            .help("Forget what was heard and start fresh for the next song")
                    }
                }
                Card("Use it") {
                    Button(action: {
                        if let k = kl.key { pads.chord = k.minor ? .minor : (pads.chord == .minor ? .open : pads.chord); pads.play(key: k.tonic) }
                    }) { IconLabel(systemName: "waveform", title: kl.key.map { "Pad in \($0.name)" } ?? "Pad in this key").frame(maxWidth: .infinity) }
                    .big(.success, fullWidth: true)
                    .disabled(kl.key == nil)
                    Button(action: { if let k = kl.key { model.matchKey(k) } }) {
                        IconLabel(systemName: "arrow.up.arrow.down", title: matchLabel).frame(maxWidth: .infinity)
                    }
                    .big(fullWidth: true)
                    .disabled(kl.key == nil || model.current?.chords == nil)
                    Caption("Move the song: changes the loaded track's key so it plays in the key the leader started in.")
                }
                if !kl.message.isEmpty { Caption(kl.message) }
                Caption("Start listening when the leader starts singing. The key settles after about 5 to 10 seconds of singing; the orange key is the note heard right now. Press New song before the next one.")
            }
            .padding(12)
        }
        .navigationTitle("Key Finder")
    }

    var subtitle: String {
        guard kl.listening || kl.key != nil else { return "Hear the key the leader is singing in" }
        guard kl.key != nil else { return "Heard \(Int(kl.heard)) s so far" }
        let sure = Int(kl.sure * 100)
        let alt = kl.runnerUp.map { " · or \($0.name)" } ?? ""
        return "\(sure)% sure\(alt)"
    }

    var matchLabel: String {
        guard let k = kl.key, let it = model.current, let tk = it.chords?.key else { return "Move song to this key" }
        let s = tk.shift(to: k)
        return "Move song to \(k.name) (\(s >= 0 ? "+" : "")\(s))"
    }
}

// MARK: - Pads

struct PadsView: View {
    @ObservedObject var pads: PadController
    @EnvironmentObject var model: AppModel
    @ObservedObject var kl = KeyListener.shared

    init(pads: PadController) { self.pads = pads }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Card {
                    Button(action: { pads.toggle() }) {
                        HStack(spacing: 8) {
                            Image(systemName: pads.on ? "stop.fill" : "play.fill")
                            Text(pads.on ? "Pad on: \(pads.keyName)" : "Start pad in \(pads.keyName)").lineLimit(1)
                            if pads.rendering { ProgressView().scaleEffect(0.5).frame(width: 14, height: 14) }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .big(pads.on ? .danger : .primary, height: Size.big, fullWidth: true, fontSize: 15)
                    .help("Start or fade out the pad (P)")
                    // Key buttons, laid out like the circle players think in.
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 6) {
                            ForEach(0..<6, id: \.self) { c in
                                let k = row * 6 + c
                                Button(action: { pads.play(key: k) }) {
                                    Text(MusicKey(tonic: k, minor: false).name).frame(maxWidth: .infinity)
                                }
                                .big(pads.key == k ? (pads.on ? .success : .primary) : .normal, height: 40, fullWidth: true, fontSize: 15)
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        Button(action: { if let k = kl.key { pads.play(key: k.tonic) } }) {
                            Text(kl.key.map { "Found key (\($0.name))" } ?? "Found key").frame(maxWidth: .infinity)
                        }
                        .big(fullWidth: true)
                        .disabled(kl.key == nil)
                        Button(action: { if let k = model.playingKey { pads.play(key: k.tonic) } }) {
                            Text(model.playingKey.map { "Song's key (\($0.name))" } ?? "Song's key").frame(maxWidth: .infinity)
                        }
                        .big(fullWidth: true)
                        .disabled(model.playingKey == nil)
                    }
                }
                Card("Sound", icon: "speaker.wave.2.fill") {
                    Segments(Array(PadSound.allCases.prefix(2)).map { ($0, $0.label) }, selection: $pads.sound, height: 32)
                    Segments(Array(PadSound.allCases.dropFirst(2)).map { ($0, $0.label) }, selection: $pads.sound, height: 32)
                    Segments(PadChord.allCases.map { ($0, $0.label) }, selection: $pads.chord, height: 32)
                    HStack(spacing: 8) {
                        Text("Volume").foregroundColor(.secondary).frame(width: 64, alignment: .leading)
                        Slider(value: Binding(get: { Double(pads.volume) }, set: { pads.volume = Float($0) }), in: 0...1.25)
                    }
                    HStack(spacing: 8) {
                        Text("Send to").foregroundColor(.secondary).frame(width: 64, alignment: .leading)
                        Segments(Route.allCases.map { ($0, $0.label) }, selection: $pads.route)
                    }
                    HStack(spacing: 8) {
                        Text("Fade").foregroundColor(.secondary).frame(width: 64, alignment: .leading)
                        Segments([(2.0, "in 2 s"), (4.0, "in 4 s"), (8.0, "in 8 s")], selection: $pads.fadeIn)
                    }
                    HStack(spacing: 8) {
                        Color.clear.frame(width: 64, height: 1)
                        Segments([(3.0, "out 3 s"), (6.0, "out 6 s"), (10.0, "out 10 s")], selection: $pads.fadeOut)
                    }
                }
                Caption("The pad plays on its own, under songs and loops, and keeps going when a song stops. Picking another key while it plays glides into it. Root + 5th fits major and minor songs.")
            }
            .padding(12)
        }
        .navigationTitle("Pads")
    }
}

// MARK: - Phone remote

struct RemoteView: View {
    @ObservedObject var server = RemoteServer.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Card {
                    ToggleTile(title: server.enabled ? "Phone control is on" : "Let a phone control the app", systemImage: "iphone",
                               isOn: server.enabled, onKind: .success, height: Size.big) { server.enabled.toggle() }
                    if server.enabled {
                        if let img = server.qrImage(size: 200) {
                            HStack { Spacer(); Image(nsImage: img).interpolation(.none).resizable().frame(width: 200, height: 200); Spacer() }
                        }
                        if server.address.isEmpty {
                            Caption("This Mac isn't on a network. Join the church Wi-Fi first.")
                        } else {
                            Text(verbatim: "http://\(server.address):\(RemoteServer.port)").font(.system(size: 13, design: .monospaced)).lineLimit(1)
                                .textSelection()
                            HStack(spacing: 6) {
                                Text("Code").foregroundColor(.secondary)
                                Text(server.pin).font(.system(size: 22, weight: .bold, design: .monospaced))
                                Spacer()
                                Button("New code") { server.newPIN() }.big()
                                Button("Refresh") { server.refreshAddress() }.big()
                            }
                        }
                        if !server.message.isEmpty { Caption(server.message) }
                    }
                }
                Caption("On the phone: join the same Wi-Fi as this MacBook, open the camera and scan the code. The page that opens has play, stop, fade, next, loop, tempo, key, the service list, pads and the key finder. Tip: in Safari use Share > Add to Home Screen so it opens like an app.")
                Caption("If the church Wi-Fi blocks devices from seeing each other, turn on the phone's hotspot and join it from the MacBook instead.")
            }
            .padding(12)
        }
        .onAppear { server.refreshAddress() }
        .navigationTitle("Phone Remote")
    }
}

extension View {
    @ViewBuilder func textSelection() -> some View {
        if #available(macOS 12.0, *) { self.textSelection(.enabled) } else { self }
    }
}

// MARK: - Keyboard (MIDI) control

struct MIDIView: View {
    @ObservedObject var midi = MIDIControl.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Card("Connected") {
                    if midi.sources.isEmpty {
                        Text("No keyboard found").foregroundColor(.secondary)
                        Caption("Connect the MOXF8's USB TO HOST port to the MacBook with a USB cable (or use a USB-MIDI cable into its MIDI OUT). If it still isn't listed, install the Yamaha USB-MIDI driver from yamaha.com.")
                    } else {
                        ForEach(midi.sources, id: \.self) { s in Label(s, systemImage: "pianokeys").lineLimit(1) }
                    }
                    ToggleTile(title: midi.enabled ? "Responding to the keyboard" : "Keyboard control is off", systemImage: "pianokeys",
                               isOn: midi.enabled, onKind: .success) { midi.enabled.toggle() }
                    if !midi.lastMessage.isEmpty {
                        Text("Last: \(midi.lastMessage)").font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                Card("Buttons") {
                    ForEach(MIDIAction.allCases) { a in
                        HStack(spacing: 6) {
                            Text(a.label).lineLimit(1).frame(width: 118, alignment: .leading)
                            if midi.learning == a {
                                Text("Press it now…").foregroundColor(.orange).lineLimit(1)
                                Spacer(minLength: 0)
                                Button("Cancel") { midi.learning = nil }.big(.warning, height: Size.small)
                            } else {
                                Text(midi.map[a]?.label ?? "Not set").font(.caption)
                                    .foregroundColor(midi.map[a] == nil ? .secondary : .primary).lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 0)
                                if midi.map[a] != nil {
                                    SquareButton(systemName: "xmark", size: Size.small, help: "Clear") { midi.clear(a) }
                                }
                                Button("Set") { midi.learning = a }.big(height: Size.small)
                            }
                        }
                    }
                }
                Caption("Click Set, then press the button, pedal or key on the keyboard you want to use. Good choices on the MOXF8: the assignable buttons [AF1] [AF2], a foot switch in the ASSIGNABLE FOOT SWITCH jack, or the very top or bottom key. The sustain pedal and mod wheel are ignored so they can't be picked by mistake.")
            }
            .padding(12)
        }
        .onAppear { midi.connectAll() }
        .navigationTitle("Keyboard Control")
    }
}
