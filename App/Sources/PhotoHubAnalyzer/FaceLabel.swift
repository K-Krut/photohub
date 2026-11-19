import Foundation

func predictFaces(_ classifier: String, train: [Sample], test: [[Float]]) -> [Prediction] {
    switch classifier {
    case "1nn": return knnPredict(train: train, test: test, k: 1)
    case "5nn": return knnPredict(train: train, test: test, k: 5)
    case "linear": return linearPredict(train: train, test: test)
    default: return centroidPredict(train: train, test: test)
    }
}

func runFacesLabel(_ args: Arguments) throws {
    let spec = args.value("--model") ?? defaultFaceModel
    let model = spec.contains("/") ? URL(fileURLWithPath: spec).deletingPathExtension().lastPathComponent : spec
    let classifier = args.value("--classifier") ?? "centroid"
    guard ["centroid", "1nn", "5nn", "linear"].contains(classifier) else { throw CLIError("--classifier: centroid, 1nn, 5nn or linear") }
    let minCount = args.int("--min-faces") ?? 10
    let seed = UInt64(args.int("--seed") ?? 42)
    let targetPrecision = args.double("--target") ?? 0.95
    let maxStrangers = args.double("--strangers") ?? 0.05
    let flip = args.flags.contains("--flip")
    let dryRun = args.flags.contains("--dry-run")
    let t0 = Date()

    let db = try openStore()
    try ensureEmbeddingTables(db)
    let match = try matchPhotos(db, verbose: false)
    let embeddings = try loadFaceEmbeddings(db, model: model, flip: flip)

    var named: [Sample] = [], unnamed: [Sample] = []
    var namedFaceIDs = Set<Int64>()
    for p in match.humanPairs {
        guard let v = embeddings[p.box.faceID] else { continue }
        let s = Sample(key: String(p.box.faceID), label: p.face.person ?? "", vector: v, group: "\(p.face.person ?? "")#\(p.face.day)", cropPx: p.box.cropPx)
        if p.face.person != nil {
            named.append(s)
            namedFaceIDs.insert(p.box.faceID)
        } else {
            unnamed.append(s)
        }
    }
    let counts = Dictionary(grouping: named, by: \.label).mapValues(\.count)
    let kept = Set(counts.filter { $0.value >= minCount }.keys)
    let known = named.filter { kept.contains($0.label) }
    let strangers = unnamed + named.filter { !kept.contains($0.label) }
    print("model \(model)\(flip ? " + flip" : ""), classifier \(classifier); people with ≥ \(minCount) faces: \(kept.count), their faces \(known.count); strangers \(strangers.count)")

    let (train, test) = split(known, byGroup: true, seed: seed)
    let pred = predictFaces(classifier, train: train, test: test.map(\.vector))
    let otherPred = predictFaces(classifier, train: train, test: strangers.map(\.vector))
    func stats(_ t: Float) -> (coverage: Double, precision: Double, strangers: Double) {
        let accepted = pred.indices.filter { pred[$0].score >= t }
        let ok = accepted.filter { pred[$0].label == test[$0].label }.count
        let fa = otherPred.filter { $0.score >= t }.count
        return (Double(accepted.count) / Double(max(1, test.count)), accepted.isEmpty ? 0 : Double(ok) / Double(accepted.count),
                Double(fa) / Double(max(1, otherPred.count)))
    }
    var threshold: Float?
    for t in Set(pred.map(\.score) + otherPred.map(\.score)).sorted() {
        let s = stats(t)
        if s.precision >= targetPrecision && s.strangers <= maxStrangers && s.coverage > 0 {
            threshold = t
            break
        }
    }
    guard let threshold else {
        print(String(format: "no threshold found: precision ≥ %.0f%% with ≤ %.0f%% strangers accepted is unreachable", targetPrecision * 100, maxStrangers * 100))
        return
    }
    let s = stats(threshold)
    let correct = zip(pred, test).filter { $0.label == $1.label }.count
    print(String(format: "by-day check: train %d, test %d, accuracy without threshold %@", train.count, test.count, pct(Double(correct) / Double(max(1, test.count)))))
    print(String(format: "threshold %.3f (precision ≥ %.0f%%, strangers ≤ %.0f%%): coverage %@, correct among accepted %@, strangers accepted %@",
                 threshold, targetPrecision * 100, maxStrangers * 100, pct(s.coverage), pct(s.precision), pct(s.strangers)))

    var faceRows: [Int64: (sourceID: String, idx: Int, cropPx: Int)] = [:]
    try db.rows("SELECT id, source_id, idx, crop_px FROM face") { faceRows[$0.int(0)] = ($0.text(1), Int($0.int(2)), Int($0.int(3))) }
    let candidates = embeddings.keys.filter { !namedFaceIDs.contains($0) && faceRows[$0] != nil }.sorted()
    let finalPred = predictFaces(classifier, train: known, test: candidates.map { embeddings[$0]! })
    var accepted: [(faceID: Int64, sourceID: String, idx: Int, name: String, score: Float)] = []
    for (i, id) in candidates.enumerated() where finalPred[i].score >= threshold {
        let r = faceRows[id]!
        accepted.append((id, r.sourceID, r.idx, finalPred[i].label, finalPred[i].score))
    }
    let archiveCandidates = candidates.filter { faceRows[$0]!.sourceID.hasPrefix("a:") }.count
    print("unnamed faces: \(candidates.count) (archive \(archiveCandidates), Photos \(candidates.count - archiveCandidates)); with a suggestion: \(accepted.count) (archive \(accepted.filter { $0.sourceID.hasPrefix("a:") }.count))")

    if !dryRun {
        try db.exec("BEGIN")
        try db.run("DELETE FROM face_suggestion WHERE model = ?", [model])
        let insert = try db.prepare("""
            INSERT OR REPLACE INTO face_suggestion(source_id, face_id, idx, name, score, model, classifier, threshold, created)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        let now = isoNow()
        for a in accepted {
            try insert.bind([a.sourceID, a.faceID, a.idx, a.name, a.score, model, classifier, threshold, now])
            _ = try insert.step()
        }
        try db.exec("COMMIT")
        print("written to face_suggestion: \(accepted.count)")
    }

    var itemOf: [String: Int64] = [:]
    if let catalog = try? Database(path: Paths.catalog.path, readOnly: true) {
        try? catalog.rows("SELECT path, item_id FROM member WHERE source = 'archive'") { itemOf["a:" + $0.text(0)] = $0.int(1) }
    }
    let archive = accepted.filter { $0.sourceID.hasPrefix("a:") }
    let photos = accepted.filter { $0.sourceID.hasPrefix("p:") }
    let byName = Dictionary(grouping: archive, by: \.name)
    let photosByName = Dictionary(grouping: photos, by: \.name)
    print("\narchive: suggestions per person (faces · files · catalog shots) · Photos unnamed: faces")
    let order = Set(accepted.map(\.name)).sorted { (byName[$0]?.count ?? 0, photosByName[$0]?.count ?? 0) > (byName[$1]?.count ?? 0, photosByName[$1]?.count ?? 0) }
    for name in order {
        let faces = byName[name] ?? []
        let files = Set(faces.map(\.sourceID))
        let items = Set(files.compactMap { itemOf[$0] })
        print("  " + name.padding(toLength: 22, withPad: " ", startingAt: 0) + String(format: " %5d · %5d · %5d · %5d", faces.count, files.count, items.count, photosByName[name]?.count ?? 0))
    }
    var rng = SplitMix(state: seed)
    for name in order.prefix(3) {
        let faces = (byName[name] ?? []).sorted { $0.score < $1.score }
        guard !faces.isEmpty else { continue }
        let bands = 5
        var picks: [(faceID: Int64, sourceID: String, idx: Int, name: String, score: Float)] = []
        for b in 0..<bands {
            let lo = faces.count * b / bands, hi = max(lo + 1, faces.count * (b + 1) / bands)
            var band = Array(faces[lo..<min(hi, faces.count)])
            rng.shuffle(&band)
            if let f = band.first { picks.append(f) }
        }
        print("\nsamples to review: \(name)")
        for p in picks { print(String(format: "  %.3f  face %d  #%d  %@", p.score, p.faceID, p.idx, p.sourceID)) }
    }
    print(String(format: "\n%.1f s", Date().timeIntervalSince(t0)))
}
