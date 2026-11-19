import Foundation

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

struct Arguments {
    let positional: [String]
    let options: [String: String]
    let flags: Set<String>

    init(_ raw: [String]) {
        var pos: [String] = [], opts: [String: String] = [:], flags = Set<String>()
        let valued: Set<String> = ["--limit", "--only", "--source", "--workers", "--top", "--min", "--min-faces", "--seed", "--save", "--model", "--dump", "--units", "--classifier", "--target", "--strangers"]
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if valued.contains(a), i + 1 < raw.count {
                opts[a] = raw[i + 1]
                i += 2
            } else if a.hasPrefix("--") {
                flags.insert(a)
                i += 1
            } else {
                pos.append(a)
                i += 1
            }
        }
        positional = pos
        options = opts
        self.flags = flags
    }

    func value(_ k: String) -> String? { options[k] }
    func int(_ k: String) -> Int? { options[k].flatMap { Int($0) } }
    func double(_ k: String) -> Double? { options[k].flatMap { Double($0) } }
}

let usage = """
PhotoHubAnalyzer — recognition from previews on this Mac (Vision, offline)

  run [--limit N] [--only archive|photos] [--source a:…|p:…] [--workers 4]
      analyze shots, resumes where it stopped
  stats
      what is in vision.sqlite, runs, speed
  similar <source_id> [--top 30] [--faces]
      nearest shots by Vision feature print
  search <words…> [--top 20] [--min 0.3]
      search Vision labels, in Russian or English
  faces-eval [--min-faces 10] [--seed 42]
      check whether face and animal feature prints recognize people and pets from Photos
  faces-embed [--model sface-fp16] [--only archive|photos] [--limit N] [--workers 4] [--redo] [--dump folder]
      Vision face landmarks, ArcFace template alignment and a Core ML face model embedding for every face
  faces-eval --model sface-fp16 [--flip]
      the same check on face model embeddings, next to Vision feature prints on the same faces
  faces-label [--model sface-fp16] [--classifier centroid|1nn|5nn|linear] [--target 0.95] [--strangers 0.05] [--dry-run]
      threshold from a by-day split, name suggestions for unnamed faces into face_suggestion
"""

setvbuf(stdout, nil, _IOLBF, 0)
let raw = Array(CommandLine.arguments.dropFirst())
guard let command = raw.first else {
    print(usage)
    exit(0)
}
let args = Arguments(Array(raw.dropFirst()))
do {
    switch command {
    case "run": try runAnalysis(args)
    case "stats": try printStats()
    case "similar": try runSimilar(args)
    case "search": try runSearch(args)
    case "faces-eval": try runFacesEval(args)
    case "faces-embed": try runFacesEmbed(args)
    case "faces-label": try runFacesLabel(args)
    case "help", "-h", "--help": print(usage)
    default:
        print(usage)
        exit(2)
    }
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
