import SwiftUI

struct CollectionRow: Identifiable, Hashable {
    let key: String
    let icon: String
    let width: CGFloat
    let height: CGFloat
    var id: String { key }
    @MainActor var title: String { Model.listTitles[key] ?? key }
}

@MainActor
final class CollectionLayout: ObservableObject {
    static let shared = CollectionLayout()

    static let defaults: [CollectionRow] = [
        CollectionRow(key: "days", icon: "clock.arrow.circlepath", width: 180, height: 150),
        CollectionRow(key: "trips", icon: "airplane", width: 220, height: 160),
        CollectionRow(key: "marks", icon: "star", width: 160, height: 100),
        CollectionRow(key: "people", icon: "person.2", width: 140, height: 140),
        CollectionRow(key: "pets", icon: "pawprint", width: 140, height: 140),
        CollectionRow(key: "events", icon: "folder", width: 220, height: 160),
        CollectionRow(key: "places", icon: "mappin.and.ellipse", width: 160, height: 160),
        CollectionRow(key: "cameras", icon: "camera", width: 160, height: 160),
        CollectionRow(key: "years", icon: "calendar", width: 160, height: 160),
        CollectionRow(key: "albums", icon: "rectangle.stack", width: 160, height: 160),
        CollectionRow(key: "kinds", icon: "photo.on.rectangle", width: 160, height: 100),
        CollectionRow(key: "origins", icon: "square.and.arrow.down", width: 190, height: 100),
        CollectionRow(key: "work", icon: "hourglass", width: 190, height: 100),
        CollectionRow(key: "storage", icon: "externaldrive", width: 160, height: 100),
        CollectionRow(key: "usertags", icon: "tag", width: 160, height: 100),
    ]

    private static let orderKey = "collectionRowOrder"
    private static let hiddenKey = "collectionRowHidden"

    @Published private(set) var order: [String]
    @Published private(set) var hidden: Set<String>
    @Published var customizing = false

    private init() {
        order = CollectionLayout.merge(UserDefaults.standard.stringArray(forKey: CollectionLayout.orderKey) ?? [])
        hidden = Set(UserDefaults.standard.stringArray(forKey: CollectionLayout.hiddenKey) ?? [])
    }

    static func merge(_ saved: [String]) -> [String] {
        let known = defaults.map(\.key)
        var out = saved.filter { known.contains($0) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        for (index, key) in known.enumerated() where !out.contains(key) {
            if let previous = known[..<index].last(where: { out.contains($0) }), let at = out.firstIndex(of: previous) {
                out.insert(key, at: at + 1)
            } else {
                out.insert(key, at: 0)
            }
        }
        return out
    }

    var rows: [CollectionRow] { order.compactMap { key in CollectionLayout.defaults.first { $0.key == key } } }
    var visibleRows: [CollectionRow] { rows.filter { !hidden.contains($0.key) } }
    var isDefault: Bool { order == CollectionLayout.defaults.map(\.key) && hidden.isEmpty }

    func isVisible(_ key: String) -> Bool { !hidden.contains(key) }

    func setVisible(_ key: String, _ visible: Bool) {
        if visible { hidden.remove(key) } else { hidden.insert(key) }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        order.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func restoreDefaults() {
        order = CollectionLayout.defaults.map(\.key)
        hidden = []
        UserDefaults.standard.removeObject(forKey: CollectionLayout.orderKey)
        UserDefaults.standard.removeObject(forKey: CollectionLayout.hiddenKey)
    }

    private func save() {
        UserDefaults.standard.set(order, forKey: CollectionLayout.orderKey)
        UserDefaults.standard.set(hidden.sorted(), forKey: CollectionLayout.hiddenKey)
    }
}

struct CollectionRowsEditor: View {
    @ObservedObject var layout = CollectionLayout.shared

    var body: some View {
        List {
            ForEach(layout.rows) { row in
                HStack(spacing: 10) {
                    Toggle(isOn: Binding(get: { layout.isVisible(row.key) }, set: { layout.setVisible(row.key, $0) })) { EmptyView() }
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    Image(systemName: row.icon).frame(width: 20).foregroundStyle(layout.isVisible(row.key) ? Color.accentColor : .secondary)
                    Text(row.title).foregroundStyle(layout.isVisible(row.key) ? .primary : .secondary)
                    Spacer()
                    Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .onMove { layout.move(from: $0, to: $1) }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }
}

struct CollectionRowsSheet: View {
    @ObservedObject var layout = CollectionLayout.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Customize and Reorder").font(.title2).bold()
            Text("Drag rows to change their order on the Collections screen. Uncheck a row to hide it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            CollectionRowsEditor()
                .frame(minHeight: 460)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack {
                Button("Restore Defaults") { layout.restoreDefaults() }.disabled(layout.isDefault)
                Spacer()
                Button("Done") { layout.customizing = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct CollectionsSettings: View {
    @ObservedObject var layout = CollectionLayout.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rows on the Collections screen. Drag to reorder, uncheck to hide.")
                .foregroundStyle(.secondary)
            CollectionRowsEditor()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            HStack {
                Spacer()
                Button("Restore Defaults") { layout.restoreDefaults() }.disabled(layout.isDefault)
            }
        }
        .padding(20)
    }
}

struct CustomizeRowsButton: View {
    @ObservedObject var layout = CollectionLayout.shared

    var body: some View {
        Button { layout.customizing = true } label: {
            Label("Customize and Reorder", systemImage: "slider.horizontal.3")
        }
        .buttonStyle(PillButtonStyle())
        .help("Choose which rows the Collections screen shows and in what order")
    }
}
