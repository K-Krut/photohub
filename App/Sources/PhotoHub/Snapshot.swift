import AppKit
import SwiftUI

enum Snapshot {
    private static let kinds: Set<String> = ["home", "all", "flagged", "map", "folders", "root", "list", "year", "camera", "tag", "card", "keep", "back", "forward", "settings", "menu", "deletetest", "exporttest", "trashtest", "exports", "photosonly", "stats", "hidden", "calendar"]

    @MainActor
    static func run(_ model: Model) {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["PHOTOHUB_SNAPSHOT"] else { return }
        SnapshotOptions.prepare()
        let steps = (env["PHOTOHUB_SCOPES"] ?? "home").split(separator: ";").map(String.init)
        conceal()
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in MainActor.assumeIsolated { conceal() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            for window in NSApp.windows { window.setContentSize(NSSize(width: 1500, height: 950)) }
        }
        var delay = 6.0
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { apply(step, model) }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 3.0) {
                capture("\(out)-\(index).png", step.hasPrefix("settings") ? NSApp.windows.first { $0 !== model.window && !($0 is StageWindow) && $0.isVisible && $0.frame.width > 300 } : model.window)
                describe(model, step, "\(out)-\(index).txt")
            }
            delay += SnapshotOptions.staged ? 10.0 : SnapshotOptions.visible ? 6.0 : 4.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.5) { finish(Date().addingTimeInterval(900)) }
    }

    private static func finish(_ deadline: Date) {
        guard Removal.testing, Date() < deadline else { exit(0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { finish(deadline) }
    }

    @MainActor
    private static func conceal() {
        guard !SnapshotOptions.visible || SnapshotOptions.staged && !SnapshotOptions.showing else { return }
        for window in NSApp.windows {
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        }
    }

    private static var output: String { ProcessInfo.processInfo.environment["PHOTOHUB_SNAPSHOT"] ?? "/tmp/shot" }

    @MainActor
    private static func apply(_ step: String, _ model: Model) {
        let parts = step.split(separator: "|").map(String.init)
        let head = parts.first ?? "home"
        let (kind, value) = head.split(separator: ":", maxSplits: 1).map(String.init).reduce(into: ("", "")) { acc, part in
            if acc.0.isEmpty { acc.0 = part } else { acc.1 = part }
        }
        let known = kinds.contains(kind)
        switch known ? kind : "keep" {
        case "home": model.go(.home)
        case "all": model.go(.all)
        case "flagged": model.go(.flagged)
        case "map": model.go(.map)
        case "folders": model.go(.folders(value))
        case "root": model.go(.root(value))
        case "list": model.go(.list(value))
        case "year": model.go(.year(value))
        case "camera": model.go(.camera(value))
        case "tag":
            let pair = value.split(separator: ":", maxSplits: 1).map(String.init)
            if pair.count == 2 { model.go(.tag(pair[0], pair[1])) }
        case "card": if let card = model.cards(value).first { model.go(card.scope) }
        case "back": model.goBack()
        case "forward": model.goForward()
        case "settings":
            model.settingsTab = value.isEmpty ? "general" : value
            if let menu = NSApp.mainMenu?.items.first?.submenu, let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) { menu.performActionForItem(at: index) }
            later(0.2) { conceal() }
        case "menu":
            if let (menu, index) = menuItem(value, in: NSApp.mainMenu) { menu.performActionForItem(at: index) }
        case "deletetest":
            Removal.selfTest(output + "-deletetest.txt", options: value)
        case "exporttest":
            ArchiveExport.selfTest(model, items: model.phoneOnly, report: output + "-exporttest.txt")
        case "trashtest":
            let url = Catalog.archiveRoot.appendingPathComponent(value)
            DispatchQueue.global(qos: .userInitiated).async {
                var lines = ["path: \(url.path)", "existed: \(FileManager.default.fileExists(atPath: url.path))"]
                switch Removal.trash(url) {
                case .success(let moved): lines += ["result: ok", "moved to: \(moved?.path ?? "-")"]
                case .failure(let error): lines += ["result: error", Removal.dump(error)]
                }
                lines += ["left in archive: \(FileManager.default.fileExists(atPath: url.path))", "done"]
                try? lines.joined(separator: "\n").appending("\n").write(toFile: output + "-trashtest.txt", atomically: true, encoding: .utf8)
            }
        case "stats": model.go(.statistics)
        case "exports": model.go(.kind(.photosExports))
        case "photosonly": model.go(.kind(.photosOnly))
        case "hidden": model.go(.hidden)
        case "calendar": CalendarStore.shared.open(value, model)
        default: break
        }
        for flag in known ? Array(parts.dropFirst()) : parts {
            switch flag {
            case "select": model.debugSelect(1)
            case "selectphone": model.debugSelect { $0.needsArchive }
            case "addarchive":
                model.askAddToArchive(model.archiveCandidates)
                later(0.5) { conceal() }
            case "confirmcopies", "confirmoriginals":
                model.exportConfirm = nil
                later(0.6) { model.exportConfirm = flag == "confirmcopies" ? .removeCopies : .removeOriginals }
                later(1.2) { conceal() }
            case "close": model.exportConfirm = nil
            case "customize":
                CollectionLayout.shared.customizing = true
                later(0.5) { conceal() }
            case "rowsreset": CollectionLayout.shared.restoreDefaults()
            case "statsyears", "statshighlights", "statstop", "statsmarks", "statsspace":
                later(1.0) {
                    StatisticsStore.shared.section = String(flag.dropFirst(5))
                    StatisticsStore.shared.jump += 1
                }
            case "vexport": later(1.0) { if let page = model.page, let index = page.versions.firstIndex(where: { $0.role == "export" }) { page.index = index } }
            case "select3": model.debugSelect(3)
            case "agent": model.agentOpen = true
            case "view": model.openPage()
            case "reload": model.reload()
            case "withme": model.peopleFilter = .withMe
            case "withoutme": model.peopleFilter = .withoutMe
            case "page":
                model.debugSelect(1)
                model.openPage()
            case "back": model.goBack()
            case "forward": model.goForward()
            case "menus": later(0.5) { dumpMenus("\(ProcessInfo.processInfo.environment["PHOTOHUB_SNAPSHOT"] ?? "/tmp/shot")-menus.txt") }
            case "open":
                if case .folders(let path) = model.scope, let node = model.sortedFolders(in: path).first { model.go(model.folderScope(node)) }
            case "v2": later(1.0) { model.page?.stepVersion(1) }
            case "compare": later(1.2) { model.page?.compare = true }
            case "zoom": later(1.8) { model.page?.zoom { $0.set(200) } }
            default:
                if flag.hasPrefix("rowtop="), let index = CollectionLayout.shared.order.firstIndex(of: String(flag.dropFirst(7))) {
                    CollectionLayout.shared.move(from: [index], to: 0)
                } else if flag.hasPrefix("rowhide=") {
                    CollectionLayout.shared.setVisible(String(flag.dropFirst(8)), false)
                } else if flag.hasPrefix("step"), let n = Int(flag.dropFirst(4)) { model.step(n) } else if !HiddenSnapshot.apply(flag, model) && !SnapshotOptions.apply(flag, model) { ShotSnapshot.apply(flag, model) }
            }
        }
    }

    @MainActor
    private static func menuItem(_ title: String, in menu: NSMenu?) -> (NSMenu, Int)? {
        guard let menu else { return nil }
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        for (index, item) in menu.items.enumerated() {
            if item.title == title { return (menu, index) }
            if let found = menuItem(title, in: item.submenu) { return found }
        }
        return nil
    }

    @MainActor
    private static func dumpMenus(_ path: String) {
        var lines: [String] = []
        for top in NSApp.mainMenu?.items ?? [] {
            guard let menu = top.submenu else { continue }
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            lines.append(top.title)
            for item in menu.items where !item.isSeparatorItem {
                var keys = ""
                if !item.keyEquivalent.isEmpty {
                    let mods = item.keyEquivalentModifierMask
                    keys = (mods.contains(.control) ? "⌃" : "") + (mods.contains(.option) ? "⌥" : "") + (mods.contains(.shift) ? "⇧" : "") + (mods.contains(.command) ? "⌘" : "") + item.keyEquivalent.uppercased()
                }
                lines.append("    \(item.title)\(keys.isEmpty ? "" : "  " + keys)\(item.isEnabled ? "" : "  [off]")\(item.state == .on ? "  [✓]" : "")")
            }
        }
        try? lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    @MainActor
    private static func later(_ seconds: Double, _ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { action() }
    }

    @MainActor
    private static func describe(_ model: Model, _ step: String, _ path: String) {
        var lines = ["step: \(step)", "title: \(model.title)", "viewing: \(model.viewing)",
                     "selected: \(model.selected.map { "\($0.title) [\($0.key)]" } ?? "-")", "selection: \(model.selection.count)",
                     "version: \(model.viewing ? (model.page?.current?.name ?? "-") : "-")",
                     "shown: \(model.shown), filters: \(model.activeFilters)"]
        lines.append("back: " + model.backStack.map { describe(model, $0) }.joined(separator: " ← "))
        lines.append("forward: " + model.forwardStack.map { describe(model, $0) }.joined(separator: " → "))
        lines.append(SnapshotOptions.toolbar(model.window))
        lines.append("windows: " + NSApp.windows.map { "\(type(of: $0)) \"\($0.title)\" \(Int($0.frame.width))x\(Int($0.frame.height)) visible=\($0.isVisible)" }.joined(separator: "; "))
        try? lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    @MainActor
    private static func describe(_ model: Model, _ location: Location) -> String {
        var text = model.title(of: location.scope)
        if let photo = location.photo { text += " / item \(photo)" }
        if let anchor = location.anchor, location.photo == nil { text += " (selected \(anchor))" }
        return "[" + text + "]"
    }

    @MainActor
    private static func capture(_ path: String, _ target: NSWindow?) {
        if SnapshotOptions.visible {
            SnapshotOptions.announce(path, target ?? NSApp.windows.first { $0.contentView != nil && !($0 is StageWindow) && $0.frame.width > 400 })
            return
        }
        guard let window = target ?? NSApp.windows.first(where: { $0.contentView != nil && !($0 is StageWindow) && $0.frame.width > 400 }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        if let sheet = window.attachedSheet, sheet !== window {
            capture(path.replacingOccurrences(of: ".png", with: "-sheet.png"), sheet)
        }
    }
}
