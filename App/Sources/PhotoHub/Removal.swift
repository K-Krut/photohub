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
}

struct RemovalOutcome {
    var photos: PhotosDeletion?
    var trashed: [(index: Int, file: TrashedFile)] = []
    var failures: [(index: Int, message: String)] = []

    var accepted: Bool { photos == nil || photos == .deleted }
}

enum Removal {
    static let mobileDocuments = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents")
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

    static func execute(photos: [String], files: [(url: URL, name: String)], trashing: @escaping () -> Void = {},
                        progress: @escaping (Int) -> Void = { _ in }, completion: @escaping (RemovalOutcome) -> Void) {
        let batch = photoBatch(photos)
        func trashFiles(_ start: RemovalOutcome) {
            guard !files.isEmpty else { return completion(start) }
            trashing()
            DispatchQueue.global(qos: .userInitiated).async {
                var outcome = start
                for (index, file) in files.enumerated() {
                    let bytes = size(file.url)
                    switch trash(file.url) {
                    case .success(let moved):
                        outcome.trashed.append((index, TrashedFile(original: file.url, trashed: moved ?? locate(file.url, size: bytes), size: bytes)))
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
        dirs.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
        return dirs
    }

    static func locate(_ original: URL, size bytes: Int64) -> URL? {
        let name = original.lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        let stem = (name as NSString).deletingPathExtension
        var best: (URL, Int) = (original, -1)
        for dir in trashFolders(for: original) {
            guard let list = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for entry in list where (entry as NSString).pathExtension.lowercased() == ext && (entry == name || entry.hasPrefix(stem + " ")) {
                let url = dir.appendingPathComponent(entry)
                var st = stat()
                guard lstat(url.path, &st) == 0, bytes < 0 || Int64(st.st_size) == bytes else { continue }
                if st.st_ctimespec.tv_sec > best.1 { best = (url, st.st_ctimespec.tv_sec) }
            }
        }
        return best.1 >= 0 ? best.0 : nil
    }

    static func putBack(_ file: TrashedFile) -> Error? {
        guard let source = file.trashed.flatMap({ exists($0) ? $0 : nil }) ?? locate(file.original, size: file.size) else {
            return NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: [NSFilePathErrorKey: file.original.path,
                NSLocalizedDescriptionKey: String(localized: "“\(file.original.lastPathComponent)” is no longer in the Trash.")])
        }
        if exists(file.original) {
            return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: [NSFilePathErrorKey: file.original.path,
                NSLocalizedDescriptionKey: String(localized: "Another file named “\(file.original.lastPathComponent)” is already in its place.")])
        }
        do {
            try FileManager.default.createDirectory(at: file.original.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return error
        }
        if renamex_np(source.path, file.original.path, UInt32(RENAME_EXCL)) == 0 { return nil }
        do {
            try FileManager.default.moveItem(at: source, to: file.original)
            return nil
        } catch {
            return error
        }
    }

    static func selfTest(_ report: String, options: String) {
        DispatchQueue.global(qos: .userInitiated).async { runSelfTest(report, options: options) }
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
            let errors = record.files.compactMap { putBack($0.file) }
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

    private static func runFlowTest(folder: URL, ext: String, log: (String) -> Void) {
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
            let errors = outcome.trashed.map { putBack($0.file) }
            log("\(label) put back: \(errors.filter { $0 == nil }.count) of \(outcome.trashed.count), present \(present()), same content \(urls.allSatisfy { content($0).hasPrefix("flow ") })")
            for error in errors.compactMap({ $0 }) { log("  error: \(error.localizedDescription)") }
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
        if case .success(let moved) = trash(urls[0]) {
            let file = TrashedFile(original: urls[0], trashed: nil, size: size(moved ?? urls[0]))
            let listable = trashFolders(for: urls[0]).map { "\($0.lastPathComponent) \((try? FileManager.default.contentsOfDirectory(atPath: $0.path)) != nil)" }
            log("no resulting url: located \(locate(urls[0], size: file.size)?.path ?? "-"), trash listable: \(listable)")
            try? Data("occupied\n".utf8).write(to: urls[0])
            log("occupied original: \(putBack(TrashedFile(original: urls[0], trashed: moved, size: file.size))?.localizedDescription ?? "put back (wrong)")")
            unlink(urls[0].path)
            let located = putBack(file)
            log("after freeing the place, without the resulting url: \(located?.localizedDescription ?? "put back")")
            if located != nil, let moved {
                log("after freeing the place, with the resulting url: \(putBack(TrashedFile(original: urls[0], trashed: moved, size: file.size))?.localizedDescription ?? "put back")")
            }
            log("content: \(content(urls[0]).hasPrefix("flow ") ? "original" : "-")")
        }
        for url in urls { unlink(url.path) }
        log("left in archive: \(present())")
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
            runFlowTest(folder: folder, ext: ext) { lines.append($0) }
            runScopeTest(folder: folder) { lines.append($0) }
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
