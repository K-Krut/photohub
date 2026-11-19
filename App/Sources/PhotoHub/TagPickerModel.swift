import AppKit
import SwiftUI
import Vision

struct TagRef: Hashable, Identifiable {
    let kind: String
    let name: String

    var id: String { kind + "\u{1F}" + name }

    var icon: String {
        switch kind {
        case "person": return "person.crop.circle"
        case "pet": return "pawprint"
        default: return "tag"
        }
    }
}

enum TagChoice: Hashable, Identifiable {
    case tag(TagRef)
    case create(TagRef)

    var id: String {
        switch self {
        case .tag(let ref): return "t\u{1F}" + ref.id
        case .create(let ref): return "c\u{1F}" + ref.id
        }
    }

    var ref: TagRef {
        switch self {
        case .tag(let ref), .create(let ref): return ref
        }
    }
}

struct TagSection: Identifiable {
    let id: String
    let title: String
    let choices: [TagChoice]
    let total: Int

    var grid: Bool { id == "person" || id == "pet" }
}

enum TagCoverage {
    case none, some, all
}

enum TagMatch {
    private static let cyrillic: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k",
        "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u", "ф": "f", "х": "kh", "ц": "ts",
        "ч": "ch", "ш": "sh", "щ": "shch", "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya", "і": "i", "ї": "yi", "є": "ye", "ґ": "g"]
    private static let layout: [Character: Character] = {
        let en = Array("qwertyuiop[]asdfghjkl;'zxcvbnm,.`"), ru = Array("йцукенгшщзхъфывапролджэячсмитьбюё")
        var map: [Character: Character] = [:]
        for (a, b) in zip(en, ru) {
            map[a] = b
            map[b] = a
        }
        return map
    }()

    static func fold(_ text: String) -> String {
        text.lowercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func latin(_ text: String) -> String {
        fold(text.lowercased().map { cyrillic[$0] ?? String($0) }.joined())
    }

    static func swapped(_ text: String) -> String {
        String(text.lowercased().map { layout[$0] ?? $0 })
    }

    static func words(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func same(_ a: String, _ b: String) -> Bool { fold(a) == fold(b) }

    static func score(_ name: String, _ query: String) -> Int? {
        let needle = fold(query)
        guard !needle.isEmpty else { return 0 }
        var best: Int?
        func consider(_ haystack: String, _ needle: String, _ penalty: Int) {
            guard !needle.isEmpty, let value = raw(haystack, needle) else { return }
            best = max(best ?? Int.min, value - penalty)
        }
        consider(fold(name), needle, 0)
        consider(latin(name), latin(query), 30)
        let other = swapped(query)
        if fold(other) != needle { consider(fold(name), fold(other), 60) }
        return best
    }

    private static func raw(_ name: String, _ needle: String) -> Int? {
        if name == needle { return 1000 }
        if name.hasPrefix(needle) { return 800 }
        let parts = words(name), tokens = words(needle)
        if !tokens.isEmpty, tokens.allSatisfy({ token in parts.contains { $0.hasPrefix(token) } }) { return 600 }
        if name.contains(needle) { return 400 }
        if needle.count >= 2, sparse(needle, parts) { return 200 }
        return nil
    }

    private static func sparse(_ needle: String, _ parts: [String]) -> Bool {
        let wanted = Array(needle.filter { $0.isLetter || $0.isNumber })
        guard let first = wanted.first else { return false }
        for index in parts.indices where parts[index].first == first {
            var rest = wanted.dropFirst()[...]
            for character in parts[index...].joined().dropFirst() where character == rest.first {
                rest = rest.dropFirst()
                if rest.isEmpty { break }
            }
            if rest.isEmpty { return true }
        }
        return false
    }
}

enum TagRecents {
    private static let key = "tagPickerRecent"

    static func list() -> [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func touch(_ ref: TagRef) {
        var list = list().filter { $0 != ref.id }
        list.insert(ref.id, at: 0)
        UserDefaults.standard.set(Array(list.prefix(60)), forKey: key)
    }
}

struct TagChange {
    let ref: TagRef
    let on: [Item]
    let off: [Item]
}

@MainActor
final class TagPickerState: ObservableObject {
    static var snapshotQuery: String?
    static weak var active: TagPickerState?
    static let columns = 7
    static let kinds: [(kind: String, title: String)] = [("person", String(localized: "People")), ("pet", String(localized: "Pets")), ("user", String(localized: "My Tags"))]

    let model: Model
    let items: [Item]
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            navigating = false
            highlight = TagMatch.fold(query).isEmpty ? nil : best
        }
    }
    @Published var highlight: TagChoice?
    @Published var navigating = false
    @Published var expanded: Set<String> = []
    @Published private(set) var history: [TagChange] = []
    private let recents: [String: Int]

    init(model: Model, items: [Item]) {
        self.model = model
        self.items = items
        recents = Dictionary(TagRecents.list().enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var current: [Item] { items.map { model.latest($0) } }

    private var ids: [Int64] { current.map { $0.id } }

    func coverage(_ ref: TagRef) -> TagCoverage {
        guard let set = model.pickerSets(ref.kind)[ref.name] else { return .none }
        let count = ids.filter { set.contains($0) }.count
        return count == 0 ? .none : count == items.count ? .all : .some
    }

    func count(_ ref: TagRef) -> Int {
        guard let set = model.pickerSets(ref.kind)[ref.name] else { return 0 }
        return ids.filter { set.contains($0) }.count
    }

    func usage(_ ref: TagRef) -> Int { model.tagSets(ref.kind)[ref.name]?.count ?? 0 }

    var applied: [TagRef] {
        let list = ids
        return TagPickerState.kinds.flatMap { entry in
            model.pickerSets(entry.kind).filter { _, set in list.contains { set.contains($0) } }.keys
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { TagRef(kind: entry.kind, name: $0) }
        }
    }

    private var strongest: Int {
        let needle = query
        return TagPickerState.kinds.flatMap { entry in model.tagSets(entry.kind).keys.compactMap { TagMatch.score($0, needle) } }.max() ?? Int.min
    }

    var sections: [TagSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [TagSection] = []
        for entry in TagPickerState.kinds {
            let sets = model.tagSets(entry.kind)
            let scored: [(ref: TagRef, score: Int, recent: Int, count: Int)] = sets.compactMap { name, set in
                guard let score = TagMatch.score(name, needle) else { return nil }
                let ref = TagRef(kind: entry.kind, name: name)
                return (ref, score, recents[ref.id] ?? Int.max, set.count)
            }
            let sorted = scored.sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                if a.recent != b.recent { return a.recent < b.recent }
                if a.count != b.count { return a.count > b.count }
                return a.ref.name.localizedStandardCompare(b.ref.name) == .orderedAscending
            }
            let grid = entry.kind != "user"
            let limit = expanded.contains(entry.kind) ? Int.max : needle.isEmpty ? (grid ? TagPickerState.columns * 2 : 24) : (grid ? TagPickerState.columns * 4 : 40)
            out.append(TagSection(id: entry.kind, title: entry.title, choices: sorted.prefix(limit).map { .tag($0.ref) }, total: sorted.count))
        }
        if !needle.isEmpty {
            let create = ["user", "person", "pet"].compactMap { kind -> TagChoice? in
                model.tagSets(kind).keys.contains { TagMatch.same($0, needle) } ? nil : .create(TagRef(kind: kind, name: needle))
            }
            if !create.isEmpty {
                let section = TagSection(id: "create", title: String(localized: "Create"), choices: create, total: create.count)
                if strongest < 400 { out.insert(section, at: 0) } else { out.append(section) }
            }
        }
        return out.filter { !$0.choices.isEmpty }
    }

    var best: TagChoice? {
        let list = sections
        if let first = list.first, first.id == "create" { return first.choices.first }
        let needle = query
        let existing = list.filter { $0.id != "create" }.flatMap { $0.choices }
        let scored = existing.map { ($0, TagMatch.score($0.ref.name, needle) ?? Int.min) }
        let open = scored.filter { $0.1 >= 400 && coverage($0.0.ref) != .all }
        let pool = open.isEmpty ? scored : open
        guard let top = pool.map({ $0.1 }).max() else { return nil }
        return pool.first { $0.1 == top }?.0
    }

    func toggle(_ choice: TagChoice) {
        switch choice {
        case .tag(let ref): set(ref, on: coverage(ref) != .all)
        case .create(let ref): set(ref, on: true)
        }
        if !query.isEmpty { query = "" }
    }

    func set(_ ref: TagRef, on: Bool) {
        let fresh = current
        let members = model.pickerSets(ref.kind)[ref.name] ?? []
        let had = fresh.filter { members.contains($0.id) }, lacked = fresh.filter { !members.contains($0.id) }
        guard on ? !lacked.isEmpty : !had.isEmpty else { return }
        history.append(TagChange(ref: ref, on: had, off: lacked))
        model.setTag(ref.kind, ref.name, on: on, items: fresh)
        if on { TagRecents.touch(ref) }
    }

    func undo() {
        guard let change = history.popLast() else { return }
        if !change.on.isEmpty { model.setTag(change.ref.kind, change.ref.name, on: true, items: change.on) }
        if !change.off.isEmpty { model.setTag(change.ref.kind, change.ref.name, on: false, items: change.off) }
    }

    func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        let flags = modifiers.intersection([.command, .option, .control, .shift])
        switch code {
        case 53:
            close()
        case 36, 76:
            if flags.contains(.command) {
                close()
            } else if let choice = highlight {
                toggle(choice)
            } else if !TagMatch.fold(query).isEmpty, let choice = best {
                toggle(choice)
            } else {
                close()
            }
        case 125, 126:
            guard flags.isEmpty else { return false }
            navigating = true
            move(code)
        case 123, 124:
            guard flags.isEmpty, navigating else { return false }
            move(code)
        case 48:
            navigating = true
            move(flags.contains(.shift) ? 123 : 124)
        case 6:
            guard flags == .command, !history.isEmpty else { return false }
            undo()
        default:
            return false
        }
        return true
    }

    func close() {
        ShotActions.shared.tagging = []
    }

    static func snapshot(_ name: String, _ value: String) {
        switch name {
        case "tagquery": snapshotQuery = value
        case "tagkeys":
            let codes = value.split(separator: ",").compactMap { UInt16($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                for code in codes { _ = active?.key(code, code == 6 ? .command : []) }
            }
        default: break
        }
    }

    func move(_ key: UInt16) {
        let list = sections
        guard !list.isEmpty else { return }
        guard let highlight, let s = list.firstIndex(where: { $0.choices.contains(highlight) }),
              let i = list[s].choices.firstIndex(of: highlight) else {
            self.highlight = list.first?.choices.first
            return
        }
        let section = list[s], columns = section.grid ? TagPickerState.columns : 1
        var target: (Int, Int) = (s, i)
        switch key {
        case 123: target = i > 0 ? (s, i - 1) : s > 0 ? (s - 1, list[s - 1].choices.count - 1) : (s, i)
        case 124: target = i + 1 < section.choices.count ? (s, i + 1) : s + 1 < list.count ? (s + 1, 0) : (s, i)
        case 125:
            if i + columns < section.choices.count {
                target = (s, i + columns)
            } else if section.grid && (i / columns) < (section.choices.count - 1) / columns {
                target = (s, section.choices.count - 1)
            } else if s + 1 < list.count {
                let next = list[s + 1]
                target = (s + 1, next.grid ? min(i % columns, next.choices.count - 1) : 0)
            }
        case 126:
            if i - columns >= 0 {
                target = (s, i - columns)
            } else if s > 0 {
                let previous = list[s - 1]
                if previous.grid {
                    let lastRow = (previous.choices.count - 1) / TagPickerState.columns * TagPickerState.columns
                    target = (s - 1, min(lastRow + i % columns, previous.choices.count - 1))
                } else {
                    target = (s - 1, previous.choices.count - 1)
                }
            }
        default: break
        }
        self.highlight = list[target.0].choices[target.1]
    }
}

@MainActor
final class TagAvatars {
    static let shared = TagAvatars()
    private var cache: [TagRef: NSImage] = [:]
    private var waiting: [TagRef: [(NSImage?) -> Void]] = [:]

    private final class Once { var done = false }

    func image(_ ref: TagRef, model: Model, completion: @escaping (NSImage?) -> Void) {
        if let hit = cache[ref] {
            completion(hit)
            return
        }
        if waiting[ref] != nil {
            waiting[ref]?.append(completion)
            return
        }
        waiting[ref] = [completion]
        let list = candidates(ref, model: model)
        attempt(list.solo.prefix(4), list.all.first, ref) { [weak self] image in
            guard let self else { return }
            if let image { self.cache[ref] = image }
            let callbacks = self.waiting.removeValue(forKey: ref) ?? []
            callbacks.forEach { $0(image) }
        }
    }

    private func candidates(_ ref: TagRef, model: Model) -> (solo: [Item], all: [Item]) {
        let sets = model.tagSets(ref.kind)
        guard let ids = sets[ref.name] else { return ([], []) }
        let others = sets.filter { $0.key != ref.name }.map { $0.value }
        let items = ids.compactMap { model.byID[$0] }.filter { !$0.thumbAsset.isEmpty || !$0.thumbPath.isEmpty || !$0.mainPath.isEmpty || !$0.mainAsset.isEmpty }
        let sorted = items.sorted { a, b in
            let ra = model.marks[a.key]?.rating ?? 0, rb = model.marks[b.key]?.rating ?? 0
            if ra != rb { return ra > rb }
            if a.isVideo != b.isVideo { return !a.isVideo }
            if a.date != b.date { return a.date > b.date }
            return a.key < b.key
        }
        return (sorted.filter { item in !others.contains { $0.contains(item.id) } }, sorted)
    }

    private func attempt(_ list: ArraySlice<Item>, _ fallback: Item?, _ ref: TagRef, _ done: @escaping (NSImage?) -> Void) {
        guard let item = list.first else {
            guard let fallback else { return done(nil) }
            let once = Once()
            Thumbs.shared.image(for: fallback, side: 240) { image in
                guard !once.done else { return }
                once.done = true
                done(image)
            }
            return
        }
        let once = Once()
        Thumbs.shared.image(for: item, side: 320) { [weak self] image in
            guard !once.done else { return }
            once.done = true
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                self?.attempt(list.dropFirst(), fallback, ref, done)
                return
            }
            let animal = ref.kind == "pet"
            DispatchQueue.global(qos: .userInitiated).async {
                let crop = TagAvatars.crop(cg, animal: animal)
                DispatchQueue.main.async {
                    if let crop { done(NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height))) } else { self?.attempt(list.dropFirst(), fallback, ref, done) }
                }
            }
        }
    }

    nonisolated static func crop(_ image: CGImage, animal: Bool) -> CGImage? {
        let request: VNImageBasedRequest = animal ? VNRecognizeAnimalsRequest() : VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let boxes = ((request.results as? [VNDetectedObjectObservation]) ?? []).map { $0.boundingBox }
            .sorted { $0.width * $0.height > $1.width * $1.height }
        guard let box = boxes.first else { return nil }
        if boxes.count > 1, box.width * box.height < 2.5 * boxes[1].width * boxes[1].height { return nil }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let w = box.width * width, h = box.height * height
        guard max(w, h) >= 20 else { return nil }
        let side = min(max(w, h) * (animal ? 1.15 : 1.9), width, height)
        let x = box.midX * width, y = (1 - box.midY) * height - (animal ? 0 : h * 0.08)
        let rect = CGRect(x: min(max(0, x - side / 2), width - side), y: min(max(0, y - side / 2), height - side), width: side, height: side)
        return image.cropping(to: rect.integral)
    }
}
