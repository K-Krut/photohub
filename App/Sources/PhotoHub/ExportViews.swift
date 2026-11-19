import SwiftUI

struct ExportTile: View {
    @ObservedObject var model: Model
    let item: Item
    let selected: Bool
    @State private var pair: ExportPair?

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            side(pair?.original, String(localized: "In Photos"), .blue)
            side(pair?.copy, String(localized: "Copy in archive"), .gray)
        }
        .padding(3)
        .selectionRing(selected)
        .help(item.title + (pair.map { " · " + ($0.copy.path as NSString).deletingLastPathComponent } ?? ""))
        .task(id: "\(item.key)-\(model.epoch)") { pair = model.exportPairs([item]).first }
    }

    @ViewBuilder private func side(_ member: Member?, _ title: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .bottomLeading) {
                if let member {
                    MemberThumb(member: member, side: 148, epoch: model.epoch)
                } else {
                    Color.gray.opacity(0.2).frame(width: 148, height: 148)
                }
                Badge(text: title, color: color).padding(4)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
            Text(member.map(caption) ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(width: 148, alignment: .leading)
        }
    }

    private func caption(_ member: Member) -> String {
        [member.width > 0 ? "\(member.width)×\(member.height)" : "", ByteCountFormatter.string(fromByteCount: member.size, countStyle: .file)]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct ExportBar: View {
    @ObservedObject var model: Model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled").foregroundStyle(.secondary)
            Text(model.selection.isEmpty ? "Nothing selected — actions apply to all (\(model.shown))" : "Selected: \(model.selection.count)")
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) { model.askExport(.removeCopies) } label: { Label("Delete Copies from Archive…", systemImage: "trash") }
                .help("Copies from the archive go to the Trash, originals stay in Photos")
            Button(role: .destructive) { model.askExport(.removeOriginals) } label: { Label("Delete from Photos, Keep in Archive…", systemImage: "iphone.slash") }
                .help("Originals from Photos go to Recently Deleted, copies stay in the archive")
        }
        .disabled(!model.busyTool.isEmpty || model.shown == 0)
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .glassBar()
    }
}
