import AppKit
import SwiftUI

enum ColorLabel: String, CaseIterable, Identifiable {
    case red, yellow, green, blue, purple

    var id: String { rawValue }

    init?(keyCode: UInt16) {
        switch keyCode {
        case 22: self = .red
        case 26: self = .yellow
        case 28: self = .green
        case 25: self = .blue
        default: return nil
        }
    }

    var key: String? {
        switch self {
        case .red: return "6"
        case .yellow: return "7"
        case .green: return "8"
        case .blue: return "9"
        case .purple: return nil
        }
    }

    var title: String {
        switch self {
        case .red: return String(localized: "Red")
        case .yellow: return String(localized: "Yellow")
        case .green: return String(localized: "Green")
        case .blue: return String(localized: "Blue")
        case .purple: return String(localized: "Purple")
        }
    }

    var titleWithKey: String { key.map { title + " (\($0))" } ?? title }

    var nsColor: NSColor {
        switch self {
        case .red: return NSColor(srgbRed: 0.90, green: 0.26, blue: 0.27, alpha: 1)
        case .yellow: return NSColor(srgbRed: 0.98, green: 0.78, blue: 0.10, alpha: 1)
        case .green: return NSColor(srgbRed: 0.22, green: 0.68, blue: 0.36, alpha: 1)
        case .blue: return NSColor(srgbRed: 0.20, green: 0.48, blue: 0.96, alpha: 1)
        case .purple: return NSColor(srgbRed: 0.58, green: 0.34, blue: 0.84, alpha: 1)
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    var swatch: NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            self.nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    static func rank(_ code: String?) -> Int {
        ColorLabel(rawValue: code ?? "").flatMap { allCases.firstIndex(of: $0) } ?? allCases.count
    }

    static func sectionTitle(_ code: String) -> String {
        ColorLabel(rawValue: code)?.title ?? String(localized: "No Label")
    }
}

enum LabelFilter: Hashable {
    case any
    case one(ColorLabel)
    case anyLabel
    case none

    func matches(_ code: String) -> Bool {
        switch self {
        case .any: return true
        case .one(let label): return code == label.rawValue
        case .anyLabel: return ColorLabel(rawValue: code) != nil
        case .none: return ColorLabel(rawValue: code) == nil
        }
    }

    var value: String? {
        switch self {
        case .any: return nil
        case .one(let label): return label.title
        case .anyLabel: return String(localized: "any label")
        case .none: return String(localized: "none")
        }
    }
}

enum Presence: Hashable, CaseIterable {
    case all, with, without

    func matches(_ has: Bool) -> Bool {
        switch self {
        case .all: return true
        case .with: return has
        case .without: return !has
        }
    }
}

extension Model {
    func label(of item: Item) -> ColorLabel? { ColorLabel(rawValue: marks[item.key]?.color ?? "") }

    func setLabel(_ label: ColorLabel?, items: [Item]? = nil) {
        for item in items ?? targets() {
            var mark = marks[item.key] ?? Mark()
            mark.color = label?.rawValue ?? ""
            marks[item.key] = mark
            catalog?.setMark(item.key, mark)
        }
        if labelFilter != .any || sort == .label { apply() }
    }

    func toggleLabel(_ label: ColorLabel, items: [Item]? = nil) {
        let list = items ?? targets()
        let same = !list.isEmpty && list.allSatisfy { self.label(of: $0) == label }
        setLabel(same ? nil : label, items: list)
    }

    func selectLabel(_ label: ColorLabel) {
        let chosen = flat.filter { self.label(of: $0) == label }
        selection = Set(chosen.map { $0.id })
        if let current = selected, selection.contains(current.id) { return }
        selected = chosen.first
        scrollRequest += 1
    }

    var hasTargets: Bool { isBrowsing && (selected != nil || !selection.isEmpty) }
}

struct LabelBadge: View {
    let label: ColorLabel?
    var size: CGFloat = 12

    var body: some View {
        if let label {
            Circle().fill(label.color)
                .frame(width: size, height: size)
                .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.4), radius: 1.5)
                .help(label.title)
        }
    }
}

struct TileLabel: View {
    let mark: Mark?

    var body: some View {
        if let label = ColorLabel(rawValue: mark?.color ?? "") {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                label.color.frame(height: 4)
            }
            LabelBadge(label: label)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 6).padding(.bottom, 9)
        }
    }
}

struct LabelPicker: View {
    @ObservedObject var model: Model
    let item: Item

    var body: some View {
        let current = model.label(of: item)
        HStack(spacing: 6) {
            Text("Label").font(.caption).foregroundStyle(.secondary)
            ForEach(ColorLabel.allCases) { label in
                Button { model.toggleLabel(label) } label: {
                    Circle().fill(label.color)
                        .frame(width: 15, height: 15)
                        .overlay(Circle().stroke(Color.primary.opacity(current == label ? 0.9 : 0), lineWidth: 2).padding(-3))
                        .overlay(current == label ? Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white) : nil)
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(label.titleWithKey)
            }
            if current != nil {
                Button { model.setLabel(nil) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(String(localized: "Remove label"))
            }
            Spacer(minLength: 0)
        }
    }
}

struct LabelMenuItems: View {
    @ObservedObject var model: Model
    let preview: [Item]
    let items: () -> [Item]

    var body: some View {
        let common = preview.first.flatMap { first in preview.allSatisfy { model.label(of: $0) == model.label(of: first) } ? model.label(of: first) : nil }
        ForEach(ColorLabel.allCases) { label in
            Button { model.toggleLabel(label, items: items()) } label: {
                Label { Text(label.titleWithKey + (common == label ? "  ✓" : "")) } icon: { Image(nsImage: label.swatch) }
            }
        }
        Divider()
        Button("No Label") { model.setLabel(nil, items: items()) }
    }
}

struct ShotFilterMenus: View {
    @ObservedObject var model: Model

    var body: some View {
        presence("RAW", $model.rawFilter, [String(localized: "All"), String(localized: "With RAW"), String(localized: "Without RAW")])
        presence(String(localized: "Edits"), $model.editFilter, [String(localized: "All"), String(localized: "With Edits"), String(localized: "Without Edits")])
        presence(String(localized: "Stacks"), $model.stackFilter, [String(localized: "All"), String(localized: "Several Versions"), String(localized: "Single Version")])
        Menu {
            Picker(String(localized: "Label"), selection: $model.labelFilter) {
                Text("All").tag(LabelFilter.any)
                Divider()
                ForEach(ColorLabel.allCases) { label in
                    Label { Text(label.title) } icon: { Image(nsImage: label.swatch) }.tag(LabelFilter.one(label))
                }
                Divider()
                Text("With Any Label").tag(LabelFilter.anyLabel)
                Text("No Label").tag(LabelFilter.none)
            }
            .pickerStyle(.inline).labelsHidden()
            if model.hasTargets || !model.flat.isEmpty {
                Divider()
                Menu("Select All with Label") {
                    ForEach(ColorLabel.allCases) { label in
                        Button { model.selectLabel(label) } label: { Label { Text(label.title) } icon: { Image(nsImage: label.swatch) } }
                    }
                }
            }
        } label: { chip(model.labelFilter.value.map { String(localized: "Label") + ": " + $0 } ?? String(localized: "Label"), model.labelFilter != .any) }
    }

    private func presence(_ name: String, _ binding: Binding<Presence>, _ titles: [String]) -> some View {
        let index = Presence.allCases.firstIndex(of: binding.wrappedValue) ?? 0
        return Menu {
            Picker(name, selection: binding) {
                ForEach(Array(Presence.allCases.enumerated()), id: \.offset) { index, value in
                    Text(titles[index]).tag(value)
                }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: { chip(index == 0 ? name : titles[index], index != 0) }
    }

    private func chip(_ text: String, _ active: Bool) -> some View {
        Text(text)
            .fontWeight(active ? .semibold : .regular)
            .foregroundStyle(active ? Color.accentColor : Color.primary)
    }
}
