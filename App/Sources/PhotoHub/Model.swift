import AppKit
import MapKit
import Photos
import SwiftUI

enum Kind: String, CaseIterable, Hashable {
    case raw = "With RAW"
    case edited = "With Edits"
    case stacks = "Version Stacks"
    case video = "Videos"
    case archiveOnly = "Only in Archive"
    case photosOnly = "Only in Photos"
    case both = "In Archive and Photos"
    case rawUnedited = "RAW Without Edits"
    case editsNotInPhotos = "Edits Not on Phone"
    case noDate = "No Exact Date"
    case photosExports = "Photos Copies in Archive"

    var title: String { rawValue.localized }

    var icon: String {
        switch self {
        case .raw: return "camera.aperture"
        case .edited: return "wand.and.stars"
        case .stacks: return "square.stack.3d.up"
        case .video: return "film"
        case .archiveOnly: return "externaldrive"
        case .photosOnly: return "iphone"
        case .both: return "arrow.triangle.2.circlepath"
        case .rawUnedited: return "hourglass"
        case .editsNotInPhotos: return "iphone.slash"
        case .noDate: return "calendar.badge.exclamationmark"
        case .photosExports: return "photo.on.rectangle.angled"
        }
    }

    func matches(_ item: Item) -> Bool {
        switch self {
        case .raw: return item.hasRaw
        case .edited: return item.nEdit > 0
        case .stacks: return item.nMembers > 1
        case .video: return item.isVideo
        case .archiveOnly: return item.inArchive && !item.inPhotos
        case .photosOnly: return item.inPhotos && !item.inArchive
        case .both: return item.inPhotos && item.inArchive
        case .rawUnedited: return item.hasRaw && item.nEdit == 0
        case .editsNotInPhotos: return item.nEdit > 0 && !item.inPhotos
        case .noDate: return !item.dateExact
        case .photosExports: return item.nExport > 0 && item.inPhotos
        }
    }
}

enum Scope: Hashable {
    case home
    case all
    case flagged
    case root(String)
    case album(String)
    case year(String)
    case kind(Kind)
    case tag(String, String)
    case list(String)
    case folders(String)
    case loose(String)
    case map
    case custom(String)
    case camera(String)
    case statistics
    case hidden
    case calendar(String)
}

struct Location: Equatable {
    var scope: Scope
    var photo: String?
    var version: String?
    var anchor: String?
    var selection: Set<String> = []
    var custom: Set<String> = []
}

struct ExportPair {
    let item: Item
    let copy: Member
    let original: Member?
}

enum ExportAction: String, Identifiable {
    case removeCopies, removeOriginals
    var id: String { rawValue }
}

struct Notice: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

struct ArchiveSuggestion: Identifiable, Hashable {
    let path: String
    let reason: String
    let exists: Bool
    var id: String { path }
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String
    let text: String
}

struct MapPoint: Identifiable {
    let id: Int
    let coordinate: CLLocationCoordinate2D
    let itemIDs: [Int64]
}

enum Place: String, CaseIterable, Identifiable {
    case any = "Anywhere"
    case archiveOnly = "Archive Only"
    case photosOnly = "Photos Only"
    case both = "Both"
    var id: String { rawValue }
    var title: String { rawValue.localized }
}

struct MonthSection: Identifiable {
    let id: String
    let title: String
    let items: [Item]
}

enum SortKey: String, CaseIterable, Identifiable {
    case dateDesc = "Newest First"
    case dateAsc = "Oldest First"
    case nameAsc = "Name: A → Z"
    case nameDesc = "Name: Z → A"
    case sizeDesc = "Largest Files First"
    case sizeAsc = "Smallest Files First"
    case versions = "Most Versions"
    case rating = "By Rating"
    case label = "By Label"
    case folder = "By Folder"
    var id: String { rawValue }
    var title: String { rawValue.localized }
}

enum Media: String, CaseIterable, Identifiable {
    case any = "Photos and Videos"
    case photo = "Only Photos"
    case video = "Only Videos"
    var id: String { rawValue }
    var title: String { rawValue.localized }
}

enum Tri: String, CaseIterable, Identifiable {
    case any = "Doesn't Matter"
    case yes = "Yes"
    case no = "No"
    var id: String { rawValue }
    var title: String { rawValue.localized }
}

enum PickFilter: String, CaseIterable, Identifiable {
    case any = "Any"
    case picked = "Picked"
    case hideRejected = "Hide Rejected"
    case rejected = "Rejected"
    case unmarked = "Unmarked"
    var id: String { rawValue }
    var title: String { rawValue.localized }
}

enum PeopleFilter: Hashable {
    case any
    case withMe
    case withoutMe
    case one(String, String)

    var label: String? {
        switch self {
        case .any: return nil
        case .withMe: return String(localized: "with me")
        case .withoutMe: return String(localized: "without me")
        case .one(_, let name): return name
        }
    }
}

enum CardSort: String, CaseIterable, Identifiable {
    case standard = "Default"
    case dateDesc = "Newest First"
    case dateAsc = "Oldest First"
    case name = "By Name"
    case count = "By Count"
    var id: String { rawValue }
    var title: String { rawValue.localized }
}

struct FolderNode: Identifiable, Hashable {
    let id: String
    let name: String
    let count: Int
    let own: Int
    let date: String
    let cover: Item?
    let children: [FolderNode]?
}

struct Card: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let scope: Scope
    let cover: Item?
    let icon: String
    var count = 0
    var date = ""
}

enum Months {
    static let short = DateText.shortMonths

    static func label(_ month: String, short isShort: Bool = false) -> String {
        if month.isEmpty { return String(localized: "No Date") }
        return DateText.month(month, short: isShort) ?? month
    }

    static func days(_ from: String, _ to: String) -> String {
        DateText.days(from, to) ?? from
    }

    static func tripTitle(_ name: String) -> String {
        let parts = name.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        return parts.count == 3 ? parts[2] : name
    }

    static func range(_ from: String, _ to: String) -> String {
        if from.isEmpty || to.isEmpty { return "" }
        let a = String(from.prefix(7)), b = String(to.prefix(7))
        return a == b ? label(a, short: true) : label(a, short: true) + " – " + label(b, short: true)
    }
}

@MainActor
final class Model: ObservableObject {
    @Published var sections: [MonthSection] = []
    @Published var shown = 0
    @Published private(set) var scope: Scope = .home {
        didSet {
            viewing = false
            selected = nil
            selection = []
            apply()
        }
    }
    @Published private(set) var backStack: [Location] = []
    @Published private(set) var forwardStack: [Location] = []
    @Published var scrollRequest = 0
    private var pendingVersion: String?
    weak var window: NSWindow?
    @Published var settingsTab = "general"
    @Published var confirmPhone = false
    @Published var inspectorHidden = false
    @Published var place: Place = .any { didSet { apply() } }
    @Published var rawFilter: Presence = .all { didSet { apply() } }
    @Published var editFilter: Presence = .all { didSet { apply() } }
    @Published var stackFilter: Presence = .all { didSet { apply() } }
    @Published var labelFilter: LabelFilter = .any { didSet { apply() } }
    @Published var search = "" { didSet { apply() } }
    @Published var sort: SortKey = .dateDesc { didSet { apply() } }
    @Published var media: Media = .any { didSet { apply() } }
    @Published var formats: Set<String> = [] { didSet { apply() } }
    @Published var year = "" { didSet { apply() } }
    @Published var typeFilter = "" { didSet { apply() } }
    @Published var geo: Tri = .any { didSet { apply() } }
    @Published var dated: Tri = .any { didSet { apply() } }
    @Published var phone: Tri = .any { didSet { apply() } }
    @Published var originFilter = "" { didSet { apply() } }
    @Published var cameraFilter = "" {
        didSet {
            if !lensFilter.isEmpty && !lensNames.contains(lensFilter) { lensFilter = "" }
            apply()
        }
    }
    @Published var lensFilter = "" { didSet { apply() } }
    @Published var peopleFilter: PeopleFilter = .any { didSet { apply() } }
    @Published var meName = UserDefaults.standard.string(forKey: "meName") ?? "" {
        didSet {
            UserDefaults.standard.set(meName, forKey: "meName")
            rebuildPeopleCards()
            if peopleFilter == .withMe || peopleFilter == .withoutMe { apply() }
        }
    }
    @Published var peopleStatus = ""
    @Published var tagsPending = false
    @Published var hideForeign = UserDefaults.standard.object(forKey: "hideForeign") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(hideForeign, forKey: "hideForeign")
            rebuildFeedCards()
            apply()
        }
    }
    @Published var hidden = 0
    @Published var allCameras: [String] = []
    private var allLenses: [String] = []
    private var lensesByCamera: [String: [String]] = [:]
    @Published var cardSort: CardSort = .standard
    @Published var allFormats: [String] = []
    @Published var allYears: [String] = []
    private var located: Set<Int64> = []

    var typeNames: [String] { (tags["type"] ?? [:]).filter { !$0.value.isEmpty }.keys.sorted() }

    var lensNames: [String] { cameraFilter.isEmpty ? allLenses : (lensesByCamera[cameraFilter] ?? []) }

    private func names(_ kind: String) -> [String] {
        (tags[kind] ?? [:]).sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }.map { $0.key }
    }

    var personNames: [String] { names("person") }
    var petNames: [String] { names("pet") }
    var autoMe: String { personNames.first ?? "" }
    var me: String { !meName.isEmpty && tags["person"]?[meName] != nil ? meName : autoMe }

    static let origins: [(code: String, label: String, icon: String)] = [
        ("shot", String(localized: "Shot by Me"), "camera"), ("edit", String(localized: "Edits Without Original"), "slider.horizontal.3"),
        ("screenshot", String(localized: "Screenshots"), "camera.viewfinder"), ("messenger", String(localized: "From Messengers"), "bubble.left.and.bubble.right"),
        ("saved", String(localized: "Saved"), "square.and.arrow.down"), ("generated", String(localized: "Generated"), "sparkles"),
        ("unknown", String(localized: "Unknown"), "questionmark.circle")]
    static let types: [(code: String, label: String, icon: String)] = [
        ("favorite", String(localized: "Favorites"), "heart"), ("selfie", String(localized: "Selfies"), "person.crop.square"),
        ("live", String(localized: "Live Photos"), "livephoto"), ("portrait", String(localized: "Portraits"), "cube"),
        ("panorama", String(localized: "Panoramas"), "pano"), ("screenshot", String(localized: "Screenshots"), "camera.viewfinder"),
        ("slomo", String(localized: "Slo-mo"), "slowmo"), ("timelapse", String(localized: "Time-lapse"), "timelapse")]
    static let markKinds: [(code: String, label: String, icon: String)] = [
        ("picked", String(localized: "Picked"), "checkmark.seal"), ("best", String(localized: "Best (★4 and Up)"), "star.fill"),
        ("rated", String(localized: "Rated"), "star"), ("rejected", String(localized: "Rejected"), "xmark.seal")]
    static let foreignOrigins: Set<String> = ["screenshot", "messenger", "saved", "generated"]

    static func originLabel(_ code: String) -> String? { origins.first { $0.code == code }?.label }

    static func typeLabel(_ code: String) -> String { types.first { $0.code == code }?.label ?? code }

    static func tagTitle(_ kind: String, _ name: String) -> String {
        switch kind {
        case "trip": return Months.tripTitle(name)
        case "origin": return originLabel(name) ?? name
        case "type": return typeLabel(name)
        case "mark": return markKinds.first { $0.code == name }?.label ?? name
        case "dup": return String(localized: "Exact Copies")
        default: return name
        }
    }

    var foreignScope: Bool {
        switch scope {
        case .all, .year, .calendar: return true
        case .tag(let kind, _): return ["day", "trip", "place"].contains(kind)
        default: return false
        }
    }

    private func isForeign(_ item: Item, _ shots: Set<Int64>) -> Bool {
        Model.foreignOrigins.contains(item.origin) || shots.contains(item.id)
    }

    var activeFilters: Int {
        var n = 0
        if minRating != 0 { n += 1 }
        if pickFilter != .any { n += 1 }
        if place != .any { n += 1 }
        if media != .any { n += 1 }
        if !formats.isEmpty { n += 1 }
        if !year.isEmpty { n += 1 }
        if !typeFilter.isEmpty { n += 1 }
        if geo != .any { n += 1 }
        if dated != .any { n += 1 }
        if phone != .any { n += 1 }
        if !originFilter.isEmpty { n += 1 }
        if !cameraFilter.isEmpty { n += 1 }
        if !lensFilter.isEmpty { n += 1 }
        if peopleFilter != .any { n += 1 }
        if rawFilter != .all { n += 1 }
        if editFilter != .all { n += 1 }
        if stackFilter != .all { n += 1 }
        if labelFilter != .any { n += 1 }
        return n
    }

    func resetFilters() {
        place = .any
        media = .any
        formats = []
        year = ""
        typeFilter = ""
        geo = .any
        dated = .any
        phone = .any
        originFilter = ""
        cameraFilter = ""
        lensFilter = ""
        peopleFilter = .any
        rawFilter = .all
        editFilter = .all
        stackFilter = .all
        labelFilter = .any
        minRating = 0
        pickFilter = .any
    }

    private func matchesSearch(_ title: String, _ subtitle: String) -> Bool {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty || title.lowercased().contains(needle) || subtitle.lowercased().contains(needle)
    }

    func sortedCards(_ key: String) -> [Card] {
        let list = cards(key).filter { matchesSearch($0.title, $0.subtitle) }
        switch cardSort {
        case .standard: return list
        case .dateDesc: return list.sorted { $0.date > $1.date }
        case .dateAsc: return list.sorted { $0.date < $1.date }
        case .name: return list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .count: return list.sorted { $0.count > $1.count }
        }
    }

    func sortedFolders(in path: String) -> [FolderNode] {
        let list = folders(in: path).filter { matchesSearch($0.name, "") }
        switch cardSort {
        case .standard: return list
        case .dateDesc: return list.sorted { $0.date > $1.date }
        case .dateAsc: return list.sorted { $0.date < $1.date }
        case .name: return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .count: return list.sorted { $0.count > $1.count }
        }
    }
    @Published var selected: Item?
    @Published var selection: Set<Int64> = []
    @Published var chat: [ChatMessage] = []
    @Published var agentBusy = false
    @Published var agentOpen = false
    @Published var userTagCards: [Card] = []
    @Published var marks: [String: Mark] = [:]
    @Published var minRating = 0 { didSet { apply() } }
    @Published var pickFilter: PickFilter = .any { didSet { apply() } }
    @Published var workCards: [Card] = []
    @Published var markCards: [Card] = []
    @Published var dayCards: [Card] = []
    @Published var busyTool = ""
    private var idByKey: [String: Int64] = [:]
    private var keyMonitor: Any?
    private var navigationMonitor: Any?
    private var watchTimer: Timer?
    private var loadedVersion: Int64 = -2
    private var hadTags = false
    private var seenSignature = ""
    private var seenSince = Date()

    static let editors: [(name: String, url: URL)] = {
        var out: [(name: String, url: URL)] = []
        let apps = ((try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []).sorted().reversed()
        for (label, prefix) in [("Photoshop", "Adobe Photoshop"), ("Lightroom Classic", "Adobe Lightroom Classic")] {
            for dir in apps where dir.hasPrefix(prefix) {
                let inner = "/Applications/\(dir)/\(dir).app"
                if FileManager.default.fileExists(atPath: inner) {
                    out.append((label, URL(fileURLWithPath: inner)))
                    break
                }
            }
        }
        out.append((String(localized: "Preview"), URL(fileURLWithPath: "/System/Applications/Preview.app")))
        return out
    }()

    func targets() -> [Item] {
        let chosen = flat.filter { selection.contains($0.id) }
        return chosen.isEmpty ? (selected.map { [$0] } ?? []) : chosen
    }

    func rate(_ stars: Int) {
        for item in targets() {
            var mark = marks[item.key] ?? Mark()
            mark.rating = stars
            marks[item.key] = mark
            catalog?.setMark(item.key, mark)
        }
        rebuildMarkCards()
        if minRating != 0 || sort == .rating { apply() }
    }

    func pick(_ value: Int) {
        let items = targets()
        let same = !items.isEmpty && items.allSatisfy { (marks[$0.key]?.pick ?? 0) == value }
        for item in items {
            var mark = marks[item.key] ?? Mark()
            mark.pick = same ? 0 : value
            marks[item.key] = mark
            catalog?.setMark(item.key, mark)
        }
        rebuildMarkCards()
        if pickFilter != .any { apply() }
    }

    func toggleFlagSelection() {
        let items = targets()
        let allOn = !items.isEmpty && items.allSatisfy { flagged.contains($0.key) }
        for item in items {
            if allOn { flagged.remove(item.key) } else { flagged.insert(item.key) }
            catalog?.setFlag(item.key, !allOn)
        }
        if scope == .flagged || phone != .any { apply() }
    }

    private func rebuildMarkCards() {
        var picked: Set<Int64> = [], rejected: Set<Int64> = [], best: Set<Int64> = [], rated: Set<Int64> = []
        for (key, mark) in marks {
            guard let id = idByKey[key] else { continue }
            if mark.pick == 1 { picked.insert(id) }
            if mark.pick == -1 { rejected.insert(id) }
            if mark.rating >= 4 { best.insert(id) }
            if mark.rating > 0 { rated.insert(id) }
        }
        tags["mark"] = ["picked": picked, "best": best, "rated": rated, "rejected": rejected]
        markCards = Model.markKinds.compactMap { kind -> Card? in
            guard let ids = tags["mark"]?[kind.code], !ids.isEmpty else { return nil }
            return Card(id: "mark:" + kind.code, title: kind.label, subtitle: "\(ids.count)", scope: .tag("mark", kind.code), cover: nil, icon: kind.icon, count: ids.count)
        }
    }

    private func handleKey(_ code: UInt16, _ flags: NSEvent.ModifierFlags) -> Bool {
        if let window, NSApp.keyWindow !== window { return false }
        guard isBrowsing, selected != nil || !selection.isEmpty else { return false }
        if viewing, let pageKeys, NSApp.keyWindow?.sheetParent == nil, !(NSApp.keyWindow?.firstResponder is NSText), pageKeys(code, flags) { return true }
        guard flags.intersection([.command, .option, .control]).isEmpty else { return false }
        if NSApp.keyWindow?.firstResponder is NSText { return false }
        switch code {
        case 29: rate(0)
        case 18: rate(1)
        case 19: rate(2)
        case 20: rate(3)
        case 21: rate(4)
        case 23: rate(5)
        case 35: pick(1)
        case 7: pick(-1)
        case 32: pick(0)
        case 17: toggleFlagSelection()
        case 49: if viewing { goBack() } else { openPage() }
        default:
            guard let label = ColorLabel(keyCode: code) else { return false }
            toggleLabel(label)
        }
        return true
    }

    private func runTool(_ arguments: [String], label: String, done: @escaping () -> Void) {
        guard busyTool.isEmpty else { return }
        let project = (try? String(contentsOf: Model.supportDir.appendingPathComponent("project_path.txt")))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: project + "/.venv/bin/photohub")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: project)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        busyTool = label
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard let line = text.split(separator: "\n").last, let range = line.range(of: #"\d+/\d+"#, options: .regularExpression) else { return }
            let progress = label + " " + line[range]
            DispatchQueue.main.async { self.busyTool = progress }
        }
        process.terminationHandler = { _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self.busyTool = ""
                done()
            }
        }
        do {
            try process.run()
        } catch {
            busyTool = ""
            status = String(localized: "Could not start: \(error.localizedDescription)")
        }
    }

    var previewRoot: String? {
        switch scope {
        case .root(let path) where path != "/": return path
        case .loose(let path): return path
        default: return nil
        }
    }

    func refreshCatalog() {
        runTool(["rebuild"], label: String(localized: "Refreshing catalog…")) { self.reload() }
    }

    func buildPreviews() {
        guard let root = previewRoot else { return }
        runTool(["thumbs", "--root", root], label: String(localized: "Making previews…")) {
            Thumbs.shared.forget()
            self.epoch += 1
        }
    }

    func sendToPhone() {
        runTool(["phone", "--apply"], label: String(localized: "Sending to Photos…")) { self.reload() }
    }

    func open(_ member: Member, with app: URL) {
        NSWorkspace.shared.open([Catalog.archiveRoot.appendingPathComponent(member.path)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
    private var agentSession: String?
    private var agentProcess: Process?
    private var lastTypes: [String: [String]] = [:]
    private var lastLocations: [String: CLLocationCoordinate2D] = [:]
    static let supportDir = AppPaths.support
    static let agentBinary = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude")
    static let agentModel = "claude-opus-5-5"

    func userTags(of item: Item) -> [String] {
        (tags["user"] ?? [:]).filter { $0.value.contains(item.id) }.keys.sorted()
    }

    func click(_ item: Item, command: Bool, shift: Bool) {
        if shift, let anchor = selected, let a = flat.firstIndex(where: { $0.id == anchor.id }), let b = flat.firstIndex(where: { $0.id == item.id }) {
            selection.formUnion(flat[min(a, b)...max(a, b)].map { $0.id })
            selected = item
        } else if command {
            if selection.contains(item.id) {
                selection.remove(item.id)
                if selected?.id == item.id { selected = flat.first { selection.contains($0.id) } }
            } else {
                selection.insert(item.id)
                selected = item
            }
        } else {
            selection = [item.id]
            selected = item
        }
    }

    @discardableResult
    func reload() -> Bool {
        guard let fresh = Catalog(), let snapshot = fresh.snapshot() else { return false }
        let keys = Set(flat.filter { selection.contains($0.id) }.map { $0.key })
        let primary = selected?.key
        let custom = Set(all.filter { customIDs.contains($0.id) }.map { $0.key })
        catalog = fresh
        install(snapshot)
        customIDs = Set(all.filter { custom.contains($0.key) }.map { $0.id })
        buildCollections()
        installPhotoData(types: lastTypes, locations: lastLocations)
        apply()
        selection = Set(flat.filter { keys.contains($0.key) }.map { $0.id })
        selected = flat.first { $0.key == primary }
        if primary != nil && selected == nil { viewing = false }
        epoch += 1
        return true
    }

    private func install(_ snapshot: CatalogSnapshot) {
        let snapshot = Hidden.shared.split(snapshot)
        all = snapshot.items
        albums = snapshot.albums
        tags = snapshot.tags
        flagged = snapshot.flags
        marks = snapshot.marks
        loadedVersion = snapshot.version
        hadTags = snapshot.tags.keys.contains { $0 != "user" }
        tagsPending = snapshot.tagsPending
        peopleStatus = catalog?.meta("photos_people") ?? ""
        albumNames = albums.map { (name: $0.key, count: $0.value.count) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func watch() {
        let signature = Catalog.signature()
        if signature != seenSignature {
            seenSignature = signature
            seenSince = Date()
            return
        }
        let quiet = Date().timeIntervalSince(seenSince)
        guard quiet >= 2, busyTool.isEmpty, !Catalog.writing, let catalog, catalog.dataVersion() != loadedVersion else { return }
        guard catalog.count("item") > 0 else { return }
        if hadTags && (catalog.count("tag") == 0 || !catalog.tagsCurrent()) && quiet < 30 { return }
        reload()
    }

    private func writeContext() {
        let chosen = flat.filter { selection.contains($0.id) }.prefix(500)
        let picked: [[String: Any]] = chosen.map { item in
            ["id": item.id, "key": item.key, "title": item.title, "date": item.date, "folder": item.root,
             "in_archive": item.inArchive, "in_photos": item.inPhotos,
             "files": members(of: item).map { $0.source == "archive" ? $0.path : "photos:" + $0.name }]
        }
        let context: [String: Any] = ["view": title, "shown": shown, "selected_count": selection.count, "selected": picked,
                                      "search": search, "active_filters": activeFilters]
        if let data = try? JSONSerialization.data(withJSONObject: context, options: [.prettyPrinted]) {
            try? data.write(to: Model.supportDir.appendingPathComponent("context.json"))
        }
    }

    func sendToAgent(_ text: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !agentBusy else { return }
        chat.append(ChatMessage(role: "user", text: message))
        writeContext()
        agentBusy = true
        let project = (try? String(contentsOf: Model.supportDir.appendingPathComponent("project_path.txt")))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prompt = "[PhotoHub: viewing \"\(title)\", shown \(shown), selected \(selection.count). Full context: .venv/bin/photohub context]\n\n\(message)"
        var arguments = ["-p", prompt, "--output-format", "json", "--model", Model.agentModel,
                         "--allowedTools", "Read", "Grep", "Glob", "Bash(.venv/bin/photohub:*)",
                         "--append-system-prompt", "You are the assistant inside the PhotoHub app. Before your first action, read AGENT.md and follow it strictly. Reply in the user's language; default Russian. Keep replies short, without tables."]
        if let session = agentSession { arguments += ["--resume", session] }
        let process = Process()
        process.executableURL = Model.agentBinary
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: project)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin"
        environment.removeValue(forKey: "ANTHROPIC_API_KEY")
        environment.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        agentProcess = process
        DispatchQueue.global().async {
            var reply = ""
            var session: String?
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let raw = String(decoding: data, as: UTF8.self)
                if let start = raw.firstIndex(of: "{"),
                   let json = try? JSONSerialization.jsonObject(with: Data(raw[start...].utf8)) as? [String: Any] {
                    reply = json["result"] as? String ?? ""
                    session = json["session_id"] as? String
                }
                if reply.isEmpty {
                    reply = process.terminationStatus == 0 ? String(localized: "The agent did not reply.") : String(localized: "The agent was stopped or exited with an error.")
                }
            } catch {
                reply = String(localized: "Could not start the agent: \(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                self.chat.append(ChatMessage(role: "agent", text: reply))
                if let session { self.agentSession = session }
                self.agentBusy = false
                self.agentProcess = nil
                self.reload()
            }
        }
    }

    func debugSelect(_ count: Int) {
        let picked = flat.prefix(count)
        selection = Set(picked.map { $0.id })
        selected = picked.first
    }

    func debugSelect(where match: (Item) -> Bool) {
        guard let item = flat.first(where: match) else { return }
        selection = [item.id]
        selected = item
        scrollRequest += 1
    }

    func stopAgent() { agentProcess?.terminate() }

    func newChat() {
        chat = []
        agentSession = nil
    }
    @Published var viewing = false
    @Published var flagged: Set<String> = []
    @Published var status = String(localized: "Loading…")
    @Published var epoch = 0
    @Published var tree: [FolderNode] = []
    @Published var albumNames: [(name: String, count: Int)] = []
    @Published var eventCards: [Card] = []
    @Published var yearCards: [Card] = []
    @Published var albumCards: [Card] = []
    @Published var kindCards: [Card] = []
    @Published var tripCards: [Card] = []
    @Published var placeCards: [Card] = []
    @Published var personCards: [Card] = []
    @Published var petCards: [Card] = []
    @Published var typeCards: [Card] = []
    @Published var storageCards: [Card] = []
    @Published var originCards: [Card] = []
    @Published var cameraCards: [Card] = []
    @Published var points: [MapPoint] = []
    var mapRegion: MKCoordinateRegion?
    private var customIDs: Set<Int64> = []

    private(set) var catalog: Catalog?
    private var all: [Item] = []
    private(set) var flat: [Item] = []
    private var albums: [String: Set<Int64>] = [:]
    private(set) var tags: [String: [String: Set<Int64>]] = [:]
    private(set) var byID: [Int64: Item] = [:]
    private var nodeIndex: [String: FolderNode] = [:]

    static let listTitles = ["trips": String(localized: "Trips"), "people": String(localized: "People"), "pets": String(localized: "Pets"),
                             "places": String(localized: "Places"), "events": String(localized: "Events and Shoots"), "years": String(localized: "Years"),
                             "albums": String(localized: "Photos Albums"), "kinds": String(localized: "Types"), "storage": String(localized: "Where It Is Stored"),
                             "usertags": String(localized: "My Tags"), "work": String(localized: "To Sort Out"), "marks": String(localized: "Picks and Ratings"),
                             "days": String(localized: "On These Days in Past Years"), "origins": String(localized: "Origin"), "cameras": String(localized: "Cameras")]

    var subtitle: String {
        if !busyTool.isEmpty { return busyTool }
        let base = isBrowsing && status.isEmpty ? String(localized: "\(shown) items") : status
        guard tagsPending else { return base }
        return base.isEmpty ? String(localized: "Catalog is updating…") : String(localized: "\(base) · catalog is updating…")
    }

    var isBrowsing: Bool {
        if case .home = scope { return false }
        if case .list = scope { return false }
        if case .folders = scope { return false }
        if case .map = scope { return false }
        if case .statistics = scope { return false }
        return true
    }

    func showItems(_ ids: Set<Int64>, title: String) {
        go(.custom(title), custom: ids)
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    private var here: Location {
        var location = Location(scope: scope)
        location.anchor = selected?.key
        location.selection = Set(selection.compactMap { byID[$0]?.key })
        if viewing, let key = selected?.key {
            location.photo = key
            location.version = page?.current?.path
        }
        if case .custom = scope { location.custom = Set(customIDs.compactMap { byID[$0]?.key }) }
        return location
    }

    private func push(_ location: Location) {
        backStack.append(location)
        if backStack.count > 100 { backStack.removeFirst() }
        forwardStack = []
    }

    func go(_ target: Scope, custom ids: Set<Int64>? = nil) {
        if target == scope && !viewing && ids == nil { return }
        let from = here
        if let ids { customIDs = ids }
        scope = target
        push(from)
    }

    func openPage() {
        guard !viewing, selected != nil else { return }
        push(here)
        viewing = true
    }

    func goBack() {
        guard let index = backStack.lastIndex(where: { viewing || $0.photo != nil || $0.scope != scope }) else {
            if viewing { viewing = false }
            return
        }
        let target = backStack[index]
        backStack.removeSubrange(index...)
        forwardStack.append(here)
        restore(target)
    }

    func goForward() {
        guard let target = forwardStack.popLast() else { return }
        backStack.append(here)
        restore(target)
    }

    func takeVersion() -> String? {
        defer { pendingVersion = nil }
        return pendingVersion
    }

    private func restore(_ location: Location) {
        var target = location
        if viewing, target.photo == nil, target.scope == scope, let current = selected?.key {
            target.anchor = current
            if target.selection.count <= 1 { target.selection = [current] }
        }
        if case .custom = target.scope { customIDs = Set(target.custom.compactMap { idByKey[$0] }) }
        if target.scope != scope {
            scope = target.scope
        } else {
            viewing = false
            if case .custom = target.scope { apply() }
        }
        let index = Dictionary(flat.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        selection = Set(target.selection.compactMap { index[$0]?.id })
        selected = target.anchor.flatMap { index[$0] }
        if let key = target.photo, let item = index[key] {
            selected = item
            if !selection.contains(item.id) { selection = [item.id] }
            pendingVersion = target.version
            viewing = true
        }
        scrollRequest += 1
    }

    private func handleNavigation(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        switch event.type {
        case .otherMouseDown:
            if event.buttonNumber == 3 { goBack() } else if event.buttonNumber == 4 { goForward() } else { return false }
        case .swipe:
            if event.deltaX > 0 { goBack() } else if event.deltaX < 0 { goForward() } else { return false }
        default:
            return false
        }
        return true
    }

    private func rebuildTypeCards() {
        func kind(_ k: Kind) -> [Card] { kindCards.filter { $0.id == "kind:" + k.rawValue } }
        let fromPhotos = Model.types.compactMap { type -> Card? in
            guard let ids = tags["type"]?[type.code], !ids.isEmpty else { return nil }
            return Card(id: "type:" + type.code, title: type.label, subtitle: "\(ids.count)", scope: .tag("type", type.code), cover: nil, icon: type.icon, count: ids.count)
        }
        typeCards = Array(fromPhotos.prefix(1)) + kind(.video) + Array(fromPhotos.dropFirst()) + kind(.raw) + kind(.edited) + kind(.stacks)
        if fromPhotos.first?.id != "type:favorite" { typeCards = kind(.video) + fromPhotos + kind(.raw) + kind(.edited) + kind(.stacks) }
        storageCards = kind(.archiveOnly) + kind(.photosOnly) + kind(.both)
        var work = kind(.rawUnedited) + kind(.editsNotInPhotos) + kind(.noDate) + kind(.photosExports)
        if let dup = tags["dup"]?.first, !dup.value.isEmpty {
            work.append(Card(id: "dup", title: String(localized: "Exact Copies in Archive"), subtitle: "\(dup.value.count)", scope: .tag("dup", dup.key), cover: nil, icon: "doc.on.doc", count: dup.value.count))
        }
        workCards = work
    }

    private func installPhotoData(types: [String: [String]], locations: [String: CLLocationCoordinate2D]) {
        var assetItem: [String: Int64] = [:]
        for item in all where !item.thumbAsset.isEmpty { assetItem[item.thumbAsset] = item.id }
        var typeSets: [String: Set<Int64>] = [:]
        for (name, ids) in types { typeSets[name] = Set(ids.compactMap { assetItem[$0] }) }
        tags["type"] = typeSets
        rebuildTypeCards()
        rebuildFeedCards()
        var buckets: [String: (CLLocationCoordinate2D, [Int64])] = [:]
        for (asset, coordinate) in locations {
            guard let id = assetItem[asset] else { continue }
            let key = "\(Int((coordinate.latitude * 1000).rounded()))_\(Int((coordinate.longitude * 1000).rounded()))"
            buckets[key, default: (coordinate, [])].1.append(id)
        }
        let photoLocated = Set(buckets.values.flatMap { $0.1 })
        for (id, coordinate) in AppPaths.archiveLocations() where !photoLocated.contains(id) && byID[id] != nil {
            let key = "\(Int((coordinate.latitude * 1000).rounded()))_\(Int((coordinate.longitude * 1000).rounded()))"
            buckets[key, default: (coordinate, [])].1.append(id)
        }
        points = buckets.values.enumerated().map { MapPoint(id: $0.offset, coordinate: $0.element.0, itemIDs: $0.element.1) }
        located = Set(points.flatMap { $0.itemIDs })
    }

    func folders(in path: String) -> [FolderNode] {
        path.isEmpty ? tree : (nodeIndex[path]?.children ?? [])
    }

    func ownCount(_ path: String) -> Int { nodeIndex[path]?.own ?? 0 }

    var bannerCover: Item? {
        switch scope {
        case .home, .list, .folders, .map: return nil
        case .root(let path), .loose(let path):
            if let cover = nodeIndex[path]?.cover { return cover }
        default:
            for key in Model.listTitles.keys.sorted() {
                if let cover = cards(key).first(where: { $0.scope == scope })?.cover { return cover }
            }
        }
        return sections.first?.items.first
    }

    func folderScope(_ node: FolderNode) -> Scope {
        node.children == nil ? .root(node.id) : .folders(node.id)
    }

    var crumbs: [(name: String, scope: Scope)]? {
        let path: String
        switch scope {
        case .folders(let p): path = p
        case .root(let p), .loose(let p): path = p == "/" ? "" : p
        default: return nil
        }
        var out: [(name: String, scope: Scope)] = [(String(localized: "Folders"), .folders(""))]
        var current = ""
        for part in path.split(separator: "/").map(String.init) {
            current = current.isEmpty ? part : current + "/" + part
            let node = nodeIndex[current]
            out.append((part, node.map(folderScope) ?? .root(current)))
        }
        if case .root("/") = scope { out.append((String(localized: "No Folder"), scope)) }
        if case .loose = scope { out.append((String(localized: "Files in This Folder"), scope)) }
        return out
    }

    func cards(_ key: String) -> [Card] {
        switch key {
        case "trips": return tripCards
        case "people": return personCards
        case "pets": return petCards
        case "places": return placeCards
        case "events": return eventCards
        case "years": return yearCards
        case "albums": return albumCards
        case "storage": return storageCards
        case "usertags": return userTagCards
        case "work": return workCards
        case "marks": return markCards
        case "days": return dayCards
        case "origins": return originCards
        case "cameras": return cameraCards
        default: return typeCards
        }
    }

    var title: String { title(of: scope) }

    func title(of scope: Scope) -> String {
        switch scope {
        case .home: return String(localized: "Collections")
        case .all: return String(localized: "All Items")
        case .flagged: return String(localized: "To Phone")
        case .root(let r): return r == "/" ? String(localized: "No Folder") : (r.split(separator: "/").last.map(String.init) ?? r)
        case .album(let a): return a
        case .year(let y): return y
        case .kind(let k): return k.title
        case .tag(let kind, let name): return Model.tagTitle(kind, name)
        case .list(let key): return Model.listTitles[key] ?? key
        case .folders(let p): return p.isEmpty ? String(localized: "Folders") : (p.split(separator: "/").last.map(String.init) ?? p)
        case .loose(let p): return String(localized: "\(p.split(separator: "/").last.map(String.init) ?? p) — files in the folder")
        case .map: return String(localized: "Map")
        case .custom(let title): return title
        case .camera(let camera): return camera
        case .statistics: return String(localized: "Statistics")
        case .hidden: return String(localized: "Hidden")
        case .calendar(let value): return CalendarRoute.title(value)
        }
    }

    func start() {
        guard let catalog = Catalog() else {
            status = String(localized: "Catalog not found: \(Catalog.path)")
            return
        }
        self.catalog = catalog
        if let snapshot = catalog.snapshot() { install(snapshot) }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let handled = MainActor.assumeIsolated { self.handleKey(event.keyCode, event.modifierFlags) }
                return handled ? nil : event
            }
        }
        if navigationMonitor == nil {
            navigationMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .swipe]) { [weak self] event in
                guard let self else { return event }
                let handled = MainActor.assumeIsolated { self.handleNavigation(event) }
                return handled ? nil : event
            }
        }
        if watchTimer == nil {
            watchTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.watch() }
            }
        }
        var formatCounts: [String: Int] = [:]
        var years: Set<String> = []
        for item in all {
            for token in item.formats.split(separator: " ") { formatCounts[String(token), default: 0] += 1 }
            if item.date.count >= 4 { years.insert(String(item.date.prefix(4))) }
        }
        allFormats = formatCounts.sorted { $0.value > $1.value }.map { $0.key }
        allYears = years.sorted(by: >)
        buildCollections()
        apply()
        if AppPaths.noPhotos {
            DispatchQueue.main.async {
                self.installPhotoData(types: [:], locations: [:])
                self.apply()
                self.status = ""
                self.epoch += 1
            }
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { auth in
            let ok = auth == .authorized || auth == .limited
            if ok { Thumbs.shared.loadAssets() }
            let types = ok ? Thumbs.shared.typeIdentifiers() : [:]
            let locations = ok ? Thumbs.shared.locations() : [:]
            DispatchQueue.main.async {
                if Hidden.shared.photosChanged() { self.reload() }
                self.lastTypes = types
                self.lastLocations = locations
                self.installPhotoData(types: types, locations: locations)
                self.apply()
                self.status = ok ? "" : String(localized: "No access to Photos: previews of phone items will not show")
                self.epoch += 1
            }
        }
    }

    private static func isContainer(_ name: String) -> Bool {
        if Catalog.containerFolders.contains(name) { return true }
        return name.count == 4 && Int(name) != nil
    }

    private static func order(_ a: FolderNode, _ b: FolderNode) -> Bool {
        let ad = a.name.first?.isNumber ?? false, bd = b.name.first?.isNumber ?? false
        if ad != bd { return ad }
        let cmp = a.name.localizedStandardCompare(b.name)
        return ad ? cmp == .orderedDescending : cmp == .orderedAscending
    }

    private func buildCollections() {
        final class Box {
            let name: String
            let path: String
            var own = 0
            var kids: [String: Box] = [:]
            init(_ name: String, _ path: String) { self.name = name; self.path = path }
        }
        struct Stat { var count = 0; var cover: Item?; var newest = ""; var oldest = ""; var raw = 0; var edited = 0 }

        var rootStats: [String: Stat] = [:]
        var kindStats: [Kind: Stat] = [:]
        func add(_ stat: inout Stat, _ item: Item) {
            stat.count += 1
            if item.hasRaw { stat.raw += 1 }
            if item.nEdit > 0 { stat.edited += 1 }
            if !item.date.isEmpty {
                if stat.newest.isEmpty { stat.newest = item.date }
                stat.oldest = item.date
            }
            if stat.cover == nil || (stat.cover!.thumbAsset.isEmpty && !item.thumbAsset.isEmpty) { stat.cover = item }
        }
        for item in all {
            if item.inArchive { add(&rootStats[item.root, default: Stat()], item) }
            for kind in Kind.allCases where kind.matches(item) { add(&kindStats[kind, default: Stat()], item) }
        }

        let top = Box("", "")
        for (root, stat) in rootStats where !root.isEmpty {
            var current = top
            var path = ""
            for part in root.split(separator: "/").map(String.init) {
                path = path.isEmpty ? part : path + "/" + part
                if current.kids[part] == nil { current.kids[part] = Box(part, path) }
                current = current.kids[part]!
            }
            current.own += stat.count
        }
        func convert(_ box: Box) -> FolderNode {
            let kids = box.kids.values.map(convert).sorted(by: Model.order)
            let cover = rootStats[box.path]?.cover ?? kids.first { $0.cover != nil }?.cover
            let date = max(rootStats[box.path]?.newest ?? "", kids.map { $0.date }.max() ?? "")
            return FolderNode(id: box.path, name: box.name, count: box.own + kids.reduce(0) { $0 + $1.count }, own: box.own, date: date, cover: cover, children: kids.isEmpty ? nil : kids)
        }
        var nodes = top.kids.values.map(convert).sorted(by: Model.order)
        if let loose = rootStats[""] { nodes.append(FolderNode(id: "/", name: String(localized: "No Folder"), count: loose.count, own: loose.count, date: loose.newest, cover: loose.cover, children: nil)) }
        tree = nodes
        var index: [String: FolderNode] = [:]
        func walk(_ node: FolderNode) {
            index[node.id] = node
            node.children?.forEach(walk)
        }
        nodes.forEach(walk)
        nodeIndex = index

        eventCards = rootStats
            .filter { !$0.key.isEmpty && !Model.isContainer($0.key.split(separator: "/").last.map(String.init) ?? "") }
            .sorted { $0.value.newest > $1.value.newest }
            .map { root, stat in
                let parts = root.split(separator: "/").map(String.init)
                let parent = parts.dropLast().joined(separator: " / ")
                let range = Months.range(stat.oldest, stat.newest)
                let work = stat.raw > 0 ? "RAW \(stat.raw) · ✎ \(stat.edited)" : (stat.edited > 0 ? "✎ \(stat.edited)" : "")
                let sub = ["\(stat.count)", range, work, parent].filter { !$0.isEmpty }.joined(separator: " · ")
                return Card(id: "root:" + root, title: parts.last ?? root, subtitle: sub, scope: .root(root), cover: stat.cover, icon: "folder", count: stat.count, date: stat.newest)
            }
        kindCards = Kind.allCases.compactMap { kind in
            guard let stat = kindStats[kind] else { return nil }
            return Card(id: "kind:" + kind.rawValue, title: kind.title, subtitle: "\(stat.count)", scope: .kind(kind), cover: nil, icon: kind.icon, count: stat.count)
        }
        byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        idByKey = Dictionary(all.map { ($0.key, $0.id) }, uniquingKeysWith: { first, _ in first })
        tripCards = (tags["trip"] ?? [:]).sorted { $0.key > $1.key }.map { name, ids in
            let parts = name.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let when = parts.count == 3 ? Months.days(parts[0], parts[1]) : ""
            return Card(id: "trip:" + name, title: Months.tripTitle(name), subtitle: "\(when) · \(ids.count)", scope: .tag("trip", name), cover: cover(ids), icon: "airplane", count: ids.count, date: name)
        }
        placeCards = (tags["place"] ?? [:]).sorted { $0.value.count > $1.value.count }.map { name, ids in
            Card(id: "place:" + name, title: name, subtitle: "\(ids.count)", scope: .tag("place", name), cover: cover(ids), icon: "mappin.and.ellipse", count: ids.count)
        }
        rebuildPeopleCards()
        rebuildUserTagCards()
        originCards = Model.origins.compactMap { origin -> Card? in
            guard let ids = tags["origin"]?[origin.code], !ids.isEmpty else { return nil }
            return Card(id: "origin:" + origin.code, title: origin.label, subtitle: "\(ids.count)", scope: .tag("origin", origin.code), cover: nil, icon: origin.icon, count: ids.count)
        }
        var cameraIDs: [String: Set<Int64>] = [:]
        var lensCounts: [String: [String: Int]] = [:]
        var allLensCounts: [String: Int] = [:]
        for item in all {
            if !item.camera.isEmpty { cameraIDs[item.camera, default: []].insert(item.id) }
            if !item.lens.isEmpty {
                allLensCounts[item.lens, default: 0] += 1
                if !item.camera.isEmpty { lensCounts[item.camera, default: [:]][item.lens, default: 0] += 1 }
            }
        }
        func byCount(_ counts: [String: Int]) -> [String] {
            counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { $0.key }
        }
        allCameras = byCount(cameraIDs.mapValues { $0.count })
        allLenses = byCount(allLensCounts)
        lensesByCamera = lensCounts.mapValues(byCount)
        cameraCards = allCameras.compactMap { name -> Card? in
            guard let ids = cameraIDs[name], ids.count >= 20 else { return nil }
            return Card(id: "camera:" + name, title: name, subtitle: "\(ids.count)", scope: .camera(name), cover: cover(ids), icon: "camera", count: ids.count)
        }
        rebuildFeedCards()
        defer {
            rebuildTypeCards()
            rebuildMarkCards()
        }
        albumCards = albumNames.map { album in
            let ids = albums[album.name] ?? []
            let cover = all.first { ids.contains($0.id) }
            return Card(id: "album:" + album.name, title: album.name, subtitle: "\(album.count)", scope: .album(album.name), cover: cover, icon: "rectangle.stack", count: album.count, date: cover?.date ?? "")
        }
    }

    private func rebuildPeopleCards() {
        let me = self.me
        func cards(_ kind: String, _ icon: String) -> [Card] {
            names(kind).map { name in
                let ids = tags[kind]?[name] ?? []
                let subtitle = kind == "person" && name == me ? String(localized: "\(ids.count) · this is me") : "\(ids.count)"
                return Card(id: kind + ":" + name, title: name, subtitle: subtitle, scope: .tag(kind, name), cover: cover(ids), icon: icon, count: ids.count)
            }
        }
        personCards = cards("person", "person.crop.circle")
        petCards = cards("pet", "pawprint")
    }

    func people(of item: Item) -> [(title: String, icon: String, scope: Scope)] {
        [("person", "person.crop.circle"), ("pet", "pawprint")].flatMap { kind, icon in
            names(kind).filter { tags[kind]?[$0]?.contains(item.id) ?? false }.map { (title: $0, icon: icon, scope: Scope.tag(kind, $0)) }
        }
    }

    private func cover(_ ids: Set<Int64>) -> Item? {
        var fallback: Item?
        for id in ids {
            guard let item = byID[id] else { continue }
            if !item.thumbAsset.isEmpty { return item }
            if fallback == nil { fallback = item }
        }
        return fallback
    }

    private func rebuildFeedCards() {
        let shots = hideForeign ? (tags["type"]?["screenshot"] ?? []) : []
        let calendar = Calendar.current
        let today = Date()
        var window: Set<String> = []
        for offset in -3...3 {
            if let day = calendar.date(byAdding: .day, value: offset, to: today) {
                let parts = calendar.dateComponents([.month, .day], from: day)
                window.insert(String(format: "%02d-%02d", parts.month ?? 0, parts.day ?? 0))
            }
        }
        let thisYear = calendar.component(.year, from: today)
        var days: [String: Set<Int64>] = [:]
        var visibleDays: [String: Set<Int64>] = [:]
        var yearCount: [String: Int] = [:]
        var yearCover: [String: Item] = [:]
        for item in all {
            let mine = !hideForeign || !isForeign(item, shots)
            if mine && item.date.count >= 4 {
                let year = String(item.date.prefix(4))
                yearCount[year, default: 0] += 1
                if let current = yearCover[year] {
                    if current.thumbAsset.isEmpty && !item.thumbAsset.isEmpty { yearCover[year] = item }
                } else {
                    yearCover[year] = item
                }
            }
            guard item.dateExact && item.date.count >= 10 && item.formats != "PNG" else { continue }
            let year = String(item.date.prefix(4))
            if Int(year) == thisYear { continue }
            if window.contains(String(item.date.dropFirst(5).prefix(5))) {
                days[year, default: []].insert(item.id)
                if mine { visibleDays[year, default: []].insert(item.id) }
            }
        }
        tags["day"] = days
        yearCards = yearCount.sorted { $0.key > $1.key }.map { year, count in
            Card(id: "year:" + year, title: year, subtitle: String(localized: "\(count) items"), scope: .year(year), cover: yearCover[year], icon: "calendar", count: count, date: year)
        }
        dayCards = visibleDays.sorted { $0.key > $1.key }.map { year, ids in
            let ago = thisYear - (Int(year) ?? thisYear)
            return Card(id: "day:" + year, title: String(localized: "\(ago) years ago") + " · " + year, subtitle: "\(ids.count)", scope: .tag("day", year), cover: cover(ids), icon: "clock.arrow.circlepath", count: ids.count, date: year)
        }
    }

    func members(of item: Item) -> [Member] { catalog?.members(of: item.key) ?? [] }

    func latest(_ item: Item) -> Item { idByKey[item.key].flatMap { byID[$0] } ?? item }

    func provenance(of item: Item) -> [(title: String, icon: String, scope: Scope)] {
        var out: [(title: String, icon: String, scope: Scope)] = []
        if let origin = Model.origins.first(where: { $0.code == item.origin }) {
            out.append((origin.label, origin.icon, .tag("origin", origin.code)))
        }
        if !item.camera.isEmpty { out.append((item.camera, "camera", .camera(item.camera))) }
        return out
    }

    var pageKeys: ((UInt16, NSEvent.ModifierFlags) -> Bool)?
    weak var page: PageState?

    func versions(of item: Item) -> [Member] {
        Versions.ordered(members(of: item), choice: catalog?.mainChoice(item.key), thumbPath: item.thumbPath)
    }

    func meta(_ member: Member) -> FileMeta? {
        member.source == "archive" ? catalog?.fileMeta(member.path) : nil
    }

    func setMain(_ item: Item, _ member: Member) {
        catalog?.setMain(item.key, member.path)
        Thumbs.shared.forget()
        reload()
    }

    func collections(of item: Item) -> [(title: String, icon: String, scope: Scope)] {
        var out: [(title: String, icon: String, scope: Scope)] = []
        for name in userTags(of: item) { out.append((name, "tag", .tag("user", name))) }
        out += people(of: item)
        out += provenance(of: item)
        let spec: [(String, String)] = [("trip", "airplane"), ("place", "mappin.and.ellipse"), ("country", "globe"), ("type", "photo.on.rectangle")]
        for (kind, icon) in spec {
            for (name, ids) in (tags[kind] ?? [:]).sorted(by: { $0.key < $1.key }) where ids.contains(item.id) {
                out.append((Model.tagTitle(kind, name), icon, .tag(kind, name)))
            }
        }
        for (name, ids) in albums.sorted(by: { $0.key < $1.key }) where ids.contains(item.id) {
            out.append((name, "rectangle.stack", .album(name)))
        }
        for kind in [Kind.raw, .edited, .video, .archiveOnly, .photosOnly, .both] where kind.matches(item) {
            out.append((kind.title, kind.icon, .kind(kind)))
        }
        return out
    }

    func toggleFlag(_ item: Item) {
        let on = !flagged.contains(item.key)
        if on { flagged.insert(item.key) } else { flagged.remove(item.key) }
        catalog?.setFlag(item.key, on)
        if scope == .flagged { apply() }
    }

    func step(_ delta: Int) {
        guard !flat.isEmpty else { return }
        let index = selected.flatMap { s in flat.firstIndex { $0.id == s.id } } ?? -1
        let next = flat[min(max(index + delta, 0), flat.count - 1)]
        selection = [next.id]
        selected = next
    }

    func apply() {
        Hidden.shared.follow(scope)
        guard isBrowsing else {
            sections = []
            flat = []
            shown = all.count
            hidden = 0
            return
        }
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        let albumSet: Set<Int64>? = {
            if case .album(let name) = scope { return albums[name] ?? [] }
            if case .tag(let kind, let name) = scope { return tags[kind]?[name] ?? [] }
            if case .custom = scope { return customIDs }
            return nil
        }()
        let typeSet: Set<Int64>? = typeFilter.isEmpty ? nil : (tags["type"]?[typeFilter] ?? [])
        let peopleFilter: PeopleFilter = tagsPending ? .any : self.peopleFilter
        let peopleSet: Set<Int64> = {
            switch peopleFilter {
            case .any: return []
            case .withMe, .withoutMe: return tags["person"]?[me] ?? []
            case .one(let kind, let name): return tags[kind]?[name] ?? []
            }
        }()
        let hiding = hideForeign && foreignScope && needle.isEmpty && originFilter.isEmpty
        let shots = hiding ? (tags["type"]?["screenshot"] ?? []) : []
        var hiddenCount = 0
        let filtered = Hidden.shared.source(all, scope).filter { item in
            switch scope {
            case .home, .all, .list, .folders, .map, .statistics, .hidden: break
            case .camera(let camera): if item.camera != camera { return false }
            case .calendar(let value): if !CalendarRoute.includes(item, value) { return false }
            case .loose(let root): if !(item.inArchive && item.root == root) { return false }
            case .flagged: if !flagged.contains(item.key) { return false }
            case .root(let root):
                if !item.inArchive { return false }
                if root == "/" { if !item.root.isEmpty { return false } }
                else if !(item.root == root || item.root.hasPrefix(root + "/")) { return false }
            case .album, .tag, .custom: if !(albumSet?.contains(item.id) ?? false) { return false }
            case .year(let year): if !item.date.hasPrefix(year) { return false }
            case .kind(let kind): if !kind.matches(item) { return false }
            }
            switch place {
            case .any: break
            case .archiveOnly: if !(item.inArchive && !item.inPhotos) { return false }
            case .photosOnly: if !(item.inPhotos && !item.inArchive) { return false }
            case .both: if !(item.inPhotos && item.inArchive) { return false }
            }
            if !rawFilter.matches(item.hasRaw) { return false }
            if !editFilter.matches(item.nEdit > 0) { return false }
            if !stackFilter.matches(item.nMembers > 1) { return false }
            if !labelFilter.matches(marks[item.key]?.color ?? "") { return false }
            switch media {
            case .any: break
            case .photo: if item.isVideo { return false }
            case .video: if !item.isVideo { return false }
            }
            if !formats.isEmpty && formats.isDisjoint(with: item.formats.split(separator: " ").map(String.init)) { return false }
            if !year.isEmpty && !item.date.hasPrefix(year) { return false }
            if let typeSet, !typeSet.contains(item.id) { return false }
            if !originFilter.isEmpty && item.origin != originFilter { return false }
            if !cameraFilter.isEmpty && item.camera != cameraFilter { return false }
            if !lensFilter.isEmpty && item.lens != lensFilter { return false }
            switch peopleFilter {
            case .any: break
            case .withMe, .one: if !peopleSet.contains(item.id) { return false }
            case .withoutMe: if peopleSet.contains(item.id) { return false }
            }
            switch geo {
            case .any: break
            case .yes: if !located.contains(item.id) { return false }
            case .no: if located.contains(item.id) { return false }
            }
            switch dated {
            case .any: break
            case .yes: if !item.dateExact { return false }
            case .no: if item.dateExact { return false }
            }
            switch phone {
            case .any: break
            case .yes: if !flagged.contains(item.key) { return false }
            case .no: if flagged.contains(item.key) { return false }
            }
            let mark = marks[item.key]
            if minRating > 0 && (mark?.rating ?? 0) < minRating { return false }
            if minRating < 0 && (mark?.rating ?? 0) > 0 { return false }
            switch pickFilter {
            case .any: break
            case .picked: if mark?.pick != 1 { return false }
            case .rejected: if mark?.pick != -1 { return false }
            case .hideRejected: if mark?.pick == -1 { return false }
            case .unmarked: if (mark?.pick ?? 0) != 0 { return false }
            }
            if !needle.isEmpty && !item.title.lowercased().contains(needle) && !item.root.lowercased().contains(needle) && !item.date.hasPrefix(needle) && !item.formats.lowercased().contains(needle) { return false }
            if hiding && isForeign(item, shots) {
                hiddenCount += 1
                return false
            }
            return true
        }
        hidden = hiddenCount
        var sorted = filtered
        switch sort {
        case .dateDesc: break
        case .dateAsc: sorted = Array(filtered.filter { !$0.date.isEmpty }.reversed()) + filtered.filter { $0.date.isEmpty }
        case .nameAsc: sorted.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .nameDesc: sorted.sort { $0.title.localizedStandardCompare($1.title) == .orderedDescending }
        case .sizeDesc: sorted.sort { $0.size > $1.size }
        case .sizeAsc: sorted.sort { $0.size < $1.size }
        case .versions: sorted.sort { $0.nMembers == $1.nMembers ? $0.date > $1.date : $0.nMembers > $1.nMembers }
        case .rating:
            sorted.sort {
                let a = marks[$0.key]?.rating ?? 0, b = marks[$1.key]?.rating ?? 0
                return a == b ? $0.date > $1.date : a > b
            }
        case .label:
            sorted.sort {
                let a = ColorLabel.rank(marks[$0.key]?.color), b = ColorLabel.rank(marks[$1.key]?.color)
                return a == b ? $0.date > $1.date : a < b
            }
        case .folder: sorted.sort { $0.root == $1.root ? $0.date > $1.date : $0.root.localizedStandardCompare($1.root) == .orderedAscending }
        }
        var out: [MonthSection] = []
        func group(_ key: (Item) -> String, _ title: (String) -> String) {
            var current: String?
            var bucket: [Item] = []
            for item in sorted {
                let k = key(item)
                if k != current {
                    if let current, !bucket.isEmpty { out.append(MonthSection(id: current, title: title(current), items: bucket)) }
                    current = k
                    bucket = []
                }
                bucket.append(item)
            }
            if let current, !bucket.isEmpty { out.append(MonthSection(id: current, title: title(current), items: bucket)) }
        }
        switch sort {
        case .dateDesc, .dateAsc: group({ $0.month }, { Months.label($0) })
        case .folder: group({ $0.root }, { $0.isEmpty ? String(localized: "No Folder in Archive") : $0 })
        case .label: group({ ColorLabel(rawValue: self.marks[$0.key]?.color ?? "")?.rawValue ?? "" }, ColorLabel.sectionTitle)
        default: if !sorted.isEmpty { out = [MonthSection(id: "all", title: sort.title, items: sorted)] }
        }
        sections = out
        flat = sorted
        shown = sorted.count
    }

    @Published var notice: Notice?
    @Published var exportConfirm: ExportAction?
    @Published var archiveTargets: [Item] = []

    var exportTargets: [Item] {
        let chosen = flat.filter { selection.contains($0.id) }
        return chosen.isEmpty ? flat : chosen
    }

    var archiveCandidates: [Item] { targets().filter { $0.needsArchive } }

    var phoneOnly: [Item] { all.filter { $0.needsArchive } }

    func askAddToArchive(_ items: [Item]) {
        let list = items.filter { $0.needsArchive }
        if !list.isEmpty { archiveTargets = list }
    }

    func exportPairs(_ items: [Item]) -> [ExportPair] {
        items.flatMap { item -> [ExportPair] in
            let stack = members(of: item)
            return stack.filter { $0.source == "archive" && $0.role == "export" }.map { copy in
                let uuid = String(copy.name.prefix(36)).uppercased()
                return ExportPair(item: item, copy: copy, original: stack.first { $0.source == "photos" && $0.path.uppercased().hasPrefix(uuid + "/") })
            }
        }
    }

    private static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    func exportPlan(_ action: ExportAction, _ pairs: [ExportPair]) -> String {
        let valid = pairs.filter { $0.original != nil }
        let copies = valid.reduce(Int64(0)) { $0 + $1.copy.size }
        var seen: Set<String> = []
        let originals = valid.compactMap { $0.original }.filter { seen.insert($0.path).inserted }
        let originalBytes = originals.reduce(Int64(0)) { $0 + $1.size }
        var folders: [String: Int] = [:]
        for pair in valid { folders[(pair.copy.path as NSString).deletingLastPathComponent, default: 0] += 1 }
        let top = folders.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key.isEmpty ? String(localized: "archive root") : $0.key) — \($0.value)" }.joined(separator: ", ")
        let skipped = pairs.count - valid.count
        var lines: [String] = []
        switch action {
        case .removeCopies:
            lines.append(String(localized: "To the Trash: \(valid.count) copies from the archive, \(Model.bytes(copies)). iCloud Drive files go to Recently Deleted in iCloud Drive, where they can be restored."))
            if !top.isEmpty { lines.append(String(localized: "Folders: \(top)\(folders.count > 4 ? String(localized: " and \(folders.count - 4) more") : "").")) }
            lines.append(String(localized: "Staying in Photos: \(originals.count) originals, \(Model.bytes(originalBytes))."))
        case .removeOriginals:
            let smaller = valid.filter { pair in
                guard let o = pair.original, o.width > 0, pair.copy.width > 0 else { return false }
                return pair.copy.width * pair.copy.height < o.width * o.height
            }
            lines.append(String(localized: "From Photos to Recently Deleted: \(originals.count) items, \(Model.bytes(originalBytes)). Photos will show its own confirmation window; for 30 days the items can be restored from Recently Deleted."))
            lines.append(top.isEmpty ? String(localized: "Staying in the archive: \(valid.count) copies, \(Model.bytes(copies)).")
                                     : String(localized: "Staying in the archive: \(valid.count) copies, \(Model.bytes(copies)) (\(top))."))
            if let example = smaller.first, let o = example.original {
                lines.append(String(localized: "Warning: copies smaller than the original: \(smaller.count) of \(valid.count), for example \(example.copy.width)×\(example.copy.height) instead of \(o.width)×\(o.height)."))
            }
        }
        if skipped > 0 { lines.append(String(localized: "Not in Photos and left untouched: \(skipped).")) }
        return lines.joined(separator: "\n\n")
    }

    func askExport(_ action: ExportAction) {
        let pairs = exportPairs(exportTargets)
        let smaller = pairs.contains { pair in
            guard let o = pair.original, o.width > 0, pair.copy.width > 0 else { return false }
            return pair.copy.width * pair.copy.height < o.width * o.height
        }
        if action == .removeOriginals ? smaller : RemovalPrefs.ask {
            exportConfirm = action
        } else {
            perform(action, pairs)
        }
    }

    func perform(_ action: ExportAction, _ pairs: [ExportPair]) {
        guard busyTool.isEmpty else { return }
        let valid = pairs.filter { $0.original != nil }
        guard !valid.isEmpty else { return }
        var seen: Set<Int64> = []
        let items = valid.map { $0.item }.filter { seen.insert($0.id).inserted }
        switch action {
        case .removeCopies:
            performRemoval(RemovalPlan(scope: .archive, items: items, archive: valid.map { ($0.item, $0.copy) }, photos: [],
                                       keptArchive: [], keptPhotos: valid.compactMap { $0.original }, vanishing: 0))
        case .removeOriginals:
            var paths: Set<String> = []
            let originals = valid.compactMap { pair in pair.original.map { (pair.item, $0) } }.filter { paths.insert($0.1.path).inserted }
            performRemoval(RemovalPlan(scope: .photos, items: items, archive: [], photos: originals,
                                       keptArchive: valid.map { $0.copy }, keptPhotos: [], vanishing: 0))
        }
    }

    func archiveSuggestions(_ items: [Item]) -> [ArchiveSuggestion] {
        let posix = DateFormatter()
        posix.locale = Locale(identifier: "en_US_POSIX")
        posix.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar(identifier: .gregorian)
        let dated = items.filter { $0.date.count >= 10 }
        let year = String((dated.first ?? items.first)?.date.prefix(4) ?? "")
        var window: Set<String> = []
        for item in dated {
            guard let day = posix.date(from: String(item.date.prefix(10))) else { continue }
            for offset in -1...1 {
                if let other = calendar.date(byAdding: .day, value: offset, to: day) { window.insert(posix.string(from: other)) }
            }
        }
        let ids = Set(items.map { $0.id })
        let trips: [(from: String, to: String, cities: [String])] = (tags["trip"] ?? [:]).filter { !$0.value.isDisjoint(with: ids) }.compactMap { name, _ in
            let parts = name.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            return parts.count == 3 ? (parts[0], parts[1], parts[2].components(separatedBy: " · ")) : nil
        }
        var near: [String: Int] = [:]
        var inTrip: [String: Int] = [:]
        for item in all where item.nOwnArchive > 0 && !item.root.isEmpty && item.date.count >= 10 {
            let day = String(item.date.prefix(10))
            if window.contains(day) { near[item.root, default: 0] += 1 }
            if trips.contains(where: { day >= $0.from && day <= $0.to }) { inTrip[item.root, default: 0] += 1 }
        }
        var out: [ArchiveSuggestion] = []
        func add(_ path: String, _ reason: String) {
            guard !path.isEmpty, !out.contains(where: { $0.path == path }) else { return }
            out.append(ArchiveSuggestion(path: path, reason: reason, exists: FileManager.default.fileExists(atPath: Catalog.archiveRoot.appendingPathComponent(path).path)))
        }
        let tripName = trips.first.map { $0.cities.prefix(3).joined(separator: " · ") }
        let event = near.sorted { a, b in
            let ta = inTrip[a.key] != nil, tb = inTrip[b.key] != nil
            return ta != tb ? ta : (a.value != b.value ? a.value > b.value : a.key < b.key)
        }
        for (root, n) in event.prefix(2) {
            if inTrip[root] != nil, let tripName {
                add(root, String(localized: "same trip (\(tripName)): \(n) items here shot on these days"))
            } else {
                add(root, String(localized: "\(n) archive items here shot on these days (±1 day)"))
            }
        }
        func fold(_ text: String) -> String {
            (text.applyingTransform(.toLatin, reverse: false) ?? text).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter { $0.isLetter }
        }
        var cities: [String] = trips.flatMap { $0.cities }
        for (name, members) in tags["place"] ?? [:] where !members.isDisjoint(with: ids) && !cities.contains(name) { cities.insert(name, at: 0) }
        let folded = cities.map { (name: $0, key: String(fold($0).prefix(4))) }.filter { $0.key.count == 4 }
        let ranges = trips.map { ($0.from, $0.to) } + window.map { ($0, $0) }
        var byPlace: [(path: String, reason: String, score: Int)] = []
        for (path, node) in nodeIndex where path != "/" {
            let name = node.name
            var reasons: [String] = []
            if let city = folded.first(where: { fold(name).contains($0.key) }) { reasons.append(String(localized: "the name contains the city \(city.name)")) }
            let day = String(name.prefix(10))
            if name.count >= 10, posix.date(from: day) != nil, ranges.contains(where: { day >= $0.0 && day <= $0.1 }) {
                reasons.append(trips.isEmpty ? String(localized: "the date in the name is the shooting day") : String(localized: "the date in the name falls within the trip"))
            }
            if !reasons.isEmpty { byPlace.append((path, reasons.joined(separator: ", "), reasons.count * 100_000 + node.count)) }
        }
        for place in byPlace.sorted(by: { $0.score > $1.score }).prefix(2) { add(place.path, place.reason) }
        if !year.isEmpty, !me.isEmpty, !Catalog.meFolder.isEmpty, !(tags["person"]?[me] ?? []).isDisjoint(with: ids) {
            add("\(Catalog.meFolder)/\(year)", String(localized: "you are in the photo (\(me))"))
        }
        if !year.isEmpty { add(year, String(localized: "year folder")) }
        return Array(out.prefix(4))
    }

    func addToArchive(_ items: [Item], folder: String, completion: @escaping (String?) -> Void) {
        guard busyTool.isEmpty else {
            completion(String(localized: "Wait until “\(busyTool)” finishes."))
            return
        }
        let jobs = items.filter { $0.needsArchive }.compactMap { item -> (key: String, asset: String)? in
            guard let asset = versions(of: item).first(where: { $0.source == "photos" }) else { return nil }
            return (item.key, asset.path)
        }
        guard !jobs.isEmpty else {
            completion(String(localized: "None of the selected items are only in Photos."))
            return
        }
        let target = folder.isEmpty ? Catalog.archiveRoot : Catalog.archiveRoot.appendingPathComponent(folder)
        busyTool = String(localized: "Adding to the archive…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ArchiveExport.run(jobs.map { $0.asset }, to: target) { done in
                DispatchQueue.main.async { self.busyTool = String(localized: "Adding to the archive… \(done) of \(jobs.count)") }
            }
            DispatchQueue.main.async {
                self.busyTool = ""
                var text = String(localized: "Files added to “\(folder.isEmpty ? String(localized: "archive root") : folder)”: \(result.written.count).")
                if !result.failures.isEmpty { text += "\n\n" + String(localized: "Failed: \(result.failures.count).") + " " + result.failures.prefix(3).joined(separator: "\n") }
                guard !result.written.isEmpty else {
                    completion(text)
                    return
                }
                completion(nil)
                self.runTool(["rebuild"], label: String(localized: "Refreshing catalog…")) {
                    if let fresh = Catalog() {
                        for job in jobs { if let key = fresh.key(ofAsset: job.asset) { fresh.moveKey(job.key, to: key) } }
                    }
                    self.reload()
                    self.notice = Notice(title: result.failures.isEmpty ? String(localized: "Added to the Archive") : String(localized: "Not Everything Was Added"), text: text)
                }
            }
        }
    }

    func revealInFinder(_ member: Member) {
        NSWorkspace.shared.activateFileViewerSelecting([Catalog.archiveRoot.appendingPathComponent(member.path)])
    }

    func open(_ member: Member) {
        NSWorkspace.shared.open(Catalog.archiveRoot.appendingPathComponent(member.path))
    }

    func showInPhotos(_ member: Member) {
        let source = "tell application \"Photos\"\nactivate\nspotlight media item id \"\(member.path)\"\nend tell"
        DispatchQueue.global().async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }
}

extension Model {
    func tagSets(_ kind: String) -> [String: Set<Int64>] { tags[kind] ?? [:] }

    private func rebuildUserTagCards() {
        userTagCards = (tags["user"] ?? [:]).sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }.map { name, ids in
            Card(id: "user:" + name, title: name, subtitle: "\(ids.count)", scope: .tag("user", name), cover: cover(ids), icon: "tag", count: ids.count)
        }
    }

    func setTag(_ kind: String, _ name: String, on: Bool, items: [Item]) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let keys = items.map { $0.key }
        guard !name.isEmpty, !keys.isEmpty else { return }
        let ids = Set(keys.compactMap { idByKey[$0] })
        var members = tags[kind]?[name] ?? []
        if on { members.formUnion(ids) } else { members.subtract(ids) }
        tags[kind, default: [:]][name] = members.isEmpty ? nil : members
        Hidden.shared.retag(kind, name, items, on: on)
        if kind == "user" {
            catalog?.setUserTag(name, keys: keys, on: on)
            rebuildUserTagCards()
        } else {
            catalog?.setTagOverride(kind, name, keys: keys, on: on)
            rebuildPeopleCards()
        }
        if let page, let item = page.item { page.collections = collections(of: item) }
        var affected = peopleFilter != .any && kind != "user"
        if case .tag(let shown, _) = scope, shown == kind { affected = true }
        if affected { apply() }
    }
}
