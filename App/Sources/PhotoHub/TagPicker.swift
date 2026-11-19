import AppKit
import SwiftUI

extension Model {
    func askTags(_ items: [Item]? = nil) {
        let list = items ?? targets()
        guard !list.isEmpty else { return }
        ShotActions.shared.tagging = list
    }
}

struct TagPickerButton: View {
    @ObservedObject var model: Model

    var body: some View {
        Button { model.askTags() } label: { Label("Add Tag…", systemImage: "plus").font(.caption).lineLimit(1) }
            .buttonStyle(.bordered).controlSize(.small)
            .help("Add or remove tags, people and pets (⌘T)")
    }
}

struct TagPicker: View {
    @ObservedObject var model: Model
    let items: [Item]
    @StateObject private var state: TagPickerState
    @FocusState private var focused: Bool
    @State private var monitor: Any?

    init(model: Model, items: [Item]) {
        self.model = model
        self.items = items
        _state = StateObject(wrappedValue: TagPickerState(model: model, items: items))
    }

    var body: some View {
        let sections = state.sections
        VStack(alignment: .leading, spacing: 12) {
            header
            search
            applied
            Divider().opacity(0.6)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(sections) { section in sectionView(section) }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: state.highlight) { choice in
                    guard let choice else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(choice.id) }
                }
            }
            Text("↑ ↓ ← → choose · Return add or remove · ⌘Z undo · Esc close")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 600, height: 640)
        .onAppear {
            if let query = TagPickerState.snapshotQuery {
                TagPickerState.snapshotQuery = nil
                state.query = query
            }
            focused = true
            TagPickerState.active = state
            install()
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label("Tags", systemImage: "tag").font(.title2.bold())
            Text(items.count == 1 ? items[0].title : String(localized: "Selected items: \(items.count)"))
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Undo") { state.undo() }
                .disabled(state.history.isEmpty)
                .help("Undo the last tag change (⌘Z)")
            Button("Done", action: close)
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
        }
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search or create a tag", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($focused)
            if !state.query.isEmpty {
                Button { state.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .glassBar()
    }

    @ViewBuilder private var applied: some View {
        let refs = state.applied
        if refs.isEmpty {
            Text(items.count == 1 ? "No tags on this item yet." : "No tags on the selected items yet.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            ScrollView {
                WrapLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(refs) { ref in AppliedTagChip(state: state, ref: ref) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 88)
            .fixedSize(horizontal: false, vertical: refs.count < 12)
        }
    }

    @ViewBuilder private func sectionView(_ section: TagSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(section.title).font(.headline)
                if section.id != "create" {
                    Text("\(section.total)").font(Theme.count(11)).foregroundStyle(.tertiary)
                }
                Spacer()
                if state.expanded.contains(section.id) {
                    Button("Show Less") { state.expanded.remove(section.id) }.buttonStyle(.link).font(.caption)
                } else if section.total > section.choices.count {
                    Button("Show All (\(section.total))") { state.expanded.insert(section.id) }.buttonStyle(.link).font(.caption)
                }
            }
            if section.grid {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(72), spacing: 4), count: TagPickerState.columns), alignment: .leading, spacing: 8) {
                    ForEach(section.choices) { choice in
                        AvatarCell(state: state, ref: choice.ref, highlighted: state.highlight == choice).id(choice.id)
                    }
                }
            } else if section.id == "create" {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(section.choices) { choice in
                        CreateRow(state: state, choice: choice, highlighted: state.highlight == choice).id(choice.id)
                    }
                }
            } else {
                WrapLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(section.choices) { choice in
                        SuggestionChip(state: state, ref: choice.ref, highlighted: state.highlight == choice).id(choice.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func close() {
        ShotActions.shared.tagging = []
    }

    private func install() {
        guard monitor == nil else { return }
        let state = state
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                guard let window = NSApp.keyWindow, window.sheetParent != nil, window.isVisible,
                      (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
                return state.key(event.keyCode, event.modifierFlags)
            } ? nil : event
        }
    }
}

private struct TagHighlight: ViewModifier {
    let on: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            if on {
                RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2)
                    .shadow(color: Color.accentColor.opacity(0.45), radius: 4)
            }
        }
    }
}

struct TagAvatar: View {
    @ObservedObject var model: Model
    let ref: TagRef
    let side: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color.accentColor.opacity(0.30), Color.purple.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if side >= 30 {
                    Text(initials).font(.system(size: side * 0.34, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                } else {
                    Image(systemName: ref.kind == "pet" ? "pawprint.fill" : "person.fill").font(.system(size: side * 0.5)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
        .task(id: ref) {
            TagAvatars.shared.image(ref, model: model) { image = $0 }
        }
    }

    private var initials: String {
        let parts = TagMatch.words(ref.name).prefix(2).compactMap { $0.first }
        return parts.isEmpty ? "?" : String(parts).uppercased()
    }
}

private struct AvatarCell: View {
    @ObservedObject var state: TagPickerState
    let ref: TagRef
    let highlighted: Bool
    @State private var hover = false

    var body: some View {
        let coverage = state.coverage(ref)
        VStack(spacing: 5) {
            TagAvatar(model: state.model, ref: ref, side: 54)
                .overlay {
                    if coverage != .none {
                        Circle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: coverage == .some ? [4, 3] : []))
                            .padding(-4)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if coverage != .none {
                        Image(systemName: coverage == .all ? "checkmark.circle.fill" : "minus.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .font(.system(size: 17))
                            .offset(x: 4, y: 4)
                    }
                }
                .padding(.top, 4)
            Text(ref.name)
                .font(.system(size: 11, weight: coverage == .none ? .regular : .semibold))
                .lineLimit(2).multilineTextAlignment(.center)
                .frame(width: 68)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 5)
        .frame(width: 72)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hover ? 0.06 : 0)))
        .modifier(TagHighlight(on: highlighted, radius: 10))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { state.toggle(.tag(ref)) }
        .help(TagPickerHelp.text(state, ref, coverage))
    }
}

private struct SuggestionChip: View {
    @ObservedObject var state: TagPickerState
    let ref: TagRef
    let highlighted: Bool

    var body: some View {
        let coverage = state.coverage(ref)
        HStack(spacing: 5) {
            Image(systemName: coverage == .all ? "checkmark" : coverage == .some ? "minus" : "tag")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(coverage == .none ? Color.secondary : Color.accentColor)
            Text(ref.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            Text("\(state.usage(ref))").font(Theme.count(11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(coverage == .none ? Color.primary.opacity(0.06) : Color.accentColor.opacity(0.16)))
        .overlay(Capsule(style: .continuous).strokeBorder(coverage == .none ? Color.primary.opacity(0.09) : Color.accentColor.opacity(0.45),
                                                          style: StrokeStyle(lineWidth: 1, dash: coverage == .some ? [3, 2.5] : [])))
        .modifier(TagHighlight(on: highlighted, radius: 20))
        .contentShape(Capsule())
        .onTapGesture { state.toggle(.tag(ref)) }
        .help(TagPickerHelp.text(state, ref, coverage))
    }
}

private struct AppliedTagChip: View {
    @ObservedObject var state: TagPickerState
    let ref: TagRef

    var body: some View {
        let coverage = state.coverage(ref)
        let partial = coverage == .some
        HStack(spacing: 5) {
            if ref.kind == "user" {
                Image(systemName: "tag").font(.system(size: 10, weight: .semibold)).padding(.leading, 3)
            } else {
                TagAvatar(model: state.model, ref: ref, side: 20)
            }
            Text(ref.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            if partial {
                Text(verbatim: "\(state.count(ref))/\(state.items.count)").font(Theme.count(10)).foregroundStyle(.secondary)
            }
            Button { state.set(ref, on: false) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).padding(3).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove")
        }
        .padding(.leading, 4).padding(.trailing, 6).padding(.vertical, 3)
        .background(Capsule(style: .continuous).fill(partial ? Color.primary.opacity(0.04) : Color.accentColor.opacity(0.16)))
        .overlay(Capsule(style: .continuous).strokeBorder(partial ? Color.primary.opacity(0.35) : Color.accentColor.opacity(0.4),
                                                          style: StrokeStyle(lineWidth: 1, dash: partial ? [3, 2.5] : [])))
        .contentShape(Capsule())
        .onTapGesture { if partial { state.set(ref, on: true) } }
        .help(TagPickerHelp.text(state, ref, coverage))
    }
}

private struct CreateRow: View {
    @ObservedObject var state: TagPickerState
    let choice: TagChoice
    let highlighted: Bool

    var body: some View {
        let ref = choice.ref
        HStack(spacing: 10) {
            Image(systemName: ref.kind == "person" ? "person.crop.circle.badge.plus" : ref.kind == "pet" ? "pawprint.circle" : "plus.circle")
                .font(.system(size: 15)).foregroundStyle(Color.accentColor).frame(width: 20)
            Text(title(ref)).lineLimit(1)
            Spacer()
            if highlighted { Image(systemName: "return").foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(highlighted ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.04)))
        .contentShape(Rectangle())
        .onTapGesture { state.toggle(choice) }
    }

    private func title(_ ref: TagRef) -> String {
        switch ref.kind {
        case "person": return String(localized: "New Person “\(ref.name)”")
        case "pet": return String(localized: "New Pet “\(ref.name)”")
        default: return String(localized: "Create Tag “\(ref.name)”")
        }
    }
}

enum TagPickerHelp {
    @MainActor
    static func text(_ state: TagPickerState, _ ref: TagRef, _ coverage: TagCoverage) -> String {
        switch coverage {
        case .some: return String(localized: "On \(state.count(ref)) of \(state.items.count) items. Click to add to all.")
        case .all: return String(localized: "Click to remove")
        case .none: return String(localized: "Click to add")
        }
    }
}
