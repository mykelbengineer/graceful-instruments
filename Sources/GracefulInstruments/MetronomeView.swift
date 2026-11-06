import SwiftUI

/// Stand-alone metronome: tempo, meter, subdivisions and click sound, without a track.
struct MetronomeView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var clock = AppModelHolder.clock
    @State private var taps: [Date] = []

    var running: Bool { model.current?.kind == .metronome && clock.playing }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Tempo
                VStack(spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(formatBPM(model.metroBPM)).font(.system(size: 56, weight: .bold, design: .rounded)).lineLimit(1)
                        Text("BPM").foregroundColor(.secondary)
                    }
                    HStack(spacing: 6) {
                        stepButton("−5", -5); stepButton("−1", -1)
                        Button("Tap") { tap() }.big(height: Size.big)
                        stepButton("+1", 1); stepButton("+5", 5)
                    }
                    Slider(value: $model.metroBPM, in: 30...240, step: 1)
                    BeatDots(beats: model.metroTimeSig.beatsPerBar, bpm: model.metroBPM, active: running)
                        .padding(.top, 2)
                    Button(action: { model.toggleMetronome() }) {
                        HStack(spacing: 6) {
                            Image(systemName: running ? "stop.fill" : "play.fill")
                            Text(running ? "Stop" : "Start").lineLimit(1)
                        }
                        .frame(width: 150)
                    }
                    .big(running ? .danger : .primary, height: Size.big, fontSize: 15)
                    .help("Start / stop (Space)")
                }
                .frame(maxWidth: .infinity)

                Card("Meter") {
                    Stacked("Time") {
                        Segments(TimeSig.allCases.map { ($0, $0.rawValue) }, selection: $model.metroTimeSig, height: 32)
                    }
                    Stacked("Subdivide") {
                        Segments([(1, "Off"), (2, "8ths"), (3, "Triplets"), (4, "16ths")], selection: $model.subdivision, height: 32)
                        .disabled(model.metroTimeSig.compound)
                    }
                    Toggle("Beat one louder (accent)", isOn: $model.accentOn)
                    if model.metroTimeSig.compound {
                        Caption("6/8 and 12/8 click every eighth note; the BPM counts the dotted-quarter pulse.")
                    }
                }

                Card("Sound") {
                    ForEach(0..<(ClickSound.allCases.count + 1) / 2, id: \.self) { row in
                        HStack(spacing: 6) {
                            ForEach(Array(ClickSound.allCases[(row * 2)..<min(row * 2 + 2, ClickSound.allCases.count)])) { snd in
                                Button(action: { model.clickSound = snd }) {
                                    Text(snd.label).frame(maxWidth: .infinity)
                                }
                                .big(model.clickSound == snd ? .primary : .normal, fullWidth: true)
                            }
                        }
                    }
                    Stacked("Volume") {
                        Slider(value: Binding(get: { Double(model.clickVol) }, set: { model.clickVol = Float($0) }), in: 0...1.25)
                    }
                    Stacked("Send to") {
                        Segments(Route.allCases.map { ($0, $0.label) }, selection: $model.clickRoute, height: 32)
                    }
                    Caption("The sound, accent and subdivision also apply to the click under tracks.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .navigationTitle("Metronome")
    }

    func stepButton(_ title: String, _ d: Double) -> some View {
        Button(title) { model.metroBPM = min(240, max(30, model.metroBPM.rounded() + d)) }
            .big(height: Size.big)
    }

    func tap() {
        let now = Date()
        if let last = taps.last, now.timeIntervalSince(last) > 2 { taps.removeAll() }
        taps.append(now)
        if taps.count > 6 { taps.removeFirst() }
        guard taps.count >= 3 else { return }
        let gaps = zip(taps.dropFirst(), taps).map { $0.timeIntervalSince($1) }
        model.metroBPM = min(240, max(30, (60 / (gaps.reduce(0, +) / Double(gaps.count))).rounded()))
    }
}

/// Small label on top, control underneath: fits the narrow middle column.
struct Stacked<Content: View>: View {
    let label: String
    let content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) { self.label = label; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundColor(.secondary).lineLimit(1)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One dot per beat; the current beat lights up while the metronome runs.
struct BeatDots: View {
    @ObservedObject private var clock = AppModelHolder.clock
    let beats: Int
    let bpm: Double
    let active: Bool

    var body: some View {
        let current = active ? Int(clock.position * bpm / 60) % max(beats, 1) : -1
        HStack(spacing: 10) {
            ForEach(0..<beats, id: \.self) { i in
                Circle()
                    .fill(i == current ? (i == 0 ? Color.orange : Color.accentColor) : Color(NSColor.separatorColor))
                    .frame(width: i == 0 ? 16 : 12, height: i == 0 ? 16 : 12)
            }
        }
        .frame(height: 18)
    }
}
