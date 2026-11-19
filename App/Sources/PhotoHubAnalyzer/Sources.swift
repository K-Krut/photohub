import CryptoKit
import Foundation
import ImageIO

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static var support: URL {
        if let v = ProcessInfo.processInfo.environment["PHOTOHUB_SUPPORT"] { return URL(fileURLWithPath: v) }
        return home.appendingPathComponent("Library/Application Support/PhotoHub")
    }
    static var catalog: URL {
        if let v = ProcessInfo.processInfo.environment["PHOTOHUB_CATALOG"] { return URL(fileURLWithPath: v) }
        return support.appendingPathComponent("catalog.sqlite")
    }
    static var vision: URL {
        if let v = ProcessInfo.processInfo.environment["PHOTOHUB_VISION"] { return URL(fileURLWithPath: v) }
        return support.appendingPathComponent("vision.sqlite")
    }
    static var previews: URL { support.appendingPathComponent("previews") }
    static var thumbs: URL { support.appendingPathComponent("thumbs") }
    static var photosLibrary: URL {
        if let v = ProcessInfo.processInfo.environment["PHOTOHUB_PHOTOS_LIBRARY"] { return URL(fileURLWithPath: v) }
        return home.appendingPathComponent("Pictures/Photos Library.photoslibrary")
    }
    static var derivatives: URL { photosLibrary.appendingPathComponent("resources/derivatives") }
    static var photosDatabase: URL { photosLibrary.appendingPathComponent("database/Photos.sqlite") }
}

struct InputImage {
    let sourceID: String
    let url: URL
    let size: Int64
    let mtime: Double
}

struct CatalogMember {
    let itemID: Int64
    let source: String
    let path: String
    let name: String
    let role: String
    let taken: String
}

func sha1Hex(_ s: String) -> String {
    Insecure.SHA1.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

func fileStat(_ url: URL) -> (Int64, Double)? {
    var st = stat()
    guard stat(url.path, &st) == 0 else { return nil }
    let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
    return (Int64(st.st_size), mtime)
}

func sourceID(for member: CatalogMember) -> String {
    if member.source == "archive" { return "a:" + member.path }
    return "p:" + (member.path.split(separator: "/").first.map(String.init) ?? member.path)
}

func loadCatalogMembers() throws -> [CatalogMember] {
    let db = try Database(path: Paths.catalog.path, readOnly: true)
    var out: [CatalogMember] = []
    try db.rows("SELECT item_id, source, path, name, role, coalesce(taken, '') FROM member") {
        out.append(CatalogMember(itemID: $0.int(0), source: $0.text(1), path: $0.text(2), name: $0.text(3), role: $0.text(4), taken: $0.text(5)))
    }
    return out
}

func archiveInputs(_ members: [CatalogMember]) -> [InputImage] {
    var seen = Set<String>()
    var out: [InputImage] = []
    for m in members where m.source == "archive" && ["photo", "edit", "raw"].contains(m.role) {
        guard seen.insert(m.path).inserted else { continue }
        let name = sha1Hex(m.path) + ".jpg"
        for dir in [Paths.previews, Paths.thumbs] {
            let url = dir.appendingPathComponent(name)
            if let (size, mtime) = fileStat(url) {
                out.append(InputImage(sourceID: "a:" + m.path, url: url, size: size, mtime: mtime))
                break
            }
        }
    }
    return out
}

func pixelSize(_ url: URL) -> (Int, Int)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (w, h)
}

func derivativeIndex() -> [String: [URL]] {
    var index: [String: [URL]] = [:]
    let fm = FileManager.default
    guard let walker = fm.enumerator(at: Paths.derivatives, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return index }
    let exts: Set<String> = ["jpeg", "jpg", "heic"]
    for case let url as URL in walker {
        guard exts.contains(url.pathExtension.lowercased()) else { continue }
        let name = url.lastPathComponent
        guard name.count > 36 else { continue }
        index[String(name.prefix(36)), default: []].append(url)
    }
    return index
}

func bestDerivative(_ candidates: [URL], maxSide: Int = 2048) -> URL? {
    var best: (URL, Int)?
    for url in candidates {
        guard let (w, h) = pixelSize(url), max(w, h) <= maxSide + 64 else { continue }
        if best == nil || w * h > best!.1 { best = (url, w * h) }
    }
    return best?.0
}

func photosInputs(_ members: [CatalogMember]) -> (inputs: [InputImage], missing: Int) {
    let index = derivativeIndex()
    var seen = Set<String>()
    var out: [InputImage] = []
    var missing = 0
    for m in members where m.source == "photos" && ["photo", "raw"].contains(m.role) {
        let id = sourceID(for: m)
        guard seen.insert(id).inserted else { continue }
        let uuid = String(id.dropFirst(2))
        guard let url = bestDerivative(index[uuid] ?? []), let (size, mtime) = fileStat(url) else {
            missing += 1
            continue
        }
        out.append(InputImage(sourceID: id, url: url, size: size, mtime: mtime))
    }
    return (out, missing)
}
