import Foundation

struct LyricLine: Codable, Hashable {
    var time: Double
    var text: String
}

/// Words for a song. Timed lines scroll with the music; plain text just shows.
struct Lyrics: Codable, Hashable {
    var plain: String
    var lines: [LyricLine]?      // timed, in the track's own seconds
    var source: String           // "LRCLIB", "YouTube captions", "Pasted"
    var offset: Double = 0       // nudge timed lyrics earlier (-) or later (+)
    var matchTitle: String?      // what was matched, e.g. "Way Maker - Sinach"

    var isTimed: Bool { !(lines ?? []).isEmpty }

    /// Index of the line being sung at `t`.
    func lineIndex(at t: Double) -> Int? {
        guard let ls = lines, !ls.isEmpty else { return nil }
        let x = t - offset
        var lo = 0, hi = ls.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if ls[mid].time <= x { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found >= 0 ? found : nil
    }
}

enum LyricsFinder {
    struct Result: Identifiable, Hashable {
        var id: Int
        var track: String
        var artist: String
        var album: String
        var duration: Double
        var plain: String
        var synced: String?
        var instrumental: Bool
        /// How far the recording's length is from ours (smaller = more likely the same recording).
        var lengthGap: Double = 0
        var score: Double = 0
    }

    static let agent = "GracefulInstruments/1.0 (church playback app)"

    /// Strips the bits YouTube titles add: "(Official Video)", "[Lyrics]", "Live", "ft. X", "| Worship".
    static func searchText(_ title: String) -> String {
        var s = title
        let patterns = [#"\((?:[^)]*?(official|video|audio|lyric|lyrics|live|visualizer|performance|hd|4k|remix)[^)]*?)\)"#,
                        #"\[(?:[^\]]*)\]"#, #"\|.*$"#, #"(?i)\bfeat\.?.*$"#, #"(?i)\bft\.?.*$"#,
                        #"(?i)\b(official\s+(music\s+)?video|lyric\s+video|lyrics|audio|live)\b"#,
                        #"(?i)\b\d{2,3}\s*bpm\b"#, #"(?i)\b(in\s+)?key\s+of\s+\w+"#, #"(?i)\binstrumental\b"#]
        for p in patterns { s = s.replacingOccurrences(of: p, with: " ", options: [.regularExpression, .caseInsensitive]) }
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " -–_.,"))
    }

    static func search(_ query: String, duration: Double?, completion: @escaping ([Result], String?) -> Void) {
        var comps = URLComponents(string: "https://lrclib.net/api/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        var req = URLRequest(url: comps.url!, timeoutInterval: 15)
        req.setValue(agent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            guard let data = data, err == nil, (resp as? HTTPURLResponse)?.statusCode == 200,
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                DispatchQueue.main.async { completion([], err?.localizedDescription ?? "The lyrics search did not answer. Check the internet connection.") }
                return
            }
            let qWords = Set(words(query))
            var results: [Result] = arr.compactMap { o in
                guard let id = o["id"] as? Int else { return nil }
                var r = Result(id: id,
                               track: o["trackName"] as? String ?? "",
                               artist: o["artistName"] as? String ?? "",
                               album: o["albumName"] as? String ?? "",
                               duration: o["duration"] as? Double ?? 0,
                               plain: o["plainLyrics"] as? String ?? "",
                               synced: o["syncedLyrics"] as? String,
                               instrumental: o["instrumental"] as? Bool ?? false)
                if r.plain.isEmpty, let s = r.synced { r.plain = parseLRC(s).map(\.text).joined(separator: "\n") }
                guard !r.instrumental, !r.plain.isEmpty else { return nil }
                let tWords = Set(words(r.track + " " + r.artist))
                let overlap = qWords.isEmpty ? 0 : Double(qWords.intersection(tWords).count) / Double(qWords.count)
                r.lengthGap = duration.map { abs($0 - r.duration) } ?? 0
                // Same title words, same length (within a few seconds) and timed lines all count.
                r.score = overlap * 2 + (r.synced != nil ? 0.4 : 0) - min(r.lengthGap, 60) / 15
                return r
            }
            results.sort { $0.score > $1.score }
            DispatchQueue.main.async { completion(results, nil) }
        }.resume()
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 }
    }

    static func lyrics(from r: Result) -> Lyrics {
        let timed = r.synced.map(parseLRC) ?? []
        return Lyrics(plain: r.plain, lines: timed.isEmpty ? nil : timed, source: "LRCLIB",
                      matchTitle: r.artist.isEmpty ? r.track : "\(r.track) - \(r.artist)")
    }

    /// "[01:02.50] Way maker" lines.
    static func parseLRC(_ s: String) -> [LyricLine] {
        var out: [LyricLine] = []
        let re = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        for raw in s.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let ms = re.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = ms.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for m in ms {
                let mm: Double = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let ss: Double = Double(ns.substring(with: m.range(at: 2))) ?? 0
                let t = mm * 60 + ss
                out.append(LyricLine(time: t, text: text))
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    /// YouTube captions (.vtt). Auto-captions repeat each line as it scrolls; keep each line once, at its first time.
    static func parseVTT(_ s: String) -> [LyricLine] {
        var out: [LyricLine] = []
        var lastText = ""
        let blocks = s.components(separatedBy: "\n\n")
        let timeRe = try! NSRegularExpression(pattern: #"(\d+):(\d+):(\d+(?:\.\d+)?)\s+-->"#)
        let tagRe = try! NSRegularExpression(pattern: #"<[^>]+>"#)
        var seen = Set<String>()
        for b in blocks {
            let lines = b.components(separatedBy: "\n")
            guard let tl = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let ns = lines[tl] as NSString
            guard let m = timeRe.firstMatch(in: lines[tl], range: NSRange(location: 0, length: ns.length)) else { continue }
            let hh: Double = Double(ns.substring(with: m.range(at: 1))) ?? 0
            let mm: Double = Double(ns.substring(with: m.range(at: 2))) ?? 0
            let ss: Double = Double(ns.substring(with: m.range(at: 3))) ?? 0
            let t = hh * 3600 + mm * 60 + ss
            for raw in lines[(tl + 1)...] {
                let clean = tagRe.stringByReplacingMatches(in: raw, range: NSRange(location: 0, length: (raw as NSString).length), withTemplate: "")
                    .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "'")
                    .trimmingCharacters(in: .whitespaces)
                guard !clean.isEmpty, clean != lastText, !clean.hasPrefix("[") else { continue }
                // Auto-captions show the previous line again above the new one.
                if seen.contains(clean) && out.last.map({ t - $0.time < 8 }) == true { continue }
                seen.insert(clean)
                out.append(LyricLine(time: t, text: clean))
                lastText = clean
            }
        }
        return out
    }
}
