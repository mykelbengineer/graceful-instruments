import Foundation
import Network
import AppKit
import CoreImage

/// A small web page on the church Wi-Fi so a phone can run the app: open the address (or scan the code) in the phone's browser.
/// Every request must carry the 4-digit code, so someone else on the network can't take over.
final class RemoteServer: ObservableObject {
    static let shared = RemoteServer()
    static let port: UInt16 = 7700

    @Published var running = false
    @Published var address = ""
    @Published var lastPhone = ""
    @Published var message = ""
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "remoteEnabled"); enabled ? start() : stop() } }
    @Published var pin: String

    weak var model: AppModel?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "gi.remote")

    init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "remoteEnabled") == nil ? true : d.bool(forKey: "remoteEnabled")
        if let p = d.string(forKey: "remotePIN"), p.count == 4 { pin = p }
        else { pin = String(format: "%04d", Int.random(in: 0...9999)); d.set(pin, forKey: "remotePIN") }
    }

    func newPIN() {
        pin = String(format: "%04d", Int.random(in: 0...9999))
        UserDefaults.standard.set(pin, forKey: "remotePIN")
    }

    var url: String { address.isEmpty ? "" : "http://\(address):\(RemoteServer.port)/?k=\(pin)" }

    func startIfEnabled() { if enabled { start() } }

    func start() {
        refreshAddress()
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: RemoteServer.port)!)
            l.stateUpdateHandler = { [weak self] st in
                DispatchQueue.main.async {
                    switch st {
                    case .ready: self?.running = true; self?.message = ""
                    case .failed(let e): self?.running = false; self?.message = "Phone remote stopped: \(e.localizedDescription)"; self?.listener = nil
                    case .cancelled: self?.running = false
                    default: break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            l.start(queue: queue)
            listener = l
        } catch {
            message = "Phone remote could not start: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
    }

    /// The Mac's address on the local network (Wi-Fi or Ethernet).
    func refreshAddress() {
        var best = ""
        var ifs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifs) == 0, let first = ifs else { return }
        defer { freeifaddrs(ifs) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let i = p {
            let name = String(cString: i.pointee.ifa_name)
            if let a = i.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET), name.hasPrefix("en") || name.hasPrefix("bridge") {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: host)
                if !ip.hasPrefix("169.254") && (best.isEmpty || name == "en0") { best = ip }
            }
            p = i.pointee.ifa_next
        }
        address = best
    }

    // MARK: HTTP

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        // A phone that connects and never sends a request is dropped after 15 seconds.
        queue.asyncAfter(deadline: .now() + 15) { if c.state != .cancelled { c.cancel() } }
        var buffer = Data()
        func readMore() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, err in
                guard let self = self else { c.cancel(); return }
                if let d = data { buffer.append(d) }
                if let r = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(data: buffer[..<r.lowerBound], encoding: .utf8) ?? ""
                    self.respond(c, head: head)
                } else if done || err != nil || buffer.count > 65536 {
                    c.cancel()
                } else {
                    readMore()
                }
            }
        }
        readMore()
    }

    private func respond(_ c: NWConnection, head: String) {
        let first = head.components(separatedBy: "\r\n").first ?? ""
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { c.cancel(); return }
        let target = String(parts[1])
        let comps = URLComponents(string: "http://x" + target)
        let path = comps?.path ?? "/"
        var q: [String: String] = [:]
        for i in comps?.queryItems ?? [] { q[i.name] = i.value ?? "" }

        var status = "200 OK", type = "application/json", body = Data()
        if path == "/" || path == "/index.html" {
            type = "text/html; charset=utf-8"
            body = Data(RemotePage.html.utf8)
        } else if path.hasPrefix("/api/") {
            if q["k"] != pin {
                status = "403 Forbidden"
                body = Data(#"{"error":"code"}"#.utf8)
            } else {
                let action = path == "/api/do" ? q["a"] : nil
                let value = q["v"]
                body = DispatchQueue.main.sync { () -> Data in
                    if let a = action { self.run(a, value) }
                    return self.state()
                }
            }
        } else {
            status = "404 Not Found"; type = "text/plain"; body = Data("not found".utf8)
        }
        var out = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    // MARK: actions and state (main thread)

    private func run(_ a: String, _ v: String?) {
        guard let m = model else { return }
        lastPhone = "Phone connected"
        switch a {
        case "play": m.togglePlay()
        case "stop": m.stop()
        case "fade": m.fadeOut()
        case "next": m.playNext()
        case "prev": m.playPrevious()
        case "loop": m.toggleLoop()
        case "click": m.clickOn.toggle()
        case "tempo+": m.nudgeTempo(1)
        case "tempo-": m.nudgeTempo(-1)
        case "key+": m.update { $0.semitones = min(7, $0.semitones + 1) }
        case "key-": m.update { $0.semitones = max(-7, $0.semitones - 1) }
        case "keyreset": m.update { $0.semitones = 0 }
        case "bar+": m.jumpBars(1)
        case "bar-": m.jumpBars(-1)
        case "entry":
            if let id = v.flatMap(UUID.init(uuidString:)), let sid = m.activeSetlist { m.openEntry(id, in: sid) }
        case "service":
            if let id = v.flatMap(UUID.init(uuidString:)) { m.activeSetlist = id }
        case "portion":
            if let id = v.flatMap(UUID.init(uuidString:)), let r = m.current?.regions?.first(where: { $0.id == id }) { m.activatePortion(r) }
        case "pad": m.pads.toggle()
        case "padkey": if let k = v.flatMap(Int.init) { m.pads.play(key: Notes.wrap(k)) }
        case "padsound": if let s = v.flatMap(PadSound.init(rawValue:)) { m.pads.sound = s }
        case "padfound": m.perform(.padFoundKey)
        case "listen": KeyListener.shared.toggle()
        case "listenreset": KeyListener.shared.reset()
        case "match": if let k = KeyListener.shared.key { m.matchKey(k) }
        case "metronome": m.toggleMetronome()
        default: break
        }
    }

    private func state() -> Data {
        guard let m = model else { return Data("{}".utf8) }
        var s: [String: Any] = [:]
        let it = m.current
        s["title"] = it?.title ?? ""
        s["kind"] = it?.kind.label ?? ""
        s["playing"] = m.clock.playing
        s["pos"] = m.clock.position
        s["dur"] = it?.duration ?? 0
        s["bpm"] = it?.playingBPM.map { formatBPM($0) } ?? ""
        s["key"] = m.playingKey?.name ?? ""
        s["semitones"] = it?.semitones ?? 0
        s["loop"] = it?.loopOn ?? false
        s["click"] = m.clickOn
        s["entry"] = m.entryPosition ?? ""
        s["next"] = m.nextInSetlist()?.item.title ?? ""
        if let it = it, let chart = it.chords {
            let t = m.clock.position
            let flats = chart.key.transposed(it.semitones).usesFlats
            if let i = chart.segs.firstIndex(where: { $0.start <= t && t < $0.end }) {
                s["chord"] = chart.segs[i].symbol(transpose: it.semitones, flats: flats, simple: false)
                if let n = chart.segs[(i + 1)...].first(where: { $0.root >= 0 && $0.end - $0.start > 0.3 }) {
                    s["nextChord"] = n.symbol(transpose: it.semitones, flats: flats, simple: false)
                }
            }
        }
        if let it = it, let ly = it.lyrics, let i = ly.lineIndex(at: m.clock.position), let lines = ly.lines {
            s["lyric"] = lines[i].text
            s["nextLyric"] = i + 1 < lines.count ? lines[i + 1].text : ""
        }
        s["portions"] = (it?.regions ?? []).map { r in
            ["id": r.id.uuidString, "name": r.name, "on": (it?.loopOn ?? false) && it?.loopStart == r.start && it?.loopEnd == r.end] as [String: Any]
        }
        s["services"] = m.setlists.map { ["id": $0.id.uuidString, "name": $0.name] }
        if let sid = m.activeSetlist, let sl = m.setlists.first(where: { $0.id == sid }) {
            s["service"] = [
                "id": sl.id.uuidString, "name": sl.name,
                "sections": sl.sections.map { sec in
                    ["name": sec.name, "entries": sec.entries.map { e in
                        ["id": e.id.uuidString, "title": m.items.first { $0.id == e.itemID }?.title ?? "(missing)",
                         "current": e.id == m.currentEntry] as [String: Any]
                    }] as [String: Any]
                }
            ] as [String: Any]
        }
        s["pad"] = ["on": m.pads.on, "key": m.pads.key, "name": m.pads.keyName, "sound": m.pads.sound.rawValue] as [String: Any]
        let kl = KeyListener.shared
        s["finder"] = ["on": kl.listening, "key": kl.key?.longName ?? "", "sure": kl.sure, "alt": kl.runnerUp?.longName ?? ""] as [String: Any]
        // JSONSerialization throws an Objective-C exception (a crash) on NaN or infinity, so check first.
        guard JSONSerialization.isValidJSONObject(s) else { return Data("{}".utf8) }
        return (try? JSONSerialization.data(withJSONObject: s)) ?? Data("{}".utf8)
    }

    /// QR code for the address, so the phone can just scan it.
    func qrImage(size: CGFloat = 180) -> NSImage? {
        guard !url.isEmpty, let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(url.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage else { return nil }
        let scale = size / out.extent.width
        let scaled = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
