import AppKit
import Photos
import SwiftUI

enum ArchiveExport {
    struct Written {
        let asset: String
        let kind: String
        let url: URL
        let expected: Int64
        let actual: Int64
    }

    static func size(of resource: PHAssetResource) -> Int64 {
        guard resource.responds(to: NSSelectorFromString("fileSize")) else { return -1 }
        return (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? -1
    }

    static func originals(_ asset: PHAsset) -> [PHAssetResource] {
        let all = PHAssetResource.assetResources(for: asset)
        func first(_ type: PHAssetResourceType) -> [PHAssetResource] { all.first { $0.type == type }.map { [$0] } ?? [] }
        if asset.mediaType == .video { return first(.video) }
        var out = first(.photo) + first(.alternatePhoto)
        if asset.mediaSubtypes.contains(.photoLive) { out += first(.pairedVideo) }
        return out
    }

    static func kind(_ resource: PHAssetResource) -> String {
        switch resource.type {
        case .photo: return String(localized: "original")
        case .alternatePhoto: return "RAW"
        case .pairedVideo: return String(localized: "Live Photo video")
        case .video: return String(localized: "video")
        default: return String(localized: "file")
        }
    }

    private static func freeNames(_ names: [String], in folder: URL) -> [String] {
        for n in 1...999 {
            let candidate = names.map { name -> String in
                guard n > 1 else { return name }
                let ext = (name as NSString).pathExtension
                return (name as NSString).deletingPathExtension + " \(n)" + (ext.isEmpty ? "" : ".\(ext)")
            }
            let clash = candidate.contains { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
            if !clash && Set(candidate.map { $0.lowercased() }).count == candidate.count { return candidate }
        }
        return names.map { UUID().uuidString + "-" + $0 }
    }

    private static func write(_ resource: PHAssetResource, to url: URL) -> Error? {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        var failure: Error?
        let done = DispatchSemaphore(value: 0)
        PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
            failure = error
            done.signal()
        }
        done.wait()
        return failure
    }

    static func run(_ ids: [String], to folder: URL, progress: @escaping (Int) -> Void) -> (written: [Written], failures: [String]) {
        var written: [Written] = []
        var failures: [String] = []
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return ([], [String(localized: "Could not create the folder “\(folder.lastPathComponent)”: \(error.localizedDescription)")])
        }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assets: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in assets[asset.localIdentifier] = asset }
        for (index, id) in ids.enumerated() {
            defer { progress(index + 1) }
            guard let asset = assets[id] else {
                failures.append(String(localized: "Item \(id) was not found in Photos."))
                continue
            }
            let resources = originals(asset)
            guard !resources.isEmpty else {
                failures.append(String(localized: "Item \(id) has no original in Photos."))
                continue
            }
            let names = freeNames(resources.map { $0.originalFilename }, in: folder)
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoHub-export-" + UUID().uuidString)
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            for (resource, name) in zip(resources, names) {
                let temp = scratch.appendingPathComponent(name)
                let target = folder.appendingPathComponent(name)
                if let error = write(resource, to: temp) {
                    failures.append(String(localized: "“\(resource.originalFilename)”: Photos did not provide the original — \(error.localizedDescription)"))
                    continue
                }
                do {
                    try FileManager.default.moveItem(at: temp, to: target)
                    let actual = ((try? FileManager.default.attributesOfItem(atPath: target.path))?[.size] as? NSNumber)?.int64Value ?? -1
                    let expected = size(of: resource)
                    written.append(Written(asset: id, kind: kind(resource), url: target, expected: expected, actual: actual))
                    if expected >= 0 && expected != actual {
                        failures.append(String(localized: "“\(name)”: the size is \(actual) bytes, but \(expected) bytes in Photos."))
                    }
                } catch {
                    failures.append(String(localized: "“\(name)”: could not put it into the archive — \(error.localizedDescription)"))
                }
            }
        }
        return (written, failures)
    }

    @MainActor
    static func selfTest(_ model: Model, items: [Item], report: String) {
        guard let item = items.first(where: { $0.needsArchive && !$0.isVideo && $0.formats == "HEIC" && $0.size > 800_000 && $0.size < 3_000_000 }),
              let asset = model.versions(of: item).first(where: { $0.source == "photos" }) else {
            try? "no phone-only HEIC item found\ndone\n".write(toFile: report, atomically: true, encoding: .utf8)
            return
        }
        let folder = Catalog.archiveRoot.appendingPathComponent("_photohub_test_export")
        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            let result = run([asset.path], to: folder) { _ in }
            var lines = ["item: \(item.title) [\(item.key)]", "date: \(item.date)", "asset: \(asset.path)", "folder: \(folder.path)",
                         "seconds: \(String(format: "%.1f", Date().timeIntervalSince(started)))"]
            for w in result.written {
                lines.append("\(w.kind): \(w.url.lastPathComponent) · PhotoKit fileSize \(w.expected) · written \(w.actual) · \(w.expected == w.actual ? "equal" : "DIFFERENT")")
            }
            lines += result.failures.map { "failure: \($0)" }
            lines.append("done")
            try? lines.joined(separator: "\n").appending("\n").write(toFile: report, atomically: true, encoding: .utf8)
        }
    }
}

final class ArchivePanelDelegate: NSObject, NSOpenSavePanelDelegate {
    let root = Catalog.archiveRoot.standardizedFileURL.resolvingSymlinksInPath().path

    func inside(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path == root || path.hasPrefix(root + "/")
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool { inside(url) }

    func panel(_ sender: Any, validate url: URL) throws {
        guard inside(url) else {
            throw NSError(domain: "PhotoHub", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Choose a folder inside the archive.")])
        }
    }

    func relative(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path == root ? "" : String(path.dropFirst(root.count + 1))
    }
}

struct AddToArchiveSheet: View {
    @ObservedObject var model: Model
    let items: [Item]
    @State private var suggestions: [ArchiveSuggestion] = []
    @State private var choice: String?
    @State private var custom: String?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add to Archive").font(.title2).bold()
            Text(summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Where to").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(suggestions) { suggestion in
                    row(suggestion.path, suggestion.reason, exists: suggestion.exists)
                }
                if let custom, !suggestions.contains(where: { $0.path == custom }) {
                    row(custom, String(localized: "chosen manually"), exists: FileManager.default.fileExists(atPath: Catalog.archiveRoot.appendingPathComponent(custom).path))
                }
                if suggestions.isEmpty && custom == nil {
                    Text("No suggestions — choose a folder manually.").foregroundStyle(.secondary)
                }
            }
            Button("Other Folder…", action: chooseFolder).disabled(working)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text(model.busyTool.isEmpty ? String(localized: "Adding…") : model.busyTool).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Cancel") { model.archiveTargets = [] }
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(choice == nil || working)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            suggestions = model.archiveSuggestions(items)
            choice = suggestions.first?.path
        }
    }

    private var summary: String {
        let what = items.count == 1 ? String(localized: "Item “\(items[0].title)” is only in Photos.") : String(localized: "Items only in Photos: \(items.count).")
        return what + " " + String(localized: "The original is copied to the archive folder under its original name (for a Live Photo, the video too). If the original is stored in iCloud, Photos downloads it first. Then the catalog is refreshed.")
    }

    private func row(_ path: String, _ reason: String, exists: Bool) -> some View {
        Button { choice = path } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: choice == path ? "largecircle.fill.circle" : "circle").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(path.isEmpty ? String(localized: "Archive root") : path).bold()
                    Text(exists ? reason : String(localized: "\(reason) · the folder does not exist yet, it will be created")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chooseFolder() {
        let delegate = ArchivePanelDelegate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = Catalog.archiveRoot.appendingPathComponent(choice ?? "")
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "A folder inside the archive. You can create a new one with the New Folder button.")
        panel.delegate = delegate
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard delegate.inside(url) else {
            error = String(localized: "Choose a folder inside the archive.")
            return
        }
        custom = delegate.relative(url)
        choice = custom
        error = nil
    }

    private func add() {
        guard let choice else { return }
        working = true
        error = nil
        model.addToArchive(items, folder: choice) { failure in
            working = false
            if let failure { error = failure } else { model.archiveTargets = [] }
        }
    }
}
