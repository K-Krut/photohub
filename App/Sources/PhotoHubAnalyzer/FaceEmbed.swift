import Accelerate
import CoreGraphics
import CoreML
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

let arcfaceTemplate: [CGPoint] = [
    CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014), CGPoint(x: 56.0252, y: 71.7366),
    CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041),
]

let defaultFaceModel = "sface-fp16"

struct FaceModelFile {
    let name: String
    let url: URL
}

func faceModelSearchDirs() -> [URL] {
    var dirs: [URL] = []
    if let v = ProcessInfo.processInfo.environment["PHOTOHUB_MODELS"] { dirs.append(URL(fileURLWithPath: v)) }
    if let r = Bundle.module.resourceURL { dirs.append(r) }
    dirs.append(Paths.support.appendingPathComponent("models"))
    return dirs
}

func locateFaceModel(_ spec: String?) throws -> FaceModelFile {
    let value = spec ?? defaultFaceModel
    if value.contains("/") {
        let url = URL(fileURLWithPath: value)
        guard FileManager.default.fileExists(atPath: url.path) else { throw CLIError("no model at \(url.path)") }
        return FaceModelFile(name: url.deletingPathExtension().lastPathComponent, url: url)
    }
    for dir in faceModelSearchDirs() {
        for ext in ["mlmodelc", "mlpackage"] {
            let url = dir.appendingPathComponent("\(value).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return FaceModelFile(name: value, url: url) }
        }
    }
    throw CLIError("model \(value) not found in: " + faceModelSearchDirs().map(\.path).joined(separator: ", "))
}

func directoryDigest(_ url: URL) -> String {
    var files: [URL] = []
    if let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) {
        for case let f as URL in walker where (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(f) }
    }
    var hasher = SHA256()
    let base = url.standardizedFileURL.path
    for f in files.sorted(by: { $0.path < $1.path }) {
        hasher.update(data: Data(f.standardizedFileURL.path.dropFirst(base.count).utf8))
        if let data = try? Data(contentsOf: f, options: .mappedIfSafe) { hasher.update(data: data) }
    }
    return hasher.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
}

func compiledFaceModel(_ file: FaceModelFile) throws -> URL {
    if file.url.pathExtension == "mlmodelc" { return file.url }
    let cache = Paths.support.appendingPathComponent("models/compiled")
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let target = cache.appendingPathComponent("\(file.name)-\(directoryDigest(file.url)).mlmodelc")
    if FileManager.default.fileExists(atPath: target.path) { return target }
    let tmp = try MLModel.compileModel(at: file.url)
    for old in (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
    where old.lastPathComponent.hasPrefix("\(file.name)-") {
        try? FileManager.default.removeItem(at: old)
    }
    try FileManager.default.moveItem(at: tmp, to: target)
    return target
}

final class FaceEmbedder {
    let name: String
    let model: MLModel
    let side: Int
    let inputName: String
    let outputName: String
    let template: [CGPoint]

    init(name: String, compiled: URL, units: MLComputeUnits = .all) throws {
        let config = MLModelConfiguration()
        config.computeUnits = units
        model = try MLModel(contentsOf: compiled, configuration: config)
        self.name = name
        let desc = model.modelDescription
        guard let (inName, inDesc) = desc.inputDescriptionsByName.first(where: { $0.value.type == .image }),
              let constraint = inDesc.imageConstraint else { throw CLIError("model has no image input") }
        inputName = inName
        let s = constraint.pixelsWide
        side = s
        guard let outName = desc.outputDescriptionsByName.keys.sorted().first else { throw CLIError("model has no output") }
        outputName = outName
        let scale = s == 112 ? 1.0 : Double(s) / 112 * 0.9
        let shift = Double(s) / 2 - 56 * scale
        template = arcfaceTemplate.map { CGPoint(x: $0.x * scale + shift, y: $0.y * scale + shift + (s == 112 ? 0 : -4 * scale)) }
    }

    func pixelBuffer(_ image: CGImage, transform: CGAffineTransform, flip: Bool) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.interpolationQuality = .high
        let S = CGFloat(side), H = CGFloat(image.height)
        let fromImage = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H)
        var toContext = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: S)
        if flip { toContext = toContext.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: S, ty: 0)) }
        ctx.concatenate(fromImage.concatenating(transform).concatenating(toContext))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pb
    }

    func embed(_ buffers: [CVPixelBuffer]) throws -> [[Float]] {
        let inputs = try buffers.map { try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: $0)]) }
        let out = try model.predictions(from: MLArrayBatchProvider(array: inputs), options: MLPredictionOptions())
        return (0..<out.count).map { i in
            guard let arr = out.features(at: i).featureValue(for: outputName)?.multiArrayValue else { return [] }
            return (0..<arr.count).map { arr[$0].floatValue }
        }
    }
}

func similarityTransform(from src: [CGPoint], to dst: [CGPoint]) -> (CGAffineTransform, Double) {
    let n = Double(src.count)
    let sx = src.map(\.x).reduce(0, +) / n, sy = src.map(\.y).reduce(0, +) / n
    let dx = dst.map(\.x).reduce(0, +) / n, dy = dst.map(\.y).reduce(0, +) / n
    var num1 = 0.0, num2 = 0.0, den = 0.0
    for (p, q) in zip(src, dst) {
        let px = p.x - sx, py = p.y - sy, qx = q.x - dx, qy = q.y - dy
        num1 += px * qx + py * qy
        num2 += px * qy - py * qx
        den += px * px + py * py
    }
    let a = den > 0 ? num1 / den : 1, b = den > 0 ? num2 / den : 0
    let tx = dx - (a * sx - b * sy), ty = dy - (b * sx + a * sy)
    let t = CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
    var err = 0.0
    for (p, q) in zip(src, dst) {
        let r = p.applying(t)
        err += (r.x - q.x) * (r.x - q.x) + (r.y - q.y) * (r.y - q.y)
    }
    return (t, sqrt(err / n))
}

func centroid(_ pts: [CGPoint]) -> CGPoint {
    let n = CGFloat(max(1, pts.count))
    return CGPoint(x: pts.map(\.x).reduce(0, +) / n, y: pts.map(\.y).reduce(0, +) / n)
}

struct FivePoints {
    let points: [CGPoint]
    let confidence: Float
}

func fivePoints(_ lm: VNFaceLandmarks2D, width: Int, height: Int) -> FivePoints? {
    let size = CGSize(width: width, height: height)
    func pts(_ r: VNFaceLandmarkRegion2D?) -> [CGPoint]? {
        guard let r, r.pointCount > 0 else { return nil }
        return r.pointsInImage(imageSize: size).map { CGPoint(x: $0.x, y: CGFloat(height) - $0.y) }
    }
    guard let le = pts(lm.leftPupil).map(centroid) ?? pts(lm.leftEye).map(centroid),
          let re = pts(lm.rightPupil).map(centroid) ?? pts(lm.rightEye).map(centroid),
          let lips = pts(lm.outerLips), let nose = pts(lm.nose) else { return nil }
    var a = le, b = re
    if a.x > b.x { swap(&a, &b) }
    let ex = b.x - a.x, ey = b.y - a.y
    let len = max(1e-6, hypot(ex, ey))
    let ux = ex / len, uy = ey / len
    let down = CGPoint(x: -uy, y: ux)
    let proj = { (p: CGPoint) in p.x * ux + p.y * uy }
    let mouthLeft = lips.min { proj($0) < proj($1) }!
    let mouthRight = lips.max { proj($0) < proj($1) }!
    let depth = { (p: CGPoint) in p.x * down.x + p.y * down.y }
    let tip = nose.max { depth($0) < depth($1) }!
    let noseCenter = centroid(nose)
    let noseTip = CGPoint(x: (tip.x + noseCenter.x) / 2, y: (tip.y + noseCenter.y) / 2)
    return FivePoints(points: [a, b, noseTip, mouthLeft, mouthRight], confidence: lm.confidence)
}

struct StoredFace {
    let id: Int64
    let sourceID: String
    let idx: Int
    let box: CGRect
    let roll: Double?
    let yaw: Double?
}

struct FaceEmbedding {
    let face: StoredFace
    let points: [CGPoint]
    let landmarkConfidence: Float
    let alignError: Double
    let vector: [Float]
    let flipVector: [Float]
}

func embedImage(file: URL, faces: [StoredFace], embedder: FaceEmbedder, dump: URL?) -> (results: [FaceEmbedding], failed: Int, error: String?) {
    var results: [FaceEmbedding] = []
    var failed = 0
    var errorText: String?
    autoreleasepool {
        guard let image = loadImage(file) else {
            errorText = "cannot read file"
            return
        }
        let observations = faces.map {
            VNFaceObservation(requestRevision: Revisions.faces, boundingBox: $0.box,
                              roll: $0.roll.map { NSNumber(value: $0) }, yaw: $0.yaw.map { NSNumber(value: $0) }, pitch: nil)
        }
        let request = VNDetectFaceLandmarksRequest()
        request.inputFaceObservations = observations
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            errorText = "vision: \(error.localizedDescription)"
            return
        }
        let observed = request.results ?? []
        var buffers: [CVPixelBuffer] = []
        var pending: [(StoredFace, FivePoints, Double)] = []
        for (i, face) in faces.enumerated() {
            let obs = observed.first { $0.uuid == observations[i].uuid } ?? (observed.count == faces.count ? observed[i] : nil)
            guard let lm = obs?.landmarks, let five = fivePoints(lm, width: image.width, height: image.height) else {
                failed += 1
                continue
            }
            let (t, err) = similarityTransform(from: five.points, to: embedder.template)
            guard let pb = embedder.pixelBuffer(image, transform: t, flip: false),
                  let pbFlip = embedder.pixelBuffer(image, transform: t, flip: true) else {
                failed += 1
                continue
            }
            buffers.append(pb)
            buffers.append(pbFlip)
            pending.append((face, five, err))
            if let dump { writePNG(pb, to: dump.appendingPathComponent("\(face.id).png")) }
        }
        guard !buffers.isEmpty else { return }
        do {
            let vectors = try embedder.embed(buffers)
            for (k, p) in pending.enumerated() {
                results.append(FaceEmbedding(face: p.0, points: p.1.points, landmarkConfidence: p.1.confidence, alignError: p.2,
                                             vector: vectors[2 * k], flipVector: vectors[2 * k + 1]))
            }
        } catch {
            errorText = "core ml: \(error.localizedDescription)"
            failed += pending.count
        }
    }
    return (results, failed, errorText)
}

func writePNG(_ pb: CVPixelBuffer, to url: URL) {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb),
                              bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
          let img = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

func floatData(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }

func ensureEmbeddingTables(_ db: Database) throws {
    try db.exec("""
        CREATE TABLE IF NOT EXISTS face_embedding (face_id INTEGER, model TEXT, source_id TEXT, idx INTEGER,
            dim INTEGER, vector BLOB, vector_flip BLOB, points BLOB, landmark_confidence REAL, align_error REAL,
            created TEXT, PRIMARY KEY (face_id, model));
        CREATE INDEX IF NOT EXISTS face_embedding_source ON face_embedding(source_id);
        CREATE TABLE IF NOT EXISTS face_embedding_fail (face_id INTEGER, model TEXT, reason TEXT, PRIMARY KEY (face_id, model)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS face_suggestion (source_id TEXT, face_id INTEGER, idx INTEGER, name TEXT, score REAL,
            model TEXT, classifier TEXT, threshold REAL, created TEXT, PRIMARY KEY (face_id, model)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS face_suggestion_name ON face_suggestion(name, score);
        """)
    try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", ["face_embedding",
        "vector, vector_flip: float32 as returned by the model (not normalized); points: 5 float32 x,y points in image pixels, origin at top left: left eye, right eye, nose, left mouth corner, right mouth corner; similarity alignment to the ArcFace 112×112 template"])
}

func runFacesEmbed(_ args: Arguments) throws {
    let file = try locateFaceModel(args.value("--model"))
    let workers = max(1, args.int("--workers") ?? 4)
    let limit = args.int("--limit")
    let dump = args.value("--dump").map { URL(fileURLWithPath: $0) }
    if let dump { try FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true) }
    let units: MLComputeUnits = args.value("--units") == "cpu" ? .cpuOnly : args.value("--units") == "gpu" ? .cpuAndGPU : .all
    let t0 = Date()
    let compiled = try compiledFaceModel(file)
    let probe = try FaceEmbedder(name: file.name, compiled: compiled, units: units)
    print(String(format: "model %@: input %d×%d, %@ (%.1f s to load)", file.name, probe.side, probe.side, file.url.path, Date().timeIntervalSince(t0)))

    let db = try openStore()
    try ensureEmbeddingTables(db)
    if args.flags.contains("--redo") {
        try db.run("DELETE FROM face_embedding WHERE model = ?", [file.name])
        try db.run("DELETE FROM face_embedding_fail WHERE model = ?", [file.name])
    }
    try db.run("DELETE FROM face_embedding WHERE model = ? AND face_id NOT IN (SELECT id FROM face)", [file.name])
    var byImage: [String: (file: String, faces: [StoredFace])] = [:]
    var order: [String] = []
    var where_ = ""
    if let only = args.value("--only") { where_ = only == "photos" ? " AND f.source_id LIKE 'p:%'" : " AND f.source_id LIKE 'a:%'" }
    try db.rows("""
        SELECT f.id, f.source_id, f.idx, f.x, f.y, f.w, f.h, f.roll, f.yaw, i.file
        FROM face f JOIN image i ON i.source_id = f.source_id
        WHERE f.id NOT IN (SELECT face_id FROM face_embedding WHERE model = ?)
          AND f.id NOT IN (SELECT face_id FROM face_embedding_fail WHERE model = ?)\(where_)
        ORDER BY f.source_id, f.idx
        """, [file.name, file.name]) {
        let face = StoredFace(id: $0.int(0), sourceID: $0.text(1), idx: Int($0.int(2)),
                              box: CGRect(x: $0.double(3), y: $0.double(4), width: $0.double(5), height: $0.double(6)),
                              roll: $0.isNull(7) ? nil : $0.double(7), yaw: $0.isNull(8) ? nil : $0.double(8))
        if byImage[face.sourceID] == nil { order.append(face.sourceID); byImage[face.sourceID] = ($0.text(9), []) }
        byImage[face.sourceID]!.faces.append(face)
    }
    if let limit { order = Array(order.prefix(limit)) }
    let totalFaces = order.map { byImage[$0]!.faces.count }.reduce(0, +)
    print("shots with faces to process: \(order.count), faces: \(totalFaces), workers: \(workers)")
    guard !order.isEmpty else { return }

    let insert = try db.prepare("""
        INSERT OR REPLACE INTO face_embedding(face_id, model, source_id, idx, dim, vector, vector_flip, points, landmark_confidence, align_error, created)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """)
    let insertFail = try db.prepare("INSERT OR REPLACE INTO face_embedding_fail(face_id, model, reason) VALUES (?, ?, ?)")
    let lock = NSLock()
    var buffer: [(String, [StoredFace], [FaceEmbedding], String?)] = []
    func flush() {
        guard !buffer.isEmpty else { return }
        do {
            try db.exec("BEGIN")
            let now = isoNow()
            for (_, faces, results, err) in buffer {
                let done = Set(results.map(\.face.id))
                for r in results {
                    try insert.bind([r.face.id, file.name, r.face.sourceID, r.face.idx, r.vector.count, floatData(r.vector), floatData(r.flipVector),
                                     floatData(r.points.flatMap { [Float($0.x), Float($0.y)] }), r.landmarkConfidence, r.alignError, now])
                    _ = try insert.step()
                }
                for f in faces where !done.contains(f.id) {
                    try insertFail.bind([f.id, file.name, err ?? "no face landmarks"])
                    _ = try insertFail.step()
                }
            }
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            FileHandle.standardError.write("write error: \(error)\n".data(using: .utf8)!)
        }
        buffer.removeAll()
    }

    let stop = Flag()
    installStopHandler(stop)
    let counter = Counter()
    var facesDone = 0, facesFailed = 0
    let start = Date()
    let group = DispatchGroup()
    let total = order.count
    for _ in 0..<workers {
        group.enter()
        let thread = Thread {
            defer { group.leave() }
            guard let embedder = try? FaceEmbedder(name: file.name, compiled: compiled, units: units) else { return }
            while !stop.isSet, let i = counter.take(limit: total) {
                let id = order[i]
                let entry = byImage[id]!
                let r = embedImage(file: URL(fileURLWithPath: entry.file), faces: entry.faces, embedder: embedder, dump: dump)
                lock.lock()
                buffer.append((id, entry.faces, r.results, r.error))
                facesDone += r.results.count
                facesFailed += entry.faces.count - r.results.count
                if buffer.count >= 100 { flush() }
                let fd = facesDone, ff = facesFailed
                lock.unlock()
                if let e = r.error { print("error: \(id): \(e)") }
                let n = counter.finish(failed: r.error != nil)
                if n % 500 == 0 || n == total {
                    let elapsed = Date().timeIntervalSince(start)
                    print(String(format: "faces: shots %d/%d · faces %d, no landmarks %d · %.1f faces/s · memory %.0f MB",
                                 n, total, fd, ff, Double(fd + ff) / max(elapsed, 0.001), peakRSSMegabytes()))
                }
            }
        }
        thread.stackSize = 4 << 20
        thread.start()
    }
    group.wait()
    lock.lock()
    flush()
    lock.unlock()
    let elapsed = Date().timeIntervalSince(start)
    try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", ["face_model:\(file.name)",
        "\(file.url.lastPathComponent); input \(probe.side)×\(probe.side); \(probe.model.modelDescription.metadata[.license] as? String ?? "")"])
    try? db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
    print(String(format: "%@: faces %d, no face landmarks %d, %@, %.1f faces/s, %.1f shots/s, peak memory %.0f MB",
                 stop.isSet ? "stopped" : "done", facesDone, facesFailed, formatDuration(elapsed),
                 Double(facesDone + facesFailed) / max(elapsed, 0.001), Double(counter.done) / max(elapsed, 0.001), peakRSSMegabytes()))
}
