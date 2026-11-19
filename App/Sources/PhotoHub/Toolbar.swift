import AppKit
import SwiftUI

extension View {
    @ViewBuilder func replacingSidebarToggle() -> some View {
        if #available(macOS 14.0, *) {
            toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }
}

struct MainToolbar: ToolbarContent {
    @ObservedObject var model: Model

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            if #available(macOS 14.0, *) {
                Button { MainToolbar.toggleSidebar() } label: { Label("Sidebar", systemImage: "sidebar.left") }
                    .help("Show or hide the sidebar")
            }
            Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!model.canGoBack)
                .help("Back (⌘[)")
            Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(!model.canGoForward)
                .help("Forward (⌘])")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.scope == .flagged && !model.flagged.isEmpty {
                Button { model.confirmPhone = true } label: { Label("Send to Photos", systemImage: "iphone.and.arrow.forward") }
                    .help("Send the flagged items to the Photos library")
                    .disabled(!model.busyTool.isEmpty)
            }
            Toggle(isOn: $model.agentOpen) { Label("Agent", systemImage: "sparkles") }
                .help("Agent panel (⌥⌘A)")
            if model.isBrowsing {
                Toggle(isOn: Binding(get: { !model.inspectorHidden }, set: { model.inspectorHidden = !$0 })) {
                    Label(model.inspectorHidden ? "Show Panel" : "Hide Panel", systemImage: "sidebar.right")
                }
                .help(model.inspectorHidden ? "Show the item panel (⌥⌘I)" : "Hide the item panel (⌥⌘I)")
            }
            Menu {
                Button { model.refreshCatalog() } label: { Label("Refresh Catalog", systemImage: "arrow.clockwise") }
                    .help("Reread the archive and the Photos library (⌘R)")
                    .disabled(!model.busyTool.isEmpty)
                if model.previewRoot != nil {
                    Button { model.buildPreviews() } label: { Label("Make Previews for Folder", systemImage: "photo.badge.arrow.down") }
                        .help("Make previews for this folder: files download one by one and go back to the cloud")
                        .disabled(!model.busyTool.isEmpty)
                }
                if model.scope == .home {
                    Button { CollectionLayout.shared.customizing = true } label: { Label("Customize and Reorder…", systemImage: "slider.horizontal.3") }
                }
                if !model.flagged.isEmpty {
                    Divider()
                    Button { model.confirmPhone = true } label: { Label("Send Flagged to Photos…", systemImage: "iphone.and.arrow.forward") }
                        .help("Send the flagged items to the Photos library")
                        .disabled(!model.busyTool.isEmpty)
                }
                Divider()
                Button { model.go(.statistics) } label: { Label("Statistics", systemImage: "chart.bar.xaxis") }
                Button { SettingsWindow.open(model) } label: { Label("Settings…", systemImage: "gearshape") }
                    .help("Language, appearance, archive, collections and statistics (⌘,)")
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More actions: refresh the catalog, make previews, send to Photos")
        }
    }

    @MainActor
    static func toggleSidebar() {
        NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
    }
}
