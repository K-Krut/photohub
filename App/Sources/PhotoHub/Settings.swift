import AppKit
import SwiftUI

enum DiskUsage {
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isDirectory != true { return Int64(values.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: nil)
        while let file = walker?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    static func catalog() -> Int64 {
        ["", "-wal", "-shm", "-journal"].reduce(0) { $0 + size(of: URL(fileURLWithPath: Catalog.path + $1)) }
    }
}

struct SettingsView: View {
    @ObservedObject var model: Model

    var body: some View {
        TabView(selection: $model.settingsTab) {
            GeneralSettings().settingsTab("general", "General", "gearshape")
            ArchiveSettings(model: model).settingsTab("archive", "Archive", "folder")
            CatalogSettings(model: model).settingsTab("catalog", "Catalog", "internaldrive")
            PeopleSettings(model: model).settingsTab("people", "People", "person.2")
            CollectionsSettings().settingsTab("collections", "Collections", "square.grid.2x2")
            HiddenSettings(model: model).settingsTab("hidden", "Hidden", "eye.slash")
            StatisticsSettings(model: model).settingsTab("statistics", "Statistics", "chart.bar.xaxis")
            AgentSettings().settingsTab("agent", "Agent", "sparkles")
        }
        .frame(width: 640, height: 500)
        .scrollContentBackground(.hidden)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background(VisualEffect(material: .underWindowBackground).ignoresSafeArea())
        .background(WindowReader { Chrome.styleSettings($0) })
    }
}

struct ArchiveSettings: View {
    @ObservedObject var model: Model
    @State private var root = Catalog.archiveRoot.path
    @State private var changed = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Archive folder") {
                    Text(root).textSelection(.enabled).multilineTextAlignment(.trailing)
                }
                HStack {
                    Spacer()
                    Button("Choose Folder…", action: choose)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            } footer: {
                Text("By default, the Photos folder in iCloud Drive. The path is stored in config.json; both the app and photohub read it.")
            }
            Section {
                DeleteConfirmationToggle()
            }
            Section {
                Text(changed ? "The folder has changed. Rebuild the catalog so that items from the new folder appear in it." : "After changing the folder, the catalog needs a rebuild.")
                    .foregroundStyle(changed ? Color.accentColor : .secondary)
                HStack {
                    Button("Rebuild Catalog") { model.refreshCatalog() }
                        .disabled(!model.busyTool.isEmpty)
                    if !model.busyTool.isEmpty {
                        ProgressView().controlSize(.small)
                        Text(model.busyTool).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Catalog.archiveRoot
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "The folder that holds the photo archive")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Catalog.setArchiveRoot(url)
            root = url.path
            changed = true
            error = nil
        } catch {
            self.error = String(localized: "Could not save the setting: \(error.localizedDescription)")
        }
    }
}

struct CatalogSettings: View {
    @ObservedObject var model: Model
    @State private var sizes: [String: Int64]?

    var body: some View {
        Form {
            Section {
                LabeledContent("Data folder") {
                    Text(Model.supportDir.path).textSelection(.enabled).multilineTextAlignment(.trailing)
                }
                HStack {
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Model.supportDir]) }
                }
            }
            Section("Size") {
                LabeledContent("Catalog", value: size("catalog"))
                LabeledContent("Thumbnails", value: size("thumbs"))
                LabeledContent("Previews", value: size("previews"))
            }
            Section {
                Toggle("Hide items that are not mine", isOn: $model.hideForeign)
            } footer: {
                Text("Screenshots, images from messengers, saved and generated images are not shown in All Items, years, trips, places and On These Days. Search and the Origin filter show everything.")
            }
        }
        .formStyle(.grouped)
        .task {
            sizes = await Task.detached(priority: .utility) {
                ["catalog": DiskUsage.catalog(), "thumbs": DiskUsage.size(of: Thumbs.cacheDir), "previews": DiskUsage.size(of: Thumbs.previewDir)]
            }.value
        }
    }

    private func size(_ key: String) -> String {
        guard let sizes else { return String(localized: "calculating…") }
        return ByteCountFormatter.string(fromByteCount: sizes[key] ?? 0, countStyle: .file)
    }
}

struct PeopleSettings: View {
    @ObservedObject var model: Model

    var body: some View {
        Form {
            Section {
                Picker("This is me", selection: $model.meName) {
                    Text(model.autoMe.isEmpty ? "Automatic" : "Automatic (\(model.autoMe))").tag("")
                    if !model.meName.isEmpty && !model.personNames.contains(model.meName) {
                        Text("\(model.meName) (not in the catalog)").tag(model.meName)
                    }
                    ForEach(model.personNames, id: \.self) { Text($0).tag($0) }
                }
            } footer: {
                Text("The People filter uses this person for With Me and Without Me. Automatic picks the person who is in the most items.")
            }
            Section {
                LabeledContent("Named people", value: "\(model.personNames.count)")
                LabeledContent("Named pets", value: "\(model.petNames.count)")
            } footer: {
                Text(model.peopleStatus == "no_access"
                     ? "No access to the Photos database. Give PhotoHub Full Disk Access and refresh the catalog."
                     : "People and pets come from the Photos app (named faces) when the catalog is refreshed.")
            }
        }
        .formStyle(.grouped)
    }
}

struct AgentSettings: View {
    var body: some View {
        let path = Model.agentBinary.path
        let found = FileManager.default.isExecutableFile(atPath: path)
        let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
        Form {
            Section {
                LabeledContent("Program") {
                    Text(path).textSelection(.enabled).multilineTextAlignment(.trailing)
                }
                if let target {
                    LabeledContent("Link points to") {
                        Text(target).textSelection(.enabled).multilineTextAlignment(.trailing)
                    }
                }
                LabeledContent("Status") {
                    Label(found ? "found" : "not found", systemImage: found ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(found ? .green : .red)
                }
                LabeledContent("Model") {
                    Text(Model.agentModel).textSelection(.enabled)
                }
            } footer: {
                Text("The agent is Claude Code on your Claude subscription. If the program is not found, install Claude Code and sign in.")
            }
        }
        .formStyle(.grouped)
    }
}
