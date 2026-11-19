import CoreLocation
import Foundation
import SQLite3

enum AppPaths {
    static let support: URL = {
        if let value = ProcessInfo.processInfo.environment["PHOTOHUB_SUPPORT"], !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PhotoHub")
    }()

    static let noPhotos: Bool = {
        let value = ProcessInfo.processInfo.environment["PHOTOHUB_NO_PHOTOS"] ?? ""
        return !value.isEmpty && value != "0"
    }()

    static func archiveLocations() -> [Int64: CLLocationCoordinate2D] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(Catalog.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return [:]
        }
        defer { sqlite3_close(db) }
        let sql = "SELECT m.item_id, MIN(f.lat), MIN(f.lon) FROM file_meta f JOIN member m ON m.source = 'archive' AND m.path = f.path "
            + "WHERE f.lat IS NOT NULL AND f.lon IS NOT NULL AND NOT (f.lat = 0 AND f.lon = 0) GROUP BY m.item_id"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var out: [Int64: CLLocationCoordinate2D] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            out[sqlite3_column_int64(stmt, 0)] = CLLocationCoordinate2D(latitude: sqlite3_column_double(stmt, 1), longitude: sqlite3_column_double(stmt, 2))
        }
        return out
    }
}
