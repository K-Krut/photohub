import AppKit
import Photos
import SwiftUI

final class ZoomController: ObservableObject {
    @Published var percent = 0
    weak var view: ZoomScrollView?

    func zoomIn() { view?.zoom(by: 1.25) }
    func zoomOut() { view?.zoom(by: 0.8) }
    func fit() { view?.fit() }
    func actual() { view?.actualSize(at: nil) }
    func toggle() { view?.toggle(at: nil) }
    func set(_ percent: Int) { view?.setPercent(percent) }
}

final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

final class ZoomImageView: NSImageView {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let scroll = enclosingScrollView as? ZoomScrollView {
            scroll.toggle(at: convert(event.locationInWindow, from: nil))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        var origin = clip.bounds.origin
        origin.x -= event.deltaX / scroll.magnification
        origin.y += event.deltaY / scroll.magnification
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }
}

final class ZoomScrollView: NSScrollView {
    let imageView = ZoomImageView()
    var onPercent: ((Int) -> Void)?
    private var fitMode = true
    private var key = ""
    private var logical = CGSize.zero
    private var lastPercent = -1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let clip = CenteringClipView()
        clip.drawsBackground = false
        contentView = clip
        documentView = imageView
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageFrameStyle = .none
        imageView.isEditable = false
        allowsMagnification = true
        minMagnification = 0.01
        maxMagnification = 16
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        drawsBackground = false
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self, selector: #selector(endMagnify), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    func show(_ image: NSImage?, logical size: CGSize, key newKey: String) {
        if imageView.image !== image { imageView.image = image }
        if newKey != key {
            key = newKey
            fitMode = true
        }
        if size != logical, size.width > 0, size.height > 0 {
            logical = size
            imageView.frame = NSRect(origin: .zero, size: size)
            if fitMode { applyFit() }
        }
    }

    override func tile() {
        super.tile()
        if fitMode { applyFit() }
    }

    private var fitMagnification: CGFloat? {
        let box = contentView.frame.size
        guard logical.width > 0, logical.height > 0, box.width > 1, box.height > 1 else { return nil }
        return min(box.width / logical.width, box.height / logical.height)
    }

    private func applyFit() {
        guard let target = fitMagnification else { return }
        if abs(magnification - target) > 0.0001 { magnification = target }
        report()
    }

    private var center: NSPoint { NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY) }

    func fit() {
        fitMode = true
        applyFit()
    }

    func zoom(by factor: CGFloat) {
        fitMode = false
        setMagnification(min(max(magnification * factor, minMagnification), maxMagnification), centeredAt: center)
    }

    func actualSize(at point: NSPoint?) {
        fitMode = false
        setMagnification(1 / scale, centeredAt: point ?? center)
    }

    func setPercent(_ percent: Int) {
        fitMode = false
        setMagnification(CGFloat(percent) / 100 / scale, centeredAt: center)
    }

    func toggle(at point: NSPoint?) {
        if fitMode || abs(magnification - (fitMagnification ?? 0)) < 0.001 { actualSize(at: point) } else { fit() }
    }

    @objc private func boundsChanged() { report() }

    @objc private func endMagnify() {
        fitMode = false
        report()
    }

    private func report() {
        let percent = Int((magnification * scale * 100).rounded())
        guard percent != lastPercent else { return }
        lastPercent = percent
        onPercent?(percent)
    }
}

struct ZoomView: NSViewRepresentable {
    let image: NSImage?
    let logical: CGSize
    let key: String
    let controller: ZoomController

    func makeNSView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView(frame: .zero)
        view.onPercent = { [weak controller] percent in
            DispatchQueue.main.async { controller?.percent = percent }
        }
        controller.view = view
        return view
    }

    func updateNSView(_ view: ZoomScrollView, context: Context) {
        controller.view = view
        view.show(image, logical: logical, key: key)
    }
}

final class ImageLoader: ObservableObject {
    enum Phase: Equatable {
        case loading, ready, missing, downloading
        case failed(String)
    }

    @Published var image: NSImage?
    @Published var logical = CGSize.zero
    @Published var caption = ""
    @Published var phase = Phase.loading
    @Published var elapsed = 0
    @Published var cloudOnly = false
    private var member: Member?
    private var request: PHImageRequestID?
    private var generation = 0
    private var timer: Timer?

    deinit {
        if let request { PHImageManager.default().cancelImageRequest(request) }
        timer?.invalidate()
    }

    private var known = CGSize.zero

    private func size(of image: NSImage) -> CGSize {
        let own = image.size
        guard known.width > 0, known.height > 0, own.width > 0, own.height > 0 else { return own }
        let turned = (own.width >= own.height) == (known.width >= known.height) ? known : CGSize(width: known.height, height: known.width)
        return max(turned.width, turned.height) > max(own.width, own.height) ? turned : own
    }

    func load(_ member: Member, known: CGSize = .zero) {
        self.known = known
        if let request { PHImageManager.default().cancelImageRequest(request) }
        request = nil
        timer?.invalidate()
        timer = nil
        generation += 1
        self.member = member
        image = nil
        caption = ""
        logical = .zero
        cloudOnly = false
        phase = .loading
        if member.source == "photos" { loadAsset(member, generation) } else { loadFile(member, generation) }
    }

    private func loadAsset(_ member: Member, _ gen: Int) {
        guard let asset = Thumbs.shared.asset(member.path) else {
            phase = .failed(String(localized: "The item was not found in the Photos library, or there is no access to it."))
            return
        }
        logical = CGSize(width: asset.pixelWidth, height: asset.pixelHeight)
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .none
        options.version = .current
        options.progressHandler = { [weak self] progress, _, _, _ in
            DispatchQueue.main.async {
                guard let self, self.generation == gen, self.image != nil, !self.caption.isEmpty else { return }
                self.caption = String(localized: "preview · loading from iCloud \(Int(progress * 100)) %")
            }
        }
        request = PHImageManager.default().requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .default, options: options) { [weak self] image, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            let error = (info?[PHImageErrorKey] as? Error)?.localizedDescription
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                if let image {
                    if self.logical == .zero { self.logical = image.size }
                    self.image = image
                    self.phase = .ready
                    self.caption = degraded ? String(localized: "preview · loading full size…") : ""
                } else if self.image == nil {
                    self.phase = .failed(error ?? String(localized: "Photos did not provide the image."))
                } else if !degraded {
                    self.caption = String(localized: "preview · full size did not load")
                }
            }
        }
    }

    private func loadFile(_ member: Member, _ gen: Int) {
        let url = Catalog.archiveRoot.appendingPathComponent(member.path)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let local = Thumbs.isLocal(url)
            var found: (NSImage, String)?
            if local, let image = Thumbs.decode(url) {
                found = (image, "")
            } else if let image = Thumbs.decode(Thumbs.previewFile(member.path)) {
                found = (image, String(localized: "preview \(String(Int(max(image.size.width, image.size.height)))) px"))
            } else if let image = Thumbs.decode(Thumbs.cachedFile(member.path)) {
                found = (image, String(localized: "thumbnail \(String(Int(max(image.size.width, image.size.height)))) px"))
            }
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.cloudOnly = !local
                if let (image, caption) = found {
                    self.logical = self.size(of: image)
                    self.image = image
                    self.caption = caption
                    self.phase = .ready
                } else {
                    self.phase = .missing
                }
            }
        }
    }

    func download() {
        guard let member, member.source == "archive", phase != .downloading else { return }
        let gen = generation
        let url = Catalog.archiveRoot.appendingPathComponent(member.path)
        phase = .downloading
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.elapsed += 1 }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var image: NSImage?
            var failure: String?
            do {
                let data = try Data(contentsOf: url)
                image = Thumbs.decode(CGImageSourceCreateWithData(data as CFData, nil))
                if image == nil { failure = String(localized: "The file is downloaded but cannot be shown here — open it with the Open button.") }
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.timer?.invalidate()
                self.timer = nil
                self.cloudOnly = !Thumbs.isLocal(url)
                if let image {
                    self.logical = image.size
                    self.image = image
                    self.caption = ""
                    self.phase = .ready
                } else {
                    self.phase = self.image == nil ? .failed(failure ?? "") : .ready
                    if self.image != nil { self.caption = failure ?? "" }
                }
            }
        }
    }
}

@MainActor
final class PageState: ObservableObject {
    @Published var item: Item?
    @Published var versions: [Member] = []
    @Published var index = 0
    @Published var compare = false
    @Published var metas: [String: FileMeta] = [:]
    @Published var collections: [(title: String, icon: String, scope: Scope)] = []
    let left = ZoomController()
    let right = ZoomController()
    weak var model: Model?

    var current: Member? { versions.indices.contains(index) ? versions[index] : nil }

    var original: Member? {
        versions.first { $0.source == "archive" && $0.role == "photo" && ["jpg", "jpeg"].contains($0.ext.lowercased()) }
            ?? versions.first { $0.source == "archive" && $0.role == "photo" }
            ?? versions.first { $0.role == "raw" }
            ?? versions.first { $0.source == "photos" }
    }

    func load(_ stale: Item, model: Model) {
        self.model = model
        let item = model.latest(stale)
        let keep = model.takeVersion() ?? (self.item?.key == item.key ? current?.path : nil)
        self.item = item
        versions = model.versions(of: item)
        var found: [String: FileMeta] = [:]
        for member in versions { if let meta = model.meta(member) { found[member.path] = meta } }
        metas = found
        collections = model.collections(of: item)
        index = keep.flatMap { path in versions.firstIndex { $0.path == path } } ?? 0
    }

    func pixels(_ member: Member) -> CGSize {
        if let meta = metas[member.path], meta.width > 0, meta.height > 0 { return CGSize(width: meta.width, height: meta.height) }
        if member.width > 0 && member.height > 0 { return CGSize(width: member.width, height: member.height) }
        return .zero
    }

    func stepVersion(_ delta: Int) {
        guard !versions.isEmpty else { return }
        index = min(max(index + delta, 0), versions.count - 1)
    }

    func zoom(_ action: (ZoomController) -> Void) {
        action(right)
        if compare { action(left) }
    }

    func label(_ member: Member) -> String {
        let ext = member.ext.uppercased()
        if member.source == "photos" { return String(localized: "In Photos") + " · " + ext }
        switch member.role {
        case "raw": return "RAW · " + ext
        case "video": return String(localized: "Video") + " · " + ext
        case "export": return String(localized: "Copy from Photos") + " · " + ext
        case "edit":
            let software = (metas[member.path]?.software ?? "").trimmingCharacters(in: .whitespaces)
            var tool = ""
            if software.lowercased().contains("lightroom") { tool = "Lightroom" }
            else if software.lowercased().contains("photoshop") { tool = "Photoshop" }
            else if !software.isEmpty { tool = String(software.prefix(22)) }
            else if member.name.contains("_LR") || member.name.contains("LR-") { tool = "Lightroom" }
            else if member.name.contains("_PS") || member.name.lowercased().contains("-ps") || member.ext.lowercased() == "psd" { tool = "Photoshop" }
            return tool.isEmpty ? String(localized: "Edit") : String(localized: "Edit") + " · " + tool
        default: return String(localized: "Original") + " · " + ext
        }
    }

    func handle(_ code: UInt16, _ flags: NSEvent.ModifierFlags) -> Bool {
        guard let model else { return false }
        let mods = flags.intersection([.command, .option, .control])
        if mods == [.command] {
            switch code {
            case 24, 69: zoom { $0.zoomIn() }
            case 27, 78: zoom { $0.zoomOut() }
            case 29, 82: zoom { $0.fit() }
            case 18, 83: zoom { $0.actual() }
            default: return false
            }
            return true
        }
        guard mods.isEmpty else { return false }
        switch code {
        case 123: model.step(-1)
        case 124: model.step(1)
        case 126: stepVersion(-1)
        case 125: stepVersion(1)
        case 53: model.goBack()
        case 8: compare.toggle()
        case 6: zoom { $0.toggle() }
        default: return false
        }
        return true
    }
}

struct Flow: Layout {
    var spacing: CGFloat = 6

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (CGSize, [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        var points: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > width {
                x = 0
                y += row + spacing
                row = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            widest = max(widest, x - spacing)
            row = max(row, size.height)
        }
        return (CGSize(width: min(widest, width), height: y + row), points)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? 320, subviews).0
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let points = arrange(bounds.width, subviews).1
        for (view, point) in zip(subviews, points) {
            view.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

struct MemberThumb: View {
    let member: Member
    let side: CGFloat
    let epoch: Int
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.gray.opacity(0.2)
                    Image(systemName: member.source == "photos" ? "photo" : "icloud").font(.title2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: side, height: side).clipped()
        .task(id: "\(member.source):\(member.path)-\(epoch)") {
            image = nil
            Thumbs.shared.image(for: member, side: side) { image = $0 }
        }
    }
}

struct PhotoPane: View {
    let member: Member
    let label: String?
    var known = CGSize.zero
    @ObservedObject var controller: ZoomController
    @StateObject private var loader = ImageLoader()

    var body: some View {
        ZStack {
            ZoomView(image: loader.image, logical: loader.logical, key: member.source + ":" + member.path, controller: controller)
            if loader.image == nil { placeholder }
            VStack {
                if let label {
                    HStack {
                        Text(label).font(.callout.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 5)
                            .foregroundStyle(.white).hudCapsule()
                        Spacer()
                    }
                }
                Spacer()
                HStack(alignment: .bottom) {
                    captionView
                    Spacer()
                    if loader.image != nil { zoomBar }
                }
            }
            .padding(14)
        }
        .clipped()
        .task(id: member.source + ":" + member.path) { loader.load(member, known: known) }
    }

    @ViewBuilder private var captionView: some View {
        if loader.image != nil && (!loader.caption.isEmpty || loader.phase == .downloading) {
            HStack(spacing: 8) {
                if loader.phase == .downloading {
                    ProgressView().controlSize(.small)
                    Text("downloading the original from iCloud · \(loader.elapsed) s")
                } else {
                    Text(loader.caption)
                    if loader.cloudOnly && member.source == "archive" && member.role != "video" {
                        Button("Download Original") { loader.download() }.buttonStyle(.link)
                    }
                }
            }
            .lineLimit(1)
            .font(.caption).foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .hudCapsule()
        }
    }

    @ViewBuilder private var placeholder: some View {
        VStack(spacing: 12) {
            switch loader.phase {
            case .loading, .ready:
                ProgressView().controlSize(.large)
            case .missing:
                Image(systemName: member.role == "video" ? "film" : "icloud").font(.system(size: 44))
                Text(member.role == "video" ? "The video is in iCloud, there is no preview for it" : "The original is in iCloud, there is no preview for it yet")
                Text(member.name + " · " + ByteCountFormatter.string(fromByteCount: member.size, countStyle: .file)).font(.caption).opacity(0.7)
                if member.role != "video" {
                    Button { loader.download() } label: { Label("Download Original", systemImage: "icloud.and.arrow.down") }
                        .controlSize(.large)
                }
            case .downloading:
                ProgressView().controlSize(.large)
                Text("Downloading the original from iCloud… \(ByteCountFormatter.string(fromByteCount: member.size, countStyle: .file)) · \(loader.elapsed) s")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle").font(.system(size: 40))
                Text(message).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
        }
        .foregroundStyle(.white)
    }

    private var zoomBar: some View {
        HStack(spacing: 10) {
            Button { controller.zoomOut() } label: { Image(systemName: "minus") }.help("Zoom Out (⌘−)")
            Text(controller.percent > 0 ? "\(controller.percent) %" : "—").font(Theme.count(13)).frame(minWidth: 46)
            Button { controller.zoomIn() } label: { Image(systemName: "plus") }.help("Zoom In (⌘+)")
            Divider().frame(height: 14)
            Button("Fit") { controller.fit() }.help("Fit to window (⌘0)")
            Button("100%") { controller.actual() }.help("Pixel for pixel (⌘1)")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .foregroundStyle(.white)
        .lineLimit(1)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .hudCapsule()
        .fixedSize()
    }
}

struct PhotoPage: View {
    @ObservedObject var model: Model
    let item: Item
    @Environment(\.colorScheme) private var scheme
    @StateObject private var state = PageState()

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                topBar
                stage.frame(maxWidth: .infinity, maxHeight: .infinity)
                filmstrip
            }
            .background { PageBackdrop(item: item, epoch: model.epoch).ignoresSafeArea(edges: scheme == .dark ? .all : [.bottom, .horizontal]) }
            .environment(\.colorScheme, .dark)
            if !model.inspectorHidden {
                info.frame(width: 340).glassSidebar()
            }
        }
        .task(id: "\(item.key)-\(model.epoch)") { state.load(item, model: model) }
        .onAppear {
            model.page = state
            model.pageKeys = { [weak state] code, flags in state?.handle(code, flags) ?? false }
        }
        .onDisappear {
            if model.page === state {
                model.page = nil
                model.pageKeys = nil
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { model.step(-1) } label: { Image(systemName: "arrow.left") }.help("Previous item (←)")
            Button { model.step(1) } label: { Image(systemName: "arrow.right") }.help("Next item (→)")
            Text(item.title).font(.headline).lineLimit(1).truncationMode(.middle)
            LabelBadge(label: model.label(of: item))
            if state.versions.count > 1 {
                Text("version \(state.index + 1) of \(state.versions.count)").foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: $state.compare) { Label("Compare with Original", systemImage: "rectangle.split.2x1") }
                .toggleStyle(.button)
                .help("The original and the chosen version side by side (C)")
                .disabled(state.versions.count < 2)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .hudPanel(radius: Theme.barRadius)
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
    }

    @ViewBuilder private var stage: some View {
        if let current = state.current {
            if state.compare, let original = state.original {
                HStack(spacing: 0) {
                    PhotoPane(member: original, label: state.label(original), known: state.pixels(original), controller: state.left)
                    Rectangle().fill(Color.white.opacity(0.22)).frame(width: 1.5)
                    PhotoPane(member: current, label: state.label(current) + (state.index == 0 ? " · " + String(localized: "main") : ""), known: state.pixels(current), controller: state.right)
                }
            } else {
                PhotoPane(member: current, label: nil, known: state.pixels(current), controller: state.right)
            }
        } else {
            ZStack {
                Color.clear
                Text("This item has no files in the catalog").foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(state.versions.enumerated()), id: \.element.id) { index, member in
                        VStack(spacing: 5) {
                            ZStack(alignment: .topLeading) {
                                MemberThumb(member: member, side: 110, epoch: model.epoch)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .selectionRing(index == state.index, radius: 10)
                                if index == 0 {
                                    Label("Main", systemImage: "star.fill").font(.system(size: 9, weight: .semibold))
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(Color.accentColor, in: Capsule()).foregroundStyle(.white)
                                        .padding(5)
                                }
                            }
                            Text(state.label(member)).font(.caption).fontWeight(index == state.index ? .semibold : .regular)
                                .foregroundStyle(index == state.index ? .primary : .secondary)
                                .lineLimit(1).frame(width: 118)
                        }
                        .id(member.id)
                        .contentShape(Rectangle())
                        .onTapGesture { state.index = index }
                        .help(member.name)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .onChange(of: state.index) { _ in
                if let id = state.current?.id { withAnimation { proxy.scrollTo(id) } }
            }
        }
        .frame(height: 158)
        .hudPanel(radius: 18)
        .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 4)
    }

    private var info: some View {
        let mark = model.marks[item.key]
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(item.title).font(.title2).bold().textSelection(.enabled).glassSection("head")
                Label(item.dateLabel, systemImage: "calendar")
                    .foregroundStyle(.secondary)
                    .glassSection("head")
                if !item.root.isEmpty {
                    Button { model.go(.root(item.root)) } label: { Label(item.root, systemImage: "folder").multilineTextAlignment(.leading) }
                        .buttonStyle(.link)
                        .help("Open Folder")
                        .glassSection("head")
                }
                GlassGap()
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { n in
                        Button { model.rate((mark?.rating ?? 0) == n ? 0 : n) } label: {
                            Image(systemName: n <= (mark?.rating ?? 0) ? "star.fill" : "star").foregroundStyle(.yellow)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Button { model.pick(1) } label: { Label("Pick", systemImage: mark?.pick == 1 ? "checkmark.seal.fill" : "checkmark.seal") }
                    Button { model.pick(-1) } label: { Label("Reject", systemImage: mark?.pick == -1 ? "xmark.seal.fill" : "xmark.seal") }.glassSection("controls")
                }
                .controlSize(.small)
                LabelPicker(model: model, item: item)
                Toggle(isOn: Binding(get: { model.flagged.contains(item.key) }, set: { _ in model.toggleFlag(item) })) {
                    Label("To Phone", systemImage: "iphone")
                }
                .toggleStyle(.switch)
                .glassSection("controls")
                HiddenToggle(model: model, item: item)
                if model.latest(item).needsArchive {
                    Button { model.askAddToArchive([model.latest(item)]) } label: { Label("Add to Archive…", systemImage: "externaldrive.badge.plus") }
                        .help("Copy the original from Photos to an archive folder")
                        .disabled(!model.busyTool.isEmpty)
                        .glassSection("controls")
                }
                GlassGap()
                if !state.collections.isEmpty {
                    Text("Tags and Collections").font(.headline).glassSection("about")
                    Flow(spacing: 6) {
                        ForEach(Array(state.collections.enumerated()), id: \.offset) { _, chip in
                            Button { model.go(chip.scope) } label: { Label(chip.title, systemImage: chip.icon).font(.caption).lineLimit(1) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                        TagPickerButton(model: model)
                    }
                    .glassSection("about")
                }
                if !item.lens.isEmpty {
                    Label(item.lens, systemImage: "circle.circle").font(.caption).foregroundStyle(.secondary).textSelection(.enabled).glassSection("about")
                }
                if let current = state.current {
                    if let exposure = exposureLine(state.metas[current.path]) {
                        Label(exposure, systemImage: "camera").font(.callout).foregroundStyle(.secondary).textSelection(.enabled).glassSection("about")
                    }
                    GlassGap()
                    versionInfo(current).glassSection("version")
                }
                GlassGap()
                Text("← → items · ↑ ↓ versions · C compare · Z fit/100% · ⌘+ ⌘− ⌘0 ⌘1 · double-click — 100% · Esc — back · 1–5, P, X, U, T as in the grid")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSections()
            .padding(.horizontal, 26).padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func versionInfo(_ member: Member) -> some View {
        let pixels = state.pixels(member)
        let width = Int(pixels.width), height = Int(pixels.height)
        let url = Catalog.archiveRoot.appendingPathComponent(member.path)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(state.label(member)).font(.headline)
                if state.index == 0 { Badge(text: String(localized: "main"), color: .accentColor) }
            }
            Text(member.name).bold().textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            Text([ByteCountFormatter.string(fromByteCount: member.size, countStyle: .file), width > 0 ? "\(width) × \(height) px" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                .foregroundStyle(.secondary)
            if member.source == "archive" {
                Label(member.path, systemImage: "externaldrive").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if Thumbs.isLocal(url) {
                    Label("Downloaded to this Mac", systemImage: "checkmark.icloud").font(.caption).foregroundStyle(.green)
                } else {
                    Label("Only in iCloud — opens after downloading", systemImage: "icloud").font(.caption).foregroundStyle(.secondary)
                }
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
                Label("Photos library", systemImage: "photo.on.rectangle").font(.caption).foregroundStyle(.secondary)
                Button("Show in Photos") { model.showInPhotos(member) }.controlSize(.small)
            }
            HStack {
                if state.index != 0 {
                    Button { model.setMain(item, member) } label: { Label("Make Main", systemImage: "star") }
                }
                Button(role: .destructive) { model.askRemoval(member, of: item) } label: { Label("Delete…", systemImage: "trash") }
                    .disabled(!model.busyTool.isEmpty)
                if !model.busyTool.isEmpty { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)
        }
    }

    private func exposureLine(_ meta: FileMeta?) -> String? {
        guard let meta else { return nil }
        func clean(_ s: String) -> String {
            var t = s.trimmingCharacters(in: .whitespaces)
            if t.hasSuffix(".0") { t.removeLast(2) }
            return t
        }
        var camera = clean(meta.model)
        let make = clean(meta.make)
        if !make.isEmpty && !camera.lowercased().hasPrefix(make.lowercased().split(separator: " ").first.map(String.init) ?? "") { camera = make + " " + camera }
        let seconds = String(localized: "s")
        var shutter = clean(meta.shutter)
        if let value = Double(shutter), value > 0 {
            shutter = (value < 1 ? "1/\(Int((1 / value).rounded()))" : clean(String(value))) + " " + seconds
        } else if !shutter.isEmpty && !shutter.hasSuffix(seconds) {
            shutter += " " + seconds
        }
        let parts = [camera.trimmingCharacters(in: .whitespaces), clean(meta.lens),
                     meta.aperture.isEmpty ? "" : "ƒ/" + clean(meta.aperture), shutter,
                     meta.iso.isEmpty ? "" : "ISO " + clean(meta.iso), meta.focal.isEmpty ? "" : clean(meta.focal) + " " + String(localized: "mm")].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct PageBackdrop: View {
    let item: Item
    let epoch: Int
    @State private var shown: (key: String, image: NSImage)?

    var body: some View {
        ZStack {
            VisualEffect(material: .hudWindow, dark: true)
            if let shown {
                Image(nsImage: shown.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
                    .scaleEffect(1.3)
                    .blur(radius: 70, opaque: true)
                    .saturation(1.6)
                    .overlay(Color.black.opacity(0.34))
                    .id(shown.key)
                    .transition(.opacity)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .task(id: PaletteStore.key(item) + "-\(epoch)") {
            let key = PaletteStore.key(item)
            Thumbs.shared.image(for: item, side: 150) { image in
                guard let image, shown?.key != key else { return }
                withAnimation(.easeInOut(duration: 0.5)) { shown = (key, image) }
            }
        }
    }
}
