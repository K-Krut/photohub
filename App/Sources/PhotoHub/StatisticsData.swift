import Foundation
import SQLite3

struct Tally: Identifiable, Hashable {
    let name: String
    let count: Int
    var bytes: Int64 = 0
    var group = ""
    var id: String { group + "|" + name }
}

struct CatalogStats {
    var shots = 0
    var files = 0
    var videos = 0
    var rawShots = 0
    var rawFiles = 0
    var editShots = 0
    var editFiles = 0
    var stacks = 0
    var archiveOnly = 0
    var photosOnly = 0
    var both = 0
    var origins: [String: Int] = [:]
    var copyGroups = 0
    var copyFiles = 0
    var copyWaste: Int64 = 0
    var archiveBytes: Int64 = 0
    var archiveFiles = 0
    var photosBytes: Int64 = 0
    var photosFiles = 0
    var byRole: [Tally] = []
    var bytesByYear: [Tally] = []
    var perYear: [Tally] = []
    var perMonth: [Tally] = []
    var cameras: [Tally] = []
    var lenses: [Tally] = []
    var people: [Tally] = []
    var pets: [Tally] = []
    var places: [Tally] = []
    var countries = 0
    var trips = 0
    var busiestDay: Tally?
    var oldest: (title: String, date: String)?
    var longestTrip: (name: String, days: Int)?
    var travelDays = 0
    var travelShots = 0
    var ratings: [Int: Int] = [:]
    var picks = 0
    var rejects = 0
    var labels: [String: Int] = [:]
    var flagged = 0
    var hidden = 0
    var tagsPending = false
    var elapsed: TimeInterval = 0

    var photos: Int { shots - videos }
    var editShare: Double { shots == 0 ? 0 : Double(editShots) / Double(shots) }
    var perTravelDay: Double { travelDays == 0 ? 0 : Double(travelShots) / Double(travelDays) }
    var rated: Int { ratings.values.reduce(0, +) }
    var labeled: Int { labels.values.reduce(0, +) }
    var yearSpan: (first: String, last: String)? {
        let years = perYear.map(\.name).filter { $0 >= "1971" }
        guard let first = years.min(), let last = years.max() else { return nil }
        return (first, last)
    }

    static func tripDays(_ name: String) -> Int {
        let parts = name.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return 0 }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd"
        guard let from = format.date(from: parts[0]), let to = format.date(from: parts[1]) else { return 0 }
        return Int((to.timeIntervalSince(from) / 86400).rounded()) + 1
    }

    static func compute(catalog path: String, hidden: Set<String>) -> CatalogStats? {
        let started = Date()
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        HiddenShadow.install(db, hidden)
        func rows(_ sql: String, _ each: (OpaquePointer) -> Void) {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW { each(stmt) }
        }
        func text(_ s: OpaquePointer, _ i: Int32) -> String { sqlite3_column_text(s, i).map { String(cString: $0) } ?? "" }
        func int(_ s: OpaquePointer, _ i: Int32) -> Int { Int(sqlite3_column_int64(s, i)) }
        func meta(_ key: String) -> String? {
            var out: String?
            rows("SELECT value FROM meta WHERE key = '\(key)'") { out = text($0, 0) }
            return out
        }

        var out = CatalogStats()
        out.hidden = hidden.count
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        defer { sqlite3_exec(db, "COMMIT", nil, nil, nil) }
        rows("""
            SELECT COUNT(*), SUM(is_video), SUM(has_raw), SUM(n_edit > 0), SUM(n_members > 1),
                   SUM(in_archive AND NOT in_photos), SUM(in_photos AND NOT in_archive), SUM(in_archive AND in_photos) FROM item
            """) { s in
            out.shots = int(s, 0)
            out.videos = int(s, 1)
            out.rawShots = int(s, 2)
            out.editShots = int(s, 3)
            out.stacks = int(s, 4)
            out.archiveOnly = int(s, 5)
            out.photosOnly = int(s, 6)
            out.both = int(s, 7)
        }
        guard out.shots > 0 else { return nil }
        rows("SELECT origin, COUNT(*) FROM item GROUP BY origin") { out.origins[text($0, 0)] = int($0, 1) }
        rows("SELECT source, role, COUNT(*), SUM(size) FROM member GROUP BY source, role") { s in
            let source = text(s, 0), role = text(s, 1), count = int(s, 2), bytes = sqlite3_column_int64(s, 3)
            out.files += count
            if role == "raw" { out.rawFiles += count }
            if role == "edit" { out.editFiles += count }
            if source == "archive" {
                out.archiveBytes += bytes
                out.archiveFiles += count
            } else {
                out.photosBytes += bytes
                out.photosFiles += count
            }
            out.byRole.append(Tally(name: role, count: count, bytes: bytes, group: source))
        }
        out.byRole.sort { $0.bytes > $1.bytes }
        rows("SELECT substr(i.date, 1, 4), m.source, COUNT(*), SUM(m.size) FROM member m JOIN item i ON i.id = m.item_id GROUP BY 1, 2 ORDER BY 1") { s in
            out.bytesByYear.append(Tally(name: text(s, 0), count: int(s, 2), bytes: sqlite3_column_int64(s, 3), group: text(s, 1)))
        }
        var years: [String: Int] = [:]
        rows("SELECT substr(date, 1, 7), COUNT(*) FROM item WHERE date != '' GROUP BY 1 ORDER BY 1") { s in
            let month = text(s, 0), count = int(s, 1)
            years[String(month.prefix(4)), default: 0] += count
            if month.count == 7 { out.perMonth.append(Tally(name: month, count: count)) }
        }
        out.perYear = years.sorted { $0.key < $1.key }.map { Tally(name: $0.key, count: $0.value) }
        func top(_ column: String) -> [Tally] {
            var list: [Tally] = []
            rows("SELECT \(column), COUNT(*) FROM item WHERE \(column) != '' GROUP BY 1 ORDER BY 2 DESC, 1 LIMIT 8") { list.append(Tally(name: text($0, 0), count: int($0, 1))) }
            return list
        }
        out.cameras = top("camera")
        out.lenses = top("lens")
        let build = meta("build_id")
        out.tagsPending = build != nil && meta("tags_build_id") != build
        if !out.tagsPending {
            var trips: [Tally] = []
            rows("SELECT kind, name, COUNT(*) FROM tag WHERE kind IN ('person', 'pet', 'place', 'country', 'trip') GROUP BY kind, name ORDER BY 3 DESC, 2") { s in
                let tally = Tally(name: text(s, 1), count: int(s, 2), group: text(s, 0))
                switch tally.group {
                case "person": out.people.append(tally)
                case "pet": out.pets.append(tally)
                case "place": out.places.append(tally)
                case "country": out.countries += 1
                default: trips.append(tally)
                }
            }
            out.trips = trips.count
            for trip in trips {
                let days = tripDays(trip.name)
                out.travelDays += days
                out.travelShots += trip.count
                if days > (out.longestTrip?.days ?? 0) { out.longestTrip = (trip.name, days) }
            }
        }
        var copies: [(count: Int, size: Int64)] = []
        rows("SELECT COUNT(*), MAX(size) FROM exact_copy GROUP BY sha256 HAVING COUNT(*) > 1") { copies.append((int($0, 0), sqlite3_column_int64($0, 1))) }
        out.copyGroups = copies.count
        out.copyFiles = copies.reduce(0) { $0 + $1.count }
        out.copyWaste = copies.reduce(Int64(0)) { $0 + Int64(max($1.count - 1, 0)) * $1.size }
        rows("SELECT substr(date, 1, 10), COUNT(*) FROM item WHERE date_exact = 1 AND length(date) >= 10 AND date >= '1971' GROUP BY 1 ORDER BY 2 DESC, 1 DESC LIMIT 1") {
            out.busiestDay = Tally(name: text($0, 0), count: int($0, 1))
        }
        rows("SELECT title, date FROM item WHERE date_exact = 1 AND date >= '1971' ORDER BY date LIMIT 1") { out.oldest = (text($0, 0), text($0, 1)) }
        rows("SELECT m.rating, m.pick, COALESCE(m.color, ''), COUNT(*) FROM mark m JOIN item i ON i.key = m.key GROUP BY 1, 2, 3") { s in
            let rating = int(s, 0), pick = int(s, 1), color = text(s, 2), count = int(s, 3)
            if rating > 0 { out.ratings[rating, default: 0] += count }
            if pick == 1 { out.picks += count }
            if pick == -1 { out.rejects += count }
            if !color.isEmpty { out.labels[color, default: 0] += count }
        }
        rows("SELECT COUNT(*) FROM flag f JOIN item i ON i.key = f.key WHERE f.phone = 1") { out.flagged = int($0, 0) }
        out.elapsed = Date().timeIntervalSince(started)
        return out
    }
}

struct DiskStats {
    var localFiles = 0
    var localBytes: Int64 = 0
    var cloudFiles = 0
    var cloudBytes: Int64 = 0
    var missingFiles = 0
    var photosLibrary: Int64?
    var data: [Tally] = []
    var downloadCache: Int64?
    var elapsed: TimeInterval = 0
    var scanElapsed: TimeInterval = 0

    var dataBytes: Int64 { data.reduce(0) { $0 + $1.bytes } }

    static func allocated(_ url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        if values.isDirectory != true { return Int64(values.totalFileAllocatedSize ?? 0) }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) else { return nil }
        var total: Int64 = 0
        while let file = walker.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    static func files(_ base: String, _ suffixes: [String]) -> Int64 {
        suffixes.reduce(Int64(0)) { $0 + (allocated(URL(fileURLWithPath: base + $1)) ?? 0) }
    }

    static func compute(catalog: String, archive: URL, support: URL, photosLibrary: URL?, hidden: Set<String>) -> DiskStats {
        let started = Date()
        var out = DiskStats()
        var db: OpaquePointer?
        var paths: [(String, Int64)] = []
        if sqlite3_open_v2(catalog, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            HiddenShadow.install(db, hidden)
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT path, size FROM member WHERE source = 'archive'", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    paths.append((sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "", sqlite3_column_int64(stmt, 1)))
                }
            }
            sqlite3_finalize(stmt)
        }
        sqlite3_close(db)
        let root = archive.path.hasSuffix("/") ? archive.path : archive.path + "/"
        for (path, size) in paths {
            var st = stat()
            if lstat(root + path, &st) != 0 {
                out.missingFiles += 1
            } else if st.st_flags & 0x4000_0000 != 0 {
                out.cloudFiles += 1
                out.cloudBytes += size
            } else {
                out.localFiles += 1
                out.localBytes += size
            }
        }
        out.scanElapsed = Date().timeIntervalSince(started)
        out.data = [
            Tally(name: "catalog", count: 0, bytes: files(catalog, ["", "-wal", "-shm", "-journal"])),
            Tally(name: "thumbs", count: 0, bytes: allocated(support.appendingPathComponent("thumbs")) ?? 0),
            Tally(name: "previews", count: 0, bytes: allocated(support.appendingPathComponent("previews")) ?? 0),
            Tally(name: "vision", count: 0, bytes: files(support.appendingPathComponent("vision.sqlite").path, ["", "-wal", "-shm"])),
            Tally(name: "index", count: 0, bytes: files(support.appendingPathComponent("hash_index.sqlite").path, ["", "-wal", "-shm"])),
            Tally(name: "models", count: 0, bytes: allocated(support.appendingPathComponent("models")) ?? 0),
        ].filter { $0.bytes > 0 }
        let caches = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/CloudKit/com.apple.bird")
        if let accounts = try? FileManager.default.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil) {
            out.downloadCache = accounts.reduce(Int64(0)) { $0 + (allocated($1.appendingPathComponent("MMCS/ClonedFiles")) ?? 0) }
        }
        if let photosLibrary { out.photosLibrary = allocated(photosLibrary) }
        out.elapsed = Date().timeIntervalSince(started)
        return out
    }
}

enum HiddenShadow {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func install(_ db: OpaquePointer?, _ keys: Set<String>) {
        guard !keys.isEmpty else { return }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        sqlite3_exec(db, "CREATE TEMP TABLE hidden_key (key TEXT PRIMARY KEY)", nil, nil, nil)
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO temp.hidden_key (key) VALUES (?)", -1, &stmt, nil) == SQLITE_OK {
            for key in keys {
                sqlite3_bind_text(stmt, 1, key, -1, transient)
                sqlite3_step(stmt)
                sqlite3_reset(stmt)
            }
        }
        sqlite3_finalize(stmt)
        for sql in ["CREATE TEMP VIEW item AS SELECT * FROM main.item WHERE key NOT IN (SELECT key FROM temp.hidden_key)",
                    "CREATE TEMP VIEW member AS SELECT * FROM main.member WHERE item_id IN (SELECT id FROM temp.item)",
                    "CREATE TEMP VIEW tag AS SELECT * FROM main.tag WHERE item_id IN (SELECT id FROM temp.item)",
                    "CREATE TEMP VIEW exact_copy AS SELECT * FROM main.exact_copy WHERE item_key IS NULL OR item_key NOT IN (SELECT key FROM temp.hidden_key)"] {
            sqlite3_exec(db, sql, nil, nil, nil)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }
}
