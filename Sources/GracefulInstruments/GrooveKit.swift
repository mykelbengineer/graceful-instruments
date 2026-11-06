import Foundation
import Accelerate

/// Recorded drum and percussion hits (Resources/Drums), several loudness layers and alternate takes each.
enum Hit: String, CaseIterable {
    case kick, snare, rimshot, xstick, clap
    case hat, halfhat, openhat, pedalhat, ride, ridebell, crash
    case tomhi, tomlo
    case conga, congamute, tumba, bongohi, bongolo, djembe
    case agogohi, agogolo, claves
    case shaker, cabasa, tamb

    var part: GroovePart {
        switch self {
        case .kick: return .kick
        case .snare, .rimshot, .xstick, .clap: return .snare
        case .hat, .halfhat, .openhat, .pedalhat, .ride, .ridebell, .crash: return .hats
        case .shaker, .cabasa, .tamb: return .shaker
        case .conga, .congamute, .tumba, .bongohi, .bongolo, .djembe, .tomhi, .tomlo: return .congas
        case .agogohi, .agogolo, .claves: return .bell
        }
    }

    /// Mix level and stereo position (as heard from the audience).
    var level: Float {
        switch self {
        case .kick: return 1.0
        case .snare: return 0.72
        case .rimshot: return 0.62
        case .xstick: return 0.5
        case .clap: return 0.42
        case .hat, .halfhat, .pedalhat: return 0.36
        case .openhat: return 0.3
        case .ride: return 0.3
        case .ridebell: return 0.26
        case .crash: return 0.38
        case .tomhi, .tomlo: return 0.62
        case .conga, .congamute: return 0.5
        case .tumba: return 0.55
        case .bongohi, .bongolo: return 0.42
        case .djembe: return 0.55
        case .agogohi, .agogolo: return 0.26
        case .claves: return 0.3
        case .shaker: return 0.34
        case .cabasa: return 0.3
        case .tamb: return 0.26
        }
    }
    var pan: Float {
        switch self {
        // The kit is recorded in stereo (overhead and room mics), so it keeps its own image.
        case .kick, .snare, .rimshot, .xstick, .clap, .hat, .halfhat, .openhat, .pedalhat, .ride, .ridebell, .crash, .tomhi, .tomlo: return 0
        case .conga: return -0.3
        case .congamute: return -0.3
        case .tumba: return -0.1
        case .bongohi: return 0.4
        case .bongolo: return 0.3
        case .djembe: return 0.15
        case .agogohi, .agogolo: return 0.45
        case .claves: return 0.5
        case .shaker: return -0.45
        case .cabasa: return -0.5
        case .tamb: return 0.55
        }
    }
    /// Small timing feel per instrument, in milliseconds (positive = later, laid back).
    var lateMs: Double {
        switch self {
        case .snare, .rimshot, .clap: return 4
        case .hat, .halfhat, .openhat, .pedalhat: return 1
        case .shaker, .cabasa: return -2
        default: return 0
        }
    }
    var family: Int { [.hat, .halfhat, .openhat, .pedalhat].contains(self) ? 1 : 0 }

    /// How loosely a player places this hit, in ms (one standard deviation).
    var spreadMs: Double {
        switch self {
        case .kick: return 2.5
        case .snare, .rimshot, .xstick, .clap: return 3
        case .hat, .halfhat, .openhat, .pedalhat, .ride, .ridebell: return 3.5
        case .crash, .tomhi, .tomlo: return 4
        default: return 5
        }
    }
    /// Instruments that keep time on every subdivision get the natural "strong-weak" lilt.
    var timekeeper: Bool { [.hat, .halfhat, .ride, .shaker, .cabasa, .tamb, .pedalhat].contains(self) }

    /// File prefix in Resources/Drums. The shaker alternates down and up strokes.
    var files: [String] {
        switch self {
        case .shaker: return ["shakerdn", "shakerup"]
        default: return [rawValue]
        }
    }

    /// Synthesized stand-in when the recordings are missing.
    var synth: Drum {
        switch self {
        case .kick: return .kick
        case .snare, .rimshot: return .snare
        case .xstick, .claves: return .rim
        case .clap: return .clap
        case .hat, .halfhat, .pedalhat, .ride, .ridebell: return .hat
        case .openhat, .crash: return .openHat
        case .shaker, .cabasa, .tamb: return .shaker
        case .agogohi, .agogolo: return .bell
        case .conga, .congamute, .bongohi, .bongolo: return .congaHi
        case .tumba, .djembe: return .congaLo
        case .tomhi: return .tomHi
        case .tomlo: return .tomLo
        }
    }
}

/// One recorded hit, stereo.
struct Take { let l: [Float]; let r: [Float]; var count: Int { l.count } }

/// Loads the recorded hits once.
enum DrumKit {
    /// strokes[stroke][velocityLayer][take]
    private static var cache: [Hit: [[[Take]]]] = [:]
    private static let lock = NSLock()

    static var dir: URL? {
        let fm = FileManager.default
        if let d = ProcessInfo.processInfo.environment["GI_DRUMS_DIR"] { return URL(fileURLWithPath: d) }
        if let r = Bundle.main.resourceURL?.appendingPathComponent("Drums"), fm.fileExists(atPath: r.appendingPathComponent("kick_v1_r1.wav").path) { return r }
        // Development builds: walk up from the executable to the project's Resources folder.
        var u = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let c = u.appendingPathComponent("Resources/Drums")
            if fm.fileExists(atPath: c.appendingPathComponent("kick_v1_r1.wav").path) { return c }
            u = u.deletingLastPathComponent()
        }
        return nil
    }

    static var available: Bool { dir != nil }

    static func strokes(_ h: Hit) -> [[[Take]]] {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[h] { return c }
        var out: [[[Take]]] = []
        if let d = dir {
            for prefix in h.files {
                var layers: [[Take]] = []
                var v = 1
                while true {
                    var takes: [Take] = []
                    var r = 1
                    while true {
                        let u = d.appendingPathComponent("\(prefix)_v\(v)_r\(r).wav")
                        guard FileManager.default.fileExists(atPath: u.path), let a = try? AudioLoader.load(u) else { break }
                        takes.append(Take(l: Array(UnsafeBufferPointer(start: a.l, count: a.frames)),
                                          r: Array(UnsafeBufferPointer(start: a.r, count: a.frames))))
                        r += 1
                    }
                    if takes.isEmpty { break }
                    layers.append(takes)
                    v += 1
                }
                if !layers.isEmpty { out.append(layers) }
            }
        }
        if out.isEmpty { let x = DrumSynth.sound(h.synth); out = [[[Take(l: x, r: x)]]] }
        cache[h] = out
        return out
    }
}

/// Step patterns: X accent, x normal, o soft, g ghost, . rest. A pattern may cover 1 or 2 bars.
struct GrooveStyle: Identifiable {
    let id: String
    let name: String
    let timeSig: TimeSig
    let defaultBPM: Double
    let stepsPerBar: Int
    let parts: [(Hit, String)]
    /// Replaces matching parts (or adds new ones) in the last bar of the 8.
    let fill: [(Hit, String)]
    /// Delay of the off-beat 16ths (0 straight ... 0.33 triplet feel).
    let swing: Double
    var crashOnOne = false
    var note = ""
    /// How often the drummer drops in soft ghost notes on the snare (0...0.2).
    var ghosts: Double { ["afrobeat": 0.16, "highlife": 0.1, "worship44": 0.08, "makossa": 0.08, "africanworship": 0.08,
                          "dancehall": 0.05, "steppers": 0.06, "afrobeats": 0.06, "soukous": 0.05, "reggae": 0.04][id] ?? 0.0 }
    /// Kit styles get a drummer's tom fills; hand-drum styles keep their own.
    var usesKit: Bool { parts.contains { [.snare, .rimshot, .xstick].contains($0.0) } && parts.contains { $0.0 == .kick } }

    static func find(_ id: String?) -> GrooveStyle? { all.first { $0.id == id } }

    static let all: [GrooveStyle] = [
        // ---- Worship (slow) ----
        GrooveStyle(id: "worship44", name: "Worship 4/4", timeSig: .fourFour, defaultBPM: 70, stepsPerBar: 16,
            parts: [(.kick, "X.......x.x.....X.......x......."), (.xstick, "....x.......x.......x.......x..."),
                    (.hat, "x.o.x.o.x.o.x.o.x.o.x.o.x.o.x.og"), (.shaker, "xgogxgogxgogxgogxgogxgogxgogxgog"),
                    (.tumba, "..............o...............o.")],
            fill: [(.xstick, "....x..........."), (.tomhi, "........x.o.x..."), (.tomlo, "............x.x."),
                   (.kick, "X.......x......."), (.hat, "x.o.x.o.........")], swing: 0.06, crashOnOne: true),
        GrooveStyle(id: "worship68", name: "Worship 6/8", timeSig: .sixEight, defaultBPM: 66, stepsPerBar: 12,
            parts: [(.kick, "X.........o.X..........."), (.xstick, "......x...........x....."),
                    (.hat, "x.o.o.x.o.o.x.o.o.x.o.og"), (.shaker, "xgogxgxgogxgxgogxgxgogxg")],
            fill: [(.xstick, "......x....."), (.tomhi, "......x.o.x."), (.tomlo, "..........x."), (.hat, "x.o.o.......")],
            swing: 0, crashOnOne: true),
        GrooveStyle(id: "worship34", name: "Worship 3/4", timeSig: .threeFour, defaultBPM: 80, stepsPerBar: 12,
            parts: [(.kick, "X...........X.......o..."), (.xstick, "....x...x.......x...x..."),
                    (.hat, "x.o.x.o.x.o.x.o.x.o.x.o."), (.shaker, "xgogxgogxgogxgogxgogxgog")],
            fill: [(.xstick, "....x......."), (.tomhi, "........x.o."), (.tomlo, "..........x.")], swing: 0.06),
        GrooveStyle(id: "ballad128", name: "Gospel Ballad 12/8", timeSig: .twelveEight, defaultBPM: 58, stepsPerBar: 12,
            parts: [(.kick, "X.....X..o..X.....X....o"), (.rimshot, "...o.....x.....o.....x.."),
                    (.hat, "xooxooxooxooxooxooxooxoo"), (.tumba, "........o..........o....")],
            fill: [(.rimshot, "...o........"), (.tomhi, "......x.ox.."), (.tomlo, ".........xox"), (.hat, "xooxoo......")],
            swing: 0, crashOnOne: true, note: "Slow 12/8 church ballad with a light backbeat."),
        GrooveStyle(id: "perc68", name: "Percussive Worship 6/8", timeSig: .sixEight, defaultBPM: 78, stepsPerBar: 12,
            parts: [(.kick, "X.....o.....X.....o....."), (.tumba, "....x.......o.x.....x..."),
                    (.conga, "x.o.....x.o.x.o.....x.o."), (.congamute, "......o...........o....."),
                    (.shaker, "XgoxgoXgoxgoXgoxgoXgoxgo"), (.djembe, "......x...........x..o..")],
            fill: [(.conga, "x.o.x.o.x.x."), (.tumba, "........x.X."), (.djembe, "......x.x.xx")], swing: 0),

        // ---- Reggae ----
        GrooveStyle(id: "reggae", name: "Reggae One Drop", timeSig: .fourFour, defaultBPM: 76, stepsPerBar: 16,
            parts: [(.kick, "........X...............X......."), (.xstick, "........x...............x......."),
                    (.hat, "x.o.x.o.x.o.x.o.x.o.x.o.x.o.x.x."), (.openhat, "..............o..............o.."),
                    (.bongohi, "..o.......o.......o.......o..o..")],
            fill: [(.xstick, "........x..."), (.rimshot, "............x.x."), (.tomlo, "..............x.")],
            swing: 0.28, note: "Kick and rim together on beat 3, swung hats."),
        GrooveStyle(id: "steppers", name: "Reggae Praise (Steppers)", timeSig: .fourFour, defaultBPM: 84, stepsPerBar: 16,
            parts: [(.kick, "X...X...X...X...X...X...X...X..."), (.rimshot, "........X...............X......."),
                    (.hat, "x.x.x.x.x.x.x.x.x.x.x.x.x.x.x.x."), (.openhat, "..o...o...o...o...o...o...o...o."),
                    (.shaker, "gogxgogxgogxgogxgogxgogxgogxgogx")],
            fill: [(.rimshot, "........X...x.x."), (.tomhi, "..........x....."), (.tomlo, "..............x.")],
            swing: 0.2, crashOnOne: true),
        GrooveStyle(id: "dancehall", name: "Dancehall Praise", timeSig: .fourFour, defaultBPM: 92, stepsPerBar: 16,
            parts: [(.kick, "X...x...X...x...X...x...X...x..."), (.rimshot, "...x..x....x..x....x..x....x..x."),
                    (.hat, "x.x.x.x.x.x.x.x.x.x.x.x.x.x.x.x."), (.shaker, "gogxgogxgogxgogxgogxgogxgogxgogx"),
                    (.conga, "......x.......x.......x.....x.x.")],
            fill: [(.rimshot, "...x..x....xx.x."), (.tomlo, "............x.x.")], swing: 0),

        // ---- West African ----
        GrooveStyle(id: "highlife", name: "Highlife", timeSig: .fourFour, defaultBPM: 124, stepsPerBar: 16,
            parts: [(.kick, "X.......X..x....X.......X..x...."), (.xstick, "......x.......x.......x.......x."),
                    (.agogohi, "X.x.xx.x.x.xx.x.X.x.xx.x.x.xx.x."), (.claves, "x..x..x...x.x...x..x..x...x.x..."),
                    (.shaker, "xoxoxoxoxoxoxoxoxoxoxoxoxoxoxoxo"), (.conga, "..x...x.x.x...x...x...x.x.x...x."),
                    (.tumba, "......x.......x.......x.......x."), (.hat, "..x...x...x...x...x...x...x...x.")],
            fill: [(.conga, "..x...x.x.x.x.x."), (.tumba, "......x...x.x.x."), (.rimshot, "............x.x.")],
            swing: 0.1, note: "Ghanaian and Nigerian highlife. The bell and claves are its heartbeat (Bell part)."),
        GrooveStyle(id: "juju", name: "Juju", timeSig: .fourFour, defaultBPM: 112, stepsPerBar: 16,
            parts: [(.kick, "X.......X.......X.......X......."), (.djembe, "X..x..x...x.o...X..x..x...x.o.x."),
                    (.tumba, "....x.......x.x.....x.......x.x."), (.conga, "..o...o...o...o...o...o...o...o."),
                    (.agogolo, "x.....x.....x...x.....x.....x..."), (.agogohi, "..x.x...x.x...x...x.x...x.x...x."),
                    (.cabasa, "xoxoxoxoxoxoxoxoxoxoxoxoxoxoxoxo"), (.xstick, "....x.......x.......x.......x...")],
            fill: [(.djembe, "X..x..x.x.x.x.xx"), (.tumba, "....x...x.x.x.x.")],
            swing: 0.12, note: "Yoruba juju feel. Djembe and tumba stand in for the talking drum; cabasa for the shekere."),
        GrooveStyle(id: "afrobeat", name: "Afrobeat", timeSig: .fourFour, defaultBPM: 110, stepsPerBar: 16,
            parts: [(.kick, "X..x..x...x.x...X..x..x...x....."), (.snare, "....X..g.g..X.g.....X..g.g..X.gg"),
                    (.hat, "xoxxoxoxxoxoxxoxxoxxoxoxxoxoxxox"), (.openhat, "..............x...............x."),
                    (.claves, "x..x..x...x.x...x..x..x...x.x..."), (.cabasa, "xoxoxoxoxoxoxoxoxoxoxoxoxoxoxoxo"),
                    (.conga, "..x.x...x.x.x.....x.x...x.x.x..."), (.tumba, "......x.......x.......x.....x.x.")],
            fill: [(.snare, "....X..g.g..XgXg"), (.tomhi, "..........x....."), (.tomlo, "..............x.")],
            swing: 0.08, note: "Fela-style Afrobeat: busy hats, ghost notes, claves and shekere."),
        GrooveStyle(id: "afrobeats", name: "Afrobeats Praise", timeSig: .fourFour, defaultBPM: 104, stepsPerBar: 16,
            parts: [(.kick, "X..x..x...X.....X..x..x...X..x.."), (.xstick, "...x..x...x.....x..x..x...x...x."),
                    (.clap, "....x.......x.......x.......x..."), (.shaker, "xgogxgogxgogxgogxgogxgogxgogxgog"),
                    (.conga, "..o...x.....o.x...o...x.....o.x."), (.tumba, "......x.......x.......x.......x."),
                    (.hat, "..x...x...x...x...x...x...x...x.")],
            fill: [(.xstick, "...x..x...x.x.x."), (.tumba, "........x.x.x.x.")],
            swing: 0.14, note: "Modern Afropop praise: the 3-3-2 rim and shaker, claps on 2 and 4."),
        GrooveStyle(id: "makossa", name: "Makossa", timeSig: .fourFour, defaultBPM: 130, stepsPerBar: 16,
            parts: [(.kick, "X...X...X...X...X...X...X...X..."), (.snare, "....X.......X.......X.......X..."),
                    (.hat, "xoxoxoxoxoxoxoxoxoxoxoxoxoxoxoxo"), (.openhat, "..x...x...x...x...x...x...x...x."),
                    (.conga, "..x..x.x..x..x.x..x..x.x..x..x.x"), (.tumba, "......x.......x.......x.......x."),
                    (.shaker, "gogxgogxgogxgogxgogxgogxgogxgogx")],
            fill: [(.snare, "....X.......X.x."), (.tomhi, "..........x....."), (.tomlo, "..............x.")],
            swing: 0.04, crashOnOne: true, note: "Cameroonian makossa: four on the floor with open hats on the off-beats."),
        GrooveStyle(id: "soukous", name: "Soukous Praise", timeSig: .fourFour, defaultBPM: 140, stepsPerBar: 16,
            parts: [(.kick, "X...X...X...X...X...X...X...X..."), (.rimshot, "x..x..x...x.x...x..x..x...x.x..."),
                    (.hat, "xoxoxoxoxoxoxoxoxoxoxoxoxoxoxoxo"), (.snare, "....x.......x.......x.......x..."),
                    (.conga, "..x...x...x...x...x...x...x...x."), (.tamb, "....x.......x.......x.......x...")],
            fill: [(.snare, "....x...x.x.xxxx"), (.tomlo, "............x.x.")],
            swing: 0, crashOnOne: true, note: "Congolese soukous / ndombolo drive for fast praise."),
        GrooveStyle(id: "africanworship", name: "African Worship", timeSig: .fourFour, defaultBPM: 112, stepsPerBar: 16,
            parts: [(.kick, "X.....x...x.....X.....x...x....."), (.xstick, "....X.......X.......X.......X..."),
                    (.shaker, "xogxxogxxogxxogxxogxxogxxogxxogx"), (.agogohi, "x..x..x...x.x...x..x..x...x.x..."),
                    (.tumba, "......x.......x.......x.....x.x."), (.conga, "..x.x...x.x.x.....x.x...x.x....."),
                    (.hat, "..x...x...x...x...x...x...x...x.")],
            fill: [(.conga, "..x.x...x.x.x.xx"), (.rimshot, "....X.......X.x.")], swing: 0.1),
        GrooveStyle(id: "africanpraise", name: "African Praise (fast)", timeSig: .fourFour, defaultBPM: 138, stepsPerBar: 16,
            parts: [(.kick, "X..x..X.X..x..X.X..x..X.X..x..X."), (.snare, "....X.......X..x....X.......X..x"),
                    (.shaker, "gXgxgXgxgXgxgXgxgXgxgXgxgXgxgXgx"), (.agogohi, "x.x..x.x.x..x.x.x.x..x.x.x..x.x."),
                    (.conga, "..xx..x...xx..x...xx..x...xx..x."), (.tumba, ".......x.......x.......x.......x"),
                    (.clap, "....x.......x.......x.......x...")],
            fill: [(.snare, "....X.......X.xx"), (.conga, "..xx..x.x.xxx.x.")], swing: 0.06, crashOnOne: true),
        GrooveStyle(id: "ariaria128", name: "Praise 12/8 (Ariaria bell)", timeSig: .twelveEight, defaultBPM: 108, stepsPerBar: 12,
            parts: [(.agogohi, "x.x.xx.x.x.x"), (.kick, "x.....x.....x.....x....."),
                    (.tumba, "...x.....x.....x.....x.x"), (.conga, "x.o..ox.o..ox.o..ox.o..o"),
                    (.shaker, "xoxxoxxoxxoxxoxxoxxoxxox"), (.rimshot, "...........x...........x")],
            fill: [(.conga, "x.o..ox.oxox"), (.rimshot, "......x..xxx")], swing: 0,
            note: "Igbo 12/8 praise. The bell is the timeline (Bell part)."),
    ]
}

extension DrumSynth {
    /// Renders `bars` bars (default 8; the last is a fill) as separately mixable parts. Each part is a seamless stereo loop.
    static func renderParts(_ style: GrooveStyle, bpm rawBPM: Double, bars: Int = 8) -> [GroovePart: AudioData] {
        let sr = AudioData.sampleRate
        // A bad tempo (0, NaN, a mistyped 2000) must never size the buffers.
        let bpm = rawBPM.isFinite ? min(max(rawBPM, 30), 260) : style.defaultBPM
        let barSec = 60 / bpm * Double(style.timeSig.beatsPerBar)
        let frames = Int((barSec * Double(bars) * sr).rounded())
        var out: [GroovePart: AudioData] = [:]
        for p in GroovePart.allCases { out[p] = AudioData(frames: frames) }
        var rng = SystemRandomNumberGenerator()
        let stepSec = barSec / Double(style.stepsPerBar)
        func vel(_ c: Character) -> Float? {
            switch c {
            case "X": return 1.0
            case "x": return 0.78
            case "o": return 0.55
            case "g": return 0.3
            default: return nil
            }
        }
        struct Event { var hit: Hit; var time: Double; var vel: Float; var step: Int }
        func gauss() -> Double { // Box-Muller
            let u1 = max(1e-9, Double.random(in: 0..<1, using: &rng)), u2 = Double.random(in: 0..<1, using: &rng)
            return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
        }
        func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
        let spb = max(1, style.stepsPerBar / style.timeSig.beatsPerBar) // steps per beat
        // A drummer leans into some bars and backs off in others, and builds into the fill.
        let barLift: [Float] = [1.0, 0.95, 0.98, 0.96, 1.0, 0.95, 0.99, 1.04]
        var events: [Event] = []
        let snareHit: Hit? = style.parts.first { [.snare, .rimshot, .xstick].contains($0.0) }?.0
        let hasOpenHat = style.parts.contains { $0.0 == .openhat }
        let hasHat = style.parts.contains { $0.0 == .hat }
        // Two fills to choose from: the style's own, or a drummer's tom run.
        let tomFill = style.usesKit && chance(0.5)
        for bar in 0..<bars {
            let isFill = bar == bars - 1
            var parts = style.parts
            if isFill {
                if tomFill {
                    // Keep beats 1-2, then snare and toms down the kit on the last two beats.
                    let half = style.stepsPerBar / 2
                    let n = style.stepsPerBar - half
                    let run: [Hit] = (0..<n).map { i in i < n / 3 ? (snareHit ?? .snare) : (i < 2 * n / 3 ? .tomhi : .tomlo) }
                    parts = parts.map { (h, pat) in
                        guard ![Hit.snare, .rimshot, .xstick, .hat, .openhat, .halfhat].contains(h) else {
                            let c = Array(pat.prefix(style.stepsPerBar))
                            return (h, String(c.prefix(half)) + String(repeating: ".", count: max(0, c.count - half)))
                        }
                        return (h, pat)
                    }
                    for hit in [snareHit ?? .snare, .tomhi, .tomlo] {
                        var c = [Character](repeating: ".", count: style.stepsPerBar)
                        for (i, h) in run.enumerated() where h == hit && i % (spb >= 4 ? 1 : 1) == 0 { c[half + i] = i == n - 1 ? "X" : (i % 2 == 0 ? "x" : "o") }
                        parts.append((hit, String(c)))
                    }
                } else {
                    for (h, pat) in style.fill {
                        if let i = parts.firstIndex(where: { $0.0 == h }) { parts[i] = (h, pat) } else { parts.append((h, pat)) }
                    }
                }
            }
            for (h, pattern) in parts where !pattern.isEmpty {
                let chars = Array(pattern)
                let barsInPattern = max(1, chars.count / style.stepsPerBar)
                let segment = bar % barsInPattern
                for step in 0..<style.stepsPerBar {
                    let ci = segment * style.stepsPerBar + step
                    guard ci < chars.count, var v = vel(chars[ci]) else { continue }
                    var hit = h
                    // Shakers and hats lose the odd stroke; nobody plays every note the same.
                    if [.shaker, .cabasa, .tamb].contains(h) && chars[ci] != "X" && chance(0.03) { continue }
                    if h.timekeeper && chars[ci] != "X" {
                        let pos = step % spb
                        v *= pos == 0 ? 1.0 : (spb % 2 == 0 && pos == spb / 2 ? 0.84 : 0.7)
                    }
                    // Open the hat on the last off-beat before a new phrase.
                    if h == .hat && !hasOpenHat && !isFill && (bar == 3 || bar == 6) && step == style.stepsPerBar - spb / 2 && chance(0.6) {
                        hit = .openhat
                    }
                    v *= barLift[bar % barLift.count] * Float(1 + gauss() * 0.06)
                    var t = Double(bar) * barSec + Double(step) * stepSec
                    if style.stepsPerBar % 4 == 0 && step % 2 == 1 { t += style.swing * stepSec }
                    t += hit.lateMs / 1000 + gauss() * hit.spreadMs / 1000
                    events.append(Event(hit: hit, time: t, vel: max(0.05, min(1.1, v)), step: step))
                }
            }
            // Ghost notes: soft snare taps between the main hits.
            if !isFill, let sh = snareHit, style.ghosts > 0 {
                let pat = Array(parts.first { $0.0 == sh }?.1 ?? "")
                let seg = (bar % max(1, pat.count / style.stepsPerBar)) * style.stepsPerBar
                for step in stride(from: 1, to: style.stepsPerBar, by: 2) where seg + step < pat.count && pat[seg + step] == "." && chance(style.ghosts) {
                    let t = Double(bar) * barSec + (Double(step) + style.swing) * stepSec + gauss() * 0.004
                    events.append(Event(hit: sh == .xstick ? .xstick : .snare, time: t, vel: 0.2 + Float(gauss() * 0.04), step: step))
                }
            }
            // An extra kick pushing into the next phrase now and then.
            if bar == 3 && style.usesKit && chance(0.35) {
                let step = style.stepsPerBar - spb / 2
                events.append(Event(hit: .kick, time: Double(bar) * barSec + Double(step) * stepSec + gauss() * 0.003, vel: 0.6, step: step))
            }
            if style.crashOnOne && bar == 0 {
                events.append(Event(hit: .crash, time: 0, vel: 0.75, step: 0))
            }
        }
        _ = hasHat
        // Hi-hats: an open hat is cut off by the next closed or pedal hat, like a real drummer's foot.
        let hatTimes = events.filter { $0.hit.family == 1 }.map(\.time).sorted()
        var takeIndex: [String: Int] = [:]
        for e in events {
            let strokes = DrumKit.strokes(e.hit)
            let stroke = strokes[(e.hit == .shaker ? e.step : 0) % strokes.count]
            // Pick the loudness layer with a little blur, like a real player's touch.
            let lf = Double(e.vel) * Double(stroke.count) - 0.5 + gauss() * 0.3
            let li = min(stroke.count - 1, max(0, Int(lf.rounded())))
            let takes = stroke[li]
            let key = "\(e.hit.rawValue)-\(li)"
            let ti = (takeIndex[key] ?? Int.random(in: 0..<takes.count, using: &rng)) % takes.count
            takeIndex[key] = ti + 1 + (takes.count > 2 && chance(0.5) ? 1 : 0)
            let snd = takes[ti]
            let g = e.hit.level * (0.5 + 0.5 * e.vel)
            var len = snd.count
            if e.hit == .openhat, let next = hatTimes.first(where: { $0 > e.time + 0.01 }) {
                len = min(len, Int((next - e.time) * sr) + Int(0.02 * sr))
            }
            let fadeLen = Int(0.02 * sr)
            let dst = out[e.hit.part]!
            let gL = g * min(1, 1 - e.hit.pan), gR = g * min(1, 1 + e.hit.pan)
            var start = Int((e.time * sr).rounded())
            start = ((start % frames) + frames) % frames
            for k in 0..<len {
                var f: Float = 1
                if len < snd.count && k > len - fadeLen { f = Float(len - k) / Float(fadeLen) }
                if start >= frames { start -= frames } // tails wrap round to the loop start
                dst.l[start] += snd.l[k] * gL * f
                dst.r[start] += snd.r[k] * gR * f
                start += 1
            }
        }
        // Studio treatment: the kick and snare are compressed and lightly driven, as on a record.
        compress(out[.kick]!, ratio: 3.5, drive: 1.3)
        compress(out[.snare]!, ratio: 3, drive: 1.2)
        compress(out[.congas]!, ratio: 2, drive: 1.0)
        for p in GroovePart.allCases { roomLoop(out[p]!, wet: p.reverb * (p == .congas || p == .shaker || p == .bell ? 0.5 : 0.3)) }
        // One gain for every part (from the default mix) so the balance holds.
        let mixed = defaultMix(out, frames: frames)
        var peak: Float = 0
        vDSP_maxmgv(mixed.l, 1, &peak, vDSP_Length(frames))
        var peakR: Float = 0
        vDSP_maxmgv(mixed.r, 1, &peakR, vDSP_Length(frames))
        peak = max(peak, peakR)
        var gain: Float = peak > 0 ? 0.8 / peak : 1
        for p in GroovePart.allCases {
            let d = out[p]!
            vDSP_vsmul(d.l, 1, &gain, d.l, 1, vDSP_Length(frames))
            vDSP_vsmul(d.r, 1, &gain, d.r, 1, vDSP_Length(frames))
        }
        masterLimit(out, frames: frames)
        return out
    }

    /// Brings the groove up to the loudness of a produced loop: one limiter, driven by the full mix and
    /// applied to every part alike, so the parts still add up to the same balanced mix.
    static func masterLimit(_ parts: [GroovePart: AudioData], frames n: Int) {
        guard n > 0 else { return }
        let m = defaultMix(parts, frames: n)
        let look = Int(0.0015 * AudioData.sampleRate)
        // |l|, |r| and their max, with the start repeated at the end so the look-ahead wraps round the loop.
        var mix = [Float](repeating: 0, count: n + look)
        var absR = [Float](repeating: 0, count: n)
        vDSP_vabs(m.l, 1, &mix, 1, vDSP_Length(n))
        vDSP_vabs(m.r, 1, &absR, 1, vDSP_Length(n))
        vDSP_vmax(mix, 1, absR, 1, &mix, 1, vDSP_Length(n))
        for k in 0..<look { mix[n + k] = mix[k % n] }
        // RMS of the mono sum.
        var mono = [Float](repeating: 0, count: n)
        var half: Float = 0.5
        vDSP_vasm(m.l, 1, m.r, 1, &half, &mono, 1, vDSP_Length(n))
        var ms: Float = 0
        vDSP_measqv(mono, 1, &ms, vDSP_Length(n))
        let rms = sqrt(ms)
        guard rms > 0 else { return }
        let makeup = min(3.2, max(1, 0.13 / rms))   // aim for about -18 dB RMS, never more than +10 dB
        let ceiling: Float = 0.85
        let rel = exp(-1 / (0.06 * Float(AudioData.sampleRate)))
        // Gain needed at each moment (looking slightly ahead so peaks are caught in time).
        var ahead = [Float](repeating: 0, count: n)
        vDSP_vswmax(mix, 1, &ahead, 1, vDSP_Length(n), vDSP_Length(look + 1))
        var need = [Float](repeating: 1, count: n)
        for i in 0..<n {
            let x = ahead[i] * makeup
            need[i] = x > ceiling ? ceiling / x : 1
        }
        var g: Float = 1
        var gains = [Float](repeating: 1, count: n)
        for pass in 0..<2 { // round the loop twice so the start is settled
            for i in 0..<n {
                g = need[i] < g ? need[i] : rel * g + (1 - rel) * need[i]
                if g > need[i] { g = need[i] }
                if pass == 1 { gains[i] = g * makeup }
            }
        }
        for p in GroovePart.allCases {
            let d = parts[p]!
            vDSP_vmul(d.l, 1, gains, 1, d.l, 1, vDSP_Length(n))
            vDSP_vmul(d.r, 1, gains, 1, d.r, 1, vDSP_Length(n))
        }
    }

    /// The parts that play by default, summed (used for level and limiting).
    static func defaultMix(_ parts: [GroovePart: AudioData], frames n: Int) -> AudioData {
        let out = AudioData(frames: n)
        for p in GroovePart.allCases where p.defaultLevel > 0 {
            guard let d = parts[p] else { continue }
            let k = vDSP_Length(min(n, d.frames))
            vDSP_vadd(out.l, 1, d.l, 1, out.l, 1, k)
            vDSP_vadd(out.r, 1, d.r, 1, out.r, 1, k)
        }
        return out
    }

    /// Feed-forward compressor with a soft-clip stage. Runs round the loop twice so the start is already settled.
    static func compress(_ d: AudioData, ratio: Float, drive: Float) {
        let n = d.frames
        guard n > 0 else { return }
        var peak: Float = 0
        for i in 0..<n { peak = max(peak, abs(d.l[i]), abs(d.r[i])) }
        guard peak > 0 else { return }
        let thr = peak * 0.35
        let sr = Float(AudioData.sampleRate)
        let att = exp(-1 / (0.004 * sr)), rel = exp(-1 / (0.09 * sr))
        var env: Float = 0
        for pass in 0..<2 {
            for i in 0..<n {
                let x = max(abs(d.l[i]), abs(d.r[i]))
                env = x > env ? att * env + (1 - att) * x : rel * env + (1 - rel) * x
                guard pass == 1 else { continue }
                var g: Float = 1
                if env > thr { g = pow(env / thr, 1 / ratio - 1) }
                let l = d.l[i] * g / peak * drive, r = d.r[i] * g / peak * drive
                d.l[i] = tanh(l) * peak; d.r[i] = tanh(r) * peak
            }
        }
    }

    /// A short, natural room on a loop: run it round twice so the tail at the end carries into the start.
    static func roomLoop(_ d: AudioData, wet: Float) {
        guard wet > 0 else { return }
        let n = d.frames
        var L = [Float](repeating: 0, count: n * 2), R = L
        for i in 0..<n { L[i] = d.l[i]; L[i + n] = d.l[i]; R[i] = d.r[i]; R[i + n] = d.r[i] }
        let dryL = L, dryR = R
        Reverb.hall(&L, &R, wet: 1, decay: 0.62)
        for i in 0..<n {
            // hall() returns dry*(1-wet/2) + wet/2; recover the wet part and add it at our level.
            let wl = (L[i + n] - dryL[i + n] * 0.5) * 2, wr = (R[i + n] - dryR[i + n] * 0.5) * 2
            d.l[i] += wl * wet * 0.35
            d.r[i] += wr * wet * 0.35
        }
    }

    /// All parts mixed at their default levels.
    static func render(_ style: GrooveStyle, bpm: Double, bars: Int = 8) -> AudioData {
        let parts = renderParts(style, bpm: bpm, bars: bars)
        let frames = parts.values.first?.frames ?? 1
        let out = AudioData(frames: frames)
        for p in GroovePart.allCases where p.defaultLevel > 0 {
            var g = p.defaultLevel
            vDSP_vsma(parts[p]!.l, 1, &g, out.l, 1, out.l, 1, vDSP_Length(frames))
            vDSP_vsma(parts[p]!.r, 1, &g, out.r, 1, out.r, 1, vDSP_Length(frames))
        }
        return out
    }
}
