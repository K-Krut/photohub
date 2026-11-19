import AppKit
import Charts
import SwiftUI

@MainActor
final class StatisticsStore: ObservableObject {
    static let shared = StatisticsStore()

    @Published private(set) var stats: CatalogStats?
    @Published private(set) var disk: DiskStats?
    @Published private(set) var loading = false
    @Published private(set) var scanning = false
    @Published var section = ""
    @Published var jump = 0
    private var stamp = ""
    private var diskStamp = ""

    static var photosLibrary: URL? {
        if AppPaths.noPhotos { return nil }
        if let value = ProcessInfo.processInfo.environment["PHOTOHUB_PHOTOS_LIBRARY"], !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Photos Library.photoslibrary")
    }

    func refresh(force: Bool = false) {
        let hidden = Set(Hidden.shared.items.map(\.key))
        let hiddenStamp = "\(hidden.count)|\(hidden.hashValue)"
        let signature = Catalog.signature() + "|" + hiddenStamp
        if !loading && (force || stats == nil || signature != stamp) {
            loading = true
            let path = Catalog.path
            DispatchQueue.global(qos: .userInitiated).async {
                let result = CatalogStats.compute(catalog: path, hidden: hidden)
                DispatchQueue.main.async {
                    self.stats = result
                    self.stamp = signature
                    self.loading = false
                }
            }
        }
        if !scanning && (force || disk == nil || hiddenStamp != diskStamp) {
            scanning = true
            let path = Catalog.path, archive = Catalog.archiveRoot, support = AppPaths.support, library = StatisticsStore.photosLibrary
            DispatchQueue.global(qos: .utility).async {
                let result = DiskStats.compute(catalog: path, archive: archive, support: support, photosLibrary: library, hidden: hidden)
                DispatchQueue.main.async {
                    self.disk = result
                    self.diskStamp = hiddenStamp
                    self.scanning = false
                }
            }
        }
    }
}

enum StatFormat {
    static func bytes(_ n: Int64) -> String {
        let format = ByteCountFormatter()
        format.countStyle = .file
        format.allowsNonnumericFormatting = false
        return format.string(fromByteCount: n)
    }
    static func number(_ n: Int) -> String { n.formatted() }
    static func percent(_ part: Int, of total: Int) -> String {
        total == 0 ? "0 %" : (Double(part) / Double(total)).formatted(.percent.precision(.fractionLength(0)))
    }

    static func role(_ tally: Tally) -> String {
        switch tally.name {
        case "raw": return "RAW"
        case "edit": return String(localized: "Edits")
        case "video": return String(localized: "Videos")
        case "export": return String(localized: "Copies from Photos")
        default: return tally.group == "photos" ? String(localized: "Photos") : String(localized: "Originals")
        }
    }

    static func data(_ name: String) -> String {
        switch name {
        case "catalog": return String(localized: "Catalog")
        case "thumbs": return String(localized: "Thumbnails")
        case "previews": return String(localized: "Previews")
        case "vision": return String(localized: "Recognition data")
        case "index": return String(localized: "Hash index")
        default: return String(localized: "Face models")
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var detail = ""
    var icon = ""
    var tint: Color = .accentColor
    var action: (() -> Void)?
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if !icon.isEmpty { Image(systemName: icon).foregroundStyle(tint).frame(width: 16) }
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if action != nil { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary).opacity(hover ? 1 : 0.5) }
            }
            Text(value).font(Theme.count(22, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
            Text(detail.isEmpty ? " " : detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 12)
        .scaleEffect(hover && action != nil ? 1.02 : 1)
        .animation(Theme.spring, value: hover)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { action?() }
    }
}

struct BarRow: Identifiable {
    let id: String
    let label: String
    let value: Double
    let text: String
    var color: Color = .accentColor
    var action: (() -> Void)?
}

struct BarList: View {
    let rows: [BarRow]

    var body: some View {
        let top = max(rows.map(\.value).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 7) {
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    Text(row.label).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).frame(width: 150, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(row.color.opacity(0.85))
                            .frame(width: max(3, geo.size.width * row.value / top), height: 10)
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 14)
                    Text(row.text).font(Theme.count(12)).foregroundStyle(.secondary).lineLimit(1).frame(minWidth: 64, alignment: .trailing)
                }
                .contentShape(Rectangle())
                .onTapGesture { row.action?() }
                .help(row.action == nil ? "" : row.label)
            }
            if rows.isEmpty { Text("Nothing yet").font(.callout).foregroundStyle(.secondary) }
        }
    }
}

struct StatCard<Content: View>: View {
    let title: String
    var subtitle = ""
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                if !subtitle.isEmpty { Text(subtitle).font(Theme.count(12)).foregroundStyle(.secondary) }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassCard()
    }
}

struct SplitBar: View {
    let parts: [(label: String, value: Int64, color: Color)]

    var body: some View {
        let total = max(parts.reduce(Int64(0)) { $0 + $1.value }, 1)
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    if part.value > 0 {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(part.color)
                            .frame(width: max(4, (geo.size.width - 2 * CGFloat(parts.count - 1)) * CGFloat(part.value) / CGFloat(total)))
                    }
                }
            }
        }
        .frame(height: 14)
    }
}

struct LegendDot: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.system(size: 12))
            Text(value).font(Theme.count(12)).foregroundStyle(.secondary)
        }
    }
}

struct YearChart: View {
    @ObservedObject var model: Model
    let years: [Tally]
    @State private var hovered: String?

    var body: some View {
        let shown = years.first { $0.name == hovered } ?? years.max { $0.count < $1.count }
        VStack(alignment: .leading, spacing: 6) {
            if let shown {
                Text(verbatim: "\(shown.name): \(StatFormat.number(shown.count))").font(Theme.count(12)).foregroundStyle(.secondary)
            }
            Chart(years) { year in
                BarMark(x: .value("Year", year.name), y: .value("Shots", year.count), width: .ratio(0.7))
                    .foregroundStyle(Color.accentColor.opacity(hovered == nil || hovered == year.name ? 0.9 : 0.35))
                    .cornerRadius(3)
            }
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(Color.primary.opacity(0.08)); AxisValueLabel() } }
            .chartXAxis { AxisMarks { _ in AxisValueLabel() } }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                let origin = geo[proxy.plotAreaFrame].origin
                                hovered = proxy.value(atX: point.x - origin.x, as: String.self)
                            case .ended: hovered = nil
                            }
                        }
                        .onTapGesture { if let hovered { model.go(.year(hovered)) } }
                }
            }
            .frame(height: 180)
        }
    }
}

struct SpaceByYearChart: View {
    let tallies: [Tally]

    var body: some View {
        let rows = tallies.filter { $0.name >= "1971" }
        Chart(rows) { row in
            BarMark(x: .value("Year", row.name), y: .value("Size", Double(row.bytes) / 1_073_741_824), width: .ratio(0.7))
                .foregroundStyle(by: .value("Where", row.group == "archive" ? String(localized: "Archive") : String(localized: "Photos")))
                .cornerRadius(2)
        }
        .chartForegroundStyleScale([String(localized: "Archive"): Color.orange, String(localized: "Photos"): Color.blue])
        .chartYAxisLabel(String(localized: "GB"))
        .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(Color.primary.opacity(0.08)); AxisValueLabel() } }
        .chartLegend(position: .top, alignment: .leading)
        .frame(height: 190)
    }
}

struct MonthStrip: View {
    let months: [Tally]

    var body: some View {
        let counts = Dictionary(months.map { ($0.name, $0.count) }, uniquingKeysWith: +)
        let years = Array(Set(months.map { String($0.name.prefix(4)) }).filter { $0 >= "1971" }).sorted(by: >)
        let top = Double(max(counts.values.max() ?? 1, 1))
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Text("").frame(width: 40)
                ForEach(0..<12, id: \.self) { m in
                    Text(Months.short[m]).font(.system(size: 9)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            ForEach(years, id: \.self) { year in
                HStack(spacing: 3) {
                    Text(year).font(Theme.count(10)).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                    ForEach(1...12, id: \.self) { m in
                        let key = String(format: "%@-%02d", year, m)
                        let n = counts[key] ?? 0
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(n == 0 ? Color.primary.opacity(0.05) : Color.accentColor.opacity(0.15 + 0.85 * (Double(n) / top).squareRoot()))
                            .frame(maxWidth: .infinity).frame(height: 16)
                            .help(Text(verbatim: "\(Months.label(key)): \(StatFormat.number(n))"))
                    }
                }
            }
        }
    }
}

struct StatisticsPage: View {
    @ObservedObject var model: Model
    @ObservedObject var store = StatisticsStore.shared
    @AppStorage(Hidden.showKey) private var showHidden = true

    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 12)]
    private let wide = [GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if let stats = store.stats {
                        library(stats).id("library")
                        space(stats).id("space")
                        years(stats).id("years")
                        highlights(stats).id("highlights")
                        tops(stats).id("top")
                        marks(stats).id("marks")
                        footer(stats)
                    } else {
                        VStack(spacing: 10) {
                            ProgressView()
                            Text(store.loading ? "Counting…" : "The catalog is empty.").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 120)
                    }
                }
                .padding(.horizontal, 28).padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: store.jump) { _ in
                DispatchQueue.main.async { proxy.scrollTo(store.section, anchor: .top) }
            }
        }
        .task(id: model.epoch) { store.refresh() }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 22, weight: .bold))
    }

    private var live: Int? {
        AppPaths.noPhotos ? nil : model.cards("kinds").first { $0.id == "type:live" }?.count
    }

    @ViewBuilder private func library(_ s: CatalogStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(String(localized: "Library"))
            LazyVGrid(columns: columns, spacing: 12) {
                StatTile(title: String(localized: "Shots"), value: StatFormat.number(s.shots), detail: String(localized: "a shot is one stack of versions"), icon: "photo.stack") { model.go(.all) }
                StatTile(title: String(localized: "Files"), value: StatFormat.number(s.files), detail: String(localized: "archive \(StatFormat.number(s.archiveFiles)) · Photos \(StatFormat.number(s.photosFiles))"), icon: "doc.on.doc")
                StatTile(title: String(localized: "Photos"), value: StatFormat.number(s.photos), icon: "photo")
                StatTile(title: String(localized: "Videos"), value: StatFormat.number(s.videos), icon: "film") { model.go(.kind(.video)) }
                StatTile(title: "RAW", value: StatFormat.number(s.rawShots), detail: String(localized: "files: \(StatFormat.number(s.rawFiles))"), icon: "camera.aperture", tint: .orange) { model.go(.kind(.raw)) }
                StatTile(title: String(localized: "With Edits"), value: StatFormat.number(s.editShots), detail: String(localized: "edit files: \(StatFormat.number(s.editFiles))"), icon: "wand.and.stars", tint: .purple) { model.go(.kind(.edited)) }
                if let live {
                    StatTile(title: String(localized: "Live Photos"), value: StatFormat.number(live), icon: "livephoto") { model.go(.tag("type", "live")) }
                }
                StatTile(title: String(localized: "Screenshots"), value: StatFormat.number(s.origins["screenshot"] ?? 0), icon: "camera.viewfinder") { model.go(.tag("origin", "screenshot")) }
                StatTile(title: String(localized: "Saved Images"), value: StatFormat.number(s.origins["saved"] ?? 0), detail: String(localized: "from messengers: \(StatFormat.number(s.origins["messenger"] ?? 0))"), icon: "square.and.arrow.down") { model.go(.tag("origin", "saved")) }
                StatTile(title: String(localized: "Version Stacks"), value: StatFormat.number(s.stacks), detail: String(localized: "shots with more than one file"), icon: "square.stack.3d.up") { model.go(.kind(.stacks)) }
                StatTile(title: String(localized: "Exact Copies"), value: StatFormat.number(s.copyGroups), detail: String(localized: "\(StatFormat.number(s.copyFiles)) files, \(StatFormat.bytes(s.copyWaste)) extra"), icon: "doc.on.doc.fill", tint: .red) { model.go(.tag("dup", "exact")) }
                StatTile(title: String(localized: "Only in Archive"), value: StatFormat.number(s.archiveOnly), detail: StatFormat.percent(s.archiveOnly, of: s.shots), icon: "externaldrive") { model.go(.kind(.archiveOnly)) }
                StatTile(title: String(localized: "Only in Photos"), value: StatFormat.number(s.photosOnly), detail: StatFormat.percent(s.photosOnly, of: s.shots), icon: "iphone") { model.go(.kind(.photosOnly)) }
                StatTile(title: String(localized: "In Archive and Photos"), value: StatFormat.number(s.both), detail: StatFormat.percent(s.both, of: s.shots), icon: "arrow.triangle.2.circlepath") { model.go(.kind(.both)) }
                if showHidden && s.hidden > 0 {
                    StatTile(title: String(localized: "Hidden"), value: StatFormat.number(s.hidden), detail: String(localized: "not counted anywhere else"), icon: "eye.slash", tint: .secondary) {
                        model.go(.hidden)
                        Hidden.shared.unlock { model.apply() }
                    }
                }
            }
        }
    }

    @ViewBuilder private func space(_ s: CatalogStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(String(localized: "Space"))
            LazyVGrid(columns: wide, spacing: 16) {
                StatCard(title: String(localized: "Archive by Type"), subtitle: StatFormat.bytes(s.archiveBytes)) {
                    BarList(rows: s.byRole.filter { $0.group == "archive" }.map { BarRow(id: $0.id, label: StatFormat.role($0), value: Double($0.bytes), text: StatFormat.bytes($0.bytes)) })
                    Text("Sizes of the originals as recorded in the catalog; nothing is downloaded to count them.").font(.caption).foregroundStyle(.secondary)
                }
                if s.photosFiles > 0 {
                    StatCard(title: String(localized: "Photos Library by Type"), subtitle: StatFormat.bytes(s.photosBytes)) {
                        BarList(rows: s.byRole.filter { $0.group == "photos" }.map { BarRow(id: $0.id, label: StatFormat.role($0), value: Double($0.bytes), text: StatFormat.bytes($0.bytes), color: .blue) })
                        Text("Full-size originals, whether they are on this Mac or only in iCloud Photos.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                StatCard(title: String(localized: "Archive on This Mac")) { download }
                StatCard(title: String(localized: "On Disk")) { onDisk }
            }
            StatCard(title: String(localized: "Space by Year")) { SpaceByYearChart(tallies: s.bytesByYear) }
        }
    }

    @ViewBuilder private var download: some View {
        if let disk = store.disk {
            SplitBar(parts: [(String(localized: "Downloaded"), disk.localBytes, Color.green), (String(localized: "Only in iCloud"), disk.cloudBytes, Color.blue.opacity(0.45))])
            VStack(alignment: .leading, spacing: 4) {
                LegendDot(color: .green, label: String(localized: "Downloaded"), value: "\(StatFormat.bytes(disk.localBytes)) · \(StatFormat.number(disk.localFiles))")
                LegendDot(color: .blue.opacity(0.45), label: String(localized: "Only in iCloud"), value: "\(StatFormat.bytes(disk.cloudBytes)) · \(StatFormat.number(disk.cloudFiles))")
                if disk.missingFiles > 0 {
                    LegendDot(color: .red, label: String(localized: "Not found"), value: StatFormat.number(disk.missingFiles))
                }
            }
            Text("Checked with the file's iCloud flag, without downloading anything.").font(.caption).foregroundStyle(.secondary)
        } else {
            scanningLabel
        }
    }

    @ViewBuilder private var onDisk: some View {
        if let disk = store.disk {
            BarList(rows: diskRows(disk))
            Text("PhotoHub data: \(StatFormat.bytes(disk.dataBytes)). The iCloud download cache is kept by macOS; PhotoHub only shows its size.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            scanningLabel
        }
    }

    private func diskRows(_ disk: DiskStats) -> [BarRow] {
        var rows: [BarRow] = []
        if let library = disk.photosLibrary { rows.append(BarRow(id: "library", label: String(localized: "Photos library"), value: Double(library), text: StatFormat.bytes(library), color: .blue)) }
        if let cache = disk.downloadCache { rows.append(BarRow(id: "cache", label: String(localized: "iCloud download cache"), value: Double(cache), text: StatFormat.bytes(cache), color: .gray)) }
        rows += disk.data.map { BarRow(id: $0.name, label: StatFormat.data($0.name), value: Double($0.bytes), text: StatFormat.bytes($0.bytes), color: .teal) }
        return rows
    }

    private var scanningLabel: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Measuring…").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func years(_ s: CatalogStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(String(localized: "Over the Years"))
            StatCard(title: String(localized: "Shots per Year"), subtitle: s.yearSpan.map { "\($0.first)–\($0.last)" } ?? "") { YearChart(model: model, years: s.perYear) }
            StatCard(title: String(localized: "Shots per Month")) { MonthStrip(months: s.perMonth) }
        }
    }

    @ViewBuilder private func highlights(_ s: CatalogStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(String(localized: "Highlights"))
            LazyVGrid(columns: columns, spacing: 12) {
                if let day = s.busiestDay {
                    StatTile(title: String(localized: "Busiest Day"), value: Months.days(day.name, day.name), detail: String(localized: "\(day.count) shots"), icon: "flame")
                }
                if let oldest = s.oldest {
                    StatTile(title: String(localized: "Oldest Shot"), value: Months.days(String(oldest.date.prefix(10)), String(oldest.date.prefix(10))), detail: oldest.title, icon: "hourglass.bottomhalf.filled")
                }
                if let trip = s.longestTrip {
                    StatTile(title: String(localized: "Longest Trip"), value: String(localized: "\(trip.days) days"), detail: Months.tripTitle(trip.name), icon: "airplane") { model.go(.tag("trip", trip.name)) }
                }
                if let place = s.places.first {
                    StatTile(title: String(localized: "Most Photographed Place"), value: place.name, detail: String(localized: "\(place.count) shots"), icon: "mappin.and.ellipse") { model.go(.tag("place", place.name)) }
                }
                if !s.tagsPending {
                    StatTile(title: String(localized: "Countries"), value: StatFormat.number(s.countries), detail: String(localized: "cities: \(StatFormat.number(s.places.count))"), icon: "globe") { model.go(.list("places")) }
                    StatTile(title: String(localized: "Trips"), value: StatFormat.number(s.trips), detail: String(localized: "\(s.travelDays) days"), icon: "suitcase") { model.go(.list("trips")) }
                }
                if s.travelDays > 0 {
                    StatTile(title: String(localized: "Shots per Travel Day"), value: s.perTravelDay.formatted(.number.precision(.fractionLength(0))), detail: String(localized: "on average during trips"), icon: "camera")
                }
                StatTile(title: String(localized: "Share of Edits"), value: StatFormat.percent(s.editShots, of: s.shots), detail: String(localized: "shots with at least one edit"), icon: "slider.horizontal.3", tint: .purple)
            }
        }
    }

    @ViewBuilder private func tops(_ s: CatalogStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(String(localized: "Top"))
            LazyVGrid(columns: wide, spacing: 16) {
                StatCard(title: String(localized: "Cameras")) {
                    BarList(rows: s.cameras.map { tally in BarRow(id: tally.id, label: tally.name, value: Double(tally.count), text: StatFormat.number(tally.count)) { model.go(.camera(tally.name)) } })
                }
                StatCard(title: String(localized: "Lenses")) {
                    BarList(rows: s.lenses.map { BarRow(id: $0.id, label: $0.name, value: Double($0.count), text: StatFormat.number($0.count)) })
                }
                if !s.people.isEmpty {
                    StatCard(title: String(localized: "People")) { BarList(rows: tagRows(s.people, "person", .pink)) }
                }
                if !s.pets.isEmpty {
                    StatCard(title: String(localized: "Pets")) { BarList(rows: tagRows(s.pets, "pet", .brown)) }
                }
                if !s.places.isEmpty {
                    StatCard(title: String(localized: "Places")) { BarList(rows: tagRows(s.places, "place", .teal)) }
                }
            }
        }
    }

    private func tagRows(_ list: [Tally], _ kind: String, _ color: Color) -> [BarRow] {
        list.prefix(8).map { tally in BarRow(id: tally.id, label: tally.name, value: Double(tally.count), text: StatFormat.number(tally.count), color: color) { model.go(.tag(kind, tally.name)) } }
    }

    @ViewBuilder private func marks(_ s: CatalogStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(String(localized: "Ratings, Picks and Labels"))
            LazyVGrid(columns: wide, spacing: 16) {
                StatCard(title: String(localized: "Ratings"), subtitle: StatFormat.number(s.rated)) {
                    BarList(rows: (1...5).reversed().map { n in
                        BarRow(id: "r\(n)", label: String(repeating: "★", count: n), value: Double(s.ratings[n] ?? 0), text: StatFormat.number(s.ratings[n] ?? 0), color: .yellow) { model.go(.all); model.minRating = n }
                    })
                }
                StatCard(title: String(localized: "Picks and Labels"), subtitle: StatFormat.number(s.labeled)) {
                    BarList(rows: [
                        BarRow(id: "pick", label: String(localized: "Picked"), value: Double(s.picks), text: StatFormat.number(s.picks), color: .green) { model.go(.tag("mark", "picked")) },
                        BarRow(id: "reject", label: String(localized: "Rejected"), value: Double(s.rejects), text: StatFormat.number(s.rejects), color: .red) { model.go(.tag("mark", "rejected")) },
                        BarRow(id: "phone", label: String(localized: "To Phone"), value: Double(s.flagged), text: StatFormat.number(s.flagged), color: .mint) { model.go(.flagged) },
                    ] + ColorLabel.allCases.map { label in
                        BarRow(id: label.rawValue, label: label.title, value: Double(s.labels[label.rawValue] ?? 0), text: StatFormat.number(s.labels[label.rawValue] ?? 0), color: label.color) { model.go(.all); model.labelFilter = .one(label) }
                    })
                }
            }
        }
    }

    private func footer(_ s: CatalogStats) -> some View {
        HStack(spacing: 10) {
            Text(timing(s)).font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Button { store.refresh(force: true) } label: { Label("Recount", systemImage: "arrow.clockwise") }
                .buttonStyle(PillButtonStyle())
                .disabled(store.loading || store.scanning)
        }
    }

    private func timing(_ s: CatalogStats) -> String {
        let catalog = Measurement(value: (s.elapsed * 1000).rounded(), unit: UnitDuration.milliseconds).formatted(.measurement(width: .abbreviated))
        guard let disk = store.disk else { return String(localized: "Counted in \(catalog)") }
        let sizes = Measurement(value: (disk.elapsed * 10).rounded() / 10, unit: UnitDuration.seconds).formatted(.measurement(width: .abbreviated))
        return String(localized: "Counted in \(catalog), disk sizes in \(sizes)")
    }
}

struct StatisticsSettings: View {
    @ObservedObject var model: Model
    @ObservedObject var store = StatisticsStore.shared

    var body: some View {
        Form {
            if let s = store.stats {
                Section("Library") {
                    LabeledContent("Shots", value: StatFormat.number(s.shots))
                    LabeledContent("Files", value: StatFormat.number(s.files))
                    LabeledContent("Photos and Videos", value: "\(StatFormat.number(s.photos)) · \(StatFormat.number(s.videos))")
                    LabeledContent("RAW and Edits", value: "\(StatFormat.number(s.rawShots)) · \(StatFormat.number(s.editShots))")
                    LabeledContent("Version Stacks", value: StatFormat.number(s.stacks))
                    LabeledContent("Exact Copies", value: "\(StatFormat.number(s.copyGroups)) · \(StatFormat.bytes(s.copyWaste))")
                    LabeledContent("Archive Only · Photos Only · Both", value: "\(StatFormat.number(s.archiveOnly)) · \(StatFormat.number(s.photosOnly)) · \(StatFormat.number(s.both))")
                }
                Section("Space") {
                    LabeledContent("Archive", value: StatFormat.bytes(s.archiveBytes))
                    if s.photosFiles > 0 { LabeledContent("Photos library originals", value: StatFormat.bytes(s.photosBytes)) }
                    if let disk = store.disk {
                        LabeledContent("Archive downloaded on this Mac", value: StatFormat.bytes(disk.localBytes))
                        if let library = disk.photosLibrary { LabeledContent("Photos library on disk", value: StatFormat.bytes(library)) }
                        LabeledContent("PhotoHub data", value: StatFormat.bytes(disk.dataBytes))
                        if let cache = disk.downloadCache { LabeledContent("iCloud download cache", value: StatFormat.bytes(cache)) }
                    } else {
                        LabeledContent("On disk", value: String(localized: "calculating…"))
                    }
                }
            } else {
                Section { Text(store.loading ? "Counting…" : "The catalog is empty.").foregroundStyle(.secondary) }
            }
            Section {
                HStack {
                    Text("Charts, years, cameras, people, trips and more.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Statistics") {
                        model.go(.statistics)
                        model.window?.makeKeyAndOrderFront(nil)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { store.refresh() }
    }
}
