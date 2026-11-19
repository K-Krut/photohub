import Accelerate
import Foundation

struct PrintMatrix {
    var ids: [String] = []
    var dim = 0
    var values: [Float] = []
    var norms: [Float] = []

    var count: Int { ids.count }

    mutating func append(_ id: String, _ v: [Float]) {
        if dim == 0 { dim = v.count }
        guard v.count == dim else { return }
        ids.append(id)
        values.append(contentsOf: v)
        var n: Float = 0
        vDSP_svesq(v, 1, &n, vDSP_Length(dim))
        norms.append(n)
    }

    func row(_ i: Int) -> [Float] { Array(values[i * dim..<(i + 1) * dim]) }

    func distances(to q: [Float]) -> [Float] {
        let n = count
        var dots = [Float](repeating: 0, count: n)
        values.withUnsafeBufferPointer { m in
            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(n), Int32(dim), 1, m.baseAddress, Int32(dim), q, 1, 0, &dots, 1)
        }
        var qn: Float = 0
        vDSP_svesq(q, 1, &qn, vDSP_Length(dim))
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = sqrt(max(0, qn + norms[i] - 2 * dots[i])) }
        return out
    }
}

func loadImagePrints(_ db: Database) throws -> PrintMatrix {
    var m = PrintMatrix()
    try db.rows("SELECT source_id, print, print_type FROM image WHERE print IS NOT NULL AND print_rev = ?", [Revisions.print]) {
        m.append($0.text(0), floats($0.blob(1), type: Int($0.int(2))))
    }
    return m
}

func topK(_ d: [Float], k: Int, exclude: Set<Int> = []) -> [Int] {
    Array(d.indices.filter { !exclude.contains($0) }.sorted { d[$0] < d[$1] }.prefix(k))
}

struct CatalogIndex {
    var bySource: [String: CatalogMember] = [:]
    var archiveRoot = ""

    init() {
        if let members = try? loadCatalogMembers() {
            for m in members {
                let id = sourceID(for: m)
                if let old = bySource[id], old.role == "photo" { continue }
                bySource[id] = m
            }
        }
        if let data = try? Data(contentsOf: Paths.support.appendingPathComponent("config.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let root = obj["archive_root"] as? String {
            archiveRoot = root
        }
    }

    func describe(_ id: String) -> String {
        guard let m = bySource[id] else { return "" }
        if m.source == "archive" { return "\(m.path)  [\(m.role)]" }
        return "Photos: \(m.name)" + (m.taken.isEmpty ? "" : " · \(m.taken.prefix(10))")
    }

    func item(_ id: String) -> Int64? { bySource[id]?.itemID }
}

func runSimilar(_ args: Arguments) throws {
    guard let query = args.positional.first else { throw CLIError("source_id required: a:<path> or p:<UUID>") }
    let top = args.int("--top") ?? 30
    let db = try openStore(write: false)
    let t0 = Date()
    let m = try loadImagePrints(db)
    let loadTime = Date().timeIntervalSince(t0)
    guard let qi = m.ids.firstIndex(of: query) else { throw CLIError("no feature print for \(query) — analyze it with run --source \(query)") }
    let t1 = Date()
    let q = m.row(qi)
    let d = m.distances(to: q)
    let best = topK(d, k: top, exclude: [qi])
    let searchTime = Date().timeIntervalSince(t1)
    let catalog = CatalogIndex()
    let qItem = catalog.item(query)
    print("shot: \(query)")
    if !catalog.describe(query).isEmpty { print("      \(catalog.describe(query))") }
    print(String(format: "feature prints: %d × %d, load %.2f s, search %.1f ms", m.count, m.dim, loadTime, searchTime * 1000))
    for (rank, i) in best.enumerated() {
        let same = qItem != nil && catalog.item(m.ids[i]) == qItem ? "  ← same stack" : ""
        let desc = catalog.describe(m.ids[i])
        print(String(format: "%3d  %.3f  %@%@", rank + 1, d[i], desc.isEmpty ? m.ids[i] : (m.ids[i].hasPrefix("p:") ? "\(m.ids[i])  \(desc)" : desc), same))
    }
}
