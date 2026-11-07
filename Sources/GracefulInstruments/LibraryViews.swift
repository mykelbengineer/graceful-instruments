import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum SidebarSection: Hashable {
    case all, tracks, loops, grooves, stems, metronome, downloads, stemMaker, keyFinder, pads, remote, midi
    case service(UUID)
}

func formatTime(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let s = Int(t)
    return String(format: "%d:%02d", s / 60, s % 60)
}

func formatBPM(_ b: Double) -> String {
    abs(b - b.rounded()) < 0.05 ? String(format: "%.0f", b) : String(format: "%.1f", b)
}

struct IdentifiedUUID: Identifiable { let id: UUID }

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var section: SidebarSection? = .all
    var startSection: SidebarSection? = nil

    var body: some View {
        NavigationView {
            SidebarView(pads: model.pads, section: $section)
                .frame(minWidth: 200, idealWidth: 215)
            Group {
                switch section ?? .all {
                case .downloads: DownloadView()
                case .metronome: MetronomeView()
                case .stemMaker: StemMakerView()
                case .keyFinder: KeyFinderView(pads: model.pads)
                case .pads: PadsView(pads: model.pads)
                case .remote: RemoteView()
                case .midi: MIDIView()
                case .service(let id): ServiceView(serviceID: id)
                default: LibraryListView(section: section ?? .all)
                }
            }
            .frame(minWidth: 300, idealWidth: 330)
            PlayerView()
                .frame(minWidth: 580)
        }
        .onAppear {
            // On a service day, open straight onto that day's plan.
            if let today = model.activeSetlist { section = .service(today) }
            if let s = startSection { section = s }
            // For remote checks: --section metronome | downloads | service
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--section"), i + 1 < args.count {
                switch args[i + 1] {
                case "tracks": section = .tracks
                case "loops": section = .loops
                case "grooves": section = .grooves
                case "stemsList": section = .stems
                case "metronome": section = .metronome
                case "downloads": section = .downloads
                case "stems": section = .stemMaker
                case "keys": section = .keyFinder
                case "pads": section = .pads
                case "remote": section = .remote
                case "midi": section = .midi
                case "service": if let s = model.setlists.first { section = .service(s.id) }
                default: break
                }
            }
        }
        .alert(isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Alert(title: Text("Graceful Instruments"), message: Text(model.lastError ?? ""), dismissButton: .default(Text("OK")))
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var pads: PadController
    @ObservedObject var listener = KeyListener.shared
    @Binding var section: SidebarSection?
    @State private var creating = false

    var body: some View {
        List(selection: $section) {
            Section(header: Text("Services")) {
                ForEach(model.setlists) { s in
                    // The tag must be the last modifier: after .contextMenu, Big Sur can't select the row.
                    ServiceRow(service: s, active: model.activeSetlist == s.id)
                        .contextMenu {
                            Button("Delete Service") { model.deleteSetlist(s.id); section = .all }
                        }
                        .tag(SidebarSection.service(s.id))
                }
                Button(action: { creating = true }) {
                    SidebarRow(title: "New Service…", icon: "plus.circle.fill")
                }
                .buttonStyle(BorderlessButtonStyle())
                .foregroundColor(.accentColor)
            }
            Section(header: Text("Library")) {
                SidebarRow(title: "Everything", icon: "music.note.list").tag(SidebarSection.all)
                SidebarRow(title: "Tracks", icon: "music.note").tag(SidebarSection.tracks)
                SidebarRow(title: "Loops", icon: "repeat").tag(SidebarSection.loops)
                SidebarRow(title: "Grooves", icon: "music.quarternote.3").tag(SidebarSection.grooves)
                SidebarRow(title: "Stems", icon: "slider.vertical.3").tag(SidebarSection.stems)
            }
            Section(header: Text("Live tools")) {
                SidebarRow(title: "Key Finder", icon: "mic.fill", badge: listener.listening ? (listener.key?.name ?? "on") : nil, badgeColor: .red)
                    .tag(SidebarSection.keyFinder)
                SidebarRow(title: "Pads", icon: "waveform", badge: pads.on ? pads.keyName : nil, badgeColor: ButtonKind.success.fill)
                    .tag(SidebarSection.pads)
                SidebarRow(title: "Metronome", icon: "metronome.fill").tag(SidebarSection.metronome)
            }
            Section(header: Text("Setup")) {
                SidebarRow(title: "Phone Remote", icon: "iphone").tag(SidebarSection.remote)
                SidebarRow(title: "Keyboard Control", icon: "pianokeys").tag(SidebarSection.midi)
                SidebarRow(title: "YouTube Download", icon: "arrow.down.circle.fill").tag(SidebarSection.downloads)
                SidebarRow(title: "Stem Maker", icon: "wand.and.stars").tag(SidebarSection.stemMaker)
            }
        }
        .listStyle(SidebarListStyle())
        .sheet(isPresented: $creating) {
            NewServiceSheet { id in
                creating = false
                if let id = id { section = .service(id) }
            }
            .environmentObject(model)
        }
    }
}

/// One sidebar line: a bigger icon and text than the system default, plus an optional status badge.
struct SidebarRow: View {
    let title: String
    let icon: String
    var badge: String? = nil
    var badgeColor: Color = .accentColor
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 14)).foregroundColor(.accentColor).frame(width: 20)
            Text(title).font(.system(size: 14)).lineLimit(1)
            Spacer(minLength: 4)
            if let b = badge { Badge(text: b, color: badgeColor) }
        }
        .padding(.vertical, 3)
    }
}

struct ServiceRow: View {
    let service: Setlist
    let active: Bool
    var isToday: Bool { service.date.map { Calendar.current.isDateInToday($0) } ?? false }
    var isPast: Bool { (service.date.map { $0 < Calendar.current.startOfDay(for: Date()) }) ?? false }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: active ? "play.circle.fill" : "calendar")
                .font(.system(size: 14))
                .foregroundColor(active ? .accentColor : .secondary)
                .frame(width: 20)
            Text(service.name).font(.system(size: 14)).lineLimit(1).truncationMode(.tail)
                .foregroundColor(isPast ? .secondary : .primary)
            Spacer(minLength: 4)
            if isToday {
                Badge(text: "TODAY")
            } else {
                Text("\(service.allEntries.count)").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct NewServiceSheet: View {
    @EnvironmentObject var model: AppModel
    @State private var date = NewServiceSheet.nextSunday()
    @State private var name = ""
    @State private var copyFrom: UUID?
    let done: (UUID?) -> Void

    static func nextSunday() -> Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today) // 1 = Sunday
        return cal.date(byAdding: .day, value: (8 - weekday) % 7, to: today) ?? today
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New service").font(.headline)
            HStack(alignment: .top, spacing: 16) {
                DatePicker("", selection: $date, displayedComponents: .date)
                    .datePickerStyle(GraphicalDatePickerStyle())
                    .labelsHidden()
                    .frame(width: 230)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Name").foregroundColor(.secondary)
                    TextField(Setlist.defaultName(for: date), text: $name)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 220)
                    Text("Start from").foregroundColor(.secondary)
                    Picker("", selection: $copyFrom) {
                        Text("Empty (Worship, Praise, Ministration, Thanksgiving)").tag(UUID?.none)
                        ForEach(model.setlists) { s in Text("Copy of \(s.name)").tag(UUID?.some(s.id)) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    var id: UUID?
                    if let src = copyFrom {
                        id = model.duplicateService(src, to: date)
                        if let id = id, !name.isEmpty { model.renameSetlist(id, to: name) }
                    } else {
                        id = model.newService(date: date, name: name.isEmpty ? nil : name)
                    }
                    done(id)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

struct NamePrompt: View {
    let title: String
    @Binding var name: String
    let done: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Name", text: $name).frame(width: 320)
            HStack {
                Spacer()
                Button("Cancel") { done(false) }.keyboardShortcut(.cancelAction)
                Button("Save") { done(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

// MARK: - Filters

/// Search plus category, time signature and BPM range.
struct LibraryFilter {
    var search = ""
    var category: Category?
    var timeSig: TimeSig?
    var minBPM = ""
    var maxBPM = ""

    var isActive: Bool { category != nil || timeSig != nil || !minBPM.isEmpty || !maxBPM.isEmpty }

    func apply(_ items: [LibraryItem], model: AppModel, kinds: Set<ItemKind>? = nil) -> [LibraryItem] {
        let lo = Double(minBPM), hi = Double(maxBPM)
        return items.filter { it in
            if let k = kinds, !k.contains(it.kind) { return false }
            if !search.isEmpty && !it.title.localizedCaseInsensitiveContains(search) { return false }
            if let c = category, model.category(of: it) != c { return false }
            if let t = timeSig, it.timeSig != t { return false }
            if lo != nil || hi != nil {
                guard let b = it.playingBPM else { return false }
                if let lo = lo, b < lo { return false }
                if let hi = hi, b > hi { return false }
            }
            return true
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

struct FilterBar<Trailing: View>: View {
    @Binding var filter: LibraryFilter
    let trailing: Trailing

    init(filter: Binding<LibraryFilter>, @ViewBuilder trailing: () -> Trailing) {
        _filter = filter
        self.trailing = trailing()
    }

    var body: some View {
        // Three short rows so it fits the narrow middle column.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search", text: $filter.search)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                trailing
            }
            HStack(spacing: 6) {
                Picker("", selection: $filter.category) {
                    Text("All types").tag(Category?.none)
                    ForEach(Category.allCases) { Text($0.label).tag(Category?.some($0)) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                Picker("", selection: $filter.timeSig) {
                    Text("Any time").tag(TimeSig?.none)
                    ForEach(TimeSig.allCases) { Text($0.rawValue).tag(TimeSig?.some($0)) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
            HStack(spacing: 6) {
                Text("BPM").font(.caption).foregroundColor(.secondary).lineLimit(1)
                TextField("min", text: $filter.minBPM)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 50)
                Text("to").font(.caption).foregroundColor(.secondary)
                TextField("max", text: $filter.maxBPM)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 50)
                Spacer(minLength: 0)
                if filter.isActive {
                    Button("Clear") { filter = LibraryFilter(search: filter.search) }
                        .buttonStyle(BorderlessButtonStyle())
                        .help("Clear the type, time and BPM filters")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension FilterBar where Trailing == EmptyView {
    init(filter: Binding<LibraryFilter>) { self.init(filter: filter) { EmptyView() } }
}

// MARK: - Library list

struct LibraryListView: View {
    @EnvironmentObject var model: AppModel
    let section: SidebarSection
    @State private var filter = LibraryFilter()
    @State private var selection = Set<UUID>()
    @State private var renaming: UUID?
    @State private var newName = ""
    @State private var dropTargeted = false

    var kinds: Set<ItemKind>? {
        switch section {
        case .tracks: return [.song]
        case .loops: return [.loop]
        case .grooves: return [.groove]
        case .stems: return [.stems]
        default: return nil
        }
    }

    var filtered: [LibraryItem] { filter.apply(model.items, model: model, kinds: kinds) }

    var body: some View {
        VStack(spacing: 0) {
            FilterBar(filter: $filter) {
                Menu {
                    Button("Import Tracks or Loops...") { importTracks() }
                    Button("Import Stem Pack (folder or zip)...") { importStems() }
                    Divider()
                    ForEach(GrooveStyle.all) { g in
                        Button("New Groove: \(g.name) (\(g.timeSig.rawValue), \(Int(g.defaultBPM)) BPM)") {
                            let id = model.addGroove(g)
                            model.open(id)
                        }
                    }
                } label: {
                    HStack(spacing: 4) { Image(systemName: "plus"); Text("Add") }
                }
                .menuStyle(BorderlessButtonMenuStyle())
                .fixedSize()
            }
            .padding(8)
            Divider()
            let list = filtered
            if list.isEmpty {
                EmptyState(systemImage: model.items.isEmpty ? "square.and.arrow.down" : "magnifyingglass",
                           title: model.items.isEmpty ? "Drag MP3s here to add them" : "Nothing matches",
                           message: section == .grooves ? "Use Add > New Groove to make one." : model.items.isEmpty ? "Or use Add > Import, or download from YouTube." : "Try fewer words, or clear the filters.")
            } else {
                List(selection: $selection) {
                    ForEach(list) { item in
                        ItemRow(item: item, category: model.category(of: item), analyzing: model.analyzing.contains(item.id),
                                loaded: model.current?.id == item.id, loading: model.loadingID == item.id,
                                onLoad: { model.open(item.id) })
                            .tag(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { model.open(item.id) }
                            .contextMenu { menu(for: item) }
                    }
                }
            }
            Divider()
            HStack {
                Text("\(list.count) item\(list.count == 1 ? "" : "s")").font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(model.status).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            .padding(6)
        }
        .overlay(dropTargeted ? RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).padding(4) : nil)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            loadURLs(providers) { urls in model.importAny(urls) }
            return true
        }
        .sheet(item: Binding(get: { renaming.map { IdentifiedUUID(id: $0) } }, set: { renaming = $0?.id })) { r in
            NamePrompt(title: "Rename", name: $newName) { ok in
                if ok { model.rename(r.id, to: newName) }
                renaming = nil
            }
        }
        .navigationTitle(title)
    }

    var title: String {
        switch section {
        case .tracks: return "Tracks"
        case .loops: return "Loops"
        case .grooves: return "Grooves"
        case .stems: return "Stems"
        default: return "Everything"
        }
    }

    @ViewBuilder func menu(for item: LibraryItem) -> some View {
        let targets = selection.contains(item.id) ? Array(selection) : [item.id]
        Button("Open") { model.open(item.id) }
        if !model.setlists.isEmpty {
            Menu("Add to Service") {
                ForEach(model.setlists) { s in
                    Menu(s.name) {
                        ForEach(s.sections) { sec in
                            Button(sec.name) { model.add(targets, to: s.id, section: sec.id) }
                        }
                    }
                }
            }
        }
        if item.kind == .song || item.kind == .loop, let maker = StemMaker.shared, maker.installed {
            Menu("Make Stems") {
                Button("4 parts, best quality (slower)") { maker.enqueue(item.id, sixStems: false, best: true) }
                Button("4 parts, quick") { maker.enqueue(item.id, sixStems: false) }
                Button("6 parts (adds guitar and piano)") { maker.enqueue(item.id, sixStems: true, best: true) }
            }
        }
        Menu("Type") {
            Button("Automatic (by tempo)") { model.setCategory(nil, for: targets) }
            Divider()
            ForEach(Category.allCases) { c in
                Button(c.label) { model.setCategory(c, for: targets) }
            }
        }
        Button("Rename...") { renaming = item.id; newName = item.title }
        if item.kind != .groove {
            Button("Detect Tempo Again") { model.queueAnalysis(item.id, force: true) }
        }
        Divider()
        Button(targets.count > 1 ? "Delete \(targets.count) Items" : "Delete") {
            model.delete(Set(targets)); selection.subtract(targets)
        }
    }

    func importTracks() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.prompt = "Import"
        if p.runModal() == .OK { model.importAny(p.urls) }
    }

    func importStems() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowsMultipleSelection = true
        p.allowedFileTypes = ["zip"]
        p.prompt = "Import Stems"
        p.message = "Choose a stem pack: the zip you downloaded, or the folder with the song's stems (click, drums, bass, keys…). A download with several songs becomes several stem items."
        if p.runModal() == .OK { model.importAny(p.urls, forceStems: true) }
    }
}

func loadURLs(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
    var urls: [URL] = []
    let group = DispatchGroup()
    for p in providers {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let u = url { DispatchQueue.main.async { urls.append(u) } }
            group.leave()
        }
    }
    group.notify(queue: .main) { done(urls) }
}

struct ItemRow: View {
    let item: LibraryItem
    var category: Category?
    let analyzing: Bool
    let loaded: Bool
    let loading: Bool
    var customized = false
    /// When set, a play button loads the item with one click.
    var onLoad: (() -> Void)? = nil

    var icon: String {
        switch item.kind {
        case .song: return "music.note"
        case .loop: return "repeat"
        case .groove: return "metronome"
        case .stems: return "slider.vertical.3"
        case .metronome: return "metronome.fill"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if let load = onLoad {
                Button(action: load) {
                    Image(systemName: loaded ? "speaker.wave.2.circle.fill" : "play.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(loaded ? ButtonKind.success.fill : .accentColor)
                }
                .buttonStyle(PlainButtonStyle())
                .frame(width: 28, height: 28)
                .help(loaded ? "Loaded in the player" : "Load into the player")
            } else {
                Image(systemName: loaded ? "speaker.wave.2.fill" : icon)
                    .foregroundColor(loaded ? .accentColor : .secondary)
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 14, weight: loaded ? .semibold : .regular)).lineLimit(1).truncationMode(.tail)
                HStack(spacing: 6) {
                    if let c = category { Text(c.label) }
                    Text(item.timeSig.rawValue)
                    if let b = item.playingBPM { Text("\(formatBPM(b)) BPM") }
                    if let k = item.chords?.key { Text(k.transposed(item.semitones).name) }
                    if item.semitones != 0 { Text(String(format: "%+d", item.semitones)) }
                    if item.duration > 0 && item.kind != .groove { Text(formatTime(item.duration)) }
                    if customized { Text("custom").foregroundColor(.orange) }
                }
                .font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if analyzing || loading { ProgressView().scaleEffect(0.5).frame(width: 16, height: 16) }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Services

struct ServiceView: View {
    @EnvironmentObject var model: AppModel
    let serviceID: UUID
    @State private var adding: IdentifiedUUID?   // section being filled
    @State private var renamingSection: UUID?
    @State private var renamingService = false
    @State private var newName = ""
    @State private var copying = false
    @State private var copyDate = Date()

    var service: Setlist? { model.setlists.first { $0.id == serviceID } }

    var body: some View {
        VStack(spacing: 0) {
            if let s = service {
                header(s)
                Divider()
                List {
                    ForEach(s.sections) { sec in
                        Section(header: sectionHeader(s, sec)) {
                            if sec.entries.isEmpty {
                                Text("Empty. Use Add to put loops or tracks here.").font(.caption).foregroundColor(.secondary)
                            }
                            ForEach(Array(sec.entries.enumerated()), id: \.element.id) { idx, e in
                                entryRow(s, sec, idx, e)
                            }
                            .onMove { model.moveEntries(s.id, section: sec.id, from: $0, to: $1) }
                            .onDelete { model.removeEntries(s.id, section: sec.id, at: $0) }
                        }
                    }
                }
                Divider()
                HStack {
                    Button(action: { model.addSection(s.id, name: "New Section") }) {
                        IconLabel(systemName: "plus", title: "Add Section")
                    }
                    .big(height: Size.small)
                    Spacer()
                    Text("▶ loads a song. N / B = next / previous.").font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                .padding(8)
            } else {
                Text("This service was deleted.").foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(service?.name ?? "Service")
        .sheet(item: $adding) { sec in
            AddToServiceSheet(serviceID: serviceID, sectionID: sec.id) { adding = nil }
                .environmentObject(model)
        }
        .sheet(item: Binding(get: { renamingSection.map { IdentifiedUUID(id: $0) } }, set: { renamingSection = $0?.id })) { r in
            NamePrompt(title: "Rename section", name: $newName) { ok in
                if ok { model.renameSection(serviceID, section: r.id, to: newName) }
                renamingSection = nil
            }
        }
        .sheet(isPresented: $renamingService) {
            NamePrompt(title: "Rename service", name: $newName) { ok in
                if ok { model.renameSetlist(serviceID, to: newName) }
                renamingService = false
            }
        }
        .sheet(isPresented: $copying) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Copy this plan to another date").font(.headline)
                DatePicker("", selection: $copyDate, displayedComponents: .date)
                    .datePickerStyle(GraphicalDatePickerStyle()).labelsHidden()
                HStack {
                    Spacer()
                    Button("Cancel") { copying = false }.keyboardShortcut(.cancelAction)
                    Button("Copy") { _ = model.duplicateService(serviceID, to: copyDate); copying = false }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
    }

    func header(_ s: Setlist) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(.system(size: 17, weight: .bold)).lineLimit(1).truncationMode(.tail)
                Text("\(s.allEntries.count) songs in \(s.sections.count) sections").font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if model.activeSetlist == s.id {
                Badge(text: "IN USE", color: ButtonKind.success.fill)
            } else {
                Button(action: {
                    model.activeSetlist = s.id
                    if let first = s.allEntries.first { model.openEntry(first.id, in: s.id) }
                }) { IconLabel(systemName: "play.fill", title: "Use Now") }
                .big(.primary)
                .disabled(s.allEntries.isEmpty)
                .help("Load the first song. N and B then step through the service.")
            }
            Menu {
                Button("Rename…") { newName = s.name; renamingService = true }
                Button("Copy to Another Date…") { copyDate = NewServiceSheet.nextSunday(); copying = true }
                Divider()
                Button("Delete Service") { model.deleteSetlist(s.id) }
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 18)) }
            .menuStyle(BorderlessButtonMenuStyle())
            .fixedSize()
        }
        .padding(10)
    }

    func sectionHeader(_ s: Setlist, _ sec: SetSection) -> some View {
        HStack(spacing: 6) {
            Text(sec.name.uppercased()).font(.system(size: 12, weight: .bold)).lineLimit(1)
            Text("\(sec.entries.count)").font(.caption).foregroundColor(.secondary)
            Spacer(minLength: 0)
            Button(action: { adding = IdentifiedUUID(id: sec.id) }) { IconLabel(systemName: "plus", title: "Add", iconSize: 11) }
                .big(height: 24, fontSize: 11)
                .help("Add loops or tracks to \(sec.name)")
            Menu {
                Button("Rename…") { newName = sec.name; renamingSection = sec.id }
                Button("Move Up") { model.moveSection(s.id, section: sec.id, by: -1) }
                Button("Move Down") { model.moveSection(s.id, section: sec.id, by: 1) }
                Divider()
                Button("Remove Section") { model.removeSection(s.id, section: sec.id) }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(BorderlessButtonMenuStyle())
            .fixedSize()
        }
    }

    @ViewBuilder
    func entryRow(_ s: Setlist, _ sec: SetSection, _ idx: Int, _ e: SetEntry) -> some View {
        if let base = model.items.first(where: { $0.id == e.itemID }) {
            let item = e.apply(to: base)
            HStack(spacing: 6) {
                Text("\(idx + 1)").font(.system(size: 12, design: .monospaced)).foregroundColor(.secondary)
                    .frame(width: 18, alignment: .trailing)
                ItemRow(item: item, category: nil, analyzing: false,
                        loaded: model.currentEntry == e.id, loading: model.loadingID == base.id,
                        customized: e.hasOverrides, onLoad: { model.openEntry(e.id, in: s.id) })
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.openEntry(e.id, in: s.id) }
            .contextMenu {
                Button("Open") { model.openEntry(e.id, in: s.id) }
                if e.hasOverrides {
                    Button("Use Library Tempo, Key and Loop") { model.resetEntry(e.id) }
                }
                Divider()
                Button("Remove from \(sec.name)") { model.removeEntries(s.id, section: sec.id, at: IndexSet(integer: idx)) }
            }
        }
    }
}

struct AddToServiceSheet: View {
    @EnvironmentObject var model: AppModel
    let serviceID: UUID
    let sectionID: UUID
    let done: () -> Void
    @State private var filter = LibraryFilter()
    @State private var picked = Set<UUID>()

    var sectionName: String {
        model.setlists.first { $0.id == serviceID }?.sections.first { $0.id == sectionID }?.name ?? "section"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add to \(sectionName)").font(.headline)
            FilterBar(filter: $filter)
            List(selection: $picked) {
                ForEach(filter.apply(model.items, model: model)) { item in
                    ItemRow(item: item, category: model.category(of: item), analyzing: false, loaded: false, loading: false)
                        .tag(item.id)
                }
            }
            .frame(height: 340)
            HStack {
                Text("Click to pick; ⌘-click or ⇧-click to pick several.").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button(picked.isEmpty ? "Add" : "Add \(picked.count)") {
                    // Keep library order for a predictable result.
                    let ordered = filter.apply(model.items, model: model).map(\.id).filter { picked.contains($0) }
                    model.add(ordered, to: serviceID, section: sectionID)
                    done()
                }
                .disabled(picked.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 480)
    }
}

struct DownloadView: View {
    @EnvironmentObject var downloader: Downloader
    @State private var link = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Download from YouTube").font(.system(size: 17, weight: .bold))
            Text("Paste a link to a backing track or loop. The audio is saved into the library so it plays without internet on Sunday.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("https://www.youtube.com/watch?v=...", text: $link, onCommit: start)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                Button(action: start) { IconLabel(systemName: "arrow.down.circle.fill", title: "Download") }
                    .big(.primary).disabled(link.isEmpty)
            }
            Divider()
            if downloader.jobs.isEmpty {
                Text("No downloads yet").foregroundColor(.secondary).font(.caption)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(downloader.jobs) { job in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: job.state == .done ? "checkmark.circle.fill" : job.state == .failed ? "xmark.octagon.fill" : "arrow.down.circle")
                                    .foregroundColor(job.state == .done ? .green : job.state == .failed ? .red : .accentColor)
                                Text(job.title.isEmpty ? job.url : job.title).lineLimit(1)
                            }
                            if job.state == .running { ProgressView(value: job.progress) }
                            if !job.message.isEmpty && job.state != .running {
                                Text(job.message).font(.caption).foregroundColor(.secondary).lineLimit(3)
                            }
                        }
                    }
                }
            }
            Spacer()
            Divider()
            HStack {
                Button(downloader.installed ? "Update Downloader" : "Install Downloader") { downloader.update() }
                    .big().disabled(downloader.updating)
                if downloader.updating { ProgressView().scaleEffect(0.5) }
                Text(downloader.updateMessage).font(.caption).foregroundColor(.secondary).lineLimit(2)
            }
            Text("If downloads start failing, YouTube probably changed something. Click Update Downloader (needs internet).")
                .font(.caption2).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .navigationTitle("Download")
    }

    func start() {
        downloader.download(link)
        link = ""
    }
}
