import AppKit
import SwiftUI

@MainActor
enum TileHover {
    static var id: Int64?
    private static var monitor: Any?

    static func update(_ id: Int64, _ inside: Bool) {
        if inside { self.id = id } else if self.id == id { self.id = nil }
    }

    static func install(_ model: Model) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak model] event in
            guard event.type == .rightMouseDown || event.modifierFlags.contains(.control) else { return event }
            MainActor.assumeIsolated {
                guard let model, event.window === model.window, let id = TileHover.id, !model.selection.contains(id),
                      let item = model.flat.first(where: { $0.id == id }) else { return }
                model.click(item, command: false, shift: false)
            }
            return event
        }
    }
}

struct TileContext: ViewModifier {
    let model: Model
    let item: Item

    func body(content: Content) -> some View {
        content
            .onHover { TileHover.update(item.id, $0) }
            .contextMenu { TileMenu(model: model, item: item) }
            .onAppear { TileHover.install(model) }
    }
}

struct TileMenu: View {
    @ObservedObject var model: Model
    let item: Item

    var body: some View {
        let preview = model.contextPreview(item)
        let items = { model.contextItems(item) }
        ShotMenuItems(model: model, preview: preview, items: items, clicked: item)
    }
}

struct ShotMenuItems: View {
    @ObservedObject var model: Model
    let preview: [Item]
    let items: () -> [Item]
    var clicked: Item?

    var body: some View {
        let inArchive = preview.contains { $0.inArchive }
        let inPhotos = preview.contains { $0.inPhotos }
        let idle = model.busyTool.isEmpty
        Group {
            Button("Delete Everywhere…") { model.askRemoval(.everywhere, items()) }
                .disabled(!idle)
            Button("Delete Archive Copy…") { model.askRemoval(.archive, items()) }
                .disabled(!idle || !inArchive)
            Button("Delete from Photos…") { model.askRemoval(.photos, items()) }
                .disabled(!idle || !inPhotos)
        }
        Divider()
        Menu("Label") {
            LabelMenuItems(model: model, preview: preview, items: items)
            if let label = (clicked ?? preview.first).flatMap({ model.label(of: $0) }) {
                Divider()
                Button("Select All with This Label") { model.selectLabel(label) }
            }
        }
        Menu("Rating") {
            ForEach(0...5, id: \.self) { n in
                Button(n == 0 ? String(localized: "No Rating") : String(repeating: "★", count: n)) {
                    _ = items()
                    model.rate(n)
                }
            }
        }
        Button("Pick") {
            _ = items()
            model.pick(1)
        }
        Button("Reject") {
            _ = items()
            model.pick(-1)
        }
        Button("Unflag") {
            _ = items()
            model.pick(0)
        }
        Divider()
        Button("Add Tag…") { model.askTags(items()) }
        let tags = Array(Set(preview.flatMap { model.userTags(of: $0) })).sorted()
        Menu("Remove Tag") {
            ForEach(tags, id: \.self) { tag in
                Button(tag) { model.setTag("user", tag, on: false, items: items()) }
            }
        }
        .disabled(tags.isEmpty)
        Divider()
        Toggle("To Phone", isOn: Binding(
            get: { !preview.isEmpty && preview.allSatisfy { model.flagged.contains($0.key) } },
            set: { _ in
                _ = items()
                model.toggleFlagSelection()
            }))
        if preview.contains(where: { $0.needsArchive }) {
            Button("Add to Archive…") { model.askAddToArchive(items()) }
                .disabled(!idle)
        }
        Button("Move to Folder…") { ShotActions.shared.moving = items() }
            .disabled(!idle || !inArchive)
        HiddenMenuItems(model: model, preview: preview, items: items)
        Divider()
        Button("Show in Finder") { model.revealInFinder(items()) }
            .disabled(!inArchive)
        Menu("Open In") {
            ForEach(Model.editors, id: \.name) { editor in
                Button(editor.name) { model.open(items(), with: editor.url) }
            }
        }
        .disabled(!inArchive)
    }
}

struct ShotCommands: Commands {
    @ObservedObject var model: Model
    @ObservedObject var actions = ShotActions.shared

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            if model.viewing, let focus = actions.focus, focus.key == model.selected?.key {
                if focus.main {
                    Button("Delete Whole Shot…", action: deleteFocused)
                        .keyboardShortcut(.delete, modifiers: .command)
                        .disabled(!model.busyTool.isEmpty)
                    Button("Delete This Version…") { model.deleteShownVersion() }
                        .disabled(!model.busyTool.isEmpty)
                } else {
                    Button("Delete This Version…", action: deleteFocused)
                        .keyboardShortcut(.delete, modifiers: .command)
                        .disabled(!model.busyTool.isEmpty)
                    Button("Delete Whole Shot…") { model.deleteShownShot() }
                        .disabled(!model.busyTool.isEmpty)
                }
            } else {
                Button("Delete Everywhere…", action: deleteFocused)
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(!model.hasTargets || !model.busyTool.isEmpty)
            }
            Button("Delete Archive Copy…") { model.askRemoval(.archive) }
                .disabled(!model.hasTargets || !model.busyTool.isEmpty)
            Button("Delete from Photos…") { model.askRemoval(.photos) }
                .disabled(!model.hasTargets || !model.busyTool.isEmpty)
            Divider()
            Button("Add Tag…") { model.askTags() }
                .keyboardShortcut("t")
                .disabled(!model.hasTargets)
        }
        CommandMenu("Label") {
            ForEach(ColorLabel.allCases) { label in
                Button(label.titleWithKey) { model.toggleLabel(label) }
                    .disabled(!model.hasTargets)
            }
            Divider()
            Button("No Label") { model.setLabel(nil) }
                .disabled(!model.hasTargets)
            Divider()
            Menu("Select All with Label") {
                ForEach(ColorLabel.allCases) { label in
                    Button(label.title) { model.selectLabel(label) }
                }
            }
            .disabled(!model.isBrowsing)
        }
    }

    private func deleteFocused() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView {
            text.deleteToBeginningOfLine(nil)
            return
        }
        guard NSApp.keyWindow == nil || NSApp.keyWindow === model.window else { return }
        model.deleteFocused()
    }
}
