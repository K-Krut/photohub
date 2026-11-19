import AppKit

enum SnapshotOptions {
    static let visible = ProcessInfo.processInfo.environment["PHOTOHUB_SNAPSHOT_VISIBLE"] != nil

    @MainActor
    static func announce(_ path: String, _ window: NSWindow?) {
        guard let window else { return }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = window.frame
        let line = "\(window.windowNumber) \(Int(frame.minX)) \(Int(top - frame.maxY)) \(Int(frame.width)) \(Int(frame.height))\n"
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            try? line.write(toFile: path.replacingOccurrences(of: ".png", with: ".window"), atomically: true, encoding: .utf8)
        }
    }

    @MainActor
    static func prepare() {
        let env = ProcessInfo.processInfo.environment
        switch env["PHOTOHUB_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        let parts = (env["PHOTOHUB_SNAPSHOT_SIZE"] ?? "").split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            for window in NSApp.windows where window.frame.width > 400 { window.setContentSize(NSSize(width: parts[0], height: parts[1])) }
        }
    }

    @MainActor
    static func toolbar(_ window: NSWindow?) -> String {
        guard let toolbar = window?.toolbar else { return "toolbar: -" }
        func name(_ item: NSToolbarItem) -> String { item.label.isEmpty ? item.itemIdentifier.rawValue : item.label }
        let visible = Set((toolbar.visibleItems ?? []).map { ObjectIdentifier($0) })
        let hidden = toolbar.items.filter { !visible.contains(ObjectIdentifier($0)) && !$0.label.isEmpty }
        return "toolbar: " + toolbar.items.map(name).joined(separator: " | ") + "\noverflow: " + (hidden.isEmpty ? "-" : hidden.map(name).joined(separator: ", "))
            + "\nwindow: \(Int(window?.frame.width ?? 0))x\(Int(window?.frame.height ?? 0)) #\(window?.windowNumber ?? 0)"
    }
}
