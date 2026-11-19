import AppKit
import SwiftUI

struct AppCommands: Commands {
    @ObservedObject var model: Model

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About PhotoHub") { AppCommands.about() }
        }
        CommandMenu("Catalog") {
            Button("Refresh Catalog") { model.refreshCatalog() }
                .keyboardShortcut("r")
                .disabled(!model.busyTool.isEmpty)
            Button("Make Previews for Folder") { model.buildPreviews() }
                .disabled(model.previewRoot == nil || !model.busyTool.isEmpty)
            Divider()
            Button("Send Flagged to Photos…") { model.confirmPhone = true }
                .disabled(model.flagged.isEmpty || !model.busyTool.isEmpty)
        }
        CommandGroup(before: .toolbar) {
            Button("Collections") { model.go(.home) }.keyboardShortcut("1")
            Button("All Items") { model.go(.all) }.keyboardShortcut("2")
            Button("Map") { model.go(.map) }.keyboardShortcut("3")
            Button(String(localized: "Calendar", table: "Calendar")) { model.go(.calendar("overview")) }.keyboardShortcut("4")
            Button("Folders") { model.go(.folders("")) }.keyboardShortcut("5")
            Button("To Phone") { model.go(.flagged) }.keyboardShortcut("6")
            Button("Statistics") { model.go(.statistics) }.keyboardShortcut("7")
            Divider()
            Toggle("Agent Panel", isOn: $model.agentOpen)
                .keyboardShortcut("a", modifiers: [.command, .option])
            Button(model.inspectorHidden ? "Show Item Panel" : "Hide Item Panel") { model.inspectorHidden.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }
        CommandMenu("Go") {
            Button("Back") { model.goBack() }
                .keyboardShortcut("[")
                .disabled(!model.canGoBack)
            Button("Forward") { model.goForward() }
                .keyboardShortcut("]")
                .disabled(!model.canGoForward)
        }
    }

    static func about() {
        let credits = NSAttributedString(
            string: String(localized: "The whole photo archive in one window: folders in iCloud Drive and the Photos library."),
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
}
