import AppKit
import LocalAuthentication
import Photos
import SQLite3
import SwiftUI

enum HiddenStore {
    struct State: Equatable {
        var keys: Set<String> = []
        var shown: Set<String> = []
        var folders: Set<String> = []
        var photoAssets: Set<String> = []
        var photoKeys: Set<String> = []
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let under = "in_archive = 1 AND (root = ?1 OR substr(root, 1, length(?1) + 1) = ?1 || '/')"

    private static func open() -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open(Catalog.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 5000)
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS hidden_item (key TEXT PRIMARY KEY, hidden INTEGER NOT NULL DEFAULT 1, set_at TEXT)", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS hidden_folder (path TEXT PRIMARY KEY, set_at TEXT)", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS photos_hidden (path TEXT PRIMARY KEY)", nil, nil, nil)
        return db
    }

    private static func each(_ db: OpaquePointer?, _ sql: String, _ row: (OpaquePointer?) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    private static func text(_ s: OpaquePointer?, _ i: Int32) -> String {
        sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
    }

    static func load() -> State {
        var state = State()
        guard let db = open() else { return state }
        defer { sqlite3_close(db) }
        each(db, "SELECT key, hidden FROM hidden_item") { s in
            if sqlite3_column_int(s, 1) != 0 { state.keys.insert(text(s, 0)) } else { state.shown.insert(text(s, 0)) }
        }
        each(db, "SELECT path FROM hidden_folder") { state.folders.insert(text($0, 0)) }
        each(db, "SELECT path FROM photos_hidden") { state.photoAssets.insert(text($0, 0)) }
        each(db, "SELECT DISTINCT i.key FROM item i JOIN member m ON m.item_id = i.id JOIN photos_hidden p ON p.path = m.path WHERE m.source = 'photos'") {
            state.photoKeys.insert(text($0, 0))
        }
        return state
    }

    private static func write(_ statements: [(String, [String])]) {
        guard !statements.isEmpty, let db = open() else { return }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for (sql, args) in statements {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            for (i, arg) in args.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), arg, -1, transient) }
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    private static var now: String { ISO8601DateFormatter().string(from: Date()) }

    static func hide(_ keys: [String]) {
        let stamp = now
        write(keys.map { ("INSERT OR REPLACE INTO hidden_item (key, hidden, set_at) VALUES (?, 1, ?)", [$0, stamp]) })
    }

    static func unhide(_ keys: [String], keepShown: Set<String>) {
        let stamp = now
        write(keys.map { key in
            keepShown.contains(key) ? ("INSERT OR REPLACE INTO hidden_item (key, hidden, set_at) VALUES (?, 0, ?)", [key, stamp])
                                    : ("DELETE FROM hidden_item WHERE key = ?", [key])
        })
    }

    static func hideFolder(_ path: String) {
        write([("INSERT OR REPLACE INTO hidden_folder (path, set_at) VALUES (?, ?)", [path, now]),
               ("DELETE FROM hidden_item WHERE hidden = 0 AND key IN (SELECT key FROM item WHERE \(under))", [path])])
    }

    static func setPhotos(_ ids: [String], hidden: Bool) {
        write(ids.map { (hidden ? "INSERT OR IGNORE INTO photos_hidden (path) VALUES (?)" : "DELETE FROM photos_hidden WHERE path = ?", [$0]) })
    }

    static func unhideFolder(_ path: String) {
        write([("DELETE FROM hidden_folder WHERE path = ?", [path])])
    }
}

enum HiddenReason {
    case item, folder, photos
}

@MainActor
final class Hidden: ObservableObject {
    static let shared = Hidden()
    nonisolated static let showKey = "hiddenShowCollection"
    nonisolated static let authKey = "hiddenRequiresAuth"
    nonisolated static let photosKey = "hiddenAlsoInPhotos"
    nonisolated static let unhideKey = "hiddenPhotosUnhideConfirmed"
    static let forced = Theme.snapshot && ProcessInfo.processInfo.environment["PHOTOHUB_HIDDEN_UNLOCKED"] == "1"
    static let lockAfter: TimeInterval = 15 * 60

    @Published private(set) var state = HiddenStore.State()
    @Published private(set) var photos: Set<String> = []
    @Published private(set) var items: [Item] = []
    private(set) var tags: [String: [String: Set<Int64>]] = [:]
    @Published private(set) var unlocked = false
    @Published private(set) var revealed: String?
    @Published var folderToHide: String?
    @Published var photosQuestion: [Item] = []
    @Published var photosUnhide: [Item] = []
    private(set) var ids: Set<Int64> = []
    private var counts: [String: Int] = [:]
    private var own: [String: Int] = [:]
    private var authenticating = false
    private var settled = Date.distantPast
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    weak var model: Model?

    static var requiresAuth: Bool { UserDefaults.standard.object(forKey: authKey) as? Bool ?? true }

    var isOpen: Bool { Theme.snapshot ? Hidden.forced : (unlocked || !Hidden.requiresAuth) }

    static func covers(_ folder: String, _ root: String) -> Bool {
        root == folder || root.hasPrefix(folder + "/")
    }

    func contains(_ item: Item) -> Bool { ids.contains(item.id) }

    func reason(_ item: Item) -> HiddenReason? {
        if state.keys.contains(item.key) { return .item }
        if !state.shown.contains(item.key), item.inArchive, !item.root.isEmpty, state.folders.contains(where: { Hidden.covers($0, item.root) }) { return .folder }
        if state.photoKeys.contains(item.key) || photos.contains(item.thumbAsset) || photos.contains(item.mainAsset) { return .photos }
        return nil
    }

    func split(_ snapshot: CatalogSnapshot) -> CatalogSnapshot {
        state = HiddenStore.load()
        photos = state.photoAssets.union(Hidden.photosReadable ? Hidden.photosHiddenIDs() : [])
        var visible: [Item] = [], hidden: [Item] = []
        visible.reserveCapacity(snapshot.items.count)
        for item in snapshot.items {
            if reason(item) == nil { visible.append(item) } else { hidden.append(item) }
        }
        items = hidden
        ids = Set(hidden.map { $0.id })
        var counts: [String: Int] = [:], own: [String: Int] = [:]
        for item in hidden where item.inArchive {
            counts["", default: 0] += 1
            own[item.root.isEmpty ? "/" : item.root, default: 0] += 1
            if item.root.isEmpty { counts["/", default: 0] += 1 }
            var path = ""
            for part in item.root.split(separator: "/") {
                path = path.isEmpty ? String(part) : path + "/" + part
                counts[path, default: 0] += 1
            }
        }
        self.counts = counts
        self.own = own
        let ids = self.ids
        tags = ids.isEmpty ? [:] : snapshot.tags.mapValues { $0.mapValues { $0.intersection(ids) }.filter { !$0.value.isEmpty } }.filter { !$0.value.isEmpty }
        guard !ids.isEmpty else { return snapshot }
        let keys = Set(hidden.map { $0.key })
        return CatalogSnapshot(items: visible,
                               albums: snapshot.albums.mapValues { $0.subtracting(ids) }.filter { !$0.value.isEmpty },
                               tags: snapshot.tags.mapValues { $0.mapValues { $0.subtracting(ids) }.filter { !$0.value.isEmpty } },
                               flags: snapshot.flags.subtracting(keys), marks: snapshot.marks, version: snapshot.version, tagsPending: snapshot.tagsPending)
    }

    func count(_ scope: Scope) -> Int {
        switch scope {
        case .root(let path), .folders(let path): return counts[path] ?? 0
        case .loose(let path): return own[path] ?? 0
        case .hidden: return items.count
        default: return 0
        }
    }

    func count(under path: String) -> Int { counts[path] ?? 0 }

    func retag(_ kind: String, _ name: String, _ items: [Item], on: Bool) {
        let list = Set(items.map(\.id)).intersection(ids)
        guard !list.isEmpty else { return }
        var members = tags[kind]?[name] ?? []
        if on { members.formUnion(list) } else { members.subtract(list) }
        tags[kind, default: [:]][name] = members.isEmpty ? nil : members
    }

    func isFolderHidden(_ path: String) -> Bool { state.folders.contains(path) }

    func topFolders(under path: String? = nil) -> [String] {
        state.folders
            .filter { folder in !state.folders.contains { $0 != folder && Hidden.covers($0, folder) } }
            .filter { folder in path.map { $0.isEmpty ? folder != "/" : folder.hasPrefix($0 + "/") } ?? true }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func cover(_ folder: String) -> Item? {
        let inside = items.filter { $0.inArchive && Hidden.covers(folder, $0.root) }
        return inside.first { !$0.thumbAsset.isEmpty } ?? inside.first
    }

    func isRevealed(_ path: String) -> Bool {
        guard let revealed, isOpen else { return false }
        return revealed.isEmpty || path == revealed || path.hasPrefix(revealed + "/") || (revealed == "/" && path == "/")
    }

    func follow(_ scope: Scope) {
        guard let revealed else { return }
        switch scope {
        case .root(let path), .loose(let path), .folders(let path):
            if path == revealed || path.hasPrefix(revealed + "/") || revealed.isEmpty { return }
        default: break
        }
        self.revealed = nil
    }

    func source(_ visible: [Item], _ scope: Scope) -> [Item] {
        let extra: [Item]
        switch scope {
        case .hidden:
            guard isOpen else { return [] }
            if unlocked { touch() }
            return items
        case .root(let path) where isRevealed(path):
            extra = items.filter { $0.inArchive && (path == "/" ? $0.root.isEmpty : Hidden.covers(path, $0.root)) }
        case .loose(let path) where isRevealed(path):
            extra = items.filter { $0.inArchive && $0.root == path }
        default: return visible
        }
        guard !extra.isEmpty else { return visible }
        if unlocked { touch() }
        return (visible + extra).sorted { $0.date != $1.date ? $0.date > $1.date : $0.title < $1.title }
    }

    func reveal(_ path: String) {
        unlock {
            self.revealed = path
            self.model?.apply()
        }
    }

    func open(_ path: String) {
        guard let model else { return }
        revealed = path
        model.go(.root(path))
    }

    func conceal() {
        revealed = nil
        model?.hiddenChanged()
    }

    func unlock(_ then: @escaping @MainActor () -> Void) {
        if Theme.snapshot {
            if Hidden.forced { then() }
            return
        }
        if isOpen {
            touch()
            then()
            return
        }
        authenticate(String(localized: "show hidden items")) { ok in
            guard ok else { return }
            self.unlocked = true
            self.touch()
            then()
        }
    }

    func authenticate(_ reason: String, _ done: @escaping @MainActor (Bool) -> Void) {
        guard !Theme.snapshot, !authenticating else { return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            model?.notice = Notice(title: String(localized: "Hidden Is Locked"),
                                   text: String(localized: "This Mac cannot check Touch ID or the password: \(error?.localizedDescription ?? "")"))
            return
        }
        authenticating = true
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async {
                self.authenticating = false
                self.settled = Date()
                done(ok)
            }
        }
    }

    func touch() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Hidden.lockAfter, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        }
    }

    func lock() {
        guard !Hidden.forced, unlocked || revealed != nil else { return }
        unlocked = false
        revealed = nil
        timer?.invalidate()
        timer = nil
        model?.hiddenChanged()
    }

    func install(_ model: Model) {
        self.model = model
        guard observers.isEmpty, !Theme.snapshot else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.authenticating, Date().timeIntervalSince(self.settled) > 1.5 else { return }
                self.lock()
            }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow, window === self.model?.window else { return }
                self.lock()
            }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            })
        }
    }

    func photosChanged() -> Bool {
        guard Hidden.photosReadable else { return false }
        return Hidden.photosHiddenIDs().union(state.photoAssets) != photos
    }

    nonisolated static var photosReadable: Bool {
        !AppPaths.noPhotos && [.authorized, .limited].contains(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    nonisolated static var allAssets: PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        return options
    }

    nonisolated static func photosHiddenIDs() -> Set<String> {
        let options = allAssets
        options.predicate = NSPredicate(format: "isHidden == YES")
        var out: Set<String> = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in out.insert(asset.localIdentifier) }
        return out
    }

    func setInPhotos(_ ids: [String], hidden: Bool, done: @escaping @MainActor (String?) -> Void) {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: Hidden.allAssets)
        guard assets.count > 0 else {
            done(String(localized: "Photos did not change the items: \(String(localized: "they are not available in the Photos library"))."))
            return
        }
        PHPhotoLibrary.shared().performChanges({
            assets.enumerateObjects { asset, _, _ in PHAssetChangeRequest(for: asset).isHidden = hidden }
        }) { ok, error in
            DispatchQueue.main.async {
                if ok {
                    HiddenStore.setPhotos(ids, hidden: hidden)
                    if hidden { self.photos.formUnion(ids) } else { self.photos.subtract(ids) }
                    done(nil)
                } else {
                    done(String(localized: "Photos did not change the items: \(error?.localizedDescription ?? String(localized: "no reason given"))."))
                }
            }
        }
    }
}

extension Model {
    func pickerSets(_ kind: String) -> [String: Set<Int64>] {
        let extra = Hidden.shared.tags[kind] ?? [:]
        return extra.isEmpty ? tagSets(kind) : tagSets(kind).merging(extra) { $0.union($1) }
    }

    var targetsHidden: Bool {
        let list = targets()
        return !list.isEmpty && list.allSatisfy(Hidden.shared.contains)
    }

    func toggleHidden(_ items: [Item]? = nil) {
        let list = items ?? targets()
        guard !list.isEmpty else { return }
        if list.allSatisfy(Hidden.shared.contains) { unhide(list) } else { hide(list) }
    }

    func hide(_ items: [Item]) {
        let list = items.filter { !Hidden.shared.state.keys.contains($0.key) }
        guard !list.isEmpty else { return }
        HiddenStore.hide(list.map { $0.key })
        hiddenChanged(reload: true)
        offerPhotos(list)
    }

    private func offerPhotos(_ items: [Item]) {
        guard !AppPaths.noPhotos, !Theme.snapshot else { return }
        let candidates = items.filter { $0.inPhotos }
        guard !candidates.isEmpty else { return }
        switch UserDefaults.standard.string(forKey: Hidden.photosKey) ?? "" {
        case "always": hideInPhotos(candidates)
        case "never": break
        default: Hidden.shared.photosQuestion = candidates
        }
    }

    func hideInPhotos(_ items: [Item]) {
        let ids = items.flatMap { item in members(of: item).filter { $0.source == "photos" && !Hidden.shared.photos.contains($0.path) }.map { $0.path } }
        guard !ids.isEmpty else { return }
        Hidden.shared.setInPhotos(ids, hidden: true) { error in
            if let error { self.notice = Notice(title: String(localized: "Photos Was Not Changed"), text: error) }
        }
    }

    private func photosAssets(_ items: [Item]) -> [String] {
        guard !Hidden.shared.photos.isEmpty else { return [] }
        return items.flatMap { item in members(of: item).filter { $0.source == "photos" && Hidden.shared.photos.contains($0.path) }.map { $0.path } }
    }

    func unhide(_ items: [Item]) {
        let list = items.filter(Hidden.shared.contains)
        guard !list.isEmpty else { return }
        if !photosAssets(list).isEmpty && !UserDefaults.standard.bool(forKey: Hidden.unhideKey) {
            Hidden.shared.photosUnhide = list
            return
        }
        performUnhide(list)
    }

    func performUnhide(_ items: [Item]) {
        let hidden = Hidden.shared
        let inFolders = Set(items.filter { item in item.inArchive && !item.root.isEmpty && hidden.state.folders.contains { Hidden.covers($0, item.root) } }.map { $0.key })
        HiddenStore.unhide(items.map { $0.key }, keepShown: inFolders)
        let assets = photosAssets(items)
        guard !assets.isEmpty else {
            hiddenChanged(reload: true)
            return
        }
        hidden.setInPhotos(assets, hidden: false) { error in
            if let error { self.notice = Notice(title: String(localized: "Photos Was Not Changed"), text: error) }
            self.hiddenChanged(reload: true)
        }
    }

    func hideFolder(_ path: String) {
        guard !path.isEmpty, path != "/" else { return }
        HiddenStore.hideFolder(path)
        hiddenChanged(reload: true)
    }

    func unhideFolder(_ path: String) {
        HiddenStore.unhideFolder(path)
        hiddenChanged(reload: true)
    }

    func hiddenChanged(reload again: Bool = false) {
        if again { reload() } else { apply() }
        let visible = Set(flat.map { $0.id })
        selection = selection.intersection(visible)
        if let current = selected, !visible.contains(current.id) {
            selected = nil
            viewing = false
        }
    }
}

struct HiddenFrame<Content: View>: View {
    @ObservedObject var model: Model
    @ObservedObject private var hidden = Hidden.shared
    @AppStorage(Hidden.showKey) private var show = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        switch model.scope {
        case .hidden:
            if show && hidden.isOpen {
                VStack(spacing: 0) {
                    let folders = hidden.topFolders()
                    if !folders.isEmpty { HiddenFolderStrip(model: model, title: String(localized: "Hidden Folders"), folders: folders) }
                    content()
                        .overlay {
                            if hidden.items.isEmpty && folders.isEmpty {
                                Label("No hidden items. Hide a shot with ⌘L or its menu, or a folder from the menu of its card.", systemImage: "eye.slash")
                                    .foregroundStyle(.secondary).padding(40)
                            }
                        }
                }
            } else {
                HiddenLockScreen(model: model, off: !show)
            }
        case .root(let path), .loose(let path), .folders(let path):
            VStack(spacing: 0) {
                if show && !model.viewing && hidden.count(model.scope) > 0 {
                    HiddenFolderBar(model: model, path: path, count: hidden.count(model.scope))
                    if hidden.isRevealed(path) {
                        let folders = hidden.topFolders(under: path).filter { $0 != path }
                        if !folders.isEmpty { HiddenFolderStrip(model: model, title: String(localized: "Hidden Folders"), folders: folders) }
                    }
                }
                content()
            }
        default:
            content()
        }
    }
}

struct HiddenLockScreen: View {
    @ObservedObject var model: Model
    let off: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
            Text("Hidden").font(.title.bold())
            if off {
                Text("The Hidden collection is turned off in Settings.").foregroundStyle(.secondary)
            } else {
                Text("Use Touch ID or your password to view hidden items.").foregroundStyle(.secondary)
                Button { Hidden.shared.unlock { model.apply() } } label: { Label("View Hidden", systemImage: "touchid") }
                    .buttonStyle(PillButtonStyle())
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HiddenFolderBar: View {
    @ObservedObject var model: Model
    @ObservedObject private var hidden = Hidden.shared
    let path: String
    let count: Int

    var body: some View {
        let revealed = hidden.isRevealed(path)
        HStack(spacing: 10) {
            Image(systemName: revealed ? "eye" : "eye.slash").foregroundStyle(.secondary)
            if revealed {
                Text(hidden.isFolderHidden(path) ? String(localized: "This folder is hidden") : String(localized: "Hidden items shown: \(count)"))
            } else {
                Text("\(count) hidden items")
            }
            Spacer(minLength: 0)
            if revealed {
                if hidden.isFolderHidden(path) {
                    Button("Unhide Folder") { model.unhideFolder(path) }.buttonStyle(PillButtonStyle())
                }
                if !hidden.isFolderHidden(path) {
                    Button("Hide Again") { hidden.conceal() }.buttonStyle(PillButtonStyle())
                }
            } else {
                Button { hidden.reveal(path) } label: {
                    Label("Show", systemImage: Hidden.requiresAuth ? "touchid" : "eye")
                }
                .buttonStyle(PillButtonStyle())
            }
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .glassBar()
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 2)
    }
}

struct HiddenFolderStrip: View {
    @ObservedObject var model: Model
    let title: String
    let folders: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 15, weight: .bold))
                Text("\(folders.count)").font(Theme.count(13)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(folders, id: \.self) { path in
                        FolderCard(title: path.split(separator: "/").last.map(String.init) ?? path, count: Hidden.shared.count(under: path),
                                   cover: Hidden.shared.cover(path), epoch: model.epoch, icon: "folder.fill")
                            .overlay(alignment: .topTrailing) { HiddenMark(text: nil).padding(8) }
                            .help(path)
                            .onTapGesture { Hidden.shared.open(path) }
                            .contextMenu {
                                Button("Unhide Folder") { model.unhideFolder(path) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Catalog.archiveRoot.appendingPathComponent(path)]) }
                            }
                    }
                }
                .padding(.horizontal, 28).padding(.vertical, 8)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }
}

struct HiddenMark: View {
    let text: String?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "eye.slash.fill")
            if let text { Text(text) }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 4)
        .hudCapsule()
    }
}

struct HiddenTileBadge: View {
    @ObservedObject private var hidden = Hidden.shared
    let item: Item

    var body: some View {
        if hidden.contains(item) {
            HiddenMark(text: nil)
                .padding(5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .allowsHitTesting(false)
                .help(String(localized: "Hidden"))
        }
    }
}

struct HiddenCardBadge: View {
    @ObservedObject private var hidden = Hidden.shared
    @AppStorage(Hidden.showKey) private var show = true
    let path: String

    var body: some View {
        let count = hidden.count(under: path)
        if show && count > 0 {
            HiddenMark(text: "\(count)")
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(false)
                .help(String(localized: "\(count) hidden items"))
        }
    }
}

struct HiddenMenuItems: View {
    @ObservedObject var model: Model
    let preview: [Item]
    let items: () -> [Item]

    var body: some View {
        let hidden = !preview.isEmpty && preview.allSatisfy(Hidden.shared.contains)
        Button(hidden ? String(localized: "Unhide") : String(localized: "Hide")) { model.toggleHidden(items()) }
    }
}

struct HiddenFolderMenu: View {
    @ObservedObject var model: Model
    let path: String

    var body: some View {
        if Hidden.shared.isFolderHidden(path) {
            Button("Unhide Folder") { model.unhideFolder(path) }
        } else {
            Button("Hide Folder…") { Hidden.shared.folderToHide = path }
        }
    }
}

extension View {
    @ViewBuilder func hiddenFolderMenu(_ model: Model, _ scope: Scope) -> some View {
        switch scope {
        case .root(let path) where path != "/", .folders(let path) where !path.isEmpty:
            contextMenu { HiddenFolderMenu(model: model, path: path) }
        default:
            self
        }
    }
}

struct HiddenToggle: View {
    @ObservedObject var model: Model
    @ObservedObject private var hidden = Hidden.shared
    let item: Item

    var body: some View {
        let on = hidden.contains(item)
        Button { model.toggleHidden([item]) } label: {
            Label(on ? String(localized: "Unhide") : String(localized: "Hide"), systemImage: on ? "eye" : "eye.slash")
        }
        .controlSize(.small)
        .help(on ? String(localized: "Show this item everywhere again (⌘L)") : String(localized: "Hide this item from the library, collections and search (⌘L)"))
        .glassSection("controls")
    }
}

struct HiddenHomeRow: View {
    @ObservedObject var model: Model
    @ObservedObject private var hidden = Hidden.shared
    @AppStorage(Hidden.showKey) private var show = true

    var body: some View {
        if show {
            VStack(alignment: .leading, spacing: 8) {
                Text("Utilities").font(.system(size: 22, weight: .bold))
                let open = hidden.isOpen
                CardView(card: Card(id: "hidden", title: String(localized: "Hidden"), subtitle: open ? "\(hidden.items.count)" : String(localized: "Locked"),
                                    scope: .hidden, cover: nil, icon: open ? "eye.slash" : "lock.fill"),
                         epoch: model.epoch, width: 218, height: 150)
                    .onTapGesture {
                        model.go(.hidden)
                        hidden.unlock { model.apply() }
                    }
                    .padding(.vertical, 8)
            }
        }
    }
}

struct HiddenSettings: View {
    @ObservedObject var model: Model
    @ObservedObject private var hidden = Hidden.shared
    @AppStorage(Hidden.showKey) private var show = true
    @AppStorage(Hidden.authKey) private var auth = true
    @AppStorage(Hidden.photosKey) private var photos = ""

    var body: some View {
        Form {
            Section {
                Toggle("Show Hidden collection", isOn: $show)
                Toggle("Use Touch ID or Password to view Hidden", isOn: Binding(get: { auth }, set: { on in
                    if on {
                        auth = true
                        Hidden.shared.lock()
                    } else {
                        Hidden.shared.authenticate(String(localized: "turn off the password for hidden items")) { ok in if ok { auth = false } }
                    }
                }))
            } footer: {
                Text("Hidden items and folders disappear from the library, collections, the map and search; files are not moved. They stay in the Hidden collection, and a folder shows how many of its items are hidden. With the collection turned off, hidden items stay hidden and nothing points to them.")
            }
            if !AppPaths.noPhotos {
                Section {
                    Picker("Items that are also in Photos", selection: $photos) {
                        Text("Ask Every Time").tag("")
                        Text("Hide in Photos Too").tag("always")
                        Text("Hide Only in PhotoHub").tag("never")
                    }
                }
            }
            if show {
                Section {
                    HStack {
                        Text(hidden.isOpen ? String(localized: "Hidden items: \(hidden.items.count), folders: \(hidden.topFolders().count)") : String(localized: "Hidden is locked."))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Hidden") {
                            model.go(.hidden)
                            model.window?.makeKeyAndOrderFront(nil)
                            hidden.unlock { model.apply() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct HiddenCommands: Commands {
    @ObservedObject var model: Model

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button(model.targetsHidden ? String(localized: "Unhide") : String(localized: "Hide")) { model.toggleHidden() }
                .keyboardShortcut("l")
                .disabled(!model.hasTargets)
        }
    }
}

struct HiddenHost: ViewModifier {
    @ObservedObject var model: Model
    @ObservedObject private var hidden = Hidden.shared
    @State private var remember = false

    func body(content: Content) -> some View {
        content
            .onAppear { hidden.install(model) }
            .confirmationDialog(String(localized: "Hide the folder “\(hidden.folderToHide.map { ($0 as NSString).lastPathComponent } ?? "")”?"),
                                isPresented: Binding(get: { hidden.folderToHide != nil }, set: { if !$0 { hidden.folderToHide = nil } }),
                                presenting: hidden.folderToHide) { path in
                Button("Hide Folder") { model.hideFolder(path) }
                Button("Cancel", role: .cancel) {}
            } message: { path in
                Text("Items in “\(path)” and its subfolders: \(model.folderCount(path)). They disappear from the library, collections and search and stay in Hidden. Files are not moved or changed.")
            }
            .alert(String(localized: "Unhide in Photos Too?"), isPresented: Binding(get: { !hidden.photosUnhide.isEmpty }, set: { if !$0 { hidden.photosUnhide = [] } })) {
                Button("Unhide") {
                    let list = hidden.photosUnhide
                    hidden.photosUnhide = []
                    UserDefaults.standard.set(true, forKey: Hidden.unhideKey)
                    model.performUnhide(list)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Some of these items are hidden in the Photos library. Unhiding them here also unhides them in Photos on all your devices. PhotoHub asks only this once.")
            }
            .sheet(isPresented: Binding(get: { !hidden.photosQuestion.isEmpty }, set: { if !$0 { hidden.photosQuestion = [] } })) {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Hide in Photos Too?", systemImage: "eye.slash").font(.title2.bold())
                    Text("Items that are also in the Photos library: \(hidden.photosQuestion.count). Hidden there too, they move to the Hidden album in Photos on all your devices, including the phone.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("Remember my choice", isOn: $remember)
                    HStack {
                        Spacer()
                        Button("Only in PhotoHub") { answer(false) }.keyboardShortcut(.cancelAction)
                        Button("Hide in Photos Too") { answer(true) }.keyboardShortcut(.defaultAction)
                    }
                }
                .padding(20)
                .frame(width: 460)
            }
    }

    private func answer(_ photos: Bool) {
        let list = hidden.photosQuestion
        hidden.photosQuestion = []
        if remember { UserDefaults.standard.set(photos ? "always" : "never", forKey: Hidden.photosKey) }
        if photos { model.hideInPhotos(list) }
    }
}

extension Model {
    func folderCount(_ path: String) -> Int {
        folders(in: (path as NSString).deletingLastPathComponent).first { $0.id == path }?.count ?? 0
    }
}

enum HiddenSnapshot {
    @MainActor
    static func apply(_ flag: String, _ model: Model) -> Bool {
        let pair = flag.split(separator: "=", maxSplits: 1).map(String.init)
        let value = pair.count == 2 ? pair[1] : ""
        switch pair.first ?? "" {
        case "reveal":
            switch model.scope {
            case .root(let path), .loose(let path), .folders(let path): Hidden.shared.reveal(path)
            default: break
            }
        case "hideselected": model.hide(model.targets())
        case "unhideselected": model.unhide(model.targets())
        case "hidefolder": model.hideFolder(value)
        case "unhidefolder": model.unhideFolder(value)
        case "hiddenstats":
            let hidden = Hidden.shared
            let cards: [Card] = model.yearCards + model.tripCards + model.eventCards + model.personCards + model.petCards + model.placeCards + model.userTagCards + model.dayCards
            let coverHidden = cards.filter { $0.cover.map(hidden.contains) ?? false }.count
            let folderCovers = model.tree.filter { $0.cover.map(hidden.contains) ?? false }.count
            let points = model.points.reduce(0) { $0 + $1.itemIDs.count }
            var lines = ["scope: \(model.title)", "shown: \(model.shown)", "hidden items: \(hidden.items.count)"]
            lines.append("hidden keys: \(hidden.state.keys.count), shown exceptions: \(hidden.state.shown.count), folders: \(hidden.state.folders.sorted().joined(separator: ", "))")
            lines.append("years: " + model.yearCards.map { "\($0.title)=\($0.count)" }.joined(separator: " "))
            lines.append("events: \(model.eventCards.reduce(0) { $0 + $1.count }), folders total: \(model.tree.reduce(0) { $0 + $1.count })")
            lines.append("trips: " + model.tripCards.map { "\($0.count)" }.joined(separator: " "))
            lines.append("people: " + model.personCards.map { "\($0.title)=\($0.count)" }.joined(separator: " "))
            lines.append("covers hidden: \(coverHidden), folder covers hidden: \(folderCovers), flat hidden: \(model.flat.filter(hidden.contains).count), map points: \(points)")
            lines.append("flagged: \(model.flagged.count), days: \(model.dayCards.reduce(0) { $0 + $1.count }), kinds: \(model.kindCards.map { "\($0.count)" }.joined(separator: " "))")
            let out = (ProcessInfo.processInfo.environment["PHOTOHUB_SNAPSHOT"] ?? "/tmp/shot") + "-hidden.txt"
            let previous = (try? String(contentsOfFile: out)) ?? ""
            try? (previous + lines.joined(separator: "\n") + "\n---\n").write(toFile: out, atomically: true, encoding: .utf8)
        default:
            return false
        }
        return true
    }
}
