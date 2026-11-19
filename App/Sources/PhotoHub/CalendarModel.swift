import AppKit
import CryptoKit
import SwiftUI

enum CalendarLevel: String, CaseIterable, Identifiable {
    case day, week, month, year
    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return String(localized: "Day", table: "Calendar")
        case .week: return String(localized: "Week", table: "Calendar")
        case .month: return String(localized: "Month", table: "Calendar")
        case .year: return String(localized: "Year", table: "Calendar")
        }
    }
}

enum CalendarRoute {
    static func day(_ value: String) -> String? {
        value.hasPrefix("day:") ? String(value.dropFirst(4)) : nil
    }

    static func includes(_ item: Item, _ value: String) -> Bool {
        guard value.hasPrefix("day:") else { return true }
        return item.dateExact && item.date.utf8.starts(with: value.utf8.dropFirst(4))
    }

    static func title(_ value: String) -> String {
        if let day = day(value), let date = CalendarDate.date(day) { return CalendarText.long(date) }
        return String(localized: "Calendar", table: "Calendar")
    }
}

enum CalendarDate {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = Calendar.current.firstWeekday
        calendar.minimumDaysInFirstWeek = Calendar.current.minimumDaysInFirstWeek
        calendar.timeZone = .current
        return calendar
    }()

    static func parts(_ key: String) -> (Int, Int, Int)? {
        let numbers = key.split(separator: "-").compactMap { Int($0) }
        guard numbers.count >= 2 else { return nil }
        return (numbers[0], numbers[1], numbers.count > 2 ? numbers[2] : 1)
    }

    static func date(_ key: String) -> Date? {
        guard let (y, m, d) = parts(key) else { return nil }
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))
    }

    static func key(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 1, c.day ?? 1)
    }

    static func month(_ y: Int, _ m: Int) -> String { String(format: "%04d-%02d", y, m) }

    static var today: String { key(Date()) }

    static func adding(days: Int, to key: String) -> String {
        guard let date = date(key), let next = calendar.date(byAdding: .day, value: days, to: date) else { return key }
        return self.key(next)
    }

    static func adding(months: Int, to month: String) -> String {
        guard let (y, m, _) = parts(month) else { return month }
        let index = y * 12 + (m - 1) + months
        return self.month(index / 12, index % 12 + 1)
    }

    static func daysIn(_ month: String) -> Int {
        guard let date = date(month), let range = calendar.range(of: .day, in: .month, for: date) else { return 30 }
        return range.count
    }

    static func leading(_ month: String) -> Int {
        guard let date = date(String(month.prefix(7)) + "-01") else { return 0 }
        return (calendar.component(.weekday, from: date) - calendar.firstWeekday + 7) % 7
    }

    static func weekStart(_ key: String) -> String {
        guard let date = date(key) else { return key }
        let offset = (calendar.component(.weekday, from: date) - calendar.firstWeekday + 7) % 7
        return adding(days: -offset, to: key)
    }

    static func week(_ key: String) -> [String] {
        let start = weekStart(key)
        return (0..<7).map { adding(days: $0, to: start) }
    }

    static func dayNumber(_ key: String) -> Int { Int(key.suffix(2)) ?? 0 }
}

enum CalendarText {
    static let language = Bundle.main.preferredLocalizations.first ?? "en"
    static let locale: Locale = {
        if let region = Locale.current.region?.identifier { return Locale(identifier: language + "_" + region) }
        return Locale(identifier: language)
    }()

    private static func formatter(_ setup: (DateFormatter) -> Void) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = CalendarDate.calendar
        formatter.timeZone = CalendarDate.calendar.timeZone
        setup(formatter)
        return formatter
    }

    private static let symbols = formatter { _ in }
    private static let longFormatter = formatter { $0.dateStyle = .long }
    private static let fullFormatter = formatter { $0.dateStyle = .full }
    private static let interval: DateIntervalFormatter = {
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.calendar = CalendarDate.calendar
        formatter.timeZone = CalendarDate.calendar.timeZone
        formatter.dateTemplate = "dMMMy"
        return formatter
    }()

    static let months: [String] = (symbols.standaloneMonthSymbols ?? []).map { $0.capitalized(with: locale) }
    static let shortMonths: [String] = (symbols.shortStandaloneMonthSymbols ?? []).map { $0.capitalized(with: locale) }

    private static func ordered(_ list: [String]?) -> [String] {
        guard let list, list.count == 7 else { return [] }
        let first = CalendarDate.calendar.firstWeekday - 1
        return (0..<7).map { list[(first + $0) % 7].capitalized(with: locale) }
    }

    static let weekdays = ordered(symbols.shortStandaloneWeekdaySymbols)
    static let tinyWeekdays = ordered(symbols.veryShortStandaloneWeekdaySymbols)

    static func monthName(_ month: String) -> String {
        guard let (_, m, _) = CalendarDate.parts(month), months.indices.contains(m - 1) else { return month }
        return months[m - 1]
    }

    static func monthTitle(_ month: String) -> String {
        guard let (y, _, _) = CalendarDate.parts(month) else { return month }
        return monthName(month) + " " + String(y)
    }

    static func long(_ date: Date) -> String { longFormatter.string(from: date) }

    static func full(_ key: String) -> String {
        guard let date = CalendarDate.date(key) else { return key }
        let text = fullFormatter.string(from: date)
        return text.prefix(1).uppercased(with: locale) + text.dropFirst()
    }

    static func weekday(_ key: String) -> String {
        guard let date = CalendarDate.date(key) else { return "" }
        let index = CalendarDate.calendar.component(.weekday, from: date) - 1
        return (symbols.shortStandaloneWeekdaySymbols ?? [])[safe: index]?.capitalized(with: locale) ?? ""
    }

    static func week(_ start: String) -> String {
        guard let from = CalendarDate.date(start), let to = CalendarDate.date(CalendarDate.adding(days: 6, to: start)) else { return start }
        return interval.string(from: from, to: to)
    }

    static func shots(_ count: Int) -> String { String(localized: "\(count) shots", table: "Calendar") }

    static func tooltip(_ day: CalendarDay) -> String {
        let place = day.place.isEmpty ? day.trip : day.place
        return place.isEmpty ? shots(day.items.count) : String(localized: "\(day.items.count) shots · \(place)", table: "Calendar")
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

struct CalendarDay {
    let key: String
    let items: [Item]
    let cover: Item
    let place: String
    let trip: String
}

struct CalendarTrip: Identifiable {
    let id: String
    let from: String
    let to: String
    let title: String
    let tint: Int
}

enum MonthRow: Identifiable {
    case month(String)
    case gap(String, String)

    var id: String {
        switch self {
        case .month(let month): return month
        case .gap(let from, _): return "gap:" + from
        }
    }

    func covers(_ month: String) -> Bool {
        switch self {
        case .month(let m): return m == month
        case .gap(let from, let to): return month >= from && month <= to
        }
    }
}

struct CalendarIndex {
    var days: [String: CalendarDay] = [:]
    var ordered: [String] = []
    var months: [String: Int] = [:]
    var years: [String: Int] = [:]
    var loose: [String: [Int64]] = [:]
    var trips: [CalendarTrip] = []
    var rows: [MonthRow] = []
    var busiest = 1

    func firstDay(in prefix: String) -> String? {
        let start = ordered.partitionIndex { $0 < prefix }
        guard start < ordered.count, ordered[start].hasPrefix(prefix) else { return nil }
        return ordered[start]
    }

    func lastDay(in prefix: String) -> String? {
        let end = ordered.partitionIndex { $0 <= prefix + "~" }
        guard end > 0, ordered[end - 1].hasPrefix(prefix) else { return nil }
        return ordered[end - 1]
    }

    func neighbor(of key: String, _ delta: Int) -> String? {
        if delta > 0 {
            let index = ordered.partitionIndex { $0 <= key }
            return index < ordered.count ? ordered[index] : nil
        }
        let index = ordered.partitionIndex { $0 < key }
        return index > 0 ? ordered[index - 1] : nil
    }

    static func build(_ items: [Item], marks: [String: Mark], tags: [String: [String: Set<Int64>]], photos: Bool) -> CalendarIndex {
        var index = CalendarIndex()
        var buckets: [String: [Item]] = [:]
        var present: Set<Int64> = []
        present.reserveCapacity(items.count)
        for item in items {
            present.insert(item.id)
            if item.dateExact && item.date.count >= 10 {
                buckets[String(item.date.prefix(10)), default: []].append(item)
            } else if item.date.count >= 4 {
                index.loose[String(item.date.prefix(4)), default: []].append(item.id)
            }
        }
        var placeOf: [Int64: [String]] = [:]
        for (name, ids) in tags["place"] ?? [:] {
            for id in ids where present.contains(id) { placeOf[id, default: []].append(name) }
        }
        index.trips = (tags["trip"] ?? [:]).compactMap { name, ids -> CalendarTrip? in
            let parts = name.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, parts[0].count == 10, parts[1].count == 10, !ids.isDisjoint(with: present) else { return nil }
            let tint = parts[2].unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
            return CalendarTrip(id: name, from: parts[0], to: parts[1], title: parts[2], tint: tint)
        }.sorted { $0.from < $1.from }
        let favorites = tags["type"]?["favorite"] ?? []
        let previews = CalendarPreviews(photos: photos)
        for (key, list) in buckets {
            let timeline = list.sorted { $0.date == $1.date ? $0.key < $1.key : $0.date < $1.date }
            let cover = pickCover(timeline, marks: marks, favorites: favorites, previews: previews)
            var places: [String: Int] = [:]
            for item in timeline { for name in placeOf[item.id] ?? [] { places[name, default: 0] += 1 } }
            let place = places.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key ?? ""
            let trip = index.trips.first { key >= $0.from && key <= $0.to }?.title ?? ""
            index.days[key] = CalendarDay(key: key, items: timeline, cover: cover, place: place, trip: trip)
            index.months[String(key.prefix(7)), default: 0] += list.count
            index.years[String(key.prefix(4)), default: 0] += list.count
            index.busiest = max(index.busiest, list.count)
        }
        index.ordered = index.days.keys.sorted()
        index.rows = rows(index)
        return index
    }

    private static func rows(_ index: CalendarIndex) -> [MonthRow] {
        let today = String(CalendarDate.today.prefix(7))
        guard let first = index.ordered.first.map({ String($0.prefix(7)) }) else { return [.month(today)] }
        let last = max(String(index.ordered.last!.prefix(7)), today)
        var rows: [MonthRow] = []
        var empty: [String] = []
        func flush() {
            if empty.count >= 3 {
                rows.append(.gap(empty.first!, empty.last!))
            } else {
                rows += empty.map { .month($0) }
            }
            empty = []
        }
        var month = first
        while month <= last {
            if index.months[month] != nil || month == today {
                flush()
                rows.append(.month(month))
            } else {
                empty.append(month)
            }
            month = CalendarDate.adding(months: 1, to: month)
        }
        flush()
        return rows
    }

    static func pickCover(_ timeline: [Item], marks: [String: Mark], favorites: Set<Int64>, previews: CalendarPreviews) -> Item {
        func score(_ item: Item) -> Int {
            let mark = marks[item.key]
            let pick: Int = mark?.pick ?? 0
            let rating: Int = min(max(mark?.rating ?? 0, 0), 15)
            var score: Int = pick == -1 ? 0 : 1_000_000
            if favorites.contains(item.id) { score += 100_000 }
            score += rating * 1_000
            if pick == 1 { score += 100 }
            if item.nEdit > 0 { score += 10 }
            return score
        }
        let scores: [Int] = timeline.map(score)
        let ranked: [Int] = timeline.indices.sorted { (a: Int, b: Int) -> Bool in
            scores[a] == scores[b] ? a < b : scores[a] > scores[b]
        }
        for position in ranked.prefix(6) where previews.available(timeline[position]) { return timeline[position] }
        return timeline[ranked[0]]
    }
}

struct CalendarPreviews {
    let photos: Bool
    private let names: Set<String>

    init(photos: Bool) {
        self.photos = photos
        var names: Set<String> = []
        for folder in [Thumbs.cacheDir, Thumbs.previewDir] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] { names.insert(name) }
        }
        self.names = names
    }

    func available(_ item: Item) -> Bool {
        if photos && (!item.mainAsset.isEmpty || !item.thumbAsset.isEmpty) { return true }
        for path in [item.mainPath, item.thumbPath] where !path.isEmpty {
            if names.contains(CalendarPreviews.name(path)) { return true }
        }
        return false
    }

    private static let digits = Array("0123456789abcdef".utf8)

    static func name(_ path: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(44)
        for byte in Insecure.SHA1.hash(data: Data(path.utf8)) {
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 0x0F)])
        }
        bytes += Array(".jpg".utf8)
        return String(decoding: bytes, as: UTF8.self)
    }
}

extension Array {
    func partitionIndex(_ belongsBefore: (Element) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if belongsBefore(self[mid]) { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

final class CalendarThumbs {
    static let shared = CalendarThumbs()
    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "photohub.calendar.thumbs", qos: .userInitiated, attributes: .concurrent)

    init() { cache.countLimit = 2000 }

    func cached(_ item: Item, pixels: Int, epoch: Int) -> NSImage? {
        cache.object(forKey: key(item, pixels, epoch))
    }

    private func key(_ item: Item, _ pixels: Int, _ epoch: Int) -> NSString {
        "\(item.key)|\(item.mainAsset)|\(item.mainPath)|\(pixels)|\(epoch)" as NSString
    }

    func image(for item: Item, pixels: Int, epoch: Int, completion: @escaping (NSImage?) -> Void) {
        let cacheKey = key(item, pixels, epoch)
        if let hit = cache.object(forKey: cacheKey) {
            completion(hit)
            return
        }
        let side = CGFloat(pixels) / 2
        if !AppPaths.noPhotos && !item.mainAsset.isEmpty {
            Thumbs.shared.image(for: item, side: side, completion: completion)
            return
        }
        let paths = [item.mainPath, item.thumbPath].filter { !$0.isEmpty }
        queue.async { [weak self] in
            for path in paths {
                for url in [Thumbs.cachedFile(path), Thumbs.previewFile(path)] where FileManager.default.fileExists(atPath: url.path) {
                    guard let image = Thumbs.decode(url, maxPixel: pixels) else { continue }
                    DispatchQueue.main.async {
                        self?.cache.setObject(image, forKey: cacheKey)
                        completion(image)
                    }
                    return
                }
            }
            DispatchQueue.main.async { Thumbs.shared.image(for: item, side: side, completion: completion) }
        }
    }
}

@MainActor
final class CalendarStore: ObservableObject {
    static let shared = CalendarStore()

    @Published var anchor = ""
    @Published private(set) var overview: CalendarLevel = .month
    @Published private(set) var index: CalendarIndex?
    @Published private(set) var scrollTick = 0
    private var signature = 0
    private var pending = 0
    private var monitor: Any?

    func level(_ model: Model) -> CalendarLevel {
        if case .calendar(let value) = model.scope, CalendarRoute.day(value) != nil { return .day }
        return overview
    }

    var anchorDay: String { anchor.isEmpty ? CalendarDate.today : anchor }

    private func fingerprint(_ model: Model) -> Int {
        var hasher = Hasher()
        hasher.combine(model.epoch)
        hasher.combine(model.flat.count)
        for item in model.flat {
            hasher.combine(item.id)
            hasher.combine(item.date)
        }
        for (key, mark) in model.marks {
            hasher.combine(key)
            hasher.combine(mark)
        }
        hasher.combine(model.tags["type"]?["favorite"]?.count ?? 0)
        hasher.combine(model.tags["trip"]?.count ?? 0)
        return hasher.finalize()
    }

    func refresh(_ model: Model, now: Bool = false) {
        guard case .calendar(let value) = model.scope else { return }
        let source: [Item]
        if CalendarRoute.day(value) == nil {
            source = model.flat
        } else if index == nil {
            source = Array(model.byID.values)
        } else {
            return
        }
        let stamp = CalendarRoute.day(value) == nil ? fingerprint(model) : -1
        if stamp == signature && index != nil { return }
        signature = stamp
        let marks = model.marks, tags = model.tags, photos = !AppPaths.noPhotos
        if index == nil || now {
            install(CalendarIndex.build(source, marks: marks, tags: tags, photos: photos))
            return
        }
        pending += 1
        let ticket = pending
        DispatchQueue.global(qos: .userInitiated).async {
            let built = CalendarIndex.build(source, marks: marks, tags: tags, photos: photos)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard ticket == self.pending else { return }
                    self.install(built)
                }
            }
        }
    }

    private func install(_ built: CalendarIndex) {
        index = built
        if anchor.isEmpty { anchor = built.ordered.last ?? CalendarDate.today }
    }

    func scroll() { scrollTick += 1 }

    func openDay(_ key: String, _ model: Model, select item: Item? = nil) {
        anchor = key
        model.go(.calendar("day:" + key))
        guard let item, let found = model.flat.first(where: { $0.key == item.key }) else { return }
        model.click(found, command: false, shift: false)
        model.scrollRequest += 1
    }

    func openMonth(_ month: String, _ model: Model) {
        anchor = index?.firstDay(in: month) ?? month + "-01"
        overview = .month
        model.go(.calendar("overview"))
        scroll()
    }

    func dayTarget() -> String {
        let key = anchorDay
        if index?.days[key] != nil { return key }
        let week = CalendarDate.week(key)
        let center = week.firstIndex(of: key) ?? 0
        for day in week.indices.sorted(by: { abs($0 - center) < abs($1 - center) }).map({ week[$0] }) where index?.days[day] != nil { return day }
        return index?.firstDay(in: String(key.prefix(7))) ?? key
    }

    func setLevel(_ level: CalendarLevel, _ model: Model) {
        if level == .day {
            openDay(dayTarget(), model)
        } else {
            overview = level
            model.go(.calendar("overview"))
            if level == .month { scroll() }
        }
    }

    func zoom(_ inward: Bool, _ model: Model) {
        let order = CalendarLevel.allCases
        guard let position = order.firstIndex(of: level(model)) else { return }
        let next = position + (inward ? -1 : 1)
        guard order.indices.contains(next) else { return }
        setLevel(order[next], model)
    }

    func step(_ delta: Int, _ model: Model) {
        let key = anchorDay
        switch level(model) {
        case .day:
            guard case .calendar(let value) = model.scope, let current = CalendarRoute.day(value), let next = index?.neighbor(of: current, delta) else { return }
            openDay(next, model)
        case .week:
            anchor = CalendarDate.adding(days: 7 * delta, to: key)
        case .month:
            let month = String(key.prefix(7))
            guard let rows = index?.rows, let position = rows.firstIndex(where: { $0.covers(month) }) else { return }
            var target = position + delta
            while rows.indices.contains(target), case .gap = rows[target] { target += delta }
            guard rows.indices.contains(target), case .month(let next) = rows[target] else { return }
            anchor = index?.firstDay(in: next) ?? next + "-01"
            scroll()
        case .year:
            guard let (y, _, _) = CalendarDate.parts(key) else { return }
            let year = String(y + delta)
            anchor = index?.lastDay(in: year) ?? year + key.dropFirst(4)
        }
    }

    func today(_ model: Model) {
        anchor = CalendarDate.today
        switch level(model) {
        case .day: openDay(anchor, model)
        case .month: scroll()
        default: break
        }
    }

    func jump(_ month: String, _ model: Model) {
        switch level(model) {
        case .month:
            anchor = index?.firstDay(in: month) ?? month + "-01"
            scroll()
        case .week:
            anchor = index?.firstDay(in: month) ?? month + "-01"
        case .year:
            anchor = index?.firstDay(in: month) ?? month + "-01"
            openMonth(month, model)
        case .day:
            openMonth(month, model)
        }
    }

    func jumpYear(_ year: String, _ model: Model) {
        anchor = index?.lastDay(in: year) ?? year + "-01-01"
        if level(model) == .year { return }
        if level(model) == .month { scroll() }
    }

    func visibleMonth(_ month: String) {
        guard !anchor.hasPrefix(month) else { return }
        anchor = index?.firstDay(in: month) ?? month + "-01"
    }

    func open(_ value: String, _ model: Model) {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        let level = CalendarLevel(rawValue: parts.first ?? "") ?? .month
        overview = level == .day ? .month : level
        model.go(.calendar("overview"))
        refresh(model, now: true)
        if parts.count == 2 {
            let target = parts[1]
            if target.count == 10 {
                anchor = target
            } else {
                anchor = index?.lastDay(in: target) ?? (target.count == 4 ? target + "-06-01" : target + "-01")
            }
        }
        if level == .month {
            scroll()
        } else {
            setLevel(level, model)
        }
    }

    func installKeys(_ model: Model) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak model] event in
            guard let self, let model else { return event }
            let handled = MainActor.assumeIsolated { self.handle(event, model) }
            return handled ? nil : event
        }
    }

    private func handle(_ event: NSEvent, _ model: Model) -> Bool {
        guard case .calendar(let value) = model.scope, !model.viewing, let window = model.window, NSApp.keyWindow === window,
              !(window.firstResponder is NSText) else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let characters = event.charactersIgnoringModifiers ?? ""
        if flags.contains(.command) {
            guard flags.isDisjoint(with: [.option, .control]) else { return false }
            if characters == "=" || characters == "+" {
                zoom(true, model)
                return true
            }
            if characters == "-" {
                zoom(false, model)
                return true
            }
            return false
        }
        guard flags.isEmpty, CalendarRoute.day(value) == nil else { return false }
        switch event.keyCode {
        case 123: step(-1, model)
        case 124: step(1, model)
        default: return false
        }
        return true
    }
}
