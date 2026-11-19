import AppKit
import MapKit

final class StageWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum SnapshotOptions {
    static let visible = ProcessInfo.processInfo.environment["PHOTOHUB_SNAPSHOT_VISIBLE"] != nil
    static let staged = visible && ProcessInfo.processInfo.environment["PHOTOHUB_SNAPSHOT_BACKDROP"] != nil
    @MainActor static var showing = false
    @MainActor private static var stageWindow: StageWindow?
    @MainActor private static var previous: NSRunningApplication?

    private static func size(_ name: String) -> NSSize? {
        let parts = (ProcessInfo.processInfo.environment[name] ?? "").split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : nil
    }

    @MainActor
    static func announce(_ path: String, _ window: NSWindow?) {
        guard let window else { return }
        if let stage = stage() {
            show(window, stage)
            settle(path, window, stage, tries: 12, rounds: 2)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let line = describe(window, window.frame)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            try? line.write(toFile: path.replacingOccurrences(of: ".png", with: ".window"), atomically: true, encoding: .utf8)
        }
    }

    private static func describe(_ window: NSWindow, _ frame: NSRect) -> String {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return "\(window.windowNumber) \(Int(frame.minX)) \(Int(top - frame.maxY)) \(Int(frame.width)) \(Int(frame.height))"
    }

    @MainActor
    private static func focused(_ window: NSWindow) -> Bool {
        NSApp.isActive && (NSApp.keyWindow === window || NSApp.keyWindow?.sheetParent === window)
    }

    @MainActor
    private static func settle(_ path: String, _ window: NSWindow, _ stage: StageWindow, tries: Int, rounds: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            MainActor.assumeIsolated {
                if !focused(window) && tries > 0 {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    stage.order(.below, relativeTo: window.windowNumber)
                    settle(path, window, stage, tries: tries - 1, rounds: rounds)
                    return
                }
                let line = describe(window, stage.frame) + "\n"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    try? line.write(toFile: path.replacingOccurrences(of: ".png", with: ".window"), atomically: true, encoding: .utf8)
                    MainActor.assumeIsolated { waitFor(path, window, stage, tries: 40, rounds: rounds) }
                }
            }
        }
    }

    @MainActor
    private static func waitFor(_ path: String, _ window: NSWindow, _ stage: StageWindow, tries: Int, rounds: Int) {
        guard FileManager.default.fileExists(atPath: path) else {
            if tries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { waitFor(path, window, stage, tries: tries - 1, rounds: rounds) } }
            } else {
                hide()
            }
            return
        }
        let active = focused(window)
        if !active && rounds > 0 {
            try? FileManager.default.removeItem(atPath: path.replacingOccurrences(of: ".png", with: ".window"))
            try? FileManager.default.removeItem(atPath: path)
            show(window, stage)
            settle(path, window, stage, tries: 12, rounds: rounds - 1)
            return
        }
        try? (active ? "1\n" : "0\n").write(toFile: path.replacingOccurrences(of: ".png", with: ".ok"), atomically: true, encoding: .utf8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainActor.assumeIsolated { hide() } }
    }

    @MainActor
    private static func stage() -> StageWindow? {
        guard staged else { return nil }
        if let stageWindow { return stageWindow }
        guard let file = ProcessInfo.processInfo.environment["PHOTOHUB_SNAPSHOT_BACKDROP"], let image = NSImage(contentsOfFile: file),
              let screen = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }) else { return nil }
        let canvas = size("PHOTOHUB_SNAPSHOT_CANVAS") ?? NSSize(width: 1440, height: 900)
        let area = screen.visibleFrame
        let rect = NSRect(x: area.midX - canvas.width / 2, y: area.midY - canvas.height / 2, width: canvas.width, height: canvas.height).integral
        let window = StageWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.alphaValue = 0
        let view = NSView(frame: NSRect(origin: .zero, size: rect.size))
        view.wantsLayer = true
        view.layer?.contents = image
        view.layer?.contentsGravity = .resizeAspectFill
        window.contentView = view
        window.setFrame(rect, display: true)
        window.orderBack(nil)
        stageWindow = window
        return window
    }

    @MainActor
    private static func show(_ window: NSWindow, _ stage: StageWindow) {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous = front }
        let canvas = stage.frame
        window.setFrameOrigin(NSPoint(x: (canvas.midX - window.frame.width / 2).rounded(), y: (canvas.midY - window.frame.height / 2).rounded()))
        showing = true
        for other in NSApp.windows {
            other.ignoresMouseEvents = true
            other.alphaValue = other === window || other === stage || other.sheetParent === window ? 1 : 0
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        stage.order(.below, relativeTo: window.windowNumber)
    }

    @MainActor
    private static func hide() {
        showing = false
        for window in NSApp.windows { window.alphaValue = 0 }
        previous?.activate(options: [])
        previous = nil
    }

    @MainActor
    static func apply(_ flag: String, _ model: Model) -> Bool {
        guard flag.hasPrefix("mapregion=") else { return false }
        let values = flag.dropFirst(10).split(separator: ",").compactMap { Double($0) }
        guard values.count == 4 else { return true }
        model.mapRegion = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: values[0], longitude: values[1]),
                                             span: MKCoordinateSpan(latitudeDelta: values[2], longitudeDelta: values[3]))
        return true
    }

    @MainActor
    static func prepare() {
        let env = ProcessInfo.processInfo.environment
        switch env["PHOTOHUB_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        guard let content = size("PHOTOHUB_SNAPSHOT_SIZE") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            for window in NSApp.windows where window.frame.width > 400 && !(window is StageWindow) {
                window.setContentSize(content)
                if let stage = stage() {
                    let canvas = stage.frame
                    window.setFrameOrigin(NSPoint(x: (canvas.midX - window.frame.width / 2).rounded(), y: (canvas.midY - window.frame.height / 2).rounded()))
                }
            }
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
