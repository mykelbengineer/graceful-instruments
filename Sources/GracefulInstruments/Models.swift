import Foundation

enum ItemKind: String, Codable {
    case song, loop, groove, stems, metronome
    var label: String {
        switch self {
        case .song: return "Track"
        case .loop: return "Loop"
        case .groove: return "Groove"
        case .stems: return "Stems"
        case .metronome: return "Metronome"
        }
    }
}

/// Service part. Worship and Praise are worked out from tempo unless an item is tagged by hand.
enum Category: String, Codable, CaseIterable, Identifiable {
    case worship, praise, ministration, thanksgiving
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum TimeSig: String, Codable, CaseIterable, Identifiable {
    case fourFour = "4/4", threeFour = "3/4", sixEight = "6/8", twelveEight = "12/8"
    var id: String { rawValue }
    var beatsPerBar: Int {
        switch self {
        case .fourFour: return 4
        case .threeFour: return 3
        case .sixEight: return 2
        case .twelveEight: return 4
        }
    }
    var compound: Bool { self == .sixEight || self == .twelveEight }
    var clicksPerBeat: Int { compound ? 3 : 1 }
}

struct Marker: Codable, Identifiable, Hashable {
    var id = UUID()
    var time: Double
    var cue: String
}

struct Stem: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var file: String // file name inside the library's Audio folder
    var volume: Float = 1
    var muted = false
    var solo = false
    var inEarsOnly = false
}

struct LibraryItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var kind: ItemKind
    var stems: [Stem] = []
    var duration: Double = 0
    var bpm: Double?
    var beatOffset: Double = 0
    var timeSig: TimeSig = .fourFour
    var rate: Double = 1
    var semitones: Int = 0
    var loopOn = false
    var loopStart: Double?
    var loopEnd: Double?
    var markers: [Marker] = []
    var grooveStyle: String?
    var category: Category?
    var regions: [LoopRegion]?
    var grooveLevels: [String: Float]?
    var chords: ChordChart?
    var lyrics: Lyrics?
    var artist: String?
    var sourceURL: String?

    func grooveLevel(_ p: GroovePart) -> Float { grooveLevels?[p.rawValue] ?? p.defaultLevel }
    var added = Date()
    var analyzed = false

    var playingBPM: Double? { bpm.map { $0 * rate } }
    var beatSeconds: Double? { bpm.map { 60 / $0 } }
    var barSeconds: Double? { beatSeconds.map { $0 * Double(timeSig.beatsPerBar) } }
}

/// One song in a service. Points at a library item (no copy of the audio) and can keep its own
/// tempo, key and loop for that service without changing the library item.
struct SetEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var itemID: UUID
    var rate: Double?
    var semitones: Int?
    var loopOn: Bool?
    var loopStart: Double?
    var loopEnd: Double?

    var hasOverrides: Bool { rate != nil || semitones != nil || loopOn != nil }

    func apply(to item: LibraryItem) -> LibraryItem {
        var it = item
        if let r = rate { it.rate = r }
        if let s = semitones { it.semitones = s }
        if let l = loopOn { it.loopOn = l; it.loopStart = loopStart; it.loopEnd = loopEnd }
        return it
    }
}

struct SetSection: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var entries: [SetEntry] = []
}

/// A service (e.g. "Sunday, November 11") made of sections such as Worship and Praise.
struct Setlist: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var date: Date?
    var sections: [SetSection]

    static let defaultSections = ["Worship", "Praise", "Ministration", "Thanksgiving"]

    init(name: String, date: Date? = nil, sections: [SetSection]? = nil) {
        self.name = name
        self.date = date
        self.sections = sections ?? Setlist.defaultSections.map { SetSection(name: $0) }
    }

    var allEntries: [SetEntry] { sections.flatMap(\.entries) }

    func locate(_ entryID: UUID) -> (section: Int, entry: Int)? {
        for (si, sec) in sections.enumerated() {
            if let ei = sec.entries.firstIndex(where: { $0.id == entryID }) { return (si, ei) }
        }
        return nil
    }

    // Older library files stored a flat list of item IDs; read those into one section.
    enum CodingKeys: String, CodingKey { case id, name, date, sections, items }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Service"
        date = try? c.decodeIfPresent(Date.self, forKey: .date)
        if let secs = try? c.decode([SetSection].self, forKey: .sections) {
            sections = secs
        } else {
            let ids = (try? c.decode([UUID].self, forKey: .items)) ?? []
            sections = [SetSection(name: "Songs", entries: ids.map { SetEntry(itemID: $0) })]
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(date, forKey: .date)
        try c.encode(sections, forKey: .sections)
    }

    static func defaultName(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: date)
    }
}

struct LibraryFile: Codable {
    var items: [LibraryItem]
    var setlists: [Setlist]
}

enum Paths {
    static let base: URL = {
        // GI_LIBRARY_DIR points tests at a throwaway library.
        if let dir = ProcessInfo.processInfo.environment["GI_LIBRARY_DIR"] { return URL(fileURLWithPath: dir, isDirectory: true) }
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first!
        return music.appendingPathComponent("Graceful Instruments", isDirectory: true)
    }()
    static let audio = base.appendingPathComponent("Audio", isDirectory: true)
    static let libraryJSON = base.appendingPathComponent("library.json")
    static let bin = base.appendingPathComponent("bin", isDirectory: true)

    static func ensure() {
        for d in [base, audio, bin] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }
}

enum TitleCleaner {
    /// Turns "onlymp3.to - Ariaria Drum Loops  Praise-oA7AC3EmfP8-192k-1659939301563" into "Ariaria Drum Loops Praise".
    static func clean(_ raw: String) -> String {
        var s = raw
        for ext in [".mp3", ".mpeg", ".m4a", ".wav"] where s.lowercased().hasSuffix(ext) {
            s = String(s.dropLast(ext.count))
        }
        let patterns = [
            #"^(onlymp3\.to|y2mate\.com|y2mate\.is|yt5s\.io|yt5s\.com|ytmp3\.\w+|mp3convert\.org)\s*-\s*"#,
            #"-[A-Za-z0-9_\-]{11}-\d{2,3}k-\d{10,}$"#,
            #"\s*\[[A-Za-z0-9_\-]{11}\]"#,
            #"\s*\(\d{2,3}\s*kbps\)"#,
            #"\s*\(\d{3}\)$"#,
            #"\s*\((mp3convert\.org)\)"#,
            #"\s*with download link"#,
            #"\s*Free Download"#,
        ]
        for p in patterns {
            s = s.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "_", with: " ")
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-.")))
    }
}
