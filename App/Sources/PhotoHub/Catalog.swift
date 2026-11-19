import Foundation
import SQLite3

struct Item: Identifiable, Hashable {
    let id: Int64
    let key: String
    let date: String
    let dateExact: Bool
    let title: String
    let root: String
    let inArchive: Bool
    let inPhotos: Bool
    let hasRaw: Bool
    let nEdit: Int
    let nMembers: Int
    let thumbAsset: String
    let thumbPath: String
    let isVideo: Bool
    let formats: String
    let size: Int64
    var mainAsset = ""
    var mainPath = ""
    var origin = ""
    var camera = ""
    var lens = ""
    var dateSource = ""
    var nExport = 0
    var nOwnArchive = 0

    var month: String { date.isEmpty ? "" : String(date.prefix(7)) }

    var needsArchive: Bool { inPhotos && nOwnArchive == 0 }

    var dateLabel: String {
        if date.isEmpty { return String(localized: "Date unknown") }
        switch dateSource {
        case "exif", "name", "photos": return date
        case "file": return String(localized: "\(date) · file save date")
        case "folder": return String(localized: "\(date) (approximate, from the folder)")
        default: return dateExact ? date : String(localized: "\(date) (approximate, from the folder)")
        }
    }
}

struct CatalogSnapshot {
    let items: [Item]
    let albums: [String: Set<Int64>]
    let tags: [String: [String: Set<Int64>]]
    let flags: Set<String>
    let marks: [String: Mark]
    let version: Int64
    let tagsPending: Bool
}

struct Mark: Hashable {
    var rating = 0
    var pick = 0
    var color = ""
}

struct Member: Identifiable, Hashable {
    let id: Int64
    let source: String
    let path: String
    let name: String
    let ext: String
    let size: Int64
    let role: String
    let taken: String
    let width: Int
    let height: Int
}

struct CatalogRow {
    private(set) var columns: [String] = []
    private var values: [String: Any] = [:]

    mutating func append(_ name: String, _ value: Any) {
        columns.append(name)
        values[name] = value
    }

    subscript(_ name: String) -> Any? { values[name] }
}

struct ItemBackup {
    let item: CatalogRow
    let members: [CatalogRow]
    let tags: [CatalogRow]
    let albums: [CatalogRow]
    let choice: CatalogRow?
}

struct FileMeta {
    var taken = ""
    var make = ""
    var model = ""
    var lens = ""
    var iso = ""
    var aperture = ""
    var shutter = ""
    var focal = ""
    var software = ""
    var width = 0
    var height = 0
}

enum Versions {
    static func group(_ m: Member) -> Int {
        if m.source == "photos" { return 3 }
        switch m.role {
        case "edit": return 1
        case "raw": return 4
        case "export": return 5
        default: return 2
        }
    }

    static func ordered(_ members: [Member], choice: String?, thumbPath: String) -> [Member] {
        func byName(_ a: Member, _ b: Member) -> Bool { a.name.localizedStandardCompare(b.name) == .orderedAscending }
        let edits = members.filter { group($0) == 1 }.sorted { a, b in
            a.taken != b.taken ? a.taken > b.taken : a.name.localizedStandardCompare(b.name) == .orderedDescending
        }
        let originals = members.filter { group($0) == 2 }.sorted { a, b in
            if (a.path == thumbPath) != (b.path == thumbPath) { return a.path == thumbPath }
            if (a.role == "photo") != (b.role == "photo") { return a.role == "photo" }
            return byName(a, b)
        }
        let photos = members.filter { group($0) == 3 }.sorted { a, b in
            if (a.role == "photo") != (b.role == "photo") { return a.role == "photo" }
            if a.width * a.height != b.width * b.height { return a.width * a.height > b.width * b.height }
            return byName(a, b)
        }
        let raws = members.filter { group($0) == 4 }.sorted(by: byName)
        let exports = members.filter { group($0) == 5 }.sorted(by: byName)
        var list = edits + originals + photos + exports + raws
        if let choice, let index = list.firstIndex(where: { $0.path == choice }), index > 0 {
            list.insert(list.remove(at: index), at: 0)
        }
        return list
    }
}

final class Catalog {
    static let configFile = AppPaths.support.appendingPathComponent("config.json")

    static func setArchiveRoot(_ url: URL) throws {
        var json = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: configFile))) as? [String: Any]) ?? [:]
        json["archive_root"] = url.path
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: configFile, options: .atomic)
        archiveRoot = url
    }

    static var archiveRoot: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let value = ProcessInfo.processInfo.environment["PHOTOHUB_ARCHIVE"], !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }
        let config = configFile
        if let data = try? Data(contentsOf: config),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = json["archive_root"] as? String, !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Photos")
    }()
    private static let config: [String: Any] = {
        guard let data = try? Data(contentsOf: configFile) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }()
    static let containerFolders = Set((config["container_folders"] as? [String] ?? []).filter { !$0.isEmpty })
    static let meFolder = config["me_folder"] as? String ?? ""
    static let path = ProcessInfo.processInfo.environment["PHOTOHUB_CATALOG"] ?? AppPaths.support.appendingPathComponent("catalog.sqlite").path

    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?() {
        guard sqlite3_open(Catalog.path, &db) == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(db, 5000)
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS user_tag (key TEXT, tag TEXT, PRIMARY KEY (key, tag))", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS mark (key TEXT PRIMARY KEY, rating INTEGER DEFAULT 0, pick INTEGER DEFAULT 0)", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS main_choice (key TEXT PRIMARY KEY, path TEXT)", nil, nil, nil)
        if !columns("mark").contains("color") { sqlite3_exec(db, "ALTER TABLE mark ADD COLUMN color TEXT DEFAULT ''", nil, nil, nil) }
    }

    private func columns(_ table: String) -> Set<String> {
        var out: Set<String> = []
        guard let s = prepare("PRAGMA table_info(\(table))", []) else { return out }
        defer { sqlite3_finalize(s) }
        while sqlite3_step(s) == SQLITE_ROW { out.insert(text(s, 1)) }
        return out
    }

    deinit { sqlite3_close(db) }

    private func prepare(_ sql: String, _ args: [Any]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        for (i, arg) in args.enumerated() {
            let n = Int32(i + 1)
            switch arg {
            case let v as String: sqlite3_bind_text(stmt, n, v, -1, transient)
            case let v as Int64: sqlite3_bind_int64(stmt, n, v)
            case let v as Int: sqlite3_bind_int64(stmt, n, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, n, v)
            case let v as Data: _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, n, $0.baseAddress, Int32(v.count), transient) }
            default: sqlite3_bind_null(stmt, n)
            }
        }
        return stmt
    }

    private func text(_ s: OpaquePointer?, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(s, i) else { return "" }
        return String(cString: c)
    }

    func items() -> [Item] {
        var out: [Item] = []
        let head = "SELECT id, key, date, date_exact, title, root, in_archive, in_photos, has_raw, n_edit, n_members, thumb_asset, thumb_path, is_video, formats, (SELECT MAX(size) FROM member WHERE member.item_id = item.id)"
        let tail = " FROM item ORDER BY date DESC, title"
        var extra = 0
        var stmt: OpaquePointer?
        for (columns, count) in [(", origin, camera, lens, date_source", 4), (", origin, camera, lens", 3), ("", 0)] {
            stmt = prepare(head + columns + tail, [])
            if stmt != nil {
                extra = count
                break
            }
        }
        guard let s = stmt else { return out }
        defer { sqlite3_finalize(s) }
        let choices = mainChoices()
        var stacks: [Int64: [Member]] = [:]
        if let m = prepare("SELECT item_id, id, source, path, name, ext, size, role, taken, width, height FROM member", []) {
            while sqlite3_step(m) == SQLITE_ROW {
                stacks[sqlite3_column_int64(m, 0), default: []].append(member(m, from: 1))
            }
            sqlite3_finalize(m)
        }
        while sqlite3_step(s) == SQLITE_ROW {
            var item = Item(
                id: sqlite3_column_int64(s, 0), key: text(s, 1), date: text(s, 2), dateExact: sqlite3_column_int(s, 3) != 0,
                title: text(s, 4), root: text(s, 5), inArchive: sqlite3_column_int(s, 6) != 0, inPhotos: sqlite3_column_int(s, 7) != 0,
                hasRaw: sqlite3_column_int(s, 8) != 0, nEdit: Int(sqlite3_column_int(s, 9)), nMembers: Int(sqlite3_column_int(s, 10)),
                thumbAsset: text(s, 11), thumbPath: text(s, 12), isVideo: sqlite3_column_int(s, 13) != 0, formats: text(s, 14), size: sqlite3_column_int64(s, 15))
            if extra >= 3 {
                item.origin = text(s, 16)
                item.camera = text(s, 17)
                item.lens = text(s, 18)
            }
            if extra >= 4 { item.dateSource = text(s, 19) }
            let stack = stacks[item.id] ?? []
            item.nExport = stack.filter { $0.role == "export" }.count
            item.nOwnArchive = stack.filter { $0.source == "archive" && $0.role != "export" }.count
            if let main = Versions.ordered(stack, choice: choices[item.key], thumbPath: item.thumbPath).first {
                if main.source == "photos" { item.mainAsset = main.path } else { item.mainPath = main.path }
            }
            out.append(item)
        }
        return out
    }

    private func member(_ s: OpaquePointer?, from i: Int32) -> Member {
        Member(id: sqlite3_column_int64(s, i), source: text(s, i + 1), path: text(s, i + 2), name: text(s, i + 3), ext: text(s, i + 4),
               size: sqlite3_column_int64(s, i + 5), role: text(s, i + 6), taken: text(s, i + 7),
               width: Int(sqlite3_column_int(s, i + 8)), height: Int(sqlite3_column_int(s, i + 9)))
    }

    private func run(_ sql: String, _ args: [Any]) {
        guard let s = prepare(sql, args) else { return }
        sqlite3_step(s)
        sqlite3_finalize(s)
    }

    func mainChoices() -> [String: String] {
        var out: [String: String] = [:]
        guard let s = prepare("SELECT key, path FROM main_choice", []) else { return out }
        defer { sqlite3_finalize(s) }
        while sqlite3_step(s) == SQLITE_ROW { out[text(s, 0)] = text(s, 1) }
        return out
    }

    func mainChoice(_ key: String) -> String? {
        guard let s = prepare("SELECT path FROM main_choice WHERE key = ?", [key]) else { return nil }
        defer { sqlite3_finalize(s) }
        return sqlite3_step(s) == SQLITE_ROW ? text(s, 0) : nil
    }

    func setMain(_ key: String, _ path: String) {
        run("INSERT OR REPLACE INTO main_choice (key, path) VALUES (?, ?)", [key, path])
    }

    func fileMeta(_ path: String) -> FileMeta? {
        let sql = "SELECT taken, make, model, lens, iso, aperture, shutter, focal, software, width, height FROM file_meta WHERE path = ?"
        guard let s = prepare(sql, [path]) else { return nil }
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { return nil }
        return FileMeta(taken: text(s, 0), make: text(s, 1), model: text(s, 2), lens: text(s, 3), iso: text(s, 4), aperture: text(s, 5),
                        shutter: text(s, 6), focal: text(s, 7), software: text(s, 8),
                        width: Int(sqlite3_column_int(s, 9)), height: Int(sqlite3_column_int(s, 10)))
    }

    func snapshot() -> CatalogSnapshot? {
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_exec(db, "COMMIT", nil, nil, nil) }
        let list = items()
        guard !list.isEmpty else { return nil }
        let pending = !tagsCurrent()
        return CatalogSnapshot(items: list, albums: albums(), tags: tags(userOnly: pending), flags: flags(), marks: marks(), version: dataVersion(),
                               tagsPending: pending)
    }

    func tagsCurrent() -> Bool {
        guard let build = meta("build_id") else { return true }
        return meta("tags_build_id") == build
    }

    func meta(_ key: String) -> String? {
        guard let s = prepare("SELECT value FROM meta WHERE key = ?", [key]) else { return nil }
        defer { sqlite3_finalize(s) }
        return sqlite3_step(s) == SQLITE_ROW ? text(s, 0) : nil
    }

    func dataVersion() -> Int64 {
        guard let s = prepare("PRAGMA data_version", []) else { return -1 }
        defer { sqlite3_finalize(s) }
        return sqlite3_step(s) == SQLITE_ROW ? sqlite3_column_int64(s, 0) : -1
    }

    func count(_ table: String) -> Int {
        guard let s = prepare("SELECT COUNT(*) FROM \(table)", []) else { return 0 }
        defer { sqlite3_finalize(s) }
        return sqlite3_step(s) == SQLITE_ROW ? Int(sqlite3_column_int64(s, 0)) : 0
    }

    static var writing: Bool { FileManager.default.fileExists(atPath: path + "-journal") }

    static func signature() -> String {
        [path, path + "-wal", path + "-journal"].map { file -> String in
            var st = stat()
            guard lstat(file, &st) == 0 else { return "-" }
            return "\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec):\(st.st_size)"
        }.joined(separator: "|")
    }

    func deleteMember(_ member: Member, key: String) {
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var found: Int64?
        if let s = prepare("SELECT id FROM item WHERE key = ?", [key]) {
            if sqlite3_step(s) == SQLITE_ROW { found = sqlite3_column_int64(s, 0) }
            sqlite3_finalize(s)
        }
        guard let item = found else {
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
            return
        }
        run("DELETE FROM member WHERE item_id = ? AND source = ? AND path = ?", [item, member.source, member.path])
        run("DELETE FROM main_choice WHERE path = ?", [member.path])
        var left = 0
        if let s = prepare("SELECT COUNT(*) FROM member WHERE item_id = ?", [item]) {
            if sqlite3_step(s) == SQLITE_ROW { left = Int(sqlite3_column_int(s, 0)) }
            sqlite3_finalize(s)
        }
        if left == 0 {
            run("DELETE FROM item WHERE id = ?", [item])
            run("DELETE FROM tag WHERE item_id = ?", [item])
            run("DELETE FROM album WHERE item_id = ?", [item])
        } else {
            run("""
                UPDATE item SET
                  n_members = (SELECT COUNT(*) FROM member WHERE item_id = ?1),
                  n_edit = (SELECT COUNT(*) FROM member WHERE item_id = ?1 AND role = 'edit'),
                  has_raw = EXISTS (SELECT 1 FROM member WHERE item_id = ?1 AND role = 'raw'),
                  in_archive = EXISTS (SELECT 1 FROM member WHERE item_id = ?1 AND source = 'archive'),
                  in_photos = EXISTS (SELECT 1 FROM member WHERE item_id = ?1 AND source = 'photos'),
                  thumb_path = CASE WHEN thumb_path = ?2 THEN COALESCE((SELECT path FROM member WHERE item_id = ?1 AND source = 'archive' ORDER BY role != 'photo', name LIMIT 1), '') ELSE thumb_path END,
                  thumb_asset = CASE WHEN thumb_asset = ?2 THEN COALESCE((SELECT path FROM member WHERE item_id = ?1 AND source = 'photos' ORDER BY role != 'photo', name LIMIT 1), '') ELSE thumb_asset END
                WHERE id = ?1
                """, [item, member.path])
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    private func rows(_ sql: String, _ args: [Any]) -> [CatalogRow] {
        guard let s = prepare(sql, args) else { return [] }
        defer { sqlite3_finalize(s) }
        var out: [CatalogRow] = []
        while sqlite3_step(s) == SQLITE_ROW {
            var row = CatalogRow()
            for i in 0..<sqlite3_column_count(s) {
                let name = String(cString: sqlite3_column_name(s, i))
                switch sqlite3_column_type(s, i) {
                case SQLITE_INTEGER: row.append(name, sqlite3_column_int64(s, i))
                case SQLITE_FLOAT: row.append(name, sqlite3_column_double(s, i))
                case SQLITE_TEXT: row.append(name, text(s, i))
                case SQLITE_BLOB: row.append(name, Data(bytes: sqlite3_column_blob(s, i), count: Int(sqlite3_column_bytes(s, i))))
                default: row.append(name, NSNull())
                }
            }
            out.append(row)
        }
        return out
    }

    private func insert(_ table: String, _ row: CatalogRow, set: [String: Any] = [:], skip: Set<String> = []) {
        let names = row.columns.filter { !skip.contains($0) }
        let values = names.map { set[$0] ?? row[$0] ?? NSNull() }
        run("INSERT INTO \(table) (\(names.joined(separator: ", "))) VALUES (\(names.map { _ in "?" }.joined(separator: ", ")))", values)
    }

    private func itemID(_ key: String) -> Int64? {
        guard let s = prepare("SELECT id FROM item WHERE key = ?", [key]) else { return nil }
        defer { sqlite3_finalize(s) }
        return sqlite3_step(s) == SQLITE_ROW ? sqlite3_column_int64(s, 0) : nil
    }

    func backup(keys: [String]) -> [String: ItemBackup] {
        var out: [String: ItemBackup] = [:]
        for key in Set(keys) {
            guard let item = rows("SELECT * FROM item WHERE key = ?", [key]).first, let id = item["id"] as? Int64 else { continue }
            out[key] = ItemBackup(item: item, members: rows("SELECT * FROM member WHERE item_id = ?", [id]),
                                  tags: rows("SELECT * FROM tag WHERE item_id = ?", [id]), albums: rows("SELECT * FROM album WHERE item_id = ?", [id]),
                                  choice: rows("SELECT * FROM main_choice WHERE key = ?", [key]).first)
        }
        return out
    }

    func restore(_ backup: ItemBackup, paths: Set<String>) {
        guard let key = backup.item["key"] as? String else { return }
        let members = backup.members.filter { ($0["source"] as? String) == "archive" && paths.contains($0["path"] as? String ?? "") }
        guard !members.isEmpty else { return }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var id = itemID(key)
        if id == nil {
            insert("item", backup.item, skip: ["id"])
            id = sqlite3_last_insert_rowid(db)
            for tag in backup.tags { insert("tag", tag, set: ["item_id": id!]) }
            for album in backup.albums { insert("album", album, set: ["item_id": id!]) }
        }
        guard let item = id else {
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
            return
        }
        for member in members {
            let path = member["path"] as? String ?? ""
            if rows("SELECT id FROM member WHERE item_id = ? AND source = 'archive' AND path = ?", [item, path]).isEmpty {
                insert("member", member, set: ["item_id": item], skip: ["id"])
            }
        }
        if let choice = backup.choice, paths.contains(choice["path"] as? String ?? "") { insert("main_choice", choice) }
        if let thumb = backup.item["thumb_path"] as? String, paths.contains(thumb) { run("UPDATE item SET thumb_path = ? WHERE id = ?", [thumb, item]) }
        run("""
            UPDATE item SET
              n_members = (SELECT COUNT(*) FROM member WHERE item_id = ?1),
              n_edit = (SELECT COUNT(*) FROM member WHERE item_id = ?1 AND role = 'edit'),
              has_raw = EXISTS (SELECT 1 FROM member WHERE item_id = ?1 AND role = 'raw'),
              in_archive = EXISTS (SELECT 1 FROM member WHERE item_id = ?1 AND source = 'archive'),
              in_photos = EXISTS (SELECT 1 FROM member WHERE item_id = ?1 AND source = 'photos'),
              thumb_path = CASE WHEN EXISTS (SELECT 1 FROM member WHERE item_id = ?1 AND source = 'archive' AND path = item.thumb_path) THEN thumb_path
                ELSE COALESCE((SELECT path FROM member WHERE item_id = ?1 AND source = 'archive' ORDER BY role != 'photo', name LIMIT 1), '') END,
              thumb_asset = CASE WHEN EXISTS (SELECT 1 FROM member WHERE item_id = ?1 AND source = 'photos' AND path = item.thumb_asset) THEN thumb_asset
                ELSE COALESCE((SELECT path FROM member WHERE item_id = ?1 AND source = 'photos' ORDER BY role != 'photo', name LIMIT 1), '') END
            WHERE id = ?1
            """, [item])
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    func key(ofAsset path: String) -> String? {
        guard let s = prepare("SELECT i.key FROM member m JOIN item i ON i.id = m.item_id WHERE m.source = 'photos' AND m.path = ?", [path]) else { return nil }
        defer { sqlite3_finalize(s) }
        return sqlite3_step(s) == SQLITE_ROW ? text(s, 0) : nil
    }

    func moveKey(_ old: String, to new: String) {
        guard old != new else { return }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for table in ["user_tag", "tag_override", "mark", "flag", "date_override", "main_choice", "hidden_item"] {
            run("UPDATE OR IGNORE \(table) SET key = ? WHERE key = ?", [new, old])
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    func members(of key: String) -> [Member] {
        var out: [Member] = []
        let sql = """
            SELECT m.id, m.source, m.path, m.name, m.ext, m.size, m.role, m.taken, m.width, m.height
            FROM member m JOIN item i ON i.id = m.item_id WHERE i.key = ? ORDER BY m.source, m.role, m.name
            """
        guard let s = prepare(sql, [key]) else { return out }
        defer { sqlite3_finalize(s) }
        while sqlite3_step(s) == SQLITE_ROW { out.append(member(s, from: 0)) }
        return out
    }

    func albums() -> [String: Set<Int64>] {
        var out: [String: Set<Int64>] = [:]
        guard let s = prepare("SELECT album, item_id FROM album", []) else { return out }
        defer { sqlite3_finalize(s) }
        while sqlite3_step(s) == SQLITE_ROW {
            out[text(s, 0), default: []].insert(sqlite3_column_int64(s, 1))
        }
        return out
    }

    func tags(userOnly: Bool = false) -> [String: [String: Set<Int64>]] {
        var out: [String: [String: Set<Int64>]] = [:]
        if !userOnly, let s = prepare("SELECT kind, name, item_id FROM tag", []) {
            while sqlite3_step(s) == SQLITE_ROW {
                out[text(s, 0), default: [:]][text(s, 1), default: []].insert(sqlite3_column_int64(s, 2))
            }
            sqlite3_finalize(s)
        }
        if !userOnly, let o = prepare("SELECT o.kind, o.name, i.id, o.state FROM tag_override o JOIN item i ON i.key = o.key", []) {
            while sqlite3_step(o) == SQLITE_ROW {
                let kind = text(o, 0), name = text(o, 1), id = sqlite3_column_int64(o, 2)
                if sqlite3_column_int(o, 3) != 0 {
                    out[kind, default: [:]][name, default: []].insert(id)
                } else if out[kind]?[name]?.remove(id) != nil, out[kind]?[name]?.isEmpty == true {
                    out[kind]?[name] = nil
                }
            }
            sqlite3_finalize(o)
        }
        if let u = prepare("SELECT u.tag, i.id FROM user_tag u JOIN item i ON i.key = u.key", []) {
            while sqlite3_step(u) == SQLITE_ROW {
                out["user", default: [:]][text(u, 0), default: []].insert(sqlite3_column_int64(u, 1))
            }
            sqlite3_finalize(u)
        }
        return out
    }

    func marks() -> [String: Mark] {
        var out: [String: Mark] = [:]
        guard let s = prepare("SELECT key, rating, pick, COALESCE(color, '') FROM mark WHERE rating != 0 OR pick != 0 OR COALESCE(color, '') != ''", [])
                ?? prepare("SELECT key, rating, pick, '' FROM mark WHERE rating != 0 OR pick != 0", []) else { return out }
        defer { sqlite3_finalize(s) }
        while sqlite3_step(s) == SQLITE_ROW {
            out[text(s, 0)] = Mark(rating: Int(sqlite3_column_int(s, 1)), pick: Int(sqlite3_column_int(s, 2)), color: text(s, 3))
        }
        return out
    }

    func setMark(_ key: String, _ mark: Mark) {
        guard let s = prepare("INSERT OR REPLACE INTO mark (key, rating, pick, color) VALUES (?, ?, ?, ?)", [key, mark.rating, mark.pick, mark.color])
                ?? prepare("INSERT OR REPLACE INTO mark (key, rating, pick) VALUES (?, ?, ?)", [key, mark.rating, mark.pick]) else { return }
        sqlite3_step(s)
        sqlite3_finalize(s)
    }

    func setUserTag(_ tag: String, keys: [String], on: Bool) {
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for key in keys {
            run(on ? "INSERT OR IGNORE INTO user_tag (key, tag) VALUES (?, ?)" : "DELETE FROM user_tag WHERE key = ? AND tag = ?", [key, tag])
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    func setTagOverride(_ kind: String, _ name: String, keys: [String], on: Bool) {
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS tag_override (key TEXT, kind TEXT, name TEXT, state INTEGER, PRIMARY KEY (key, kind, name))", nil, nil, nil)
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for key in keys {
            if on {
                run("INSERT OR REPLACE INTO tag_override (key, kind, name, state) VALUES (?, ?, ?, 1)", [key, kind, name])
            } else {
                run("DELETE FROM tag_override WHERE key = ? AND kind = ? AND name = ?", [key, kind, name])
                run("""
                    INSERT INTO tag_override (key, kind, name, state) SELECT ?1, ?2, ?3, 0
                    WHERE EXISTS (SELECT 1 FROM tag t JOIN item i ON i.id = t.item_id WHERE i.key = ?1 AND t.kind = ?2 AND t.name = ?3)
                    """, [key, kind, name])
            }
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    func flags() -> Set<String> {
        var out: Set<String> = []
        guard let s = prepare("SELECT key FROM flag WHERE phone = 1", []) else { return out }
        defer { sqlite3_finalize(s) }
        while sqlite3_step(s) == SQLITE_ROW { out.insert(text(s, 0)) }
        return out
    }

    func setFlag(_ key: String, _ on: Bool) {
        let sql = on ? "INSERT OR REPLACE INTO flag (key, phone) VALUES (?, 1)" : "DELETE FROM flag WHERE key = ?"
        guard let s = prepare(sql, [key]) else { return }
        sqlite3_step(s)
        sqlite3_finalize(s)
    }
}
