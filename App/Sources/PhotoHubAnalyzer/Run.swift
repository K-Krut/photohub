import Foundation

final class Flag {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

final class Counter {
    private let lock = NSLock()
    private var next = 0
    private(set) var done = 0
    private(set) var failed = 0
    func take(limit: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard next < limit else { return nil }
        next += 1
        return next - 1
    }
    func finish(failed f: Bool) -> Int {
        lock.lock(); defer { lock.unlock() }
        done += 1
        if f { failed += 1 }
        return done
    }
}

func peakRSSMegabytes() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576
}

func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    if s >= 3600 { return "\(s / 3600) h \((s % 3600) / 60) min" }
    if s >= 60 { return "\(s / 60) min \(s % 60) s" }
    return "\(s) s"
}

private var signalSources: [DispatchSourceSignal] = []

func installStopHandler(_ stop: Flag) {
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        src.setEventHandler {
            if stop.isSet {
                print("forced exit")
                exit(130)
            }
            stop.set()
            print("stopping: finishing shots in progress… (Ctrl-C again to exit immediately)")
        }
        src.resume()
        signalSources.append(src)
    }
}

func runAnalysis(_ args: Arguments) throws {
    let only = args.value("--only")
    let single = args.value("--source")
    let limit = args.int("--limit")
    let workers = args.int("--workers") ?? 4
    if let only, !["archive", "photos"].contains(only) { throw CLIError("--only: archive or photos") }

    let t0 = Date()
    let members = try loadCatalogMembers()
    var inputs: [InputImage] = []
    var missingPhotos = 0
    let wantPhotos = single.map { $0.hasPrefix("p:") } ?? (only != "archive")
    let wantArchive = single.map { $0.hasPrefix("a:") } ?? (only != "photos")
    if wantPhotos {
        let (p, missing) = photosInputs(members)
        inputs += p
        missingPhotos = missing
    }
    if wantArchive { inputs += archiveInputs(members) }
    if let single {
        inputs = inputs.filter { $0.sourceID == single }
        if inputs.isEmpty { throw CLIError("no such shot, or it has no preview: \(single)") }
    }
    print("sources: \(inputs.filter { $0.sourceID.hasPrefix("p:") }.count) from Photos, \(inputs.filter { $0.sourceID.hasPrefix("a:") }.count) from the archive" +
          (missingPhotos > 0 ? ", without library derivatives: \(missingPhotos)" : "") + String(format: " (%.1f s)", Date().timeIntervalSince(t0)))

    let db = try openStore()
    var known: [String: (Int64, Double, Int64, Bool)] = [:]
    try db.rows("SELECT source_id, file_size, file_mtime, coalesce(print_rev, 0), error IS NOT NULL FROM image") {
        known[$0.text(0)] = ($0.int(1), $0.double(2), $0.int(3), $0.int(4) != 0)
    }
    var todo: [InputImage] = []
    var skipped = 0
    for input in inputs {
        if single == nil, let k = known[input.sourceID], k.0 == input.size, abs(k.1 - input.mtime) < 0.001, k.2 == Revisions.print, !k.3 {
            skipped += 1
            continue
        }
        todo.append(input)
    }
    if let limit { todo = Array(todo.prefix(limit)) }
    print("already done: \(skipped), to analyze: \(todo.count), workers: \(workers)")
    print("Vision revisions: classification \(Revisions.classify), feature print \(Revisions.print), faces \(Revisions.faces), face quality \(Revisions.quality), animals \(Revisions.animals)")

    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    try db.run("""
        INSERT INTO run(started, args, os, workers, classify_rev, print_rev, face_rev, quality_rev, animal_rev, planned, status)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'running')
        """, [isoNow(), CommandLine.arguments.dropFirst().joined(separator: " "), osVersion, workers,
              Revisions.classify, Revisions.print, Revisions.faces, Revisions.quality, Revisions.animals, todo.count])
    let runID = try db.scalarInt("SELECT max(id) FROM run")
    let writer = try StoreWriter(db: db, runID: runID)

    let stop = Flag()
    installStopHandler(stop)
    let counter = Counter()
    let start = Date()
    let group = DispatchGroup()
    let total = todo.count
    for _ in 0..<max(1, workers) {
        group.enter()
        let thread = Thread {
            while !stop.isSet, let i = counter.take(limit: total) {
                let a = analyze(todo[i])
                writer.add(a)
                let n = counter.finish(failed: a.error != nil)
                if a.error != nil { print("error: \(a.input.sourceID): \(a.error!)") }
                if n % 200 == 0 || n == total {
                    let elapsed = Date().timeIntervalSince(start)
                    let rate = Double(n) / max(elapsed, 0.001)
                    let eta = Double(total - n) / max(rate, 0.001)
                    print(String(format: "analysis: %d/%d · %.1f photos/s · ~%@ left · memory %.0f MB", n, total, rate, formatDuration(eta), peakRSSMegabytes()))
                }
            }
            group.leave()
        }
        thread.stackSize = 4 << 20
        thread.start()
    }
    group.wait()
    writer.flush()

    let elapsed = Date().timeIntervalSince(start)
    let done = counter.done
    let rate = Double(done) / max(elapsed, 0.001)
    let status = stop.isSet ? "stopped" : "finished"
    try db.run("""
        UPDATE run SET finished=?, done=?, failed=?, skipped=?, seconds=?, images_per_sec=?, peak_rss_mb=?, status=? WHERE id=?
        """, [isoNow(), done, counter.failed, skipped, elapsed, rate, peakRSSMegabytes(), status, runID])
    try? db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
    print(String(format: "%@: %d shots in %@, %.1f photos/s, errors %d, peak memory %.0f MB",
                 stop.isSet ? "stopped" : "done", done, formatDuration(elapsed), rate, counter.failed, peakRSSMegabytes()))
    printStoreSize(db)
}

func printStoreSize(_ db: Database) {
    let images = (try? db.scalarInt("SELECT count(*) FROM image")) ?? 0
    let size = (fileStat(Paths.vision)?.0 ?? 0) + (fileStat(URL(fileURLWithPath: Paths.vision.path + "-wal"))?.0 ?? 0)
    if images > 0 {
        print(String(format: "vision.sqlite: %.1f MB, shots %d, %.1f KB per shot", Double(size) / 1_048_576, images, Double(size) / Double(images) / 1024))
    }
}

func printStats() throws {
    let db = try openStore(write: false)
    print("database: \(Paths.vision.path)")
    try db.rows("SELECT kind, count(*), sum(error IS NOT NULL), sum(n_labels), sum(n_faces), sum(n_animals), avg(ms) FROM image GROUP BY kind") {
        let kind = $0.text(0) == "a" ? "archive" : "Photos"
        print(String(format: "%@: shots %d, errors %d, labels %d, faces %d, animals %d, avg %.0f ms per shot per worker",
                     kind, $0.int(1), $0.int(2), $0.int(3), $0.int(4), $0.int(5), $0.double(6)))
    }
    printStoreSize(db)
    var parts: [(String, Int64)] = []
    for table in ["image", "label", "face", "animal"] {
        if let n = try? db.scalarInt("SELECT sum(pgsize) FROM dbstat WHERE name LIKE ?", [table + "%"]) { parts.append((table, n)) }
    }
    if !parts.isEmpty {
        print("by table: " + parts.map { String(format: "%@ %.1f MB", $0.0, Double($0.1) / 1_048_576) }.joined(separator: ", "))
    }
    print("runs:")
    try db.rows("SELECT id, started, status, planned, done, failed, skipped, seconds, images_per_sec, peak_rss_mb, args FROM run ORDER BY id DESC LIMIT 10") {
        print(String(format: "  #%d %@ %@: %d/%d, errors %d, skipped %d, %.0f s, %.1f photos/s, peak %.0f MB, [%@]",
                     $0.int(0), $0.text(1), $0.text(2), $0.int(4), $0.int(3), $0.int(5), $0.int(6), $0.double(7), $0.double(8), $0.double(9), $0.text(10)))
    }
}
