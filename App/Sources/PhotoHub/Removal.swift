import AppKit
import Carbon
import Photos

enum PhotosDeletion: Equatable {
    case deleted, cancelled
    case failed(String)
}

struct TrashedFile: Equatable {
    let original: URL
    let trashed: URL?
    let size: Int64
    var inode: UInt64 = 0
    var at = Date()
}

enum PutBackFailure: Equatable {
    case missing, occupied, retrashed
    case failed(String)
}

struct PutBackResult {
    let file: TrashedFile
    var target: URL
    var source: URL?
    var failure: PutBackFailure?
    var attempts = 0

    var message: String {
        let name = file.original.lastPathComponent
        let folder = Removal.place(target.deletingLastPathComponent())
        switch failure {
        case nil:
            return ""
        case .missing:
            let places = Removal.trashFolders(for: file.original).map { Removal.place($0) }.joined(separator: ", ")
            return String(localized: "“\(name)” is no longer in the Trash: PhotoHub looked for it in \(places). The Trash may have been emptied.")
        case .occupied:
            return String(localized: "Another file named “\(target.lastPathComponent)” is already in “\(folder)”, so “\(name)” stays in the Trash.")
        case .retrashed:
            return String(localized: "iCloud Drive moved “\(name)” back to the Trash while it was still syncing the deletion. Wait a minute and try again.")
        case .failed(let reason):
            return String(localized: "Could not move “\(name)” from the Trash back to “\(folder)”: \(reason)")
        }
    }
}

struct RemovalOutcome {
    var photos: PhotosDeletion?
    var trashed: [(index: Int, file: TrashedFile)] = []
    var failures: [(index: Int, message: String)] = []

    var accepted: Bool { photos == nil || photos == .deleted }
}

enum Removal {
    static var cloudRoot: URL?
    static var mobileDocuments: URL { cloudRoot ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents") }
    static let attemptsKey = "PhotoHubRemovalAttempts"

    enum Method: String, CaseIterable {
        case coordinated, trashItem, icloudTrash, finder
    }

    static let order: [Method] = [.coordinated, .icloudTrash, .finder]

    enum Consent {
        case fullDisk, automation

        var pane: URL {
            switch self {
            case .fullDisk: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
            case .automation: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
            }
        }

        var instruction: String {
            switch self {
            case .fullDisk: return String(localized: "System Settings → Privacy & Security → Full Disk Access → turn on PhotoHub, then restart PhotoHub")
            case .automation: return String(localized: "System Settings → Privacy & Security → Automation → PhotoHub → turn on Finder")
            }
        }
    }

    static func dump(_ error: Error) -> String {
        var lines: [String] = []
        var current: NSError? = error as NSError
        var depth = 0
        while let e = current, depth < 6 {
            let pad = String(repeating: "  ", count: depth)
            lines.append("\(pad)domain=\(e.domain) code=\(e.code)")
            lines.append("\(pad)description=\(e.localizedDescription)")
            for (key, value) in e.userInfo where key != NSUnderlyingErrorKey && key != attemptsKey {
                lines.append("\(pad)userInfo[\(key)]=\(value)")
            }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        for (method, attempt) in attempts(error) {
            lines.append("attempt \(method):")
            lines.append(dump(attempt).split(separator: "\n").map { "  " + $0 }.joined(separator: "\n"))
        }
        return lines.joined(separator: "\n")
    }

    static func attempts(_ error: Error) -> [(String, NSError)] {
        ((error as NSError).userInfo[attemptsKey] as? [[Any]] ?? []).compactMap { pair in
            guard pair.count == 2, let method = pair[0] as? String, let e = pair[1] as? NSError else { return nil }
            return (method, e)
        }
    }

    static func inICloud(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(mobileDocuments.standardizedFileURL.path + "/")
    }

    private static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    static var hasFullDiskAccess: Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd) }
        return fd >= 0
    }

    private static func trashItem(_ url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }

    private static func coordinated(_ url: URL) throws -> URL? {
        var coordination: NSError?
        var inner: Error?
        var moved: URL?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &coordination) { actual in
            do { moved = try trashItem(actual) } catch { inner = error }
        }
        if let error = coordination ?? inner { throw error }
        return moved
    }

    private static func iCloudTrash(_ url: URL) throws -> URL? {
        let trash = mobileDocuments.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let name = url.lastPathComponent
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        for n in 1...999 {
            let candidate = n == 1 ? name : "\(stem) \(n)" + (ext.isEmpty ? "" : ".\(ext)")
            let target = trash.appendingPathComponent(candidate)
            if renamex_np(url.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
            let code = errno
            if code != EEXIST {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path,
                    NSLocalizedDescriptionKey: "renamex_np → \(target.path): \(String(cString: strerror(code)))"])
            }
        }
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: [NSFilePathErrorKey: url.path])
    }

    static var askFinder = true

    static func finderPermission(ask: Bool) -> OSStatus {
        AEDeterminePermissionToAutomateTarget(NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder").aeDesc,
                                              AEEventClass(kAECoreSuite), AEEventID(kAEDelete), ask)
    }

    private static func finder(_ url: URL) throws -> URL? {
        let status = finderPermission(ask: askFinder)
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Finder: AEDeterminePermissionToAutomateTarget = \(status)"])
        }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEDelete),
                                           targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder"),
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(fileURL: url), forKeyword: keyDirectObject)
        let reply = try event.sendEvent(options: [.waitForReply], timeout: 120)
        if let number = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value, number != 0 {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(number), userInfo: [NSFilePathErrorKey: url.path,
                NSLocalizedDescriptionKey: "Finder: \(reply.paramDescriptor(forKeyword: keyErrorString)?.stringValue ?? "error \(number)")"])
        }
        return nil
    }

    private static func run(_ method: Method, _ url: URL) throws -> URL? {
        switch method {
        case .coordinated: return try coordinated(url)
        case .trashItem: return try trashItem(url)
        case .icloudTrash: return try iCloudTrash(url)
        case .finder: return try finder(url)
        }
    }

    static func trash(_ url: URL, methods: [Method]? = nil) -> Result<URL?, Error> {
        guard exists(url) else {
            return .failure(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: [NSFilePathErrorKey: url.path]))
        }
        var tried: [[Any]] = []
        for method in methods ?? order where method != .icloudTrash || inICloud(url) {
            do {
                return .success(try run(method, url))
            } catch {
                tried.append([method.rawValue, error as NSError])
                if !exists(url) { return .success(nil) }
            }
        }
        let first = tried.first?[1] as? NSError ?? NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
        let error = NSError(domain: first.domain, code: first.code, userInfo: first.userInfo.merging([attemptsKey: tried]) { $1 })
        offerSettings(error)
        return .failure(error)
    }

    private static func isPermission(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code) { return true }
        if error.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(error.code) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermission(underlying) }
        return false
    }

    private static func isMissing(_ e: NSError) -> Bool {
        (e.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(e.code)) || (e.domain == NSPOSIXErrorDomain && e.code == Int(ENOENT))
    }

    private static func finderRefused(_ error: Error) -> Bool {
        attempts(error).contains { $0.0 == Method.finder.rawValue && $0.1.domain == NSOSStatusErrorDomain
            && [Int(errAEEventNotPermitted), Int(errAEEventWouldRequireUserConsent)].contains($0.1.code) }
    }

    static func consent(_ error: Error) -> Consent? {
        let all = attempts(error)
        let denied = all.isEmpty ? isPermission(error as NSError) : all.contains { isPermission($0.1) }
        if denied && !hasFullDiskAccess { return .fullDisk }
        if finderRefused(error) { return .automation }
        return nil
    }

    static func message(_ error: Error, name: String) -> String {
        let e = error as NSError
        let all = attempts(error)
        let codes = (all.isEmpty ? ["\(e.domain) \(e.code)"] : all.map { "\($0.0): \($0.1.domain) \($0.1.code)" }).joined(separator: "; ")
        if (all.isEmpty && isMissing(e)) || (!all.isEmpty && all.allSatisfy { isMissing($0.1) }) {
            return String(localized: "The file “\(name)” is no longer in this place (\(codes)). Refresh the catalog (⌘R).")
        }
        switch consent(error) {
        case .fullDisk:
            return String(localized: "macOS did not let PhotoHub move “\(name)” to the Trash: PhotoHub has no Full Disk Access (\(codes)). \(Consent.fullDisk.instruction), and try again.")
        case .automation:
            return String(localized: "macOS did not let PhotoHub move “\(name)” to the Trash itself, and PhotoHub is not allowed to ask Finder to do it (\(codes)). \(Consent.automation.instruction) and try deleting again.")
        case nil:
            return String(localized: "Could not move “\(name)” to the Trash either directly or through Finder (\(codes)): \(all.last?.1.localizedDescription ?? e.localizedDescription)")
        }
    }

    private static let offerLock = NSLock()
    private static var lastOffer = Date.distantPast

    static func offerSettings(_ error: Error) {
        guard let consent = consent(error), ProcessInfo.processInfo.environment["PHOTOHUB_SNAPSHOT"] == nil else { return }
        offerLock.lock()
        let fresh = Date().timeIntervalSince(lastOffer) > 30
        if fresh { lastOffer = Date() }
        offerLock.unlock()
        guard fresh else { return }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            switch consent {
            case .fullDisk:
                alert.messageText = String(localized: "Full Disk Access Is Needed")
                alert.informativeText = String(localized: "Without it, macOS does not let PhotoHub move archive files to the Trash. \(Consent.fullDisk.instruction).")
            case .automation:
                alert.messageText = String(localized: "Allow PhotoHub to Control Finder")
                alert.informativeText = String(localized: "macOS did not let PhotoHub move the file to the Trash itself, so PhotoHub asks Finder to do it. The iCloud file is not downloaded and goes to Recently Deleted in iCloud Drive. \(Consent.automation.instruction).")
            }
            alert.addButton(withTitle: String(localized: "Open Settings"))
            alert.addButton(withTitle: String(localized: "Close"))
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(consent.pane) }
        }
    }

    static func photosMessage(_ error: Error?) -> String {
        guard let e = error as NSError? else { return String(localized: "Photos did not delete the items and gave no reason.") }
        let code = "\(e.domain) \(e.code)"
        if (e.domain == NSCocoaErrorDomain && e.code == NSUserCancelledError) || (e.domain == PHPhotosErrorDomain && e.code == PHPhotosError.userCancelled.rawValue) {
            return String(localized: "Deletion was cancelled in the Photos confirmation window. Nothing was deleted.")
        }
        if e.domain == PHPhotosErrorDomain && [PHPhotosError.accessUserDenied.rawValue, PHPhotosError.accessRestricted.rawValue].contains(e.code) {
            return String(localized: "No full access to the Photos library (\(code)). System Settings → Privacy & Security → Photos → PhotoHub → Full Access.")
        }
        return String(localized: "Photos did not delete the items: \(e.localizedDescription) (\(code)).")
    }

    static func deleteAssets(_ ids: [String], completion: @escaping (PhotosDeletion) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized else {
            completion(.failed(status == .limited
                       ? String(localized: "PhotoHub has limited access to Photos, and deleting needs full access. System Settings → Privacy & Security → Photos → PhotoHub → Full Access.")
                       : String(localized: "No access to the Photos library. System Settings → Privacy & Security → Photos → PhotoHub → Full Access.")))
            return
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard assets.count > 0 else {
            completion(.failed(String(localized: "These items were not found in the Photos library.")))
            return
        }
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assets)
        }) { ok, error in
            if ok { return completion(.deleted) }
            completion(isCancel(error) ? .cancelled : .failed(photosMessage(error)))
        }
    }

    private static func isCancel(_ error: Error?) -> Bool {
        guard let e = error as NSError? else { return false }
        return (e.domain == NSCocoaErrorDomain && e.code == NSUserCancelledError) || (e.domain == PHPhotosErrorDomain && e.code == PHPhotosError.userCancelled.rawValue)
    }

    static var photosDeleter: ([String], @escaping (PhotosDeletion) -> Void) -> Void = { deleteAssets($0, completion: $1) }

    static func photoBatch(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func size(_ url: URL) -> Int64 {
        var st = stat()
        return lstat(url.path, &st) == 0 ? Int64(st.st_size) : -1
    }

    static func inode(_ url: URL) -> UInt64 {
        var st = stat()
        return lstat(url.path, &st) == 0 ? UInt64(st.st_ino) : 0
    }

    static func execute(photos: [String], files: [(url: URL, name: String)], trashing: @escaping () -> Void = {},
                        progress: @escaping (Int) -> Void = { _ in }, completion: @escaping (RemovalOutcome) -> Void) {
        let batch = photoBatch(photos)
        func trashFiles(_ start: RemovalOutcome) {
            guard !files.isEmpty else { return completion(start) }
            trashing()
            DispatchQueue.global(qos: .userInitiated).async {
                var outcome = start
                for (index, file) in files.enumerated() {
                    let bytes = size(file.url), node = inode(file.url), started = Date()
                    switch trash(file.url) {
                    case .success(let moved):
                        let record = TrashedFile(original: file.url, trashed: nil, size: bytes, inode: node, at: started)
                        outcome.trashed.append((index, TrashedFile(original: file.url, trashed: moved ?? locate(record), size: bytes, inode: node, at: started)))
                    case .failure(let error):
                        outcome.failures.append((index, message(error, name: file.name)))
                    }
                    if index % 10 == 9 { progress(index + 1) }
                }
                completion(outcome)
            }
        }
        guard !batch.isEmpty else { return trashFiles(RemovalOutcome(photos: nil)) }
        photosDeleter(batch) { result in
            guard case .deleted = result else { return completion(RemovalOutcome(photos: result)) }
            trashFiles(RemovalOutcome(photos: .deleted))
        }
    }

    static func trashFolders(for url: URL) -> [URL] {
        var dirs: [URL] = []
        if inICloud(url) { dirs.append(mobileDocuments.appendingPathComponent(".Trash")) }
        if cloudRoot == nil { dirs.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")) }
        return dirs
    }

    static func place(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let root = Catalog.archiveRoot.standardizedFileURL.path
        if path == root { return String(localized: "archive root") }
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private static func fold(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }

    private static func belongs(_ entry: String, to original: String) -> Bool {
        let name = fold(original), candidate = fold(entry)
        if candidate == name { return true }
        let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
        return (candidate as NSString).pathExtension == ext && candidate.hasPrefix(stem + " ")
    }

    static func locate(_ file: TrashedFile) -> URL? {
        let name = file.original.lastPathComponent
        var best: (url: URL, distance: Double)?
        for dir in trashFolders(for: file.original) {
            guard let list = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for entry in list where belongs(entry, to: name) {
                let url = dir.appendingPathComponent(entry)
                var st = stat()
                guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { continue }
                if file.inode != 0 && UInt64(st.st_ino) == file.inode { return url }
                guard file.size < 0 || Int64(st.st_size) == file.size else { continue }
                let changed = Double(st.st_ctimespec.tv_sec) + Double(st.st_ctimespec.tv_nsec) / 1e9
                let distance = abs(changed - file.at.timeIntervalSince1970)
                if best.map({ distance < $0.distance }) ?? true { best = (url, distance) }
            }
        }
        return best?.url
    }

    static func find(_ file: TrashedFile) -> URL? {
        if let url = file.trashed, url.standardizedFileURL != file.original.standardizedFileURL {
            var st = stat()
            if lstat(url.path, &st) == 0, (file.inode != 0 && UInt64(st.st_ino) == file.inode) || file.size < 0 || Int64(st.st_size) == file.size {
                return url
            }
        }
        return locate(file)
    }

    static var settleLimit: TimeInterval = 60
    static var watchTime: TimeInterval = 3

    private static func syncing(_ url: URL) -> Bool {
        var url = url
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.ubiquitousItemIsUploadingKey]))?.ubiquitousItemIsUploading == true
    }

    private static func settle(_ url: URL, since: Date, until deadline: Date) {
        var calm = 0
        while Date() < deadline {
            if Date().timeIntervalSince(since) >= 2, !syncing(url) {
                calm += 1
                if calm >= 2 { return }
            } else {
                calm = 0
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private static func describe(_ error: Error) -> String {
        let e = error as NSError
        var codes = ["\(e.domain) \(e.code)"]
        if let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError { codes.append("\(underlying.domain) \(underlying.code)") }
        return "\(e.localizedDescription) (\(codes.joined(separator: "; ")))"
    }

    private static func move(_ source: URL, to target: URL) -> PutBackFailure? {
        if renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 { return nil }
        let code = errno
        if code == EEXIST { return .occupied }
        let renamed = "rename: \(String(cString: strerror(code))) (\(NSPOSIXErrorDomain) \(code))"
        var coordination: NSError?
        var inner: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: target, options: [], error: &coordination) { from, to in
            guard !exists(to) else { return }
            do {
                try FileManager.default.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            } catch {
                inner = error
            }
        }
        if exists(target) { return exists(source) ? .occupied : nil }
        guard let error = coordination ?? inner else { return .failed(renamed) }
        return .failed(renamed + "; " + describe(error))
    }

    static func putBack(_ file: TrashedFile, to target: URL? = nil) -> PutBackResult {
        putBack([file], to: target.map { [0: $0] } ?? [:])[0]
    }

    static func putBack(_ files: [TrashedFile], to targets: [Int: URL] = [:]) -> [PutBackResult] {
        var results = files.enumerated().map { PutBackResult(file: $0.element, target: targets[$0.offset] ?? $0.element.original) }
        var since = files.map(\.at)
        var pending = Array(files.indices)
        let deadline = Date().addingTimeInterval(settleLimit)
        for attempt in 1...3 where !pending.isEmpty {
            var moved: [Int] = []
            for index in pending {
                var result = results[index]
                defer { results[index] = result }
                result.attempts += 1
                let file = result.file, target = result.target
                if exists(target) {
                    let same = file.inode != 0 && inode(target) == file.inode
                    result.source = same ? nil : find(file)
                    result.failure = same ? nil : result.source == nil ? .missing : .occupied
                    continue
                }
                guard let source = find(file) else {
                    result.source = nil
                    result.failure = .missing
                    continue
                }
                result.source = source
                do {
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                } catch {
                    result.failure = .failed(describe(error))
                    continue
                }
                let cloud = inICloud(target) || inICloud(source)
                if cloud && attempt > 1 { settle(source, since: since[index], until: min(deadline, Date().addingTimeInterval(15))) }
                result.failure = move(source, to: target)
                if result.failure == nil && cloud { moved.append(index) }
            }
            guard !moved.isEmpty else { break }
            let started = Date()
            var back: Set<Int> = []
            repeat {
                Thread.sleep(forTimeInterval: 0.25)
                for index in moved where !exists(results[index].target) { back.insert(index) }
            } while Date().timeIntervalSince(started) < watchTime
                || (Date() < min(deadline, started.addingTimeInterval(10)) && moved.contains { !back.contains($0) && syncing(results[$0].target) })
            for index in back {
                results[index].failure = .retrashed
                results[index].source = find(results[index].file)
                since[index] = Date()
            }
            pending = moved.filter { back.contains($0) }
        }
        return results
    }

    static func freeName(beside target: URL) -> URL {
        let dir = target.deletingLastPathComponent(), name = target.lastPathComponent
        let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
        for n in 2...9999 {
            let candidate = dir.appendingPathComponent("\(stem) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            if !exists(candidate) { return candidate }
        }
        return dir.appendingPathComponent("\(stem) \(UUID().uuidString.prefix(8))" + (ext.isEmpty ? "" : ".\(ext)"))
    }

    static func reveal(_ results: [PutBackResult]) {
        let found = results.compactMap { $0.source }.filter { exists($0) }
        if !found.isEmpty { return NSWorkspace.shared.activateFileViewerSelecting(found) }
        let folders = results.flatMap { trashFolders(for: $0.file.original) }.filter { exists($0) }
        if let folder = folders.first { NSWorkspace.shared.open(folder) }
    }

    private static let testLock = NSLock()
    private static var tests = 0

    static var testing: Bool {
        testLock.lock()
        defer { testLock.unlock() }
        return tests > 0
    }

    static func selfTest(_ report: String, options: String) {
        testLock.lock()
        tests += 1
        testLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            runSelfTest(report, options: options)
            testLock.lock()
            tests -= 1
            testLock.unlock()
        }
    }

    private static func macl(_ url: URL) -> String {
        var buffer = [UInt8](repeating: 0, count: 256)
        let n = getxattr(url.path, "com.apple.macl", &buffer, buffer.count, 0, XATTR_NOFOLLOW)
        return n < 0 ? "-" : buffer.prefix(n).map { String(format: "%02x", $0) }.joined()
    }

    private static func testItem(_ key: String) -> Item {
        Item(id: Int64(key.hashValue & 0xffff), key: key, date: "", dateExact: false, title: key, root: "", inArchive: true, inPhotos: true,
             hasRaw: false, nEdit: 0, nMembers: 0, thumbAsset: "", thumbPath: "", isVideo: false, formats: "", size: 0)
    }

    private static func testMember(_ source: String, _ path: String, role: String = "photo") -> Member {
        Member(id: 0, source: source, path: path, name: (path as NSString).lastPathComponent, ext: (path as NSString).pathExtension, size: 1,
               role: role, taken: "", width: 0, height: 0)
    }

    private static func runScopeTest(folder: URL, log: (String) -> Void) {
        let saved = photosDeleter
        defer { photosDeleter = saved }
        var asked: [[String]] = []
        photosDeleter = { ids, done in
            asked.append(ids)
            done(.deleted)
        }
        let s = testItem("S"), t = testItem("T")
        let names = ["S.JPG", "S.RAF", "T.JPG", "T.RAF"].map { "_photohub_delete_flow-DSCF\($0)" }
        let urls = names.map { folder.appendingPathComponent($0) }
        for url in urls where !exists(url) { try? Data("flow \(url.lastPathComponent)\n".utf8).write(to: url) }
        func present() -> String { urls.map { exists($0) ? "1" : "0" }.joined() }
        func stack(_ i: Int) -> [Member] {
            Versions.ordered([testMember("archive", names[i + 1], role: "raw"), testMember("archive", names[i])], choice: nil, thumbPath: "")
        }
        func run(_ plan: RemovalPlan) -> DeletionRecord {
            let finished = DispatchSemaphore(value: 0)
            var result = RemovalOutcome()
            execute(photos: plan.photoIDs, files: plan.archive.map { (url: folder.appendingPathComponent($0.1.path), name: $0.1.name) }) { outcome in
                result = outcome
                finished.signal()
            }
            _ = finished.wait(timeout: .now() + 120)
            return DeletionRecord(files: result.trashed.map { (key: plan.archive[$0.index].0.key, path: plan.archive[$0.index].1.path, file: $0.file) },
                                  backups: [:], label: plan.heading)
        }
        var history = DeletionHistory()
        let sVersions = stack(0)
        log("scope versions of S: \(sVersions.map { "\($0.name)(\($0.role))" }.joined(separator: ", "))")
        let raw = RemovalPlan.focused(s, versions: sVersions, index: 1)
        _ = history.push(run(raw))
        let rawOK = raw.version?.role == "raw" && raw.archive.map { $0.1.path } == [names[1]] && raw.keptArchive.map { $0.path } == [names[0]]
            && raw.vanishing == 0 && present() == "1011"
        log("non-main version: \(raw.heading) | trashed \(raw.archive.map { $0.1.name }) kept \(raw.keptArchive.map { $0.name }) vanishing \(raw.vanishing) present \(present())")
        log("non-main version scope ok: \(rawOK)")
        let main = RemovalPlan.focused(t, versions: stack(2), index: 0)
        _ = history.push(run(main))
        let mainOK = main.version == nil && main.scope == .everywhere && Set(main.archive.map { $0.1.path }) == Set([names[2], names[3]])
            && main.vanishing == 1 && present() == "1000"
        log("main version: \(main.heading) | trashed \(main.archive.map { $0.1.name }) vanishing \(main.vanishing) present \(present())")
        log("main version scope ok: \(mainOK)")
        let last = RemovalPlan.focused(s, versions: [testMember("archive", names[0])], index: 0)
        _ = history.push(run(last))
        log("last version: \(last.heading) | present \(present())")
        let photo = RemovalPlan.focused(s, versions: [testMember("archive", names[0]), testMember("photos", "P9/L0/001")], index: 1)
        log("photos version: \(photo.heading) | photo ids \(photo.photoIDs) archive \(photo.archive.count) kept archive \(photo.keptArchive.count)")
        let photoOK = photo.photoIDs == ["P9/L0/001"] && photo.archive.isEmpty && photo.keptArchive.count == 1
        log("photos version scope ok: \(photoOK)")
        var order: [String] = []
        var states: [String] = []
        while let record = history.take(nil) {
            let errors = putBack(record.files.map(\.file)).filter { $0.failure != nil }
            order.append(record.files.map { ($0.path as NSString).lastPathComponent }.sorted().joined(separator: "+"))
            states.append(present() + (errors.isEmpty ? "" : " errors \(errors.count)"))
        }
        log("undo order: \(order.joined(separator: " | ")) -> present \(states.joined(separator: ", "))")
        log("undo history ok: \(states == ["1000", "1011", "1111"] && order.count == 3)")
        var capped = DeletionHistory()
        let pushed = (0..<25).map { _ in DeletionRecord(files: [], backups: [:]) }
        var dropped: [UUID] = []
        for record in pushed { dropped += capped.push(record).map { $0.id } }
        let capOK = capped.records.count == DeletionHistory.limit && dropped == pushed.prefix(5).map { $0.id } && capped.records.last?.id == pushed.last?.id
        log("history cap: kept \(capped.records.count), dropped \(dropped.count), ok: \(capOK)")
        log("photos asked: \(asked.count)")
        for url in urls { unlink(url.path) }
        log("scope files left: \(present())")
    }

    private static func runFlowTest(folder: URL, ext: String, list: Bool, log: (String) -> Void) {
        let saved = photosDeleter
        defer { photosDeleter = saved }
        let names = ["a1", "b1", "c1"].map { "_photohub_delete_flow-\($0).\(ext)" }
        let urls = names.map { folder.appendingPathComponent($0) }
        func content(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "-" }
        func make() {
            for url in urls where !exists(url) { try? Data("flow \(url.lastPathComponent)\n".utf8).write(to: url) }
        }
        func present() -> String { urls.map { exists($0) ? "1" : "0" }.joined() }
        let a = testItem("A"), b = testItem("B"), c = testItem("C")
        let plan = RemovalPlan(scope: .everywhere, items: [a, b, c],
                               archive: [(a, testMember("archive", names[0])), (b, testMember("archive", names[1])), (c, testMember("archive", names[2]))],
                               photos: [(a, testMember("photos", "P1/L0/001")), (a, testMember("photos", "P2/L0/001")), (b, testMember("photos", "P3/L0/001")),
                                        (c, testMember("photos", "P1/L0/001")), (c, testMember("photos", "P4/L0/001"))],
                               keptArchive: [], keptPhotos: [], vanishing: 3)
        log("grouping: \(plan.photos.count) Photos members of \(plan.items.count) shots -> one batch \(plan.photoIDs)")
        let files = plan.archive.map { (url: folder.appendingPathComponent($0.1.path), name: $0.1.name) }
        func run(_ answer: PhotosDeletion?, _ photos: [String]) -> (calls: [[String]], before: String, outcome: RemovalOutcome) {
            var calls: [[String]] = []
            var before = "-"
            photosDeleter = { ids, done in
                calls.append(ids)
                before = present()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { done(answer ?? .deleted) }
            }
            let finished = DispatchSemaphore(value: 0)
            var result = RemovalOutcome()
            execute(photos: photos, files: files) { outcome in
                result = outcome
                finished.signal()
            }
            _ = finished.wait(timeout: .now() + 120)
            return (calls, before, result)
        }
        func putBackAll(_ outcome: RemovalOutcome, _ label: String) {
            let results = putBack(outcome.trashed.map(\.file))
            log("\(label) put back: \(results.filter { $0.failure == nil }.count) of \(outcome.trashed.count), present \(present()), same content \(urls.allSatisfy { content($0).hasPrefix("flow ") })")
            for result in results where result.failure != nil { log("  error: \(result.message)") }
        }
        for (label, answer) in [("accepted", PhotosDeletion.deleted), ("cancelled", .cancelled), ("failed", .failed("test"))] {
            make()
            let r = run(answer, plan.photoIDs)
            log("\(label): performChanges calls \(r.calls.count) with \(r.calls.map { $0.count }) ids, archive present while Photos asked \(r.before), trashed \(r.outcome.trashed.count), failures \(r.outcome.failures.count), present after \(present())")
            for t in r.outcome.trashed { log("  \(t.file.original.lastPathComponent) -> \(t.file.trashed?.path ?? "-")") }
            putBackAll(r.outcome, label)
        }
        make()
        let r = run(nil, [])
        log("archive only: performChanges calls \(r.calls.count), trashed \(r.outcome.trashed.count), present after \(present())")
        putBackAll(r.outcome, "archive only")
        make()
        let bytes = size(urls[0]), node = inode(urls[0]), started = Date()
        if case .success(let moved) = trash(urls[0]) {
            let listing = list || !inICloud(urls[0])
            let file = TrashedFile(original: urls[0], trashed: listing ? nil : moved, size: bytes, inode: node, at: started)
            if listing {
                let listable = trashFolders(for: urls[0]).map { "\($0.lastPathComponent) \((try? FileManager.default.contentsOfDirectory(atPath: $0.path)) != nil)" }
                log("no resulting url: located \(locate(file)?.path ?? "-"), trash listable: \(listable)")
            } else {
                log("no resulting url: not listing the iCloud Drive Trash without the list option")
            }
            try? Data("occupied\n".utf8).write(to: urls[0])
            let occupied = putBack(TrashedFile(original: urls[0], trashed: moved, size: bytes, inode: node, at: started))
            log("occupied original: \(occupied.failure == .occupied ? occupied.message : "put back (wrong)")")
            unlink(urls[0].path)
            let located = putBack(file)
            log("after freeing the place, without the resulting url: \(located.failure == nil ? "put back" : located.message)")
            if located.failure != nil, let moved {
                let direct = putBack(TrashedFile(original: urls[0], trashed: moved, size: bytes, inode: node, at: started))
                log("after freeing the place, with the resulting url: \(direct.failure == nil ? "put back" : direct.message)")
            }
            log("content: \(content(urls[0]).hasPrefix("flow ") ? "original" : "-")")
        }
        for url in urls { unlink(url.path) }
        log("left in archive: \(present())")
    }

    private static func write(_ url: URL, _ text: String) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
    }

    private static func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "-" }

    private static func runMockTrashTest(log: (String) -> Void) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("photohub-trash-mock-\(getpid())-\(UUID().uuidString.prefix(8))")
        let root = base.appendingPathComponent("Mobile Documents")
        let trash = root.appendingPathComponent(".Trash")
        let archive = root.appendingPathComponent("com~apple~CloudDocs/Photos")
        let saved = (cloudRoot, watchTime)
        cloudRoot = root
        watchTime = 1.5
        defer {
            (cloudRoot, watchTime) = saved
            try? FileManager.default.removeItem(at: base)
        }
        try? FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        func toTrash(_ url: URL, as name: String) -> TrashedFile {
            let file = TrashedFile(original: url, trashed: nil, size: size(url), inode: inode(url), at: Date())
            _ = renamex_np(url.path, trash.appendingPathComponent(name).path, UInt32(RENAME_EXCL))
            return file
        }
        func strip(_ file: TrashedFile, inode node: UInt64? = nil, trashed: URL? = nil) -> TrashedFile {
            TrashedFile(original: file.original, trashed: trashed, size: file.size, inode: node ?? file.inode, at: file.at)
        }
        func inTrash() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).sorted() }

        let rivne = archive.appendingPathComponent("2026-07-10 Rivne ")
        let a = rivne.appendingPathComponent("RAW/DSCF3119.RAF"), b = rivne.appendingPathComponent("RAW/DSCF3120.RAF")
        write(trash.appendingPathComponent("DSCF3119.RAF"), "decoy of another size\n")
        write(trash.appendingPathComponent("DSCF3119 3.RAF"), "decoy A\n")
        write(trash.appendingPathComponent("DSCF3120 3.RAF"), "decoy B\n")
        Thread.sleep(forTimeInterval: 1.2)
        write(a, "mock A\n")
        write(b, "mock B\n")
        let fileA = toTrash(a, as: "DSCF3119 2.RAF"), fileB = toTrash(b, as: "dscf3120 2.raf")
        try? FileManager.default.removeItem(at: rivne)
        let foundA = locate(fileA)?.lastPathComponent ?? "-", foundB = locate(strip(fileB, inode: 0))?.lastPathComponent ?? "-"
        let backA = putBack(fileA), backB = putBack(strip(fileB, inode: 0))
        let renamedOK = foundA == "DSCF3119 2.RAF" && foundB == "dscf3120 2.raf" && backA.failure == nil && backB.failure == nil
            && text(a) == "mock A\n" && text(b) == "mock B\n" && inTrash() == ["DSCF3119 3.RAF", "DSCF3119.RAF", "DSCF3120 3.RAF"]
        log("mock icloud trash: located \(foundA) by inode, \(foundB) by name, size and time; put back into “\(place(a.deletingLastPathComponent()))” recreated: \(exists(a)) \(exists(b)); trash \(inTrash())")
        log("mock renamed duplicates ok: \(renamedOK)")

        let c = archive.appendingPathComponent("2026-03-Rome/RAW/DSCF3121.RAF")
        write(c, "mock C\n")
        let fileC = strip(toTrash(c, as: "DSCF3121.RAF"), trashed: trash.appendingPathComponent("DSCF3121.RAF"))
        write(c, "another file\n")
        let occupied = putBack(fileC)
        let occupiedOK = occupied.failure == .occupied && text(c) == "another file\n" && occupied.source.map(exists) == true
        log("mock occupied: \(occupied.message)")
        log("mock occupied ok: \(occupiedOK)")
        let beside = freeName(beside: c)
        let both = putBack(fileC, to: beside)
        let bothOK = both.failure == nil && beside.lastPathComponent == "DSCF3121 2.RAF" && text(beside) == "mock C\n" && text(c) == "another file\n"
        log("mock keep both: \(beside.lastPathComponent), ok: \(bothOK)")

        let d = archive.appendingPathComponent("2026-03-Rome/RAW/DSCF3122.RAF")
        write(d, "mock D\n")
        let fileD = strip(toTrash(d, as: "DSCF3122.RAF"), trashed: trash.appendingPathComponent("DSCF3122.RAF"))
        let provider = DispatchSemaphore(value: 0)
        var retrashed = false
        DispatchQueue.global().async {
            let until = Date().addingTimeInterval(20)
            while !exists(d) && Date() < until { Thread.sleep(forTimeInterval: 0.05) }
            Thread.sleep(forTimeInterval: 0.3)
            retrashed = renamex_np(d.path, trash.appendingPathComponent("DSCF3122.RAF").path, UInt32(RENAME_EXCL)) == 0
            provider.signal()
        }
        let again = putBack(fileD)
        _ = provider.wait(timeout: .now() + 30)
        let againOK = retrashed && again.failure == nil && again.attempts == 2 && text(d) == "mock D\n" && !inTrash().contains("DSCF3122.RAF")
        log("mock put back undone by the provider: retrashed \(retrashed), attempts \(again.attempts), present \(exists(d)), ok: \(againOK)")

        let e = archive.appendingPathComponent("2026-03-Rome/RAW/DSCF3123.RAF")
        write(e, "mock E\n")
        let fileE = toTrash(e, as: "DSCF3123.RAF")
        unlink(trash.appendingPathComponent("DSCF3123.RAF").path)
        let missing = putBack(fileE)
        log("mock missing: \(missing.message)")
        log("mock missing ok: \(missing.failure == .missing && !exists(e))")
    }

    private static func runCloudTest(folder: URL, dataless: Bool, log: (String) -> Void) {
        guard cloudRoot == nil, inICloud(folder) else { return log("icloud: skipped, \(place(folder)) is not in iCloud Drive") }
        let spaced = folder.appendingPathComponent("_photohub_undo 2026-07-10 Rivne ")
        let urls = (1...3).map { folder.appendingPathComponent("RAW/_photohub_undo-DSCF000\($0).RAF") }
            + (4...6).map { spaced.appendingPathComponent("RAW/_photohub_undo-DSCF000\($0).RAF") }
        let created = [spaced.appendingPathComponent("RAW"), spaced, folder.appendingPathComponent("RAW")].filter { !exists($0) }
        for url in urls { write(url, "cloud \(url.lastPathComponent)\n" + String(repeating: "x", count: 4096)) }
        if dataless {
            let deadline = Date().addingTimeInterval(240)
            while Date() < deadline && urls.contains(where: { Thumbs.isLocal($0) }) {
                for url in urls where Thumbs.isLocal(url) { try? FileManager.default.evictUbiquitousItem(at: url) }
                Thread.sleep(forTimeInterval: 3)
            }
            log("icloud dataless: \(urls.map { Thumbs.isLocal($0) ? "0" : "1" }.joined())")
        }
        func present() -> String { urls.map { exists($0) ? "1" : "0" }.joined() }
        var records: [TrashedFile] = []
        var trashErrors: [String] = []
        for url in urls {
            let done = DispatchSemaphore(value: 0)
            execute(photos: [], files: [(url: url, name: url.lastPathComponent)]) { outcome in
                records += outcome.trashed.map(\.file)
                trashErrors += outcome.failures.map(\.message)
                done.signal()
            }
            _ = done.wait(timeout: .now() + 120)
        }
        for error in trashErrors { log("icloud trash error: \(error)") }
        log("icloud trashed one by one: \(records.count), present \(present()), recorded \(records.map { $0.trashed.map { place($0) } ?? "-" })")
        var states: [String] = []
        var attempts: [Int] = []
        var errors: [String] = []
        for file in records.reversed() {
            let started = Date()
            let result = putBack(file)
            attempts.append(result.attempts)
            if result.failure != nil { errors.append(result.message) }
            states.append(present() + String(format: " %.1fs", Date().timeIntervalSince(started)))
        }
        log("icloud undo newest first: \(states.joined(separator: ", ")), attempts \(attempts)")
        for error in errors { log("  error: \(error)") }
        Thread.sleep(forTimeInterval: 10)
        func trashed(_ file: TrashedFile) -> URL? { file.trashed.flatMap { inode($0) == file.inode ? $0 : nil } }
        let leftInTrash = records.compactMap(trashed)
        log("icloud after 10 s: present \(present()), in trash \(leftInTrash.count), ok: \(present() == "111111" && leftInTrash.isEmpty && errors.isEmpty)")
        func trashOne(_ url: URL) -> TrashedFile? {
            var file: TrashedFile?
            let done = DispatchSemaphore(value: 0)
            execute(photos: [], files: [(url: url, name: url.lastPathComponent)]) { outcome in
                file = outcome.trashed.first?.file
                done.signal()
            }
            _ = done.wait(timeout: .now() + 120)
            return file
        }
        for (index, delay) in [2.0, 1.5, 2.0, 2.5].enumerated() {
            let url = urls[5]
            guard let file = trashOne(url), let source = file.trashed else { continue }
            Thread.sleep(forTimeInterval: delay)
            if index == 0 {
                let renamed = renamex_np(source.path, url.path, UInt32(RENAME_EXCL)) == 0
                Thread.sleep(forTimeInterval: 8)
                log("icloud plain rename \(delay) s after the trash: renamed \(renamed), after 8 s in place \(exists(url)), back in the trash \(trashed(file) != nil)")
                if !exists(url) { _ = putBack(file) }
            } else {
                let result = putBack(file)
                Thread.sleep(forTimeInterval: 8)
                log("icloud put back \(delay) s after the trash: attempts \(result.attempts), \(result.failure == nil ? "ok" : result.message), after 8 s in place \(exists(url)), in the trash \(trashed(file) != nil)")
            }
        }
        let occupiedURL = urls[0]
        var occupied: TrashedFile?
        let done = DispatchSemaphore(value: 0)
        execute(photos: [], files: [(url: occupiedURL, name: occupiedURL.lastPathComponent)]) { outcome in
            occupied = outcome.trashed.first?.file
            done.signal()
        }
        _ = done.wait(timeout: .now() + 120)
        write(occupiedURL, "another file\n")
        if let occupied {
            let blocked = putBack(occupied)
            let beside = freeName(beside: occupiedURL)
            let both = putBack(occupied, to: beside)
            log("icloud occupied: \(blocked.failure == .occupied), kept the other file \(text(occupiedURL) == "another file\n"), keep both \(both.failure == nil ? beside.lastPathComponent : both.message)")
            unlink(beside.path)
        }
        for url in urls { unlink(url.path) }
        for dir in created { rmdir(dir.path) }
        let cleaned = (records + [occupied].compactMap { $0 }).compactMap(trashed).filter { unlink($0.path) == 0 }.count
        log("icloud files left: \(present()), removed from the trash: \(cleaned)")
    }

    private static func runSelfTest(_ report: String, options: String) {
        var settings: [String: String] = [:]
        for part in options.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            settings[pair[0]] = pair.count == 2 ? pair[1] : ""
        }
        let dataless = settings["dataless"] != nil
        let folder = settings["dir"].map { Catalog.archiveRoot.appendingPathComponent($0) } ?? Catalog.archiveRoot
        let ext = settings["ext"] ?? "txt"
        let size = Int(settings["size"] ?? "") ?? 5
        askFinder = settings["askfinder"] != nil
        let methods: [[Method]] = settings["each"] != nil ? Method.allCases.map { [$0] }
            : settings["only"].map { $0.split(separator: "+").compactMap { Method(rawValue: String($0)) } }.map { [$0] } ?? [order]
        var lines = ["start: \(Date())", "bundle: \(Bundle.main.bundleIdentifier ?? "-")", "pid: \(getpid())", "options: \(options)",
                     "finder permission (no prompt): \(finderPermission(ask: false))"] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: report, atomically: true, encoding: .utf8) }
        }
        if settings["flow"] != nil {
            runFlowTest(folder: folder, ext: ext, list: settings["list"] != nil) { lines.append($0) }
            runScopeTest(folder: folder) { lines.append($0) }
            runMockTrashTest { lines.append($0) }
            runCloudTest(folder: folder, dataless: dataless) { lines.append($0) }
            lines.append("done")
            return
        }
        var files: [(URL, [Method])] = []
        for (index, chain) in methods.enumerated() {
            let label = chain.map(\.rawValue).joined(separator: "+")
            let url = folder.appendingPathComponent("_photohub_delete_test-\(index)-\(label).\(ext)")
            do {
                if !exists(url) {
                    var data = Data("test \(label) \(Date())\n".utf8)
                    if size > data.count { data.append(Data(count: size - data.count)) }
                    try data.write(to: url)
                    lines.append("created \(url.lastPathComponent): by app")
                } else {
                    lines.append("created \(url.lastPathComponent): already existed")
                }
                files.append((url, chain))
            } catch {
                lines.append("created \(url.lastPathComponent): no")
                lines.append(dump(error))
            }
        }
        if dataless {
            let deadline = Date().addingTimeInterval(300)
            while Date() < deadline && files.contains(where: { Thumbs.isLocal($0.0) }) {
                for (url, _) in files where Thumbs.isLocal(url) { try? FileManager.default.evictUbiquitousItem(at: url) }
                Thread.sleep(forTimeInterval: 3)
            }
        }
        for (url, chain) in files where settings["createonly"] == nil {
            let label = chain.map(\.rawValue).joined(separator: "+")
            lines.append("== \(label): \(url.path)")
            lines.append("dataless before: \(!Thumbs.isLocal(url))")
            lines.append("macl: \(macl(url))")
            let started = Date()
            switch trash(url, methods: chain) {
            case .success(let moved):
                lines.append("result: ok in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
                lines.append("moved to: \(moved?.path ?? "-")")
                if let moved {
                    lines.append("exists at destination: \(exists(moved))")
                    lines.append("dataless at destination: \(!Thumbs.isLocal(moved))")
                }
            case .failure(let error):
                lines.append("result: error")
                lines.append(dump(error))
                lines.append("consent: \(consent(error).map { "\($0)" } ?? "-")")
                lines.append("message: \(message(error, name: url.lastPathComponent))")
            }
            lines.append("left in archive: \(exists(url))")
            if exists(url) {
                let removed = unlink(url.path) == 0
                lines.append("leftover unlinked: \(removed ? "yes" : String(cString: strerror(errno)))")
            }
        }
        lines.append("done")
    }
}
