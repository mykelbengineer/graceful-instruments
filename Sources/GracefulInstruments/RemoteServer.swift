import Foundation
import Network
import AppKit
import CoreImage
import Security

/// A small web page on the church Wi-Fi so a phone can run the app: open the address (or scan the code) in the phone's browser.
/// Every request must carry a long random key that only the QR code holds, so someone else on the network
/// can't guess it. Wrong keys lock that device out for a while, and requests for other host names are refused
/// (so a web page can't reach the app through a DNS trick).
final class RemoteServer: ObservableObject {
    static let shared = RemoteServer()
    static let port: UInt16 = 7700

    @Published var running = false
    @Published var address = ""
    @Published var lastPhone = ""
    @Published var message = ""
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "remoteEnabled"); enabled ? start() : stop() } }
    @Published private(set) var token: String

    weak var model: AppModel?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "gi.remote")
    /// Wrong keys per device (only touched on `queue`).
    private var failures: [String: (count: Int, until: Date)] = [:]
    private static let maxFailures = 5
    private static let lockout: TimeInterval = 600

    init() {
        let d = UserDefaults.standard
        // Off until someone turns it on.
        enabled = d.bool(forKey: "remoteEnabled")
        if let t = d.string(forKey: "remoteToken"), t.count == 32 { token = t }
        else { token = RemoteServer.makeToken(); d.set(token, forKey: "remoteToken") }
        currentToken = token
        d.removeObject(forKey: "remotePIN") // the old 4-digit code
    }

    /// 128 random bits as hex.
    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// A new key: every phone has to scan the code again.
    func newToken() {
        token = RemoteServer.makeToken()
        UserDefaults.standard.set(token, forKey: "remoteToken")
        let t = token
        queue.async { self.failures.removeAll(); self.currentToken = t }
    }

    /// Copy of the key that the network queue reads (only changed on `queue`).
    private var currentToken = ""

    var url: String { address.isEmpty ? "" : "http://\(address):\(RemoteServer.port)/?k=\(token)" }

    /// Compares without stopping at the first wrong character, so timing gives nothing away.
    private static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    /// Only plain addresses (192.168.x.x), localhost and .local names: anything else is a DNS-rebinding attempt.
    private static func allowedHost(_ host: String) -> Bool {
        let h = (host.split(separator: ":").first.map(String.init) ?? "").lowercased()
        if h == "localhost" || h.hasSuffix(".local") { return true }
        let parts = h.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

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
                    self.respond(c, head: head, peer: RemoteServer.peerName(c))
                } else if done || err != nil || buffer.count > 65536 {
                    c.cancel()
                } else {
                    readMore()
                }
            }
        }
        readMore()
    }

    private static func peerName(_ c: NWConnection) -> String {
        if case let .hostPort(host, _) = c.endpoint { return "\(host)" }
        return "unknown"
    }

    private func respond(_ c: NWConnection, head: String, peer: String) {
        let lines = head.components(separatedBy: "\r\n")
        let first = lines.first ?? ""
        let host = lines.dropFirst().first { $0.lowercased().hasPrefix("host:") }
            .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) } ?? ""
        guard RemoteServer.allowedHost(host) else {
            send(c, status: "403 Forbidden", type: "text/plain", body: Data("forbidden".utf8)); return
        }
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
            let now = Date()
            if let f = failures[peer], f.count >= RemoteServer.maxFailures, f.until > now {
                status = "429 Too Many Requests"
                body = Data(#"{"error":"locked"}"#.utf8)
            } else if !RemoteServer.same(q["k"] ?? "", currentToken) {
                var f = failures[peer] ?? (0, now)
                if f.until <= now { f.count = 0 }
                f.count += 1
                f.until = now.addingTimeInterval(RemoteServer.lockout)
                failures[peer] = f
                if failures.count > 500 { failures = failures.filter { $0.value.until > now } }
                status = "403 Forbidden"
                body = Data(#"{"error":"code"}"#.utf8)
            } else {
                failures[peer] = nil
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
        send(c, status: status, type: type, body: body)
    }

    private func send(_ c: NWConnection, status: String, type: String, body: Data) {
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
