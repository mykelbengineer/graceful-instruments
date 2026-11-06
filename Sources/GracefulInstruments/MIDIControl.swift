import Foundation
import CoreMIDI

/// Things a keyboard button, pedal or key can do.
enum MIDIAction: String, CaseIterable, Identifiable, Codable {
    case playPause, stop, fadeOut, next, previous, loop, click, padToggle, padFoundKey, keyUp, keyDown, tap
    var id: String { rawValue }
    var label: String {
        switch self {
        case .playPause: return "Play / pause"
        case .stop: return "Stop"
        case .fadeOut: return "Fade out"
        case .next: return "Next song"
        case .previous: return "Previous song"
        case .loop: return "Loop on / off"
        case .click: return "Click on / off"
        case .padToggle: return "Pad on / off"
        case .padFoundKey: return "Pad to the found key"
        case .keyUp: return "Key up"
        case .keyDown: return "Key down"
        case .tap: return "Tap tempo"
        }
    }
}

/// One incoming control: a note, a controller (button, pedal, knob) or a program change.
struct MIDITrigger: Codable, Hashable {
    enum Kind: String, Codable { case note, cc, program }
    var kind: Kind
    var channel: Int
    var number: Int

    var label: String {
        switch kind {
        case .note:
            let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
            return "Key \(names[number % 12])\(number / 12 - 1) (ch \(channel + 1))"
        case .cc: return "Controller \(number) (ch \(channel + 1))"
        case .program: return "Program \(number + 1) (ch \(channel + 1))"
        }
    }
}

/// Listens to every connected MIDI keyboard (the MOXF8 over USB, or any USB-MIDI cable) and runs mapped actions.
final class MIDIControl: ObservableObject {
    static let shared = MIDIControl()

    @Published var sources: [String] = []
    @Published var learning: MIDIAction?
    @Published var map: [MIDIAction: MIDITrigger] = [:]
    @Published var lastMessage = ""
    @Published var enabled = true { didSet { UserDefaults.standard.set(enabled, forKey: "midiEnabled") } }

    var perform: ((MIDIAction) -> Void)?
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var ccState: [Int: Int] = [:]   // last value per channel/controller, to fire once per press
    // Controls that move all the time while playing; never learn these by accident.
    private static let ignoredCCs: Set<Int> = [1, 2, 7, 10, 11, 64, 66, 67, 0, 32, 120, 121, 123]

    init() {
        if let data = UserDefaults.standard.data(forKey: "midiMap"),
           let m = try? JSONDecoder().decode([String: MIDITrigger].self, from: data) {
            for (k, v) in m { if let a = MIDIAction(rawValue: k) { map[a] = v } }
        }
        if UserDefaults.standard.object(forKey: "midiEnabled") != nil { enabled = UserDefaults.standard.bool(forKey: "midiEnabled") }
    }

    func start() {
        guard client == 0 else { return }
        let status = MIDIClientCreateWithBlock("Graceful Instruments" as CFString, &client) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.connectAll() }
            }
        }
        guard status == noErr else { lastMessage = "MIDI could not start (\(status))."; return }
        MIDIInputPortCreateWithBlock(client, "in" as CFString, &port) { [weak self] list, _ in
            self?.handle(list)
        }
        connectAll()
    }

    func connectAll() {
        var names: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            // Disconnect first: connecting a source twice delivers every press twice (play then pause again).
            MIDIPortDisconnectSource(port, src)
            MIDIPortConnectSource(port, src, nil)
            var name: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &name) == noErr, let n = name?.takeRetainedValue() {
                names.append(n as String)
            }
        }
        sources = names
    }

    private func save() {
        var m: [String: MIDITrigger] = [:]
        for (k, v) in map { m[k.rawValue] = v }
        if let d = try? JSONEncoder().encode(m) { UserDefaults.standard.set(d, forKey: "midiMap") }
    }

    func clear(_ a: MIDIAction) { map[a] = nil; save() }

    private func handle(_ list: UnsafePointer<MIDIPacketList>) {
        var events: [(UInt8, UInt8, UInt8)] = []
        let n = Int(list.pointee.numPackets)
        // Walk the packets in place (copying a MIDIPacket would cut long ones short).
        var p = UnsafeMutableRawPointer(mutating: list).advanced(by: 4).assumingMemoryBound(to: MIDIPacket.self)
        for _ in 0..<n {
            let len = Int(p.pointee.length)
            let bytes = UnsafeRawPointer(p).advanced(by: 10).assumingMemoryBound(to: UInt8.self)
            var i = 0
            while i < len {
                let st = bytes[i]
                if st < 0x80 || st >= 0xF0 { i += 1; continue } // running status and system messages: skip
                let type = st & 0xF0
                let size = (type == 0xC0 || type == 0xD0) ? 2 : 3
                guard i + size <= len else { break }
                events.append((st, bytes[i + 1], size == 3 ? bytes[i + 2] : 0))
                i += size
            }
            p = MIDIPacketNext(p)
        }
        guard !events.isEmpty else { return }
        DispatchQueue.main.async { for e in events { self.event(e.0, e.1, e.2) } }
    }

    private func event(_ st: UInt8, _ d1: UInt8, _ d2: UInt8) {
        let ch = Int(st & 0x0F), type = st & 0xF0
        var trig: MIDITrigger?
        switch type {
        case 0x90 where d2 > 0:
            trig = MIDITrigger(kind: .note, channel: ch, number: Int(d1))
        case 0xB0:
            let key = ch * 128 + Int(d1)
            let before = ccState[key] ?? 0
            ccState[key] = Int(d2)
            // Fire when a button or pedal goes down (crosses the middle), not again while held.
            if d2 >= 64 && before < 64 { trig = MIDITrigger(kind: .cc, channel: ch, number: Int(d1)) }
        case 0xC0:
            trig = MIDITrigger(kind: .program, channel: ch, number: Int(d1))
        default: break
        }
        guard let t = trig else { return }
        lastMessage = t.label
        if let a = learning {
            if t.kind == .cc && MIDIControl.ignoredCCs.contains(t.number) { return }
            for (k, v) in map where v == t { map[k] = nil }
            map[a] = t
            learning = nil
            save()
            return
        }
        guard enabled else { return }
        for (a, v) in map where v == t { perform?(a) }
    }
}
