import Foundation
import Accelerate

enum Drum: CaseIterable {
    case kick, snare, rim, clap, hat, openHat, shaker, bell, congaHi, congaLo, tomHi, tomLo

    var pan: Float {
        switch self {
        case .kick, .snare, .rim, .clap: return 0
        case .hat, .openHat: return 0.25
        case .shaker: return -0.3
        case .bell: return 0.35
        case .congaHi: return -0.2
        case .congaLo: return 0.15
        case .tomHi: return -0.2
        case .tomLo: return 0.2
        }
    }
    var level: Float {
        switch self {
        case .kick: return 1.0
        case .snare: return 0.7
        case .rim: return 0.55
        case .clap: return 0.5
        case .hat: return 0.22
        case .openHat: return 0.3
        case .shaker: return 0.3
        case .bell: return 0.2
        case .congaHi: return 0.55
        case .congaLo: return 0.6
        case .tomHi, .tomLo: return 0.6
        }
    }
}

/// Small synthesizer for one-shot percussion sounds.
enum DrumSynth {
    static let sr = AudioData.sampleRate
    private static var cache: [Drum: [Float]] = [:]

    private struct Rng {
        var s: UInt64
        mutating func next() -> Float {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: s >> 11) & 0xFFFFF) / Float(0x7FFFF) - 1
        }
    }

    private struct Biquad {
        var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
        var z1: Float = 0, z2: Float = 0
        static func bandpass(_ f: Double, q: Double) -> Biquad {
            let w = 2 * Double.pi * f / sr, al = sin(w) / (2 * q), a0 = 1 + al
            return Biquad(b0: Float(al / a0), b1: 0, b2: Float(-al / a0), a1: Float(-2 * cos(w) / a0), a2: Float((1 - al) / a0))
        }
        static func highpass(_ f: Double, q: Double = 0.707) -> Biquad {
            let w = 2 * Double.pi * f / sr, al = sin(w) / (2 * q), c = cos(w), a0 = 1 + al
            return Biquad(b0: Float((1 + c) / 2 / a0), b1: Float(-(1 + c) / a0), b2: Float((1 + c) / 2 / a0),
                          a1: Float(-2 * c / a0), a2: Float((1 - al) / a0))
        }
        mutating func run(_ x: Float) -> Float {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    static func sound(_ d: Drum) -> [Float] {
        if let c = cache[d] { return c }
        let s = make(d)
        cache[d] = s
        return s
    }

    private static func make(_ d: Drum) -> [Float] {
        var rng = Rng(s: 0x9E3779B97F4A7C15 &+ UInt64(Drum.allCases.firstIndex(of: d)!))
        func buf(_ sec: Double) -> [Float] { [Float](repeating: 0, count: Int(sec * sr)) }
        switch d {
        case .kick:
            var o = buf(0.5); var ph = 0.0
            for i in 0..<o.count {
                let t = Double(i) / sr
                let f = 48 + 110 * exp(-t * 28)
                ph += 2 * .pi * f / sr
                let body = sin(ph) * exp(-t * 7)
                let click = t < 0.004 ? Double(rng.next()) * (1 - t / 0.004) * 0.3 : 0
                o[i] = Float(tanh((body + click) * 1.6))
            }
            return o
        case .snare:
            var o = buf(0.3); var bp = Biquad.bandpass(3200, q: 0.7); var ph = 0.0
            for i in 0..<o.count {
                let t = Double(i) / sr
                ph += 2 * .pi * (190 + 40 * exp(-t * 40)) / sr
                let tone = sin(ph) * exp(-t * 22) * 0.6
                let noise = Double(bp.run(rng.next())) * exp(-t * 16) * 1.6
                o[i] = Float(tanh(tone + noise))
            }
            return o
        case .rim:
            var o = buf(0.08); var bp = Biquad.bandpass(1700, q: 6)
            for i in 0..<o.count {
                let t = Double(i) / sr
                let tone = sin(2 * .pi * 1720 * t) * 0.5 + sin(2 * .pi * 820 * t) * 0.4
                let n = Double(bp.run(rng.next())) * 2
                o[i] = Float((tone + n) * exp(-t * 70))
            }
            return o
        case .clap:
            var o = buf(0.25); var bp = Biquad.bandpass(1250, q: 1.2)
            for i in 0..<o.count {
                let t = Double(i) / sr
                var env = 0.0
                for k in 0..<3 { let tk = t - Double(k) * 0.011; if tk >= 0 && tk < 0.011 { env = max(env, exp(-tk * 260)) } }
                env = max(env, t >= 0.022 ? exp(-(t - 0.022) * 18) * 0.8 : 0)
                o[i] = Float(Double(bp.run(rng.next())) * env * 2.4)
            }
            return o
        case .hat, .openHat:
            let len = d == .hat ? 0.06 : 0.35
            var o = buf(len); var hp = Biquad.highpass(7500)
            let decay = d == .hat ? 70.0 : 9.0
            for i in 0..<o.count {
                let t = Double(i) / sr
                var metal = 0.0
                for f in [3200.0, 4500, 5100, 6800, 8100, 9300] { metal += sin(2 * .pi * f * t) > 0 ? 1 : -1 }
                let x = Float(metal / 6) * 0.4 + rng.next() * 0.6
                o[i] = hp.run(x) * Float(exp(-t * decay)) * 1.4
            }
            return o
        case .shaker:
            var o = buf(0.09); var hp = Biquad.highpass(5200); var bp = Biquad.bandpass(8000, q: 1)
            for i in 0..<o.count {
                let t = Double(i) / sr
                let env = t < 0.012 ? t / 0.012 : exp(-(t - 0.012) * 45)
                o[i] = bp.run(hp.run(rng.next())) * Float(env) * 2.2
            }
            return o
        case .bell:
            // A short, wooden "tock" rather than a ringing cowbell.
            var o = buf(0.12); var bp = Biquad.bandpass(2400, q: 3)
            for i in 0..<o.count {
                let t = Double(i) / sr
                let s = sin(2 * .pi * 1480 * t) * exp(-t * 38) + 0.35 * sin(2 * .pi * 2210 * t) * exp(-t * 55)
                let strike = Double(bp.run(rng.next())) * exp(-t * 300) * 0.6
                o[i] = Float((s + strike) * 0.6)
            }
            return o
        case .congaHi, .congaLo, .tomHi, .tomLo:
            let base: Double = d == .congaHi ? 330 : d == .congaLo ? 215 : d == .tomHi ? 165 : 110
            let decay: Double = d == .congaHi ? 16 : d == .congaLo ? 11 : 9
            var o = buf(0.45); var ph = 0.0; var bp = Biquad.bandpass(base * 4, q: 1.5)
            for i in 0..<o.count {
                let t = Double(i) / sr
                ph += 2 * .pi * base * (1 + 0.12 * exp(-t * 45)) / sr
                let body = sin(ph) + 0.25 * sin(ph * 1.52)
                let slap = Double(bp.run(rng.next())) * exp(-t * 90) * (d == .congaHi ? 1.2 : 0.6)
                o[i] = Float((body * exp(-t * decay) + slap) * 0.8)
            }
            return o
        }
    }

}

/// Groove parts that can be mixed separately.
enum GroovePart: String, CaseIterable, Identifiable, Codable {
    case kick, snare, hats, shaker, congas, bell
    var id: String { rawValue }
    var label: String {
        switch self {
        case .kick: return "Kick"
        case .snare: return "Snare & claps"
        case .hats: return "Hats & cymbals"
        case .shaker: return "Shakers"
        case .congas: return "Hand drums"
        case .bell: return "Bell & claves"
        }
    }
    /// The bell is off unless someone turns it on.
    var defaultLevel: Float { self == .bell ? 0 : 1 }
    var reverb: Float {
        switch self {
        case .kick: return 0.25
        case .snare: return 0.9
        case .hats: return 0.4
        case .shaker: return 0.5
        case .congas: return 0.8
        case .bell: return 0.6
        }
    }
}

extension Drum {
    var part: GroovePart {
        switch self {
        case .kick: return .kick
        case .snare, .rim, .clap: return .snare
        case .hat, .openHat: return .hats
        case .shaker: return .shaker
        case .congaHi, .congaLo, .tomHi, .tomLo: return .congas
        case .bell: return .bell
        }
    }
}
