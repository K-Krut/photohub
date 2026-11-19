import Accelerate
import Foundation

struct PhotosFace {
    let uuid: String
    let person: String?
    let x: Double
    let y: Double
    let size: Double
    let type: Int
    let orientation: Int
    let day: Int
}

struct OurBox {
    let faceID: Int64
    let sourceID: String
    let x: Double, y: Double, w: Double, h: Double
    let width: Int, height: Int
    let cropPx: Int
    let quality: Double
    let vector: [Float]
    let imageVector: [Float]?

    var center: (Double, Double) { (x + w / 2, y + h / 2) }
    var sideNorm: Double { max(w * Double(width), h * Double(height)) / Double(max(width, height)) }
}

struct Sample {
    let key: String
    let label: String
    let vector: [Float]
    let group: String
    let cropPx: Int
}

let transforms: [(String, (Double, Double) -> (Double, Double))] = [
    ("x, y", { ($0, $1) }),
    ("x, 1−y", { ($0, 1 - $1) }),
    ("1−x, y", { (1 - $0, $1) }),
    ("1−x, 1−y", { (1 - $0, 1 - $1) }),
    ("y, x", { ($1, $0) }),
    ("1−y, x", { (1 - $1, $0) }),
    ("y, 1−x", { ($1, 1 - $0) }),
    ("1−y, 1−x", { (1 - $1, 1 - $0) }),
]

func normalized(_ v: [Float]) -> [Float] {
    var n: Float = 0
    vDSP_svesq(v, 1, &n, vDSP_Length(v.count))
    let s = n > 0 ? 1 / sqrt(n) : 0
    return v.map { $0 * s }
}

struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func shuffle<T>(_ a: inout [T]) {
        guard a.count > 1 else { return }
        for i in stride(from: a.count - 1, to: 0, by: -1) {
            let j = Int(next() % UInt64(i + 1))
            a.swapAt(i, j)
        }
    }
}

func copyPhotosDatabase() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("photohub-analyzer-\(getpid())")
    try? FileManager.default.removeItem(at: dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for suffix in ["", "-wal", "-shm"] {
        let src = URL(fileURLWithPath: Paths.photosDatabase.path + suffix)
        if FileManager.default.fileExists(atPath: src.path) {
            try FileManager.default.copyItem(at: src, to: dir.appendingPathComponent("Photos.sqlite" + suffix))
        }
    }
    return dir
}

func loadPhotosFaces() throws -> [PhotosFace] {
    let dir = try copyPhotosDatabase()
    defer { try? FileManager.default.removeItem(at: dir) }
    let db = try Database(path: dir.appendingPathComponent("Photos.sqlite").path)
    var persons: [Int64: (name: String, merge: Int64?)] = [:]
    try db.rows("SELECT Z_PK, coalesce(ZDISPLAYNAME, ''), coalesce(ZFULLNAME, ''), ZMERGETARGETPERSON FROM ZPERSON") {
        let display = $0.text(1), full = $0.text(2)
        persons[$0.int(0)] = (display.isEmpty ? full : display, $0.isNull(3) ? nil : $0.int(3))
    }
    func resolve(_ pk: Int64) -> String? {
        var cur = pk
        for _ in 0..<32 {
            guard let p = persons[cur] else { return nil }
            guard let next = p.merge, next != cur else { return p.name.isEmpty ? nil : p.name }
            cur = next
        }
        return nil
    }
    var out: [PhotosFace] = []
    try db.rows("""
        SELECT a.ZUUID, f.ZPERSONFORFACE, f.ZCENTERX, f.ZCENTERY, f.ZSIZE, f.ZDETECTIONTYPE, a.ZORIENTATION, a.ZDATECREATED
        FROM ZDETECTEDFACE f JOIN ZASSET a ON a.Z_PK = f.ZASSETFORFACE
        WHERE f.ZCENTERX > 0 AND coalesce(f.ZHIDDEN, 0) = 0 AND a.ZTRASHEDSTATE = 0
        """) {
        let person = $0.isNull(1) ? nil : resolve($0.int(1))
        let day = Int(($0.double(7) + 978_307_200) / 86400)
        out.append(PhotosFace(uuid: $0.text(0), person: person, x: $0.double(2), y: $0.double(3), size: $0.double(4),
                              type: Int($0.int(5)), orientation: Int($0.int(6)), day: day))
    }
    return out
}

func loadOurBoxes(_ db: Database, table: String) throws -> [String: [OurBox]] {
    var out: [String: [OurBox]] = [:]
    try db.rows("""
        SELECT t.source_id, t.x, t.y, t.w, t.h, i.width, i.height, t.crop_px, \(table == "face" ? "coalesce(t.quality, -1)" : "t.confidence"),
               t.print, t.print_type, i.print, i.print_type, t.id
        FROM \(table) t JOIN image i ON i.source_id = t.source_id
        WHERE t.source_id LIKE 'p:%' AND t.print IS NOT NULL AND t.print_rev = ?
        ORDER BY t.source_id, t.idx
        """, [Revisions.print]) {
        let id = $0.text(0)
        let box = OurBox(faceID: $0.int(13), sourceID: id, x: $0.double(1), y: $0.double(2), w: $0.double(3), h: $0.double(4),
                         width: Int($0.int(5)), height: Int($0.int(6)), cropPx: Int($0.int(7)), quality: $0.double(8),
                         vector: normalized(floats($0.blob(9), type: Int($0.int(10)))),
                         imageVector: $0.isNull(11) ? nil : normalized(floats($0.blob(11), type: Int($0.int(12)))))
        out[String(id.dropFirst(2)), default: []].append(box)
    }
    return out
}

func matchFaces(_ ours: [OurBox], _ theirs: [PhotosFace], transform: (Double, Double) -> (Double, Double)) -> [(Int, Int, Double)] {
    var pairs: [(Int, Int, Double)] = []
    for (i, o) in ours.enumerated() {
        let W = Double(o.width), H = Double(o.height), M = max(W, H)
        let (ox, oy) = o.center
        for (j, t) in theirs.enumerated() {
            let (tx, ty) = transform(t.x, t.y)
            let d = hypot((tx - ox) * W, (ty - oy) * H) / M
            if d < 0.5 * o.sideNorm + 0.01 { pairs.append((i, j, d)) }
        }
    }
    pairs.sort { $0.2 < $1.2 }
    var usedO = Set<Int>(), usedT = Set<Int>(), out: [(Int, Int, Double)] = []
    for p in pairs where !usedO.contains(p.0) && !usedT.contains(p.1) {
        usedO.insert(p.0); usedT.insert(p.1); out.append(p)
    }
    return out
}

func matchAnimals(_ ours: [OurBox], _ theirs: [PhotosFace], transform: (Double, Double) -> (Double, Double)) -> [(Int, Int)] {
    var out: [(Int, Int)] = []
    var used = Set<Int>()
    for (j, t) in theirs.enumerated() {
        let (tx, ty) = transform(t.x, t.y)
        var best: (Int, Double)?
        for (i, o) in ours.enumerated() where !used.contains(i) {
            let inside = tx >= o.x && tx <= o.x + o.w && ty >= o.y && ty <= o.y + o.h
            guard inside else { continue }
            let area = o.w * o.h
            if best == nil || area < best!.1 { best = (i, area) }
        }
        if let b = best { used.insert(b.0); out.append((b.0, j)) }
    }
    return out
}

struct Prediction {
    let label: String
    let score: Float
}

func gram(_ a: [[Float]], _ b: [[Float]], dim: Int) -> [Float] {
    let A = a.flatMap { $0 }, B = b.flatMap { $0 }
    var C = [Float](repeating: 0, count: a.count * b.count)
    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(a.count), Int32(b.count), Int32(dim), 1, A, Int32(dim), B, Int32(dim), 0, &C, Int32(b.count))
    return C
}

func knnPredict(train: [Sample], test: [[Float]], k: Int) -> [Prediction] {
    guard let dim = train.first?.vector.count else { return [] }
    let S = gram(test, train.map(\.vector), dim: dim)
    let n = train.count
    return (0..<test.count).map { r in
        let row = Array(S[r * n..<(r + 1) * n])
        let idx = Array(row.indices.sorted { row[$0] > row[$1] }.prefix(k))
        var votes: [String: Float] = [:], best: [String: Float] = [:]
        for i in idx {
            votes[train[i].label, default: 0] += row[i]
            best[train[i].label] = max(best[train[i].label] ?? -1, row[i])
        }
        let label = votes.max { $0.value < $1.value }!.key
        return Prediction(label: label, score: best[label]!)
    }
}

func centroidPredict(train: [Sample], test: [[Float]]) -> [Prediction] {
    guard let dim = train.first?.vector.count else { return [] }
    var sums: [String: [Float]] = [:]
    for s in train {
        var acc = sums[s.label] ?? [Float](repeating: 0, count: dim)
        vDSP_vadd(acc, 1, s.vector, 1, &acc, 1, vDSP_Length(dim))
        sums[s.label] = acc
    }
    let labels = sums.keys.sorted()
    let C = labels.map { normalized(sums[$0]!) }
    let S = gram(test, C, dim: dim)
    return (0..<test.count).map { r in
        let row = Array(S[r * labels.count..<(r + 1) * labels.count])
        let j = row.indices.max { row[$0] < row[$1] }!
        return Prediction(label: labels[j], score: row[j])
    }
}

func linearPredict(train: [Sample], test: [[Float]], iterations: Int = 300) -> [Prediction] {
    guard let dim = train.first?.vector.count else { return [] }
    let labels = Array(Set(train.map(\.label))).sorted()
    let C = labels.count, N = train.count, D = dim + 1
    let index = Dictionary(uniqueKeysWithValues: labels.enumerated().map { ($1, $0) })
    var mean = [Float](repeating: 0, count: dim), std = [Float](repeating: 0, count: dim)
    for s in train { for d in 0..<dim { mean[d] += s.vector[d] } }
    for d in 0..<dim { mean[d] /= Float(N) }
    for s in train { for d in 0..<dim { let v = s.vector[d] - mean[d]; std[d] += v * v } }
    for d in 0..<dim { std[d] = max(sqrt(std[d] / Float(N)), 1e-6) }
    func prep(_ v: [Float]) -> [Float] { (0..<dim).map { (v[$0] - mean[$0]) / std[$0] } + [1] }
    let X = train.flatMap { prep($0.vector) }
    var counts = [Float](repeating: 0, count: C)
    for s in train { counts[index[s.label]!] += 1 }
    let weights = train.map { Float(N) / (Float(C) * counts[index[$0.label]!]) }
    let wsum = weights.reduce(0, +)
    var W = [Float](repeating: 0, count: D * C)
    var m = W, v = W
    let lr: Float = 0.01, b1: Float = 0.9, b2: Float = 0.999, lambda: Float = 1e-3
    var logits = [Float](repeating: 0, count: N * C)
    var grad = W
    for it in 1...iterations {
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(N), Int32(C), Int32(D), 1, X, Int32(D), W, Int32(C), 0, &logits, Int32(C))
        for i in 0..<N {
            let base = i * C
            var mx = -Float.infinity
            for c in 0..<C { mx = max(mx, logits[base + c]) }
            var z: Float = 0
            for c in 0..<C { logits[base + c] = exp(logits[base + c] - mx); z += logits[base + c] }
            let y = index[train[i].label]!
            for c in 0..<C { logits[base + c] = (logits[base + c] / z - (c == y ? 1 : 0)) * weights[i] / wsum }
        }
        cblas_sgemm(CblasRowMajor, CblasTrans, CblasNoTrans, Int32(D), Int32(C), Int32(N), 1, X, Int32(D), logits, Int32(C), 0, &grad, Int32(C))
        let c1 = 1 - pow(b1, Float(it)), c2 = 1 - pow(b2, Float(it))
        for k in 0..<(D * C) {
            let g = grad[k] + lambda * W[k]
            m[k] = b1 * m[k] + (1 - b1) * g
            v[k] = b2 * v[k] + (1 - b2) * g * g
            W[k] -= lr * (m[k] / c1) / (sqrt(v[k] / c2) + 1e-8)
        }
    }
    let T = test.flatMap { prep($0) }
    var out = [Float](repeating: 0, count: test.count * C)
    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(test.count), Int32(C), Int32(D), 1, T, Int32(D), W, Int32(C), 0, &out, Int32(C))
    return (0..<test.count).map { r in
        let row = Array(out[r * C..<(r + 1) * C])
        let mx = row.max()!
        let e = row.map { exp($0 - mx) }
        let z = e.reduce(0, +)
        let j = row.indices.max { row[$0] < row[$1] }!
        return Prediction(label: labels[j], score: e[j] / z)
    }
}

func pct(_ x: Double) -> String { String(format: "%5.1f%%", x * 100) }

func split(_ samples: [Sample], byGroup: Bool, seed: UInt64) -> (train: [Sample], test: [Sample]) {
    var rng = SplitMix(state: seed)
    var train: [Sample] = [], test: [Sample] = []
    let byLabel = Dictionary(grouping: samples, by: \.label)
    for label in byLabel.keys.sorted() {
        let items = byLabel[label]!.sorted { ($0.group, $0.key) < ($1.group, $1.key) }
        var groups: [[Sample]]
        if byGroup {
            let g = Dictionary(grouping: items, by: \.group)
            groups = g.keys.sorted().map { g[$0]!.sorted { $0.key < $1.key } }
        } else {
            groups = items.map { [$0] }
        }
        rng.shuffle(&groups)
        let target = max(1, Int((Double(items.count) * 0.2).rounded()))
        var taken = 0
        var labelTrain: [Sample] = [], labelTest: [Sample] = []
        for g in groups {
            if taken < target && taken + g.count <= 2 * target {
                labelTest += g
                taken += g.count
            } else {
                labelTrain += g
            }
        }
        if labelTest.isEmpty, groups.count > 1, let k = groups.indices.min(by: { groups[$0].count < groups[$1].count }) {
            labelTest = groups[k]
            labelTrain = groups.enumerated().filter { $0.offset != k }.flatMap { $0.element }
        }
        if labelTrain.isEmpty { swap(&labelTrain, &labelTest) }
        train += labelTrain
        test += labelTest
    }
    return (train, test)
}

func evaluate(title: String, known: [Sample], unknown: [Sample], minCount: Int, seed: UInt64) {
    let counts = Dictionary(grouping: known, by: \.label).mapValues(\.count)
    let kept = Set(counts.filter { $0.value >= minCount }.keys)
    let samples = known.filter { kept.contains($0.label) }
    let others = unknown + known.filter { !kept.contains($0.label) }
    print("\n=== \(title) ===")
    print("classes with ≥ \(minCount) samples: \(kept.count), samples: \(samples.count); strangers for the rejection check: \(others.count)")
    guard kept.count >= 2 else {
        print("too few classes to evaluate")
        return
    }
    let largest = counts.filter { kept.contains($0.key) }.values.max() ?? 0
    print("share of the most frequent class (always-guess-it baseline): \(pct(Double(largest) / Double(samples.count)))")
    for byGroup in [false, true] {
        let (train, test) = split(samples, byGroup: byGroup, seed: seed)
        let testVectors = test.map(\.vector)
        let otherVectors = others.map(\.vector)
        print("\n— split \(byGroup ? "by day (all of a person's shots from one day go entirely to train or to test)" : "random 80/20 per class"): train \(train.count), test \(test.count)")
        let classifiers: [(String, () -> ([Prediction], [Prediction]))] = [
            ("1-NN", { (knnPredict(train: train, test: testVectors, k: 1), knnPredict(train: train, test: otherVectors, k: 1)) }),
            ("5-NN", { (knnPredict(train: train, test: testVectors, k: 5), knnPredict(train: train, test: otherVectors, k: 5)) }),
            ("centroid", { (centroidPredict(train: train, test: testVectors), centroidPredict(train: train, test: otherVectors)) }),
            ("linear", {
                let all = linearPredict(train: train, test: testVectors + otherVectors)
                return (Array(all.prefix(testVectors.count)), Array(all.dropFirst(testVectors.count)))
            }),
        ]
        var perClass: [String: [String: (Double, Double)]] = [:]
        for (name, run) in classifiers {
            let t0 = Date()
            let (pred, otherPred) = run()
            let ms = Date().timeIntervalSince(t0) * 1000
            let correct = zip(pred, test).filter { $0.label == $1.label }.count
            var recalls: [Double] = [], precisions: [Double] = []
            for label in kept.sorted() {
                let truth = test.indices.filter { test[$0].label == label }
                let predicted = test.indices.filter { pred[$0].label == label }
                let tp = truth.filter { pred[$0].label == label }.count
                let r = truth.isEmpty ? Double.nan : Double(tp) / Double(truth.count)
                let p = predicted.isEmpty ? Double.nan : Double(tp) / Double(predicted.count)
                if !r.isNaN { recalls.append(r) }
                if !p.isNaN { precisions.append(p) }
                perClass[label, default: [:]][name] = (p, r)
            }
            let macroR = recalls.reduce(0, +) / Double(max(1, recalls.count))
            let macroP = precisions.reduce(0, +) / Double(max(1, precisions.count))
            print(String(format: "%@: accuracy %@ (%d/%d), macro recall %@, macro precision %@, %.0f ms",
                         name.padding(toLength: 9, withPad: " ", startingAt: 0), pct(Double(correct) / Double(max(1, test.count))), correct, test.count, pct(macroR), pct(macroP), ms))
            let scores = Set(pred.map(\.score) + otherPred.map(\.score)).sorted()
            guard !scores.isEmpty else { continue }
            var rows: [String] = []
            var marks: [String] = []
            var reached = Set<Double>()
            let quantiles = stride(from: 0.0, through: 0.9, by: 0.1).map { q in pred.map(\.score).sorted()[min(pred.count - 1, Int(Double(pred.count) * q))] }
            var shown = Set<String>()
            for t in quantiles where shown.insert(String(format: "%.3f", t)).inserted {
                let accepted = pred.indices.filter { pred[$0].score >= t }
                let ok = accepted.filter { pred[$0].label == test[$0].label }.count
                let fa = otherPred.filter { $0.score >= t }.count
                rows.append(String(format: "    threshold %.3f: coverage %@, correct among accepted %@, strangers accepted %@", t, pct(Double(accepted.count) / Double(test.count)),
                                   pct(accepted.isEmpty ? 0 : Double(ok) / Double(accepted.count)), pct(otherPred.isEmpty ? 0 : Double(fa) / Double(otherPred.count))))
            }
            for target in [0.9, 0.95, 0.98] {
                for t in scores {
                    let accepted = pred.indices.filter { pred[$0].score >= t }
                    guard accepted.count >= 5 else { break }
                    let ok = accepted.filter { pred[$0].label == test[$0].label }.count
                    if Double(ok) / Double(accepted.count) >= target, !reached.contains(target) {
                        reached.insert(target)
                        let fa = otherPred.filter { $0.score >= t }.count
                        marks.append(String(format: "    precision ≥ %.0f%% at threshold %.3f: coverage %@, strangers accepted %@", target * 100, t,
                                            pct(Double(accepted.count) / Double(test.count)), pct(otherPred.isEmpty ? 0 : Double(fa) / Double(otherPred.count))))
                        break
                    }
                }
                if !reached.contains(target) { marks.append(String(format: "    precision ≥ %.0f%% unreachable", target * 100)) }
            }
            if !otherPred.isEmpty {
                let otherScores = otherPred.map(\.score).sorted(by: >)
                for far in [0.05, 0.02, 0.01] {
                    let k = Int(Double(otherScores.count) * far)
                    let t = k < otherScores.count ? otherScores[k].nextUp : -Float.infinity
                    let accepted = pred.indices.filter { pred[$0].score >= t }
                    let ok = accepted.filter { pred[$0].label == test[$0].label }.count
                    let fa = otherPred.filter { $0.score >= t }.count
                    marks.append(String(format: "    strangers accepted ≤ %.0f%% (%@) at threshold %.3f: coverage %@, correct among accepted %@", far * 100,
                                        pct(Double(fa) / Double(otherPred.count)), t, pct(Double(accepted.count) / Double(test.count)),
                                        pct(accepted.isEmpty ? 0 : Double(ok) / Double(accepted.count))))
                }
            }
            rows.forEach { print($0) }
            marks.forEach { print($0) }
            if !byGroup {
                var buckets: [String: (Int, Int)] = [:]
                for (i, s) in test.enumerated() {
                    let b = s.cropPx < 64 ? "< 64 px" : s.cropPx < 128 ? "64–127 px" : s.cropPx < 256 ? "128–255 px" : "≥ 256 px"
                    var v = buckets[b] ?? (0, 0)
                    v.1 += 1
                    if pred[i].label == s.label { v.0 += 1 }
                    buckets[b] = v
                }
                print("    by crop size: " + ["< 64 px", "64–127 px", "128–255 px", "≥ 256 px"].compactMap { b in
                    buckets[b].map { "\(b) \(pct(Double($0.0) / Double($0.1))) (\($0.1))" }
                }.joined(separator: " · "))
            }
        }
        print("  per class (precision / recall):")
        print("    " + "class".padding(toLength: 22, withPad: " ", startingAt: 0) + "train  test   " + classifiers.map { $0.0.padding(toLength: 15, withPad: " ", startingAt: 0) }.joined())
        for label in kept.sorted(by: { counts[$0]! > counts[$1]! }) {
            let tr = train.filter { $0.label == label }.count, te = test.filter { $0.label == label }.count
            let cells = classifiers.map { c -> String in
                guard let (p, r) = perClass[label]?[c.0] else { return "".padding(toLength: 15, withPad: " ", startingAt: 0) }
                let ps = p.isNaN ? "  —" : String(format: "%3.0f", p * 100), rs = r.isNaN ? "—  " : String(format: "%-3.0f", r * 100)
                return "\(ps) / \(rs)".padding(toLength: 15, withPad: " ", startingAt: 0)
            }.joined()
            print("    " + String(label.prefix(22)).padding(toLength: 22, withPad: " ", startingAt: 0) + String(format: " %4d  %4d   ", tr, te) + cells)
        }
    }
}

struct PhotosMatch {
    let humans: [String: [PhotosFace]]
    let pets: [String: [PhotosFace]]
    let ourFaces: [String: [OurBox]]
    let ourAnimals: [String: [OurBox]]
    let chosen: [Int: Int]
    let defaultTransform: Int
    let humanPairs: [(index: Int, box: OurBox, face: PhotosFace)]
}

func matchPhotos(_ db: Database, verbose: Bool) throws -> PhotosMatch {
    let t0 = Date()
    let photosFaces = try loadPhotosFaces()
    let ourFaces = try loadOurBoxes(db, table: "face")
    let ourAnimals = try loadOurBoxes(db, table: "animal")
    let analysed = Set(try { () throws -> [String] in
        var ids: [String] = []
        try db.rows("SELECT substr(source_id, 3) FROM image WHERE source_id LIKE 'p:%' AND error IS NULL") { ids.append($0.text(0)) }
        return ids
    }())
    let humans = Dictionary(grouping: photosFaces.filter { $0.type == 1 && analysed.contains($0.uuid) }, by: \.uuid)
    let pets = Dictionary(grouping: photosFaces.filter { ($0.type == 3 || $0.type == 4) && analysed.contains($0.uuid) }, by: \.uuid)
    if verbose {
        print(String(format: "Photos: %d human faces, %d pet faces in %d analyzed shots; ours: %d faces, %d animals (%.1f s)",
                     humans.values.map(\.count).reduce(0, +), pets.values.map(\.count).reduce(0, +), analysed.count,
                     ourFaces.values.map(\.count).reduce(0, +), ourAnimals.values.map(\.count).reduce(0, +), Date().timeIntervalSince(t0)))
        print("\ncoordinate matching (share of Photos faces paired with a Vision face), by shot orientation:")
    }
    let orientations = Set(photosFaces.map(\.orientation)).sorted()
    var chosen: [Int: Int] = [:]
    for o in orientations {
        let assets = humans.filter { $0.value.first?.orientation == o }
        let total = assets.values.map(\.count).reduce(0, +)
        guard total > 0 else { continue }
        var results: [(Int, Int)] = []
        for (k, t) in transforms.enumerated() {
            var matched = 0
            for (uuid, theirs) in assets { matched += matchFaces(ourFaces[uuid] ?? [], theirs, transform: t.1).count }
            results.append((k, matched))
        }
        let best = results.max { $0.1 < $1.1 }!
        chosen[o] = best.0
        if verbose {
            print("  orientation \(o): faces \(total); " + results.map { "(\(transforms[$0.0].0)) \(pct(Double($0.1) / Double(total)))" }.joined(separator: " "))
        }
    }
    let defaultTransform = chosen.max { a, b in
        humans.values.filter { $0.first?.orientation == a.key }.count < humans.values.filter { $0.first?.orientation == b.key }.count
    }?.value ?? 1
    var pairs: [(index: Int, box: OurBox, face: PhotosFace)] = []
    for uuid in humans.keys.sorted() {
        let theirs = humans[uuid]!
        let ours = ourFaces[uuid] ?? []
        let t = transforms[chosen[theirs[0].orientation] ?? defaultTransform].1
        for (i, j, _) in matchFaces(ours, theirs, transform: t) { pairs.append((i, ours[i], theirs[j])) }
    }
    return PhotosMatch(humans: humans, pets: pets, ourFaces: ourFaces, ourAnimals: ourAnimals, chosen: chosen,
                       defaultTransform: defaultTransform, humanPairs: pairs)
}

func loadFaceEmbeddings(_ db: Database, model: String, flip: Bool, where condition: String = "") throws -> [Int64: [Float]] {
    guard db.tableExists("face_embedding") else { throw CLIError("no face_embedding table — run faces-embed --model \(model) first") }
    var out: [Int64: [Float]] = [:]
    try db.rows("SELECT e.face_id, e.vector, e.vector_flip FROM face_embedding e JOIN face f ON f.id = e.face_id WHERE e.model = ?\(condition)", [model]) {
        let v = normalized(floats($0.blob(1), type: 1))
        if flip, !$0.isNull(2) {
            let f = normalized(floats($0.blob(2), type: 1))
            out[$0.int(0)] = normalized(zip(v, f).map { $0 + $1 })
        } else {
            out[$0.int(0)] = v
        }
    }
    if out.isEmpty { throw CLIError("no embeddings for model \(model) — run faces-embed --model \(model) first") }
    return out
}

func runFacesEval(_ args: Arguments) throws {
    let minCount = args.int("--min-faces") ?? 10
    let seed = UInt64(args.int("--seed") ?? 42)
    let db = try openStore(write: false)
    let match = try matchPhotos(db, verbose: true)

    var knownFaces: [Sample] = [], unknownFaces: [Sample] = []
    var sizeRatios: [Double] = []
    for p in match.humanPairs {
        let o = p.box, f = p.face
        sizeRatios.append(f.size / o.sideNorm)
        let s = Sample(key: "\(o.sourceID)#\(p.index)", label: f.person ?? "", vector: o.vector, group: "\(f.person ?? "")#\(f.day)", cropPx: o.cropPx)
        if f.person != nil { knownFaces.append(s) } else { unknownFaces.append(s) }
    }
    sizeRatios.sort()
    let humansTotal = match.humans.values.map(\.count).reduce(0, +)
    print("\nfaces: matched \(match.humanPairs.count) of \(humansTotal) (\(pct(Double(match.humanPairs.count) / Double(max(1, humansTotal))))); named \(knownFaces.count), unnamed \(unknownFaces.count)")
    if !sizeRatios.isEmpty {
        print(String(format: "Photos ZSIZE / our box side (fraction of the shot's long side): median %.2f", sizeRatios[sizeRatios.count / 2]))
    }

    if let model = args.value("--model") {
        let name = model.contains("/") ? URL(fileURLWithPath: model).deletingPathExtension().lastPathComponent : model
        let flip = args.flags.contains("--flip")
        let embeddings = try loadFaceEmbeddings(db, model: name, flip: flip)
        let byKey = Dictionary(uniqueKeysWithValues: match.humanPairs.map { ("\($0.box.sourceID)#\($0.index)", $0.box.faceID) })
        let covered = (knownFaces + unknownFaces).filter { byKey[$0.key].flatMap { embeddings[$0] } != nil }.count
        print("embeddings \(name)\(flip ? " (+ flip)" : ""): present for \(covered) of \(knownFaces.count + unknownFaces.count) matched faces")
        func swapVectors(_ samples: [Sample]) -> [Sample] {
            samples.compactMap { s in
                guard let id = byKey[s.key], let e = embeddings[id] else { return nil }
                return Sample(key: s.key, label: s.label, vector: e, group: s.group, cropPx: s.cropPx)
            }
        }
        func sameSubset(_ samples: [Sample]) -> [Sample] {
            samples.filter { byKey[$0.key].flatMap { embeddings[$0] } != nil }
        }
        evaluate(title: "People: Vision feature print of the face crop (same faces)", known: sameSubset(knownFaces), unknown: sameSubset(unknownFaces), minCount: minCount, seed: seed)
        evaluate(title: "People: \(name) embedding\(flip ? " + flip" : "") of the aligned crop", known: swapVectors(knownFaces), unknown: swapVectors(unknownFaces), minCount: minCount, seed: seed)
        return
    }
    evaluate(title: "People: Vision feature print of the face crop", known: knownFaces, unknown: unknownFaces, minCount: minCount, seed: seed)

    var knownPets: [Sample] = [], unknownPets: [Sample] = [], knownPetsWhole: [Sample] = [], unknownPetsWhole: [Sample] = []
    var petMatched = 0
    for (uuid, theirs) in match.pets {
        let ours = match.ourAnimals[uuid] ?? []
        let t = transforms[match.chosen[theirs[0].orientation] ?? match.defaultTransform].1
        for (i, j) in matchAnimals(ours, theirs, transform: t) {
            petMatched += 1
            let o = ours[i], f = theirs[j]
            let s = Sample(key: "\(o.sourceID)#\(i)", label: f.person ?? "", vector: o.vector, group: "\(f.person ?? "")#\(f.day)", cropPx: o.cropPx)
            let w = Sample(key: s.key, label: f.person ?? "", vector: o.imageVector ?? o.vector, group: s.group, cropPx: o.cropPx)
            if f.person != nil {
                knownPets.append(s); knownPetsWhole.append(w)
            } else {
                unknownPets.append(s); unknownPetsWhole.append(w)
            }
        }
    }
    let petsTotal = match.pets.values.map(\.count).reduce(0, +)
    print("\npets: Photos pet faces \(petsTotal), matched to Vision animal boxes \(petMatched) (\(pct(Double(petMatched) / Double(max(1, petsTotal))))); named \(knownPets.count), unnamed \(unknownPets.count)")
    let animalKinds = Dictionary(grouping: match.pets.values.flatMap { $0 }.filter { $0.person != nil }, by: { $0.person! })
    for (name, faces) in animalKinds.sorted(by: { $0.value.count > $1.value.count }) {
        let types = Set(faces.map(\.type)).sorted().map(String.init).joined(separator: ",")
        print("  \(name): faces \(faces.count), type \(types) (3 = dog, 4 = cat, per Photos labels)")
    }
    evaluate(title: "Pets: Vision feature print of the animal crop", known: knownPets, unknown: unknownPets, minCount: minCount, seed: seed)
    evaluate(title: "Pets: whole-shot feature print (for comparison)", known: knownPetsWhole, unknown: unknownPetsWhole, minCount: minCount, seed: seed)
}
