import CoreGraphics
import Foundation

let schemaVersion = 1

func openStore(write: Bool = true) throws -> Database {
    if !write {
        guard FileManager.default.fileExists(atPath: Paths.vision.path) else { throw CLIError("no \(Paths.vision.path) — use run first") }
        return try Database(path: Paths.vision.path)
    }
    try FileManager.default.createDirectory(at: Paths.vision.deletingLastPathComponent(), withIntermediateDirectories: true)
    let db = try Database(path: Paths.vision.path)
    try db.exec("""
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS run (id INTEGER PRIMARY KEY, started TEXT, finished TEXT, args TEXT, os TEXT,
            workers INTEGER, classify_rev INTEGER, print_rev INTEGER, face_rev INTEGER, quality_rev INTEGER, animal_rev INTEGER,
            planned INTEGER, done INTEGER, failed INTEGER, skipped INTEGER, seconds REAL, images_per_sec REAL,
            peak_rss_mb REAL, status TEXT);
        CREATE TABLE IF NOT EXISTS image (source_id TEXT PRIMARY KEY, kind TEXT, file TEXT, file_size INTEGER, file_mtime REAL,
            width INTEGER, height INTEGER, run_id INTEGER, analyzed_at TEXT, ms REAL,
            print_rev INTEGER, print_type INTEGER, print_count INTEGER, print BLOB,
            n_labels INTEGER, n_faces INTEGER, n_animals INTEGER, error TEXT);
        CREATE TABLE IF NOT EXISTS label (source_id TEXT, identifier TEXT, confidence REAL,
            PRIMARY KEY (source_id, identifier)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS label_identifier ON label(identifier, confidence);
        CREATE TABLE IF NOT EXISTS face (id INTEGER PRIMARY KEY, source_id TEXT, idx INTEGER,
            x REAL, y REAL, w REAL, h REAL, confidence REAL, quality REAL, roll REAL, yaw REAL, crop_px INTEGER,
            print_rev INTEGER, print_type INTEGER, print_count INTEGER, print BLOB);
        CREATE INDEX IF NOT EXISTS face_source ON face(source_id);
        CREATE TABLE IF NOT EXISTS animal (id INTEGER PRIMARY KEY, source_id TEXT, idx INTEGER, label TEXT, confidence REAL,
            x REAL, y REAL, w REAL, h REAL, crop_px INTEGER,
            print_rev INTEGER, print_type INTEGER, print_count INTEGER, print BLOB);
        CREATE INDEX IF NOT EXISTS animal_source ON animal(source_id);
        """)
    let meta: [(String, String)] = [
        ("schema", String(schemaVersion)),
        ("bbox", "Vision: normalized 0…1, origin at bottom left, on the rotated (as displayed) image"),
        ("label_threshold", String(labelThreshold)),
        ("max_side", String(maxSide)),
        ("face_crop", "square, side = max(w,h) × 1.3, shifted inside the frame"),
        ("animal_crop", "square, side = max(w,h) × 1.1, shifted inside the frame"),
        ("print_layout", "raw bytes of VNFeaturePrintObservation.data; print_type 1 = float32, 2 = float64"),
        ("source_id", "a:<member.path> — archive (2048 preview or 640 thumbnail), p:<ZUUID> — Photos (library derivatives)"),
    ]
    for (k, v) in meta { try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", [k, v]) }
    return db
}

func isoNow() -> String { ISO8601DateFormatter().string(from: Date()) }

final class StoreWriter {
    private let db: Database
    private let runID: Int64
    private var pending: [Analysis] = []
    private let lock = NSLock()
    private let insertImage: Statement
    private let insertLabel: Statement
    private let insertFace: Statement
    private let insertAnimal: Statement
    private let deleteLabels: Statement
    private let deleteFaces: Statement
    private let deleteAnimals: Statement

    init(db: Database, runID: Int64) throws {
        self.db = db
        self.runID = runID
        insertImage = try db.prepare("""
            INSERT OR REPLACE INTO image(source_id, kind, file, file_size, file_mtime, width, height, run_id, analyzed_at, ms,
                print_rev, print_type, print_count, print, n_labels, n_faces, n_animals, error)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        insertLabel = try db.prepare("INSERT OR REPLACE INTO label(source_id, identifier, confidence) VALUES (?, ?, ?)")
        insertFace = try db.prepare("""
            INSERT INTO face(source_id, idx, x, y, w, h, confidence, quality, roll, yaw, crop_px, print_rev, print_type, print_count, print)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        insertAnimal = try db.prepare("""
            INSERT INTO animal(source_id, idx, label, confidence, x, y, w, h, crop_px, print_rev, print_type, print_count, print)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        deleteLabels = try db.prepare("DELETE FROM label WHERE source_id = ?")
        deleteFaces = try db.prepare("DELETE FROM face WHERE source_id = ?")
        deleteAnimals = try db.prepare("DELETE FROM animal WHERE source_id = ?")
    }

    func add(_ a: Analysis) {
        lock.lock()
        pending.append(a)
        let full = pending.count >= 50
        lock.unlock()
        if full { flush() }
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else { return }
        do {
            try db.exec("BEGIN")
            for a in pending { try write(a) }
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            FileHandle.standardError.write("write error: \(error)\n".data(using: .utf8)!)
        }
        pending.removeAll()
    }

    private func exec(_ stmt: Statement, _ args: [Any?]) throws {
        try stmt.bind(args)
        _ = try stmt.step()
    }

    private func write(_ a: Analysis) throws {
        let id = a.input.sourceID
        for stmt in [deleteLabels, deleteFaces, deleteAnimals] { try exec(stmt, [id]) }
        let p = a.print
        try exec(insertImage, [id, String(id.prefix(1)), a.input.url.path, a.input.size, a.input.mtime, a.width, a.height, runID, isoNow(), a.ms,
                               p?.revision, p?.elementType, p?.count, p?.data, a.labels.count, a.faces.count, a.animals.count, a.error])
        for (identifier, conf) in a.labels { try exec(insertLabel, [id, identifier, conf]) }
        for (i, f) in a.faces.enumerated() {
            try exec(insertFace, [id, i, Double(f.box.minX), Double(f.box.minY), Double(f.box.width), Double(f.box.height),
                                  f.confidence, f.quality, f.roll, f.yaw, f.cropPx, f.print?.revision, f.print?.elementType, f.print?.count, f.print?.data])
        }
        for (i, an) in a.animals.enumerated() {
            try exec(insertAnimal, [id, i, an.label, an.confidence, Double(an.box.minX), Double(an.box.minY), Double(an.box.width), Double(an.box.height),
                                    an.cropPx, an.print?.revision, an.print?.elementType, an.print?.count, an.print?.data])
        }
    }
}

func floats(_ data: Data, type: Int) -> [Float] {
    if type == 2 {
        return data.withUnsafeBytes { Array($0.bindMemory(to: Double.self)).map(Float.init) }
    }
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}
