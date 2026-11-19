import MapKit
import SwiftUI

struct Badge: View {
    let text: String
    let color: Color
    @Environment(\.tileActive) private var active

    var body: some View {
        Text(text).font(.system(size: 9, weight: .semibold, design: .rounded)).padding(.horizontal, 5).padding(.vertical, 1.5)
            .foregroundStyle(.white)
            .background(color.opacity(0.6), in: Capsule(style: .continuous))
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .environment(\.colorScheme, .dark)
            .opacity(active ? 1 : 0.8)
            .animation(Theme.spring, value: active)
    }
}

struct Thumb: View {
    let item: Item?
    let side: CGFloat
    let epoch: Int
    let icon: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Color.accentColor.opacity(0.22), Color.purple.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: icon).font(.system(size: side / 5)).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: "\(item?.key ?? "")-\(epoch)") {
            image = nil
            guard let item else { return }
            Thumbs.shared.image(for: item, side: side) { image = $0 }
        }
    }
}

struct Tile: View {
    let item: Item
    let selected: Bool
    let flagged: Bool
    let epoch: Int
    var mark: Mark?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Thumb(item: item, side: 150, epoch: epoch, icon: item.isVideo ? "film" : "icloud")
                .frame(width: 150, height: 150).clipped()
                .opacity(mark?.pick == -1 ? 0.3 : 1)
            TileLabel(mark: mark)
            if let mark, mark.rating > 0 || mark.pick != 0 {
                HStack(spacing: 3) {
                    if mark.pick == 1 { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green) }
                    if mark.pick == -1 { Image(systemName: "xmark.seal.fill").foregroundStyle(.red) }
                    if mark.rating > 0 { Text(String(repeating: "★", count: mark.rating)).font(.system(size: 11, weight: .bold)).foregroundStyle(.yellow) }
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .hudCapsule()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(4)
            }
            HStack(spacing: 3) {
                if item.inPhotos { Badge(text: String(localized: "Photos"), color: .blue) }
                if item.inArchive { Badge(text: String(localized: "Archive"), color: .gray) }
                if item.hasRaw { Badge(text: "RAW", color: .orange) }
                if item.nEdit > 0 { Badge(text: "✎\(item.nEdit)", color: .purple) }
            }
            .padding(4)
            if flagged {
                Image(systemName: "iphone").padding(5).background(.green, in: Circle()).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(4)
            }
        }
        .frame(width: 150, height: 150)
        .tileStyle(selected: selected)
        .help(item.title)
    }
}

struct CardView: View {
    let card: Card
    let epoch: Int
    var width: CGFloat = 210
    var height: CGFloat = 150

    var body: some View {
        PaletteReader(item: card.cover, side: max(width, height)) { palette in
            PhotoCard(title: card.title, subtitle: card.subtitle, width: width, height: height, palette: palette) {
                Thumb(item: card.cover, side: max(width, height), epoch: epoch, icon: card.icon)
            }
        }
    }
}

struct Home: View {
    @ObservedObject var model: Model
    @ObservedObject var layout = CollectionLayout.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if model.tagsPending {
                    Label("The catalog is updating… People, pets, trips and places will appear when it is rebuilt.", systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(layout.visibleRows) { section($0) }
                HiddenHomeRow(model: model)
                CustomizeRowsButton().frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 28).padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $layout.customizing) { CollectionRowsSheet() }
    }

    @ViewBuilder private func section(_ spec: CollectionRow) -> some View {
        switch spec.key {
        case "trips", "places": if !model.tagsPending { row(spec.key, spec.width, spec.height) }
        case "days", "marks", "cameras", "origins", "usertags": if !model.cards(spec.key).isEmpty { row(spec.key, spec.width, spec.height) }
        case "people", "pets": if !model.tagsPending { people(spec) }
        default: row(spec.key, spec.width, spec.height)
        }
    }

    @ViewBuilder private func people(_ spec: CollectionRow) -> some View {
        if model.personCards.isEmpty && model.petCards.isEmpty {
            if spec.key == "people" || !layout.isVisible("people") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("People and Pets").font(.title2).bold()
                    Label(model.peopleStatus == "no_access"
                          ? "No access to the Photos database, so people and pets were not read. Give PhotoHub Full Disk Access (System Settings → Privacy & Security) and refresh the catalog (Cmd+R). If the catalog is rebuilt from the Terminal, the Terminal needs the access."
                          : "No people or pets yet. Name people in the Photos app and refresh the catalog (Cmd+R).",
                          systemImage: model.peopleStatus == "no_access" ? "lock" : "person.2.crop.square.stack")
                        .foregroundStyle(.secondary)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard()
                }
            }
        } else if !model.cards(spec.key).isEmpty {
            row(spec.key, spec.width, spec.height)
        }
    }

    private func row(_ key: String, _ width: CGFloat, _ height: CGFloat) -> some View {
        let cards = model.cards(key)
        let cardWidth = (width * 1.15).rounded(), cardHeight = (height * 1.1 + 40).rounded()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Model.listTitles[key] ?? key).font(.system(size: 22, weight: .bold))
                Text("\(cards.count)").font(Theme.count(15)).foregroundStyle(.secondary)
                Spacer()
                Button { model.go(.list(key)) } label: {
                    HStack(spacing: 3) {
                        Text("All")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                }
                .buttonStyle(PillButtonStyle())
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 18) {
                    ForEach(cards.prefix(30)) { card in
                        CardView(card: card, epoch: model.epoch, width: cardWidth, height: cardHeight).onTapGesture { model.go(card.scope) }
                            .hiddenFolderMenu(model, card.scope)
                    }
                }
                .padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 36)
            }
            .padding(.horizontal, -28).padding(.top, -8).padding(.bottom, -28)
            .unclippedScroll()
        }
    }
}

struct CategoryPage: View {
    @ObservedObject var model: Model
    let key: String

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 230), spacing: 22)], alignment: .leading, spacing: 22) {
                ForEach(model.sortedCards(key)) { card in
                    CardView(card: card, epoch: model.epoch, width: 230, height: 200).onTapGesture { model.go(card.scope) }
                        .hiddenFolderMenu(model, card.scope)
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct Sidebar: View {
    @ObservedObject var model: Model

    private var selection: Binding<Scope?> {
        Binding(
            get: {
                switch model.scope {
                case .home, .list: return .home
                case .all: return .all
                case .flagged: return .flagged
                case .folders, .root, .loose: return .folders("")
                case .map: return .map
                case .statistics: return .statistics
                case .calendar: return .calendar("overview")
                default: return nil
                }
            },
            set: { if let scope = $0 { model.go(scope) } })
    }

    var body: some View {
        List(selection: selection) {
            Section("Library") {
                Label("Collections", systemImage: "square.grid.2x2").tag(Scope.home)
                Label("All Items", systemImage: "photo.on.rectangle").tag(Scope.all)
                Label("Map", systemImage: "map").tag(Scope.map)
                Label(String(localized: "Calendar", table: "Calendar"), systemImage: "calendar").tag(Scope.calendar("overview"))
                Label("Folders", systemImage: "folder").tag(Scope.folders(""))
                Label("To Phone (\(model.flagged.count))", systemImage: "iphone").tag(Scope.flagged)
                Label("Statistics", systemImage: "chart.bar.xaxis").tag(Scope.statistics)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter(model: model) }
        .glassSidebarColumn()
        .replacingSidebarToggle()
    }
}

struct Breadcrumbs: View {
    @ObservedObject var model: Model
    let crumbs: [(name: String, scope: Scope)]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary) }
                    if index == crumbs.count - 1 {
                        Text(crumb.name).fontWeight(.semibold)
                    } else {
                        Button(crumb.name) { model.go(crumb.scope) }.buttonStyle(.link)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
        }
        .fixedSize(horizontal: false, vertical: true)
        .glassBar()
    }
}

struct FolderPage: View {
    @ObservedObject var model: Model
    let path: String

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 210), spacing: 22)], alignment: .leading, spacing: 22) {
                if model.ownCount(path) > 0 {
                    FolderCard(title: String(localized: "Files in This Folder"), count: model.ownCount(path), cover: nil, epoch: model.epoch, icon: "photo.stack")
                        .onTapGesture { model.go(.loose(path)) }
                }
                ForEach(model.sortedFolders(in: path)) { node in
                    FolderCard(title: node.name, count: node.count, cover: node.cover, epoch: model.epoch, icon: node.children == nil ? "photo.on.rectangle.angled" : "folder.fill")
                        .onTapGesture { model.go(model.folderScope(node)) }
                        .overlay(HiddenCardBadge(path: node.id))
                        .hiddenFolderMenu(model, .root(node.id))
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct FolderCard: View {
    let title: String
    let count: Int
    let cover: Item?
    let epoch: Int
    let icon: String

    var body: some View {
        let shown = cover?.thumbAsset.isEmpty == false ? cover : nil
        PaletteReader(item: shown, side: 210) { palette in
            PhotoCard(title: title, subtitle: "\(count)", width: 210, height: 180, symbol: shown == nil ? nil : "folder.fill", palette: palette) {
                Thumb(item: shown, side: 210, epoch: epoch, icon: icon)
            }
        }
    }
}

struct Grid: View {
    @ObservedObject var model: Model

    private var pairs: Bool { model.scope == .kind(.photosExports) }
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: pairs ? 308 : 150, maximum: pairs ? 308 : 150), spacing: 8)] }

    @ViewBuilder private func tile(_ item: Item) -> some View {
        if pairs {
            ExportTile(model: model, item: item, selected: model.selection.contains(item.id))
        } else {
            Tile(item: item, selected: model.selection.contains(item.id), flagged: model.flagged.contains(item.key), epoch: model.epoch, mark: model.marks[item.key])
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.sections) { section in
                        Section {
                            ForEach(section.items, id: \.key) { item in
                                tile(item)
                                    .id(item.key)
                                    .overlay(HiddenTileBadge(item: item))
                                    .modifier(TileContext(model: model, item: item))
                                    .onTapGesture(count: 2) { model.click(item, command: false, shift: false); model.openPage() }
                                    .onTapGesture {
                                        let flags = NSEvent.modifierFlags
                                        model.click(item, command: flags.contains(.command), shift: flags.contains(.shift))
                                    }
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Text(section.title).font(.system(size: 13, weight: .semibold))
                                Text("\(section.items.count)").font(Theme.count(12)).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5).padding(.horizontal, 12)
                            .glassCapsule()
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 10)
            }
            .background(alignment: .top) {
                if let cover = model.bannerCover { CollectionBanner(item: cover, epoch: model.epoch) }
            }
            .focusable()
            .onMoveCommand { direction in
                switch direction {
                case .left: model.step(-1)
                case .right: model.step(1)
                case .up: model.step(-5)
                case .down: model.step(5)
                default: break
                }
                if let key = model.selected?.key { proxy.scrollTo(key) }
            }
            .onAppear { reveal(proxy) }
            .onChange(of: model.scrollRequest) { _ in reveal(proxy) }
        }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard let key = model.selected?.key else { return }
        DispatchQueue.main.async { proxy.scrollTo(key, anchor: .center) }
    }
}

struct WindowReader: NSViewRepresentable {
    let found: @MainActor (NSWindow?) -> Void

    final class Probe: NSView {
        var found: (@MainActor (NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            found?(window)
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.found = found
        return probe
    }

    func updateNSView(_ view: Probe, context: Context) {}
}

struct Detail: View {
    @ObservedObject var model: Model
    let item: Item
    @State private var members: [Member] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Thumb(item: item, side: 400, epoch: model.epoch, icon: "icloud")
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 340)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
                    .onTapGesture(count: 2) { model.openPage() }

                if model.selection.count > 1 {
                    Label("Items selected: \(model.selection.count)", systemImage: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                }
                let candidates = model.archiveCandidates
                if !candidates.isEmpty {
                    Button { model.askAddToArchive(candidates) } label: {
                        Label(candidates.count > 1 ? "Add to Archive (\(candidates.count))…" : "Add to Archive…", systemImage: "externaldrive.badge.plus")
                    }
                    .help("Copy the original from Photos to an archive folder")
                    .disabled(!model.busyTool.isEmpty)
                }
                GlassGap()
                Text(item.title).font(.title3).bold().textSelection(.enabled).glassSection("head")
                if !model.userTags(of: item).isEmpty {
                    HStack(spacing: 4) {
                        ForEach(model.userTags(of: item), id: \.self) { tag in
                            Button { model.go(.tag("user", tag)) } label: { Label(tag, systemImage: "tag").font(.caption) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
                if !model.people(of: item).isEmpty {
                    Flow(spacing: 4) {
                        ForEach(Array(model.people(of: item).enumerated()), id: \.offset) { _, chip in
                            Button { model.go(chip.scope) } label: { Label(chip.title, systemImage: chip.icon).font(.caption).lineLimit(1) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
                TagPickerButton(model: model)
                if !model.provenance(of: item).isEmpty {
                    Flow(spacing: 4) {
                        ForEach(Array(model.provenance(of: item).enumerated()), id: \.offset) { _, chip in
                            Button { model.go(chip.scope) } label: { Label(chip.title, systemImage: chip.icon).font(.caption).lineLimit(1) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
                if !item.lens.isEmpty {
                    Label(item.lens, systemImage: "circle.circle").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text(item.dateLabel).foregroundStyle(.secondary).glassSection("head")
                if !item.root.isEmpty {
                    Button { model.go(.root(item.root)) } label: { Label(item.root, systemImage: "folder") }.buttonStyle(.link).glassSection("head")
                }
                GlassGap()
                Toggle(isOn: Binding(get: { model.flagged.contains(item.key) }, set: { _ in model.toggleFlag(item) })) {
                    Label("To Phone", systemImage: "iphone")
                }
                .toggleStyle(.switch)
                .glassSection("controls")
                HiddenToggle(model: model, item: item)
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { n in
                        Button { model.rate((model.marks[item.key]?.rating ?? 0) == n ? 0 : n) } label: {
                            Image(systemName: n <= (model.marks[item.key]?.rating ?? 0) ? "star.fill" : "star").foregroundStyle(.yellow)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Button { model.pick(1) } label: {
                        Label("Pick", systemImage: model.marks[item.key]?.pick == 1 ? "checkmark.seal.fill" : "checkmark.seal")
                    }
                    Button { model.pick(-1) } label: {
                        Label("Reject", systemImage: model.marks[item.key]?.pick == -1 ? "xmark.seal.fill" : "xmark.seal")
                    }
                }
                .controlSize(.small)
                LabelPicker(model: model, item: item)
                Text("Keys: 1–5 rating, 0 reset · P pick · X reject · U unmark · T to phone · Space — large view")
                    .font(.caption2).foregroundStyle(.tertiary).glassSection("controls")
                GlassGap()
                Text("Files and versions: \(members.count)").font(.headline).glassSection("files")
                ForEach(members) { member in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Badge(text: roleLabel(member), color: roleColor(member))
                            Text(member.name).font(.callout).bold().lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: member.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                        }
                        if member.source == "archive" {
                            Text(member.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                            HStack {
                                Button("Show in Finder") { model.revealInFinder(member) }
                                Button("Open") { model.open(member) }
                                Menu("Open With…") {
                                    ForEach(Model.editors, id: \.name) { editor in
                                        Button(editor.name) { model.open(member, with: editor.url) }
                                    }
                                }
                                .fixedSize()
                            }
                            .controlSize(.small)
                        } else {
                            Text(String(localized: "Photos library") + (member.width > 0 ? " · \(member.width)×\(member.height)" : "")).font(.caption).foregroundStyle(.secondary)
                            Button("Show in Photos") { model.showInPhotos(member) }.controlSize(.small)
                        }
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .glassSection("files")
                }
            }
            .glassSections()
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .task(id: "\(item.key)-\(model.epoch)") { members = model.members(of: item) }
    }

    private func roleLabel(_ m: Member) -> String {
        if m.source == "photos" { return String(localized: "Photos") }
        switch m.role {
        case "raw": return "RAW"
        case "edit": return String(localized: "Edit")
        case "video": return String(localized: "Video")
        case "export": return String(localized: "Copy from Photos")
        default: return m.ext.uppercased()
        }
    }

    private func roleColor(_ m: Member) -> Color {
        if m.source == "photos" { return .blue }
        switch m.role {
        case "raw": return .orange
        case "edit": return .purple
        case "export": return .teal
        default: return .gray
        }
    }
}

struct AgentPanel: View {
    @ObservedObject var model: Model
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Agent", systemImage: "sparkles").font(.headline)
                Spacer()
                Button { model.newChat() } label: { Image(systemName: "square.and.pencil") }.help("New Conversation")
                Button { model.agentOpen = false } label: { Image(systemName: "xmark") }.help("Close")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16).padding(.vertical, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.chat.isEmpty {
                            Text("Select items (Cmd-click or Shift-click) and write what to do: add or remove a tag, flag them for the phone, move them to another folder. The agent first shows a file move as a plan and runs it only after you say yes. It cannot delete.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(model.chat) { message in bubble(message).id(message.id) }
                        if model.agentBusy {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("The agent is working…").foregroundStyle(.secondary)
                                Spacer()
                                Button("Stop") { model.stopAgent() }.controlSize(.small)
                            }
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.chat.count) { _ in
                    if let last = model.chat.last { withAnimation(Theme.spring) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            Text(model.selection.isEmpty ? "Nothing selected · \(model.title)" : "Selected: \(model.selection.count) · \(model.title)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.top, 8)
            HStack(alignment: .bottom) {
                TextField("What should I do?", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .disabled(model.agentBusy || draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
            .glassBar(radius: 18)
            .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 4)
        }
        .frame(width: 380)
    }

    private func send() {
        let text = draft
        draft = ""
        model.sendToAgent(text)
    }

    private func bubble(_ message: ChatMessage) -> some View {
        let mine = message.role == "user"
        let text = (try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.text)
        return Group {
            if mine {
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 0.5))
            } else {
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(GlassPlate(radius: 14))
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }
}

struct FilterBar: View {
    @ObservedObject var model: Model

    var body: some View {
        HStack(spacing: 0) {
            WrapLayout(spacing: 6, lineSpacing: 6) {
                Menu {
                    Picker("Sorting", selection: $model.sort) {
                        ForEach(SortKey.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                } label: { Label(model.sort.title, systemImage: "arrow.up.arrow.down") }
                ChipDivider()
                if model.foreignScope {
                    Toggle(isOn: $model.hideForeign) { Label("Only My Items", systemImage: "person.crop.square") }
                        .toggleStyle(.button)
                        .help("Hide screenshots, images from messengers, saved and generated images")
                    if model.hideForeign && model.hidden > 0 {
                        Text("hidden \(model.hidden)").font(.caption).foregroundStyle(.secondary)
                    }
                    ChipDivider()
                }
                if !model.personNames.isEmpty || !model.petNames.isEmpty {
                    Menu {
                        Picker("People", selection: $model.peopleFilter) {
                            Text("Everyone").tag(PeopleFilter.any)
                            Text(model.me.isEmpty ? "With Me" : "With Me (\(model.me))").tag(PeopleFilter.withMe)
                            Text("Without Me").tag(PeopleFilter.withoutMe)
                            Divider()
                            ForEach(model.personNames, id: \.self) { Text($0).tag(PeopleFilter.one("person", $0)) }
                            if !model.petNames.isEmpty {
                                Divider()
                                ForEach(model.petNames, id: \.self) { Text($0).tag(PeopleFilter.one("pet", $0)) }
                            }
                        }
                        .pickerStyle(.inline).labelsHidden()
                    } label: { chip("People", model.peopleFilter.label) }
                }
                Menu {
                    Picker("Where", selection: $model.place) { ForEach(Place.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.inline).labelsHidden()
                } label: { chip("Where", model.place == .any ? nil : model.place.title) }
                Menu {
                    Picker("Media", selection: $model.media) { ForEach(Media.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.inline).labelsHidden()
                } label: { chip("Media", model.media == .any ? nil : model.media.title) }
                Menu {
                    ForEach(model.allFormats, id: \.self) { format in
                        Toggle(format, isOn: Binding(
                            get: { model.formats.contains(format) },
                            set: { on in if on { model.formats.insert(format) } else { model.formats.remove(format) } }))
                    }
                } label: { chip("Format", model.formats.isEmpty ? nil : model.formats.sorted().joined(separator: ", ")) }
                Menu {
                    Picker("Year", selection: $model.year) {
                        Text("Any Year").tag("")
                        ForEach(model.allYears, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                } label: { chip("Year", model.year.isEmpty ? nil : model.year) }
                Menu {
                    Picker("Type", selection: $model.typeFilter) {
                        Text("Any Type").tag("")
                        ForEach(model.typeNames, id: \.self) { Text(Model.typeLabel($0)).tag($0) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                } label: { chip("Type", model.typeFilter.isEmpty ? nil : Model.typeLabel(model.typeFilter)) }
                Menu {
                    Picker("Origin", selection: $model.originFilter) {
                        Text("Any Origin").tag("")
                        ForEach(Model.origins, id: \.code) { Text($0.label).tag($0.code) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                } label: { chip("Origin", Model.originLabel(model.originFilter)) }
                if !model.allCameras.isEmpty {
                    Menu {
                        Picker("Camera", selection: $model.cameraFilter) {
                            Text("Any Camera").tag("")
                            ForEach(model.allCameras, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.inline).labelsHidden()
                    } label: { chip("Camera", model.cameraFilter.isEmpty ? nil : model.cameraFilter) }
                }
                if !model.lensNames.isEmpty {
                    Menu {
                        Picker("Lens", selection: $model.lensFilter) {
                            Text("Any Lens").tag("")
                            ForEach(model.lensNames, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.inline).labelsHidden()
                    } label: { chip("Lens", model.lensFilter.isEmpty ? nil : model.lensFilter) }
                }
                ShotFilterMenus(model: model)
                Menu {
                    Picker("Rating", selection: $model.minRating) {
                        Text("Any Rating").tag(0)
                        ForEach(1...5, id: \.self) { n in Text(n < 5 ? String(localized: "\(String(repeating: "★", count: n)) and up") : String(repeating: "★", count: n)).tag(n) }
                        Text("No Rating").tag(-1)
                    }
                    .pickerStyle(.inline).labelsHidden()
                } label: { chip("Rating", model.minRating == 0 ? nil : (model.minRating < 0 ? String(localized: "none") : "★\(model.minRating)+")) }
                Menu {
                    Picker("Pick", selection: $model.pickFilter) { ForEach(PickFilter.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.inline).labelsHidden()
                } label: { chip("Pick", model.pickFilter == .any ? nil : model.pickFilter.title) }
                Menu {
                    Picker("Geotagged", selection: $model.geo) { ForEach(Tri.allCases) { Text($0.title).tag($0) } }
                    Picker("Exact Capture Date", selection: $model.dated) { ForEach(Tri.allCases) { Text($0.title).tag($0) } }
                    Picker("Flagged for Phone", selection: $model.phone) { ForEach(Tri.allCases) { Text($0.title).tag($0) } }
                } label: {
                    chip("More", [model.geo, model.dated, model.phone].contains { $0 != .any } ? String(localized: "on") : nil)
                }
                if model.activeFilters > 0 {
                    Button { model.resetFilters() } label: { Label("Reset (\(model.activeFilters))", systemImage: "xmark.circle") }
                }
            }
            .menuStyle(GlassChipMenuStyle())
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .glassBar()
    }

    private func chip(_ key: String.LocalizationValue, _ value: String?) -> some View {
        let name = String(localized: key)
        return Text(value.map { name + ": " + $0 } ?? name)
            .fontWeight(value == nil ? .regular : .semibold)
            .foregroundStyle(value == nil ? Color.primary : Color.accentColor)
    }
}

struct CardSortBar: View {
    @ObservedObject var model: Model

    var body: some View {
        HStack {
            Picker("Sorting", selection: $model.cardSort) {
                ForEach(CardSort.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 5)
            .glassCapsule()
            Spacer()
        }
    }
}

final class PointAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let itemIDs: [Int64]

    init(_ point: MapPoint) {
        coordinate = point.coordinate
        itemIDs = point.itemIDs
    }
}

struct MapPage: NSViewRepresentable {
    @ObservedObject var model: Model

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeNSView(context: Context) -> MKMapView {
        let view = MKMapView()
        view.delegate = context.coordinator
        view.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "point")
        view.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
        return view
    }

    func updateNSView(_ view: MKMapView, context: Context) {
        let stamp = "\(model.epoch)-\(model.points.count)"
        guard context.coordinator.loaded != stamp else { return }
        context.coordinator.loaded = stamp
        view.removeAnnotations(view.annotations)
        view.addAnnotations(model.points.map(PointAnnotation.init))
        if let region = model.mapRegion {
            view.setRegion(region, animated: false)
        } else {
            view.showAnnotations(view.annotations, animated: false)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        let model: Model
        var loaded = ""

        init(_ model: Model) { self.model = model }

        private func label(_ n: Int) -> String { n >= 1000 ? "\(n / 1000)k" : "\(n)" }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let cluster = annotation as? MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier, for: annotation) as? MKMarkerAnnotationView
                let total = cluster.memberAnnotations.reduce(0) { $0 + (($1 as? PointAnnotation)?.itemIDs.count ?? 0) }
                view?.glyphText = label(total)
                view?.markerTintColor = .systemBlue
                view?.displayPriority = .required
                return view
            }
            guard let point = annotation as? PointAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "point", for: annotation) as? MKMarkerAnnotationView
            view?.clusteringIdentifier = "photos"
            view?.glyphText = label(point.itemIDs.count)
            view?.markerTintColor = .systemTeal
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            var ids: [Int64] = []
            if let cluster = view.annotation as? MKClusterAnnotation {
                ids = cluster.memberAnnotations.flatMap { ($0 as? PointAnnotation)?.itemIDs ?? [] }
            } else if let point = view.annotation as? PointAnnotation {
                ids = point.itemIDs
            }
            mapView.deselectAnnotation(view.annotation, animated: false)
            guard !ids.isEmpty else { return }
            let region = mapView.region
            let model = self.model
            DispatchQueue.main.async {
                model.mapRegion = region
                model.showItems(Set(ids), title: String(localized: "Map · \(ids.count)"))
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: Model

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model).navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            HStack(spacing: 0) {
                Group {
                    if case .home = model.scope {
                        Home(model: model)
                    } else if case .list(let key) = model.scope {
                        CategoryPage(model: model, key: key)
                    } else if case .folders(let path) = model.scope {
                        HiddenFrame(model: model) { FolderPage(model: model, path: path) }
                    } else if case .map = model.scope {
                        MapPage(model: model)
                    } else if case .statistics = model.scope {
                        StatisticsPage(model: model)
                    } else if case .calendar = model.scope, !model.viewing {
                        CalendarPage(model: model)
                    } else if model.viewing, let item = model.selected {
                        PhotoPage(model: model, item: item)
                    } else {
                        HiddenFrame(model: model) { Grid(model: model) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .top, spacing: 0) { FloatingBars(model: model) }
                if model.isBrowsing, !model.viewing, !model.inspectorHidden {
                    if let item = model.selected {
                        Detail(model: model, item: item).frame(width: 340).glassSidebar()
                    } else {
                        NoSelectionPanel().frame(width: 340).glassSidebar()
                    }
                }
                if model.agentOpen {
                    AgentPanel(model: model).glassSidebar()
                }
            }
            .glassDetail()
            .glassToolbar()
            .navigationTitle(model.title)
            .navigationSubtitle(model.subtitle)
            .confirmationDialog("Send the flagged items to Photos?", isPresented: $model.confirmPhone) {
                Button("Send \(model.flagged.count)") { model.sendToPhone() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Edits and JPEGs of the flagged items will download from iCloud, go to the Photos library into an album named after the folder and appear on the phone. RAW files are not sent.")
            }
            .confirmationDialog(model.exportConfirm == .removeOriginals ? "Delete the originals from Photos and keep the copies in the archive?" : "Delete the copies from the archive and keep the originals in Photos?",
                                isPresented: Binding(get: { model.exportConfirm != nil }, set: { if !$0 { model.exportConfirm = nil } }), presenting: model.exportConfirm) { action in
                let pairs = model.exportPairs(model.exportTargets)
                Button(action == .removeOriginals ? "Delete from Photos" : "Move Copies to Trash", role: .destructive) { model.perform(action, pairs) }
                Button("Cancel", role: .cancel) {}
            } message: { action in
                Text(model.exportPlan(action, model.exportPairs(model.exportTargets)))
            }
            .alert(model.notice?.title ?? "", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } }), presenting: model.notice) { _ in
                Button("OK", role: .cancel) {}
            } message: { notice in
                Text(notice.text)
            }
            .sheet(isPresented: Binding(get: { !model.archiveTargets.isEmpty }, set: { if !$0 { model.archiveTargets = [] } })) {
                AddToArchiveSheet(model: model, items: model.archiveTargets)
            }
            .modifier(ShotActionsHost(model: model))
            .modifier(HiddenHost(model: model))
            .toolbar {
                MainToolbar(model: model)
            }
            .searchable(text: $model.search, prompt: "Search: name, folder, 2021-07, RAF…")
        }
        .background(WindowReader {
            model.window = $0
            Chrome.style($0)
        })
        .onAppear {
            AppAppearance.apply()
            model.start()
            Snapshot.run(model)
        }
    }
}

@main
struct PhotoHubApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        Window("PhotoHub", id: "main") {
            ContentView(model: model).frame(minWidth: 1150, minHeight: 720)
        }
        .commands {
            AppCommands(model: model)
            ShotCommands(model: model)
            HiddenCommands(model: model)
        }
        Settings {
            SettingsView(model: model)
        }
    }
}
