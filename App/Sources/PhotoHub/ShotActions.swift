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

    var isEmpty: Bool { archive.isEmpty && photos.isEmpty }
    var photoIDs: [String] { Removal.photoBatch(photos.map { $0.1.path }) }
    var asksPhotos: Bool { !photoIDs.isEmpty }

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
}

struct DeletionRecord {
    let id = UUID()
    let files: [(key: String, path: String, file: TrashedFile)]
    let backups: [String: ItemBackup]
}

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
    var lastDeletion: DeletionRecord?
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
        var archive: [(Item, Member)] = [], photos: [(Item, Member)] = []
        var keptArchive: [Member] = [], keptPhotos: [Member] = []
        var vanishing = 0
        for item in items {
            let stack = members(of: item)
            let files = stack.filter { $0.source == "archive" }, assets = stack.filter { $0.source == "photos" }
            if scope.takesArchive { archive += files.map { (item, $0) } } else { keptArchive += files }
            if scope.takesPhotos { photos += assets.map { (item, $0) } } else { keptPhotos += assets }
            if !stack.isEmpty && (scope.takesArchive || files.isEmpty) && (scope.takesPhotos || assets.isEmpty) { vanishing += 1 }
        }
        return RemovalPlan(scope: scope, items: items, archive: archive, photos: photos, keptArchive: keptArchive, keptPhotos: keptPhotos, vanishing: vanishing)
    }

    func askRemoval(_ scope: RemovalScope, _ items: [Item]? = nil) {
        let list = items ?? targets()
        guard !list.isEmpty else { return }
        request(removalPlan(scope, list))
    }

    func askRemoval(_ member: Member, of item: Item) {
        let stack = members(of: item)
        let pair = [(item, member)]
        let archive = member.source == "archive"
        request(RemovalPlan(scope: archive ? .archive : .photos, items: [item], archive: archive ? pair : [], photos: archive ? [] : pair,
                            keptArchive: stack.filter { $0.source == "archive" && $0 != member }, keptPhotos: stack.filter { $0.source == "photos" && $0 != member },
                            vanishing: stack.count <= 1 ? 1 : 0, label: member.name))
    }

    func request(_ plan: RemovalPlan) {
        guard busyTool.isEmpty else { return }
        if plan.isEmpty {
            showToast(DeletionToast(title: String(localized: "Nothing to delete for this choice.")))
        } else if plan.asksPhotos || !RemovalPrefs.ask {
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
        let undo = ShotActions.shared
        window?.undoManager?.removeAllActions(withTarget: undo)
        undo.lastDeletion = nil
        if !trashed.isEmpty {
            let record = DeletionRecord(files: trashed.map { (key: $0.0.0.key, path: $0.0.1.path, file: $0.1) }, backups: backups)
            undo.lastDeletion = record
            toast.undo = record.id
            if let manager = window?.undoManager {
                manager.registerUndo(withTarget: undo) { _ in MainActor.assumeIsolated { self.undoDeletion(record.id) } }
                manager.setActionName(String(localized: "Deletion"))
            }
        }
        showToast(toast)
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

    func undoDeletion(_ id: UUID? = nil) {
        let actions = ShotActions.shared
        guard let record = actions.lastDeletion, id == nil || record.id == id else { return }
        guard busyTool.isEmpty else {
            showToast(DeletionToast(title: String(localized: "Wait until “\(busyTool)” finishes."), failed: true))
            return
        }
        actions.lastDeletion = nil
        window?.undoManager?.removeAllActions(withTarget: actions)
        busyTool = String(localized: "Putting files back…")
        DispatchQueue.global(qos: .userInitiated).async {
            let results = record.files.map { ($0, Removal.putBack($0.file)) }
            DispatchQueue.main.async {
                self.busyTool = ""
                let back = results.filter { $0.1 == nil }.map { $0.0 }
                var paths: [String: Set<String>] = [:]
                for file in back { paths[file.key, default: []].insert(file.path) }
                for (key, set) in paths {
                    if let backup = record.backups[key] { self.catalog?.restore(backup, paths: set) }
                }
                let wasViewing = self.viewing
                self.reload()
                let restored = self.flat.filter { paths[$0.key] != nil }
                if let first = restored.first {
                    self.selection = Set(restored.map { $0.id })
                    self.selected = first
                    self.viewing = wasViewing
                    self.scrollRequest += 1
                }
                let failures = results.compactMap { pair in pair.1.map { "\(pair.0.file.original.lastPathComponent): \($0.localizedDescription)" } }
                var toast = DeletionToast(title: String(localized: "Put back \(back.count) files"), icon: "arrow.uturn.backward")
                if !failures.isEmpty {
                    toast.failed = true
                    toast.detail = String(localized: "Could not put back \(failures.count) files. They are still in the Trash.")
                    toast.details = failures.joined(separator: "\n")
                    if back.isEmpty { toast.title = toast.detail; toast.detail = "" }
                }
                self.showToast(toast)
            }
        }
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
            Label(plan.label.map { String(localized: "Delete “\($0)”?") } ?? plan.scope.title, systemImage: "trash").font(.title2.bold())
            Text("Selected items: \(plan.items.count) — \(plan.names)")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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

    private var archiveLines: [String] {
        if plan.scope.takesArchive {
            guard !plan.archive.isEmpty else { return [String(localized: "No archive files.")] }
            let members = plan.archive.map { $0.1 }
            return [String(localized: "To the Trash: \(members.count) files, \(RemovalPlan.bytes(members))."),
                    String(localized: "Folders: \(plan.folders)."),
                    String(localized: "Files in iCloud Drive go to Recently Deleted in iCloud Drive. Undo (⌘Z) puts them back.")]
        }
        return plan.keptArchive.isEmpty ? [String(localized: "No archive files.")]
            : [String(localized: "Stay in the archive: \(plan.keptArchive.count) files, \(RemovalPlan.bytes(plan.keptArchive)).")]
    }

    private var photosLines: [String] {
        plan.scope.takesPhotos || plan.keptPhotos.isEmpty ? [String(localized: "No copies in Photos.")]
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
                Button("Details") { model.notice = Notice(title: String(localized: "Could Not Delete"), text: details) }
            }
            if toast.photos {
                Button("Open Photos") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Photos.app")) }
            }
            if let id = toast.undo {
                Button("Undo") { model.undoDeletion(id) }
                    .buttonStyle(.borderedProminent)
                    .help("Put the files back where they were (⌘Z)")
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
        case "confirmdelete":
            if let plan = ShotActions.shared.removal {
                ShotActions.shared.removal = nil
                model.performRemoval(plan)
            }
        case "undodelete": _ = model.window?.tryToPerform(Selector(("undo:")), with: nil)
        case "askdelete": RemovalPrefs.ask = value != "off"
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
                         "pending put-back: \(ShotActions.shared.lastDeletion?.files.map { "\($0.path) <- \($0.file.trashed?.path ?? "?")" }.joined(separator: ", ") ?? "-")"]
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
