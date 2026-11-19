import AppKit
import SwiftUI

enum RemovalScope: String, Identifiable {
    case everywhere, archive, photos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .everywhere: return String(localized: "Delete Everywhere?")
        case .archive: return String(localized: "Delete Archive Copy?")
        case .photos: return String(localized: "Delete from Photos?")
        }
    }

    var takesArchive: Bool { self != .photos }
    var takesPhotos: Bool { self != .archive }
}

struct RemovalPlan: Identifiable {
    let id = UUID()
    let scope: RemovalScope
    let items: [Item]
    let archive: [(Item, Member)]
    let photos: [(Item, Member)]
    let keptArchive: [Member]
    let keptPhotos: [Member]
    let vanishing: Int
    var label: String?
    var version: Member?

    var isEmpty: Bool { archive.isEmpty && photos.isEmpty }
    var photoIDs: [String] { Removal.photoBatch(photos.map { $0.1.path }) }
    var asksPhotos: Bool { !photoIDs.isEmpty }
    var kept: Int { keptArchive.count + keptPhotos.count }

    static func shots(_ scope: RemovalScope, _ stacks: [(Item, [Member])]) -> RemovalPlan {
        var archive: [(Item, Member)] = [], photos: [(Item, Member)] = []
        var keptArchive: [Member] = [], keptPhotos: [Member] = []
        var vanishing = 0
        for (item, stack) in stacks {
            let files = stack.filter { $0.source == "archive" }, assets = stack.filter { $0.source == "photos" }
            if scope.takesArchive { archive += files.map { (item, $0) } } else { keptArchive += files }
            if scope.takesPhotos { photos += assets.map { (item, $0) } } else { keptPhotos += assets }
            if !stack.isEmpty && (scope.takesArchive || files.isEmpty) && (scope.takesPhotos || assets.isEmpty) { vanishing += 1 }
        }
        return RemovalPlan(scope: scope, items: stacks.map { $0.0 }, archive: archive, photos: photos,
                           keptArchive: keptArchive, keptPhotos: keptPhotos, vanishing: vanishing)
    }

    static func version(_ member: Member, of item: Item, stack: [Member]) -> RemovalPlan {
        let pair = [(item, member)]
        let archive = member.source == "archive"
        let rest = stack.filter { $0.source != member.source || $0.path != member.path }
        return RemovalPlan(scope: archive ? .archive : .photos, items: [item], archive: archive ? pair : [], photos: archive ? [] : pair,
                           keptArchive: rest.filter { $0.source == "archive" }, keptPhotos: rest.filter { $0.source == "photos" },
                           vanishing: rest.isEmpty ? 1 : 0, label: member.name, version: member)
    }

    static func focused(_ item: Item, versions: [Member], index: Int) -> RemovalPlan {
        if index > 0, versions.indices.contains(index) { return version(versions[index], of: item, stack: versions) }
        return shots(.everywhere, [(item, versions)])
    }

    static func versionHeading(_ member: Member) -> String {
        let name = member.name
        if member.source == "photos" { return String(localized: "Delete Photos version “\(name)”?") }
        switch member.role {
        case "raw": return String(localized: "Delete RAW version “\(name)”?")
        case "edit": return String(localized: "Delete edited version “\(name)”?")
        case "export": return String(localized: "Delete copy from Photos “\(name)”?")
        case "video": return String(localized: "Delete video version “\(name)”?")
        default: return String(localized: "Delete original version “\(name)”?")
        }
    }

    var heading: String {
        if let version { return RemovalPlan.versionHeading(version) }
        if items.count == 1, scope == .everywhere, let item = items.first {
            return String(localized: "Delete shot “\(item.title)” (\(archive.count + photos.count) files)?")
        }
        return label.map { String(localized: "Delete “\($0)”?") } ?? scope.title
    }

    static func bytes(_ members: [Member]) -> String {
        ByteCountFormatter.string(fromByteCount: members.reduce(Int64(0)) { $0 + max($1.size, 0) }, countStyle: .file)
    }

    var folders: String {
        var counts: [String: Int] = [:]
        for (_, member) in archive { counts[(member.path as NSString).deletingLastPathComponent, default: 0] += 1 }
        let top = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(3)
        let list = top.map { "\($0.key.isEmpty ? String(localized: "archive root") : $0.key) — \($0.value)" }.joined(separator: ", ")
        return counts.count > 3 ? list + " " + String(localized: "and \(counts.count - 3) more") : list
    }

    var names: String {
        let list = items.prefix(4).map { $0.title }.joined(separator: ", ")
        return items.count > 4 ? list + " " + String(localized: "and \(items.count - 4) more") : list
    }
}

struct DeletionToast: Identifiable {
    let id = UUID()
    var title: String
    var detail = ""
    var failed = false
    var details: String?
    var undo: UUID?
    var photos = false
    var icon = "trash"
    var reveal: [PutBackResult] = []
    var conflict: UUID?
}

struct DeletionRecord {
    let id = UUID()
    let files: [(key: String, path: String, file: TrashedFile)]
    let backups: [String: ItemBackup]
    var label = ""
}

struct DeletionHistory {
    static let limit = 20
    private(set) var records: [DeletionRecord] = []

    mutating func push(_ record: DeletionRecord) -> [DeletionRecord] {
        records.append(record)
        let extra = max(0, records.count - DeletionHistory.limit)
        let dropped = Array(records.prefix(extra))
        records.removeFirst(extra)
        return dropped
    }

    mutating func take(_ id: UUID?) -> DeletionRecord? {
        guard let id else { return records.popLast() }
        guard let index = records.firstIndex(where: { $0.id == id }) else { return nil }
        return records.remove(at: index)
    }
}

struct VersionFocus: Equatable {
    let key: String
    let member: Member
    let main: Bool
}

final class DeletionUndoTarget {}

enum RemovalPrefs {
    static let askKey = "askBeforeTrashingArchiveFiles"

    static var ask: Bool {
        get { UserDefaults.standard.object(forKey: askKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: askKey) }
    }
}

struct DeleteConfirmationToggle: View {
    @AppStorage(RemovalPrefs.askKey) private var ask = true

    var body: some View {
        Toggle("Ask before moving archive files to the Trash", isOn: $ask)
        Text("Deleting Photos items is always confirmed once, in the Photos window.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

@MainActor
final class ShotActions: ObservableObject {
    static let shared = ShotActions()
    @Published var removal: RemovalPlan?
    @Published var tagging: [Item] = []
    @Published var moving: [Item] = []
    @Published var toast: DeletionToast?
    @Published var focus: VersionFocus?
    var history = DeletionHistory()
    var undoTargets: [UUID: DeletionUndoTarget] = [:]
    var restoring: [DeletionRecord] = []
    var conflicts: [UUID: DeletionRecord] = [:]
    var beside: [UUID: Bool] = [:]
}

extension Model {
    func contextPreview(_ item: Item) -> [Item] {
        guard selection.contains(item.id) else { return [item] }
        let chosen = selection.compactMap { byID[$0] }
        return chosen.isEmpty ? [item] : chosen
    }

    func contextItems(_ item: Item) -> [Item] {
        if selection.contains(item.id) { return targets() }
        click(item, command: false, shift: false)
        return [item]
    }

    func removalPlan(_ scope: RemovalScope, _ items: [Item]) -> RemovalPlan {
        RemovalPlan.shots(scope, items.map { ($0, members(of: $0)) })
    }

    func askRemoval(_ scope: RemovalScope, _ items: [Item]? = nil) {
        let list = items ?? targets()
        guard !list.isEmpty else { return }
        request(removalPlan(scope, list))
    }

    func askRemoval(_ member: Member, of item: Item) {
        request(RemovalPlan.version(member, of: item, stack: members(of: item)))
    }

    var shownShot: Item? {
        guard viewing, let item = selected else { return nil }
        return item
    }

    private var shownPage: (Item, PageState)? {
        guard let item = shownShot, let page, page.item?.key == item.key, !page.versions.isEmpty else { return nil }
        return (item, page)
    }

    func deleteFocused() {
        if let (item, page) = shownPage {
            request(RemovalPlan.focused(item, versions: page.versions, index: page.index))
        } else if let item = shownShot {
            askRemoval(.everywhere, [item])
        } else {
            askRemoval(.everywhere)
        }
    }

    func deleteShownVersion() {
        guard let (item, page) = shownPage, let member = page.current else { return }
        request(RemovalPlan.version(member, of: item, stack: page.versions))
    }

    func deleteShownShot() {
        guard let item = shownShot else { return }
        askRemoval(.everywhere, [item])
    }

    func request(_ plan: RemovalPlan) {
        guard busyTool.isEmpty else { return }
        if plan.isEmpty {
            showToast(DeletionToast(title: String(localized: "Nothing to delete for this choice.")))
        } else if plan.asksPhotos || !RemovalPrefs.ask {
            if plan.asksPhotos {
                let detail = plan.version != nil && plan.kept > 0
                    ? String(localized: "Confirm in the Photos window. Only this version is deleted, the shot keeps its other versions: \(plan.kept).")
                    : String(localized: "Confirm in the Photos window.")
                showToast(DeletionToast(title: plan.heading, detail: detail, icon: "photo.on.rectangle"))
            }
            performRemoval(plan)
        } else {
            ShotActions.shared.removal = plan
        }
    }

    func showToast(_ toast: DeletionToast) {
        withAnimation(Theme.spring) { ShotActions.shared.toast = toast }
    }

    func performRemoval(_ plan: RemovalPlan) {
        guard busyTool.isEmpty, !plan.isEmpty else { return }
        let ids = Set(plan.items.map { $0.id })
        let anchor = flat.firstIndex { ids.contains($0.id) }
        let backups = catalog?.backup(keys: plan.archive.map { $0.0.key }) ?? [:]
        let root = Catalog.archiveRoot
        let files = plan.archive.map { (url: root.appendingPathComponent($0.1.path), name: $0.1.name) }
        let total = files.count
        busyTool = plan.asksPhotos ? String(localized: "Waiting for confirmation in Photos…") : String(localized: "Moving files to the Trash…")
        Removal.execute(photos: plan.photoIDs, files: files, trashing: {
            DispatchQueue.main.async { self.busyTool = String(localized: "Moving files to the Trash…") }
        }, progress: { done in
            let text = String(localized: "Moving files to the Trash… \(done) of \(total)")
            DispatchQueue.main.async { self.busyTool = text }
        }) { outcome in
            DispatchQueue.main.async { self.finishRemoval(plan, outcome, backups: backups, anchor: anchor) }
        }
    }

    private func finishRemoval(_ plan: RemovalPlan, _ outcome: RemovalOutcome, backups: [String: ItemBackup], anchor: Int?) {
        busyTool = ""
        switch outcome.photos {
        case .cancelled?:
            showToast(DeletionToast(title: String(localized: "Nothing was deleted"), detail: String(localized: "Deletion was cancelled in the Photos window.")))
            return
        case .failed(let message)?:
            showToast(DeletionToast(title: String(localized: "Nothing was deleted"), detail: message, failed: true))
            return
        default:
            break
        }
        let fromPhotos = outcome.photos == .deleted ? plan.photos : []
        let trashed = outcome.trashed.map { (plan.archive[$0.index], $0.file) }
        for (item, member) in fromPhotos + trashed.map({ $0.0 }) { catalog?.deleteMember(member, key: item.key) }
        let keys = Set((fromPhotos + trashed.map { $0.0 }).map { $0.0.key })
        settle(after: anchor)
        let gone = plan.items.filter { keys.contains($0.key) && members(of: $0).isEmpty }.count
        var parts: [String] = []
        if !trashed.isEmpty { parts.append(String(localized: "\(trashed.count) files moved to the Trash")) }
        if !fromPhotos.isEmpty { parts.append(String(localized: "\(Set(fromPhotos.map { $0.1.path }).count) items moved to Recently Deleted in Photos")) }
        var toast = DeletionToast(title: parts.joined(separator: " · "))
        if let label = plan.label, plan.archive.count + plan.photos.count == 1 {
            toast.title = String(localized: "Deleted “\(label)”")
            toast.detail = parts.joined(separator: " · ")
            if plan.version != nil, let item = plan.items.first, !keys.isEmpty {
                let left = members(of: item).count
                if left > 0 { toast.detail = [toast.detail, String(localized: "The shot keeps its other versions: \(left).")].filter { !$0.isEmpty }.joined(separator: "\n") }
            }
        } else if gone == 1, plan.items.count == 1, let item = plan.items.first {
            toast.title = String(localized: "Deleted shot “\(item.title)”")
            toast.detail = parts.joined(separator: " · ")
        } else if gone > 0 {
            toast.title = String(localized: "Deleted \(gone) shots")
            toast.detail = parts.joined(separator: " · ")
        }
        if !fromPhotos.isEmpty {
            toast.photos = true
            toast.detail = [toast.detail, String(localized: "Restore Photos items in Photos → Recently Deleted.")].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        if !outcome.failures.isEmpty {
            toast.failed = true
            let failed = String(localized: "Could not delete \(outcome.failures.count) files")
            if parts.isEmpty { toast.title = failed } else { toast.detail = [toast.detail.isEmpty ? toast.title : toast.detail, failed].joined(separator: "\n") }
            toast.details = outcome.failures.map { $0.message }.joined(separator: "\n\n")
        }
        if !trashed.isEmpty {
            let record = DeletionRecord(files: trashed.map { (key: $0.0.0.key, path: $0.0.1.path, file: $0.1) }, backups: backups, label: plan.label ?? plan.names)
            remember(record)
            toast.undo = record.id
        }
        showToast(toast)
    }

    private func remember(_ record: DeletionRecord) {
        let actions = ShotActions.shared
        for old in actions.history.push(record) { forgetUndo(old.id) }
        guard let manager = window?.undoManager else { return }
        let target = DeletionUndoTarget()
        actions.undoTargets[record.id] = target
        manager.registerUndo(withTarget: target) { _ in MainActor.assumeIsolated { self.undoDeletion(record.id, fromUndoManager: true) } }
        manager.setActionName(String(localized: "Deletion"))
    }

    private func forgetUndo(_ id: UUID) {
        if let target = ShotActions.shared.undoTargets.removeValue(forKey: id) { window?.undoManager?.removeAllActions(withTarget: target) }
    }

    func settle(after anchor: Int?) {
        let wasViewing = viewing
        reload()
        if selected == nil, let first = flat.first(where: { selection.contains($0.id) }) {
            selected = first
            viewing = wasViewing
        } else if selected == nil, let anchor, !flat.isEmpty {
            let next = flat[min(anchor, flat.count - 1)]
            selection = [next.id]
            selected = next
            viewing = wasViewing
            scrollRequest += 1
        }
    }

    func undoDeletion(_ id: UUID? = nil, fromUndoManager: Bool = false) {
        let actions = ShotActions.shared
        guard let record = actions.history.take(id) else { return }
        if fromUndoManager {
            actions.undoTargets[record.id] = nil
        } else {
            forgetUndo(record.id)
        }
        actions.restoring.append(record)
        putBackNext()
    }

    private func putBackNext() {
        let actions = ShotActions.shared
        guard !actions.restoring.isEmpty else { return }
        guard busyTool.isEmpty else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.putBackNext() }
            return
        }
        let record = actions.restoring.removeFirst()
        busyTool = String(localized: "Putting files back…")
        let beside = actions.beside.removeValue(forKey: record.id) ?? false
        DispatchQueue.global(qos: .userInitiated).async {
            let targets = beside ? Dictionary(uniqueKeysWithValues: record.files.enumerated().map { ($0.offset, Removal.freeName(beside: $0.element.file.original)) }) : [:]
            let results = Removal.putBack(record.files.map(\.file), to: targets)
            DispatchQueue.main.async {
                self.busyTool = ""
                self.finishPutBack(record, results)
                self.putBackNext()
            }
        }
    }

    private func finishPutBack(_ record: DeletionRecord, _ results: [PutBackResult]) {
        let actions = ShotActions.shared
        let pairs = Array(zip(record.files, results))
        let back = pairs.filter { $0.1.failure == nil }
        var paths: [String: Set<String>] = [:]
        var renamed: [String: String] = [:]
        let root = Catalog.archiveRoot.standardizedFileURL.path + "/"
        for (file, result) in back {
            paths[file.key, default: []].insert(file.path)
            let target = result.target.standardizedFileURL.path
            if result.target.standardizedFileURL != file.file.original.standardizedFileURL, target.hasPrefix(root) { renamed[file.path] = String(target.dropFirst(root.count)) }
        }
        for (key, set) in paths {
            if let backup = record.backups[key] { catalog?.restore(backup, paths: set, renamed: renamed) }
        }
        let wasViewing = viewing
        if wasViewing, paths.count == 1, back.count == 1, let path = back.first?.0.path { keepVersion(renamed[path] ?? path) }
        reload()
        let restored = flat.filter { paths[$0.key] != nil }
        if let first = restored.first {
            selection = Set(restored.map { $0.id })
            selected = first
            viewing = wasViewing
            scrollRequest += 1
        }
        var toast = DeletionToast(title: String(localized: "Put back \(back.count) files"), icon: "arrow.uturn.backward")
        if !record.label.isEmpty { toast.detail = String(localized: "Undid deleting “\(record.label)”") }
        if let only = back.first, back.count == 1, renamed[only.0.path] != nil {
            toast.detail = String(localized: "Put back next to the other file as “\(only.1.target.lastPathComponent)”.")
        }
        let failed = pairs.filter { $0.1.failure != nil }
        guard !failed.isEmpty else { return showToast(toast) }
        toast.failed = true
        toast.reveal = failed.map { $0.1 }
        let summary = String(localized: "Could not put back \(failed.count) files. They are still in the Trash.")
        toast.detail = failed.count == 1 ? failed[0].1.message : summary
        if back.isEmpty {
            toast.title = failed.count == 1 ? String(localized: "Could not put back “\(failed[0].0.file.original.lastPathComponent)”") : summary
        }
        if failed.count > 1 { toast.details = failed.map { $0.1.message }.joined(separator: "\n\n") }
        let occupied = failed.filter { $0.1.failure == .occupied && $0.1.source != nil }
        if !occupied.isEmpty {
            let pending = DeletionRecord(files: occupied.map { $0.0 }, backups: record.backups, label: record.label)
            actions.conflicts[pending.id] = pending
            toast.conflict = pending.id
        }
        let retry = failed.filter { pair in
            if case .failed = pair.1.failure { return true }
            return pair.1.failure == .retrashed
        }
        if !retry.isEmpty {
            let again = DeletionRecord(files: retry.map { $0.0 }, backups: record.backups, label: record.label)
            remember(again)
            toast.undo = again.id
        }
        showToast(toast)
    }

    func putBackBeside(_ id: UUID) {
        let actions = ShotActions.shared
        guard let record = actions.conflicts.removeValue(forKey: id) else { return }
        actions.beside[record.id] = true
        actions.restoring.append(record)
        putBackNext()
    }

    func archiveURLs(_ items: [Item]) -> [URL] {
        items.compactMap { item -> URL? in
            let path = item.mainPath.isEmpty ? versions(of: item).first(where: { $0.source == "archive" })?.path : item.mainPath
            return path.map { Catalog.archiveRoot.appendingPathComponent($0) }
        }
    }

    func revealInFinder(_ items: [Item]) {
        let urls = archiveURLs(items)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func open(_ items: [Item], with app: URL) {
        let urls = archiveURLs(items)
        if !urls.isEmpty { NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) }
    }
}

enum PhotohubTool {
    private final class Captured: @unchecked Sendable { var data = Data() }

    @MainActor
    static func run(_ arguments: [String], completion: @escaping (Int32, String, String) -> Void) {
        let project = (try? String(contentsOf: Model.supportDir.appendingPathComponent("project_path.txt")))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: project + "/.venv/bin/photohub")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: project)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try process.run()
            } catch {
                DispatchQueue.main.async { completion(-1, "", error.localizedDescription) }
                return
            }
            let errors = Captured()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                errors.data = err.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            group.wait()
            process.waitUntilExit()
            let status = process.terminationStatus
            let message = String(decoding: errors.data, as: UTF8.self)
            DispatchQueue.main.async { completion(status, output, message) }
        }
    }
}

struct MovePlan {
    let moves: Int
    let skipped: [(path: String, reason: String)]
    let lightroom: Int

    init?(_ output: String) {
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("{") }),
              let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        moves = (json["moves"] as? [Any])?.count ?? 0
        skipped = ((json["skipped"] as? [[String: Any]]) ?? []).map { (($0["path"] as? String) ?? "", ($0["reason"] as? String) ?? "") }
        lightroom = json["lightroom"] as? Int ?? 0
    }
}

struct ShotActionsHost: ViewModifier {
    @ObservedObject var model: Model
    @ObservedObject var actions = ShotActions.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: $actions.removal) { plan in RemovalSheet(model: model, plan: plan) }
            .overlay(alignment: .bottom) {
                if let toast = actions.toast {
                    ToastView(model: model, toast: toast)
                        .id(toast.id)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 18)
                }
            }
            .sheet(isPresented: Binding(get: { !actions.tagging.isEmpty }, set: { if !$0 { actions.tagging = [] } })) {
                TagPicker(model: model, items: actions.tagging)
            }
            .sheet(isPresented: Binding(get: { !actions.moving.isEmpty }, set: { if !$0 { actions.moving = [] } })) {
                MoveSheet(model: model, items: actions.moving)
            }
    }
}

struct RemovalSheet: View {
    @ObservedObject var model: Model
    let plan: RemovalPlan
    @State private var skip = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(plan.heading, systemImage: "trash").font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            section("externaldrive", String(localized: "Archive"), archiveLines)
            section("photo.on.rectangle", String(localized: "Photos"), photosLines)
            if plan.vanishing > 0 {
                Label("Items that will disappear from the catalog: \(plan.vanishing).", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            HStack {
                Toggle("Don't ask again", isOn: $skip)
                    .help("Turn the question back on in Settings → Archive")
                Spacer()
                Button("Cancel") { ShotActions.shared.removal = nil }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    if skip { RemovalPrefs.ask = false }
                    ShotActions.shared.removal = nil
                    model.performRemoval(plan)
                } label: { Text("Move to Trash") }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(plan.isEmpty || !model.busyTool.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private var subtitle: String {
        guard plan.version != nil, let item = plan.items.first else { return String(localized: "Selected items: \(plan.items.count) — \(plan.names)") }
        return plan.kept > 0 ? String(localized: "Only this version is deleted. The shot “\(item.title)” keeps its other versions: \(plan.kept).")
            : String(localized: "This is the last version of the shot “\(item.title)”.")
    }

    private var archiveLines: [String] {
        var lines: [String] = []
        if plan.scope.takesArchive, !plan.archive.isEmpty {
            let members = plan.archive.map { $0.1 }
            lines = [String(localized: "To the Trash: \(members.count) files, \(RemovalPlan.bytes(members))."),
                     String(localized: "Folders: \(plan.folders)."),
                     String(localized: "Files in iCloud Drive go to Recently Deleted in iCloud Drive. Undo (⌘Z) puts them back.")]
        }
        if !plan.keptArchive.isEmpty {
            lines.append(String(localized: "Stay in the archive: \(plan.keptArchive.count) files, \(RemovalPlan.bytes(plan.keptArchive))."))
        }
        return lines.isEmpty ? [String(localized: "No archive files.")] : lines
    }

    private var photosLines: [String] {
        plan.keptPhotos.isEmpty ? [String(localized: "No copies in Photos.")]
            : [String(localized: "Stay in Photos: \(plan.keptPhotos.count) items, \(RemovalPlan.bytes(plan.keptPhotos)).")]
    }

    private func section(_ icon: String, _ title: String, _ lines: [String]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(line).foregroundStyle(index == 0 ? .primary : .secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ToastView: View {
    @ObservedObject var model: Model
    let toast: DeletionToast
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: toast.failed ? "exclamationmark.triangle.fill" : toast.icon)
                .font(.title3)
                .foregroundStyle(toast.failed ? Color.red : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).font(.headline).foregroundStyle(toast.failed ? Color.red : Color.primary)
                if !toast.detail.isEmpty {
                    Text(toast.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            if let details = toast.details {
                Button("Details") {
                    model.notice = Notice(title: toast.reveal.isEmpty ? String(localized: "Could Not Delete") : String(localized: "Could Not Put Back"), text: details)
                }
            }
            if toast.photos {
                Button("Open Photos") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Photos.app")) }
            }
            if !toast.reveal.isEmpty {
                Button("Show in Trash") { Removal.reveal(toast.reveal) }
            }
            if let id = toast.conflict {
                Button("Keep Both") {
                    close()
                    model.putBackBeside(id)
                }
                .help("Put the file back next to the other one under a new name; nothing is replaced")
            }
            if let id = toast.undo {
                Button(toast.failed ? "Try Again" : "Undo") { model.undoDeletion(id) }
                    .buttonStyle(.borderedProminent)
                    .help(toast.failed ? "Try to put the files back again (⌘Z)" : "Put the files back where they were (⌘Z)")
            }
            Button { close() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close")
        }
        .controlSize(.regular)
        .padding(.horizontal, 16).padding(.vertical, 11)
        .glassBar(radius: 14)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 24)
        .onHover { hovering = $0 }
        .task(id: hovering) {
            guard !hovering, !toast.failed, !Theme.snapshot else { return }
            try? await Task.sleep(nanoseconds: (toast.undo != nil || toast.photos ? 8 : 5) * 1_000_000_000)
            if !Task.isCancelled { close() }
        }
    }

    private func close() {
        guard ShotActions.shared.toast?.id == toast.id else { return }
        withAnimation(Theme.spring) { ShotActions.shared.toast = nil }
    }
}

struct MoveSheet: View {
    @ObservedObject var model: Model
    let items: [Item]
    @State private var folder = ""
    @State private var folders: [String] = []
    @State private var plan: MovePlan?
    @State private var planned = ""
    @State private var working = false
    @State private var error: String?

    private var matches: [String] {
        let needle = folder.trimmingCharacters(in: .whitespaces)
        return Array(folders.filter { needle.isEmpty || ($0.localizedCaseInsensitiveContains(needle) && $0 != needle) }.prefix(8))
    }

    private var target: String { folder.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move to Folder").font(.title2).bold()
            Text("Selected items: \(items.count). Their archive files move to the folder inside the archive, RAW files keep their RAW subfolder. Items that are only in Photos and files linked to Lightroom are skipped.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Folder inside the archive", text: $folder).textFieldStyle(.roundedBorder)
                Button("Choose…", action: choose)
            }
            .disabled(working)
            if !matches.isEmpty && plan == nil {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(matches, id: \.self) { path in
                        Button { folder = path } label: { Label(path, systemImage: "folder").lineLimit(1) }.buttonStyle(.link)
                    }
                }
            }
            if let plan, planned == target {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Files to move: \(plan.moves) → \(target)").bold()
                    if !plan.skipped.isEmpty {
                        Text("Skipped: \(plan.skipped.count)").foregroundStyle(.secondary)
                        ForEach(Array(plan.skipped.prefix(5).enumerated()), id: \.offset) { _, entry in
                            Text(verbatim: "\(entry.path): \(entry.reason)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text(model.busyTool.isEmpty ? String(localized: "Working…") : model.busyTool).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Cancel") { ShotActions.shared.moving = [] }.keyboardShortcut(.cancelAction).disabled(working)
                if let plan, planned == target {
                    Button("Move \(plan.moves) Files", action: apply).keyboardShortcut(.defaultAction)
                        .disabled(working || plan.moves == 0 || !model.busyTool.isEmpty)
                } else {
                    Button("Show Plan", action: preview).keyboardShortcut(.defaultAction)
                        .disabled(working || target.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            var out: [String] = []
            func walk(_ node: FolderNode) {
                if node.id != "/" { out.append(node.id) }
                node.children?.forEach(walk)
            }
            model.tree.forEach(walk)
            folders = out
            if let root = Set(items.map { $0.root }).first, items.allSatisfy({ $0.root == root }), !root.isEmpty { folder = root }
        }
    }

    private var arguments: [String] { ["move", "--to", target, "--json"] }
    private var keys: [String] { ["--keys"] + items.map { $0.key } }

    private func preview() {
        let destination = target
        guard !destination.isEmpty else { return }
        working = true
        error = nil
        PhotohubTool.run(arguments + keys) { status, output, errors in
            working = false
            guard status == 0, let parsed = MovePlan(output) else {
                error = errors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "The plan could not be built.") : errors.trimmingCharacters(in: .whitespacesAndNewlines)
                return
            }
            plan = parsed
            planned = destination
        }
    }

    private func apply() {
        let destination = target
        guard plan != nil, planned == destination, model.busyTool.isEmpty else { return }
        working = true
        error = nil
        model.busyTool = String(localized: "Moving files…")
        PhotohubTool.run(["move", "--to", destination, "--apply", "--json"] + keys) { status, output, errors in
            working = false
            model.busyTool = ""
            let done = MovePlan(output)
            model.reload()
            guard status == 0, let done else {
                error = errors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "The move did not finish.") : errors.trimmingCharacters(in: .whitespacesAndNewlines)
                return
            }
            ShotActions.shared.moving = []
            model.notice = Notice(title: String(localized: "Moved"), text: String(localized: "Files moved to “\(destination)”: \(done.moves). The agent can undo the last move."))
        }
    }

    private func choose() {
        let delegate = ArchivePanelDelegate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = Catalog.archiveRoot.appendingPathComponent(target)
        panel.prompt = String(localized: "Choose")
        panel.delegate = delegate
        guard panel.runModal() == .OK, let url = panel.url, delegate.inside(url) else { return }
        folder = delegate.relative(url)
    }
}

enum ShotSnapshot {
    @MainActor private static var stats = ""

    @MainActor
    private static func undoHandler(_ window: NSWindow?) -> String {
        var responder: NSResponder? = window?.firstResponder
        while let current = responder {
            if current.responds(to: Selector(("undo:"))) {
                let item = NSMenuItem(title: "", action: Selector(("undo:")), keyEquivalent: "z")
                let enabled = (current as? NSUserInterfaceValidations)?.validateUserInterfaceItem(item) ?? true
                return "\(type(of: current)) enabled=\(enabled) title=\(item.title)"
            }
            responder = current.nextResponder
        }
        return "-"
    }

    @MainActor
    static func apply(_ flag: String, _ model: Model) {
        let pair = flag.split(separator: "=", maxSplits: 1).map(String.init)
        let name = pair.first ?? "", value = pair.count == 2 ? pair[1] : ""
        func presence(_ text: String) -> Presence {
            switch text {
            case "with", "several": return .with
            case "without", "single": return .without
            default: return .all
            }
        }
        switch name {
        case "selectboth":
            let picked = model.flat.filter { $0.inArchive && $0.inPhotos }.prefix(Int(value) ?? 2)
            model.selection = Set(picked.map { $0.id })
            model.selected = picked.first
            model.scrollRequest += 1
        case "setlabel": model.setLabel(ColorLabel(rawValue: value))
        case "togglelabel": if let label = ColorLabel(rawValue: value) { model.toggleLabel(label) }
        case "selectlabel": if let label = ColorLabel(rawValue: value) { model.selectLabel(label) }
        case "label":
            switch value {
            case "any": model.labelFilter = .anyLabel
            case "none": model.labelFilter = .none
            default: model.labelFilter = ColorLabel(rawValue: value).map { .one($0) } ?? .any
            }
        case "raw": model.rawFilter = presence(value)
        case "edits": model.editFilter = presence(value)
        case "stacks": model.stackFilter = presence(value)
        case "sort": if let key = SortKey.allCases.first(where: { "\($0)" == value }) { model.sort = key }
        case "reset": model.resetFilters()
        case "wide": model.window?.setContentSize(NSSize(width: Int(value) ?? 2400, height: 700))
        case "noinspector": model.inspectorHidden = true
        case "delete": model.askRemoval(RemovalScope(rawValue: value) ?? .everywhere)
        case "deleteversion":
            if let item = model.selected, let page = model.page, page.versions.indices.contains(page.index) { model.askRemoval(page.versions[page.index], of: item) }
        case "deletefocused": model.deleteFocused()
        case "cmdkey":
            let keys: [String: (String, UInt16)] = ["delete": ("\u{8}", 51), "z": ("z", 6)]
            if let (characters, code) = keys[value],
               let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: model.window?.windowNumber ?? 0, context: nil, characters: characters,
                                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                for case let menu? in NSApp.mainMenu?.items.map(\.submenu) ?? [] {
                    menu.delegate?.menuNeedsUpdate?(menu)
                    menu.update()
                }
                NSApp.postEvent(event, atStart: false)
            }
        case "version":
            if let page = model.page, let index = page.versions.firstIndex(where: { $0.role == value || $0.ext.lowercased() == value.lowercased() }) { page.index = index }
        case "fakephotos":
            Removal.photosDeleter = { _, done in DispatchQueue.main.asyncAfter(deadline: .now() + 20) { done(.cancelled) } }
        case "photosversion":
            if let item = model.selected, let page = model.page {
                let asset = Member(id: -1, source: "photos", path: "SNAPSHOT-ASSET/L0/001", name: "IMG_7170.HEIC", ext: "heic", size: 2_400_000,
                                   role: "photo", taken: "", width: 4032, height: 3024)
                model.request(RemovalPlan.version(asset, of: item, stack: page.versions + [asset]))
            }
        case "confirmdelete":
            if let plan = ShotActions.shared.removal {
                ShotActions.shared.removal = nil
                model.performRemoval(plan)
            }
        case "undodelete": _ = model.window?.tryToPerform(Selector(("undo:")), with: nil)
        case "askdelete": RemovalPrefs.ask = value != "off"
        case "sampletoast" where value == "putback":
            let original = Catalog.archiveRoot.appendingPathComponent("2026-07-10 Rivne /RAW/DSCF3119.RAF")
            let result = PutBackResult(file: TrashedFile(original: original, trashed: nil, size: 1), target: original,
                                       source: Removal.mobileDocuments.appendingPathComponent(".Trash/DSCF3119.RAF"), failure: .occupied)
            model.showToast(DeletionToast(title: String(localized: "Could not put back “\(original.lastPathComponent)”"), detail: result.message, failed: true,
                                          undo: UUID(), icon: "arrow.uturn.backward", reveal: [result], conflict: UUID()))
        case "sampletoast":
            model.showToast(value == "error"
                ? DeletionToast(title: String(localized: "Could not delete \(1) files"), detail: String(localized: "\(2) files moved to the Trash"), failed: true, details: "-")
                : DeletionToast(title: String(localized: "Deleted \(3) shots"),
                                detail: String(localized: "\(4) files moved to the Trash") + " · " + String(localized: "\(3) items moved to Recently Deleted in Photos") + "\n" + String(localized: "Restore Photos items in Photos → Recently Deleted."),
                                undo: UUID(), photos: true))
        case "deletestats":
            let toast = ShotActions.shared.toast
            var lines = ["shown: \(model.shown)", "selection: \(model.selection.count)", "selected: \(model.selected?.title ?? "-")", "viewing: \(model.viewing)",
                         "busy: \(model.busyTool)", "sheet: \(ShotActions.shared.removal.map { "\($0.archive.count) archive, \($0.photos.count) photos" } ?? "-")",
                         "toast: \(toast.map { "\($0.title) | \($0.detail) | failed=\($0.failed) undo=\($0.undo != nil) photos=\($0.photos)" } ?? "-")",
                         "undo: \(model.window?.undoManager?.canUndo == true ? model.window?.undoManager?.undoMenuItemTitle ?? "" : "-")",
                         "undo: handled by \(undoHandler(model.window))",
                         "sheet title: \(ShotActions.shared.removal?.heading ?? "-")",
                         "focus: \(ShotActions.shared.focus.map { "\($0.member.name) main=\($0.main)" } ?? "-")",
                         "undo history: \(ShotActions.shared.history.records.map { $0.files.map { ($0.path as NSString).lastPathComponent }.joined(separator: "+") }.joined(separator: ", "))",
                         "page versions: \(model.viewing ? (model.page?.versions.map { $0.name }.joined(separator: ", ") ?? "-") : "-")"]
            for item in model.targets() {
                lines.append("target \(item.title): " + model.members(of: item).map { "\($0.source):\($0.path) exists=\($0.source == "archive" ? FileManager.default.fileExists(atPath: Catalog.archiveRoot.appendingPathComponent($0.path).path) : true)" }.joined(separator: ", "))
            }
            stats += lines.joined(separator: "\n") + "\n---\n"
            let out = (ProcessInfo.processInfo.environment["PHOTOHUB_SNAPSHOT"] ?? "/tmp/shot") + "-delete.txt"
            try? stats.write(toFile: out, atomically: true, encoding: .utf8)
        case "tagsheet": ShotActions.shared.tagging = model.targets()
        case "tagquery", "tagkeys": TagPickerState.snapshot(name, value)
        case "movesheet": ShotActions.shared.moving = model.targets()
        case "closesheets":
            ShotActions.shared.removal = nil
            ShotActions.shared.tagging = []
            ShotActions.shared.moving = []
        case "labelstats":
            var lines = ["shown: \(model.shown)", "selection: \(model.selection.count)", "filters: \(model.activeFilters)"]
            for label in ColorLabel.allCases {
                lines.append("\(label.rawValue): catalog \(model.marks.values.filter { $0.color == label.rawValue }.count), shown \(model.flat.filter { model.label(of: $0) == label }.count)")
            }
            lines.append("selected labels: " + model.targets().map { "\($0.title)=\(model.label(of: $0)?.rawValue ?? "-")" }.joined(separator: ", "))
            stats += lines.joined(separator: "\n") + "\n---\n"
            let out = (ProcessInfo.processInfo.environment["PHOTOHUB_SNAPSHOT"] ?? "/tmp/shot") + "-labels.txt"
            try? stats.write(toFile: out, atomically: true, encoding: .utf8)
        default:
            if name.hasPrefix("select"), let n = Int(name.dropFirst(6)) { model.debugSelect(n) }
        }
    }
}
