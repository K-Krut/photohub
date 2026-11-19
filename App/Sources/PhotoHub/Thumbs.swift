import AppKit
import CoreLocation
import CryptoKit
import Photos
import QuickLookThumbnailing

final class Thumbs {
    static let shared = Thumbs()
    static let cacheDir = AppPaths.support.appendingPathComponent("thumbs")

    private let cache = NSCache<NSString, NSImage>()
    private var assets: [String: PHAsset] = [:]
    private let manager = PHCachingImageManager()
    private let queue = DispatchQueue(label: "photohub.thumbs", qos: .userInitiated, attributes: .concurrent)

    private final class Flag { var value = false }

    func loadAssets() {
        var map: [String: PHAsset] = [:]
        PHAsset.fetchAssets(with: Hidden.allAssets).enumerateObjects { asset, _, _ in map[asset.localIdentifier] = asset }
        assets = map
    }

    func forget() { cache.removeAllObjects() }

    func locations() -> [String: CLLocationCoordinate2D] {
        assets.compactMapValues { $0.location?.coordinate }
    }

    func typeIdentifiers() -> [String: [String]] {
        var out: [String: [String]] = [:]
        for (id, asset) in assets {
            if asset.isFavorite { out["favorite", default: []].append(id) }
            let sub = asset.mediaSubtypes
            if sub.contains(.photoLive) { out["live", default: []].append(id) }
            if sub.contains(.photoDepthEffect) { out["portrait", default: []].append(id) }
            if sub.contains(.photoPanorama) { out["panorama", default: []].append(id) }
            if sub.contains(.photoScreenshot) { out["screenshot", default: []].append(id) }
            if sub.contains(.videoHighFrameRate) { out["slomo", default: []].append(id) }
            if sub.contains(.videoTimelapse) { out["timelapse", default: []].append(id) }
        }
        PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumSelfPortraits, options: nil).enumerateObjects { collection, _, _ in
            PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
                out["selfie", default: []].append(asset.localIdentifier)
            }
        }
        return out
    }

    static func isLocal(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return st.st_flags & 0x4000_0000 == 0
    }

    static func cachedFile(_ path: String) -> URL {
        let digest = Insecure.SHA1.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent(digest + ".jpg")
    }

    static let previewDir = AppPaths.support.appendingPathComponent("previews")

    static func previewFile(_ path: String) -> URL {
        previewDir.appendingPathComponent(cachedFile(path).lastPathComponent)
    }

    static func decode(_ source: CGImageSource?, maxPixel: Int? = nil) -> NSImage? {
        guard let source, CGImageSourceGetCount(source) > 0 else { return nil }
        var limit = maxPixel ?? 0
        if limit == 0 {
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
            limit = max(w, h) > 0 ? max(w, h) : 8192
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: limit]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    static func decode(_ url: URL, maxPixel: Int? = nil) -> NSImage? {
        decode(CGImageSourceCreateWithURL(url as CFURL, nil), maxPixel: maxPixel)
    }

    func asset(_ id: String) -> PHAsset? {
        if let hit = assets[id] { return hit }
        return PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    private enum Source: Equatable {
        case asset(String)
        case file(String)
    }

    func image(for item: Item, side: CGFloat, completion: @escaping (NSImage?) -> Void) {
        let cacheKey = "\(item.key)|\(item.mainAsset)|\(item.mainPath)|\(item.thumbAsset)|\(item.thumbPath)-\(Int(side))" as NSString
        if let hit = cache.object(forKey: cacheKey) {
            completion(hit)
            return
        }
        var sources: [Source] = []
        for (id, isAsset) in [(item.mainAsset, true), (item.mainPath, false), (item.thumbAsset, true), (item.thumbPath, false)] where !id.isEmpty {
            let source: Source = isAsset ? .asset(id) : .file(id)
            if !sources.contains(source) { sources.append(source) }
        }
        attempt(sources[...], side, cacheKey, completion)
    }

    func image(for member: Member, side: CGFloat, completion: @escaping (NSImage?) -> Void) {
        let cacheKey = "m:\(member.source):\(member.path)-\(Int(side))" as NSString
        if let hit = cache.object(forKey: cacheKey) {
            completion(hit)
            return
        }
        attempt([member.source == "photos" ? .asset(member.path) : .file(member.path)], side, cacheKey, completion)
    }

    private func attempt(_ sources: ArraySlice<Source>, _ side: CGFloat, _ cacheKey: NSString, _ completion: @escaping (NSImage?) -> Void) {
        guard let source = sources.first else {
            completion(nil)
            return
        }
        let rest = sources.dropFirst()
        switch source {
        case .file(let path):
            fromFiles(path, side, cacheKey) { [weak self] image in
                if let image { completion(image) } else { self?.attempt(rest, side, cacheKey, completion) }
            }
        case .asset(let id):
            guard let asset = assets[id] else {
                attempt(rest, side, cacheKey, completion)
                return
            }
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = side > 150
            options.resizeMode = .fast
            let delivered = Flag()
            manager.requestImage(for: asset, targetSize: CGSize(width: side * 2, height: side * 2), contentMode: .aspectFill, options: options) { [weak self] image, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let image {
                        delivered.value = true
                        self.cache.setObject(image, forKey: cacheKey)
                        completion(image)
                    } else if !delivered.value {
                        delivered.value = true
                        self.attempt(rest, side, cacheKey, completion)
                    }
                }
            }
        }
    }

    private func fromFiles(_ path: String, _ side: CGFloat, _ cacheKey: NSString, _ completion: @escaping (NSImage?) -> Void) {
        queue.async { [weak self] in
            if let image = NSImage(contentsOf: Thumbs.cachedFile(path)) ?? Thumbs.decode(Thumbs.previewFile(path), maxPixel: Int(side * 2)) {
                DispatchQueue.main.async {
                    self?.cache.setObject(image, forKey: cacheKey)
                    completion(image)
                }
                return
            }
            let url = Catalog.archiveRoot.appendingPathComponent(path)
            guard Thumbs.isLocal(url) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: 2, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                DispatchQueue.main.async {
                    if let image = rep?.nsImage { self?.cache.setObject(image, forKey: cacheKey) }
                    completion(rep?.nsImage)
                }
            }
        }
    }
}
