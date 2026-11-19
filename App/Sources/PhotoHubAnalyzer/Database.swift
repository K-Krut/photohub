import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct DatabaseError: Error, CustomStringConvertible {
    let description: String
}

final class Database {
    let handle: OpaquePointer

    init(path: String, readOnly: Bool = false) throws {
        var db: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            throw DatabaseError(description: "cannot open database \(path)")
        }
        handle = db
        sqlite3_busy_timeout(db, 10000)
    }

    deinit { sqlite3_close(handle) }

    var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? lastError
            sqlite3_free(err)
            throw DatabaseError(description: message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError(description: "\(lastError): \(sql)")
        }
        return Statement(stmt, db: self)
    }

    func run(_ sql: String, _ args: [Any?] = []) throws {
        let stmt = try prepare(sql)
        try stmt.bind(args)
        _ = try stmt.step()
    }

    func rows(_ sql: String, _ args: [Any?] = [], _ body: (Statement) throws -> Void) throws {
        let stmt = try prepare(sql)
        try stmt.bind(args)
        while try stmt.step() { try body(stmt) }
    }

    func scalarInt(_ sql: String, _ args: [Any?] = []) throws -> Int64 {
        var value: Int64 = 0
        try rows(sql, args) { value = $0.int(0) }
        return value
    }

    func tableExists(_ name: String) -> Bool {
        (try? scalarInt("SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?", [name])) ?? 0 > 0
    }

    func columns(_ table: String) -> Set<String> {
        var out = Set<String>()
        try? rows("PRAGMA table_info(\(table))") { out.insert($0.text(1)) }
        return out
    }
}

final class Statement {
    let stmt: OpaquePointer
    unowned let db: Database

    init(_ stmt: OpaquePointer, db: Database) {
        self.stmt = stmt
        self.db = db
    }

    deinit { sqlite3_finalize(stmt) }

    func bind(_ args: [Any?]) throws {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (i, arg) in args.enumerated() {
            let n = Int32(i + 1)
            switch arg {
            case nil: sqlite3_bind_null(stmt, n)
            case let v as String: sqlite3_bind_text(stmt, n, v, -1, sqliteTransient)
            case let v as Int: sqlite3_bind_int64(stmt, n, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, n, v)
            case let v as Int32: sqlite3_bind_int64(stmt, n, Int64(v))
            case let v as Bool: sqlite3_bind_int64(stmt, n, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(stmt, n, v)
            case let v as Float: sqlite3_bind_double(stmt, n, Double(v))
            case let v as Data:
                _ = v.withUnsafeBytes { raw in
                    sqlite3_bind_blob(stmt, n, raw.baseAddress, Int32(v.count), sqliteTransient)
                }
            default:
                throw DatabaseError(description: "unknown parameter type \(String(describing: arg))")
            }
        }
    }

    func step() throws -> Bool {
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw DatabaseError(description: db.lastError)
        }
    }

    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func text(_ i: Int32) -> String {
        guard let p = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: p)
    }
    func blob(_ i: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(stmt, i))
        guard count > 0, let p = sqlite3_column_blob(stmt, i) else { return Data() }
        return Data(bytes: p, count: count)
    }
}
