import Foundation

struct LabelNames: Decodable {
    let en: [String]
    let ru: [String]
}

struct WordForms: Decodable {
    let fold: [String: String]
    let stopWords: Set<String>
    let ruEndings: [String]
    let ruSuffixPairs: [[String]]

    enum CodingKeys: String, CodingKey { case fold, stopWords = "stop_words", ruEndings = "ru_endings", ruSuffixPairs = "ru_suffix_pairs" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fold = try c.decode([String: String].self, forKey: .fold)
        stopWords = try c.decode(Set<String>.self, forKey: .stopWords)
        ruEndings = try c.decode([String].self, forKey: .ruEndings).sorted { $0.count > $1.count }
        ruSuffixPairs = try c.decode([[String]].self, forKey: .ruSuffixPairs)
    }

    func normalize(_ s: String) -> [String] {
        let lowered = fold.reduce(s.lowercased()) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
        let cleaned = String(lowered.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
        return cleaned.split(separator: " ").map(String.init)
    }

    func isCyrillic(_ w: String) -> Bool { w.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) } }

    func forms(_ w: String) -> Set<String> {
        var out: Set<String> = [w]
        if isCyrillic(w) {
            var stem = w
            for e in ruEndings where w.hasSuffix(e) && w.count - e.count >= 3 {
                stem = String(w.dropLast(e.count))
                break
            }
            out.insert(stem)
            for base in [w, stem] {
                for pair in ruSuffixPairs where base.hasSuffix(pair[0]) && base.count >= 5 {
                    out.insert(String(base.dropLast(pair[0].count)) + pair[1])
                }
            }
        } else if w.count > 3 {
            if w.hasSuffix("ies") && w.count > 4 { out.insert(String(w.dropLast(3)) + "y") }
            for e in ["ches", "shes", "sses", "xes", "oes"] where w.hasSuffix(e) { out.insert(String(w.dropLast(2))) }
            if w.hasSuffix("s") && !w.hasSuffix("ss") { out.insert(String(w.dropLast())) }
            if w.hasSuffix("ves") { out.insert(String(w.dropLast(3)) + "f"); out.insert(String(w.dropLast(3)) + "fe") }
        }
        return out
    }

    func matches(_ a: String, _ b: String) -> Bool { a == b || !forms(a).isDisjoint(with: forms(b)) }
}

struct LabelFile: Decodable {
    static let searchKey = "_search"
    let names: [String: LabelNames]
    let words: WordForms

    struct Key: CodingKey {
        let stringValue: String
        init(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        words = try c.decode(WordForms.self, forKey: Key(stringValue: Self.searchKey))
        names = try c.allKeys.filter { $0.stringValue != Self.searchKey }.reduce(into: [:]) { $0[$1.stringValue] = try c.decode(LabelNames.self, forKey: $1) }
    }
}

struct LabelIndex {
    let names: [String: LabelNames]
    let words: WordForms
    private var phrases: [(identifier: String, tokens: [String])] = []

    init() throws {
        guard let url = Bundle.module.url(forResource: "labels", withExtension: "json") else { throw CLIError("missing labels.json resource") }
        let file = try JSONDecoder().decode(LabelFile.self, from: Data(contentsOf: url))
        names = file.names
        words = file.words
        for (id, n) in names {
            var seen = Set<[String]>()
            for name in n.en + n.ru + [id.replacingOccurrences(of: "_", with: " ")] {
                let t = words.normalize(name)
                if !t.isEmpty, seen.insert(t).inserted { phrases.append((id, t)) }
            }
        }
    }

    func match(_ q: [String], at i: Int) -> (length: Int, ids: Set<String>) {
        var best = 0
        var ids = Set<String>()
        for p in phrases where p.tokens.count <= q.count - i && p.tokens.count >= best {
            var ok = true
            for (k, t) in p.tokens.enumerated() where !words.matches(q[i + k], t) { ok = false; break }
            guard ok else { continue }
            if p.tokens.count > best { best = p.tokens.count; ids = [] }
            ids.insert(p.identifier)
        }
        return (best, ids)
    }

    func parse(_ query: String) -> (terms: [(String, Set<String>)], unknown: [String]) {
        let q = words.normalize(query)
        var terms: [(String, Set<String>)] = []
        var unknown: [String] = []
        var i = 0
        while i < q.count {
            let m = match(q, at: i)
            if m.length > 0 {
                terms.append((q[i..<i + m.length].joined(separator: " "), m.ids))
                i += m.length
            } else {
                if !words.stopWords.contains(q[i]) { unknown.append(q[i]) }
                i += 1
            }
        }
        return (terms, unknown)
    }
}

func runSearch(_ args: Arguments) throws {
    let query = args.positional.joined(separator: " ")
    guard !query.isEmpty else { throw CLIError("a search word is required") }
    let top = args.int("--top") ?? 20
    let minConf = args.double("--min") ?? 0.3
    let index = try LabelIndex()
    let (terms, unknown) = index.parse(query)
    if !unknown.isEmpty { print("unknown words: \(unknown.joined(separator: ", "))") }
    guard !terms.isEmpty else { throw CLIError("none of the query words are in the label table") }
    for (word, ids) in terms {
        let sorted = ids.sorted()
        print("\"\(word)\" → \(sorted.prefix(8).joined(separator: ", "))" + (sorted.count > 8 ? " and \(sorted.count - 8) more" : ""))
    }
    let db = try openStore(write: false)
    var perTerm: [[String: Double]] = []
    for (_, ids) in terms {
        var best: [String: Double] = [:]
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        try db.rows("SELECT source_id, max(confidence) FROM label WHERE identifier IN (\(marks)) AND confidence >= ? GROUP BY source_id",
                    Array(ids) as [Any?] + [minConf]) {
            best[$0.text(0)] = $0.double(1)
        }
        perTerm.append(best)
    }
    var scores = perTerm[0]
    for other in perTerm.dropFirst() {
        scores = scores.filter { other[$0.key] != nil }.reduce(into: [:]) { $0[$1.key] = $1.value + other[$1.key]! }
    }
    let total = try db.scalarInt("SELECT count(*) FROM image WHERE error IS NULL")
    let catalog = CatalogIndex()
    let archive = scores.keys.filter { $0.hasPrefix("a:") }.count
    let items = Set(scores.keys.compactMap { catalog.item($0) }).count
    print(String(format: "found: %d of %d analyzed (archive %d, Photos %d; catalog stacks %d), threshold %.2f",
                 scores.count, total, archive, scores.count - archive, items, minConf))
    let ranked = scores.sorted { $0.value > $1.value }.prefix(top)
    for (id, score) in ranked {
        let desc = catalog.describe(id)
        print(String(format: "  %.2f  %@", score / Double(terms.count), id.hasPrefix("p:") ? "\(id)  \(desc)" : (desc.isEmpty ? id : desc)))
    }
}
