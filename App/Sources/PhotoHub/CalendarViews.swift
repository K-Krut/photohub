import AppKit
import SwiftUI

@MainActor
struct CalendarPage: View {
    @ObservedObject var model: Model
    @ObservedObject private var store = CalendarStore.shared

    private var value: String {
        if case .calendar(let value) = model.scope { return value }
        return "overview"
    }

    var body: some View {
        let level = store.level(model)
        VStack(spacing: 0) {
            CalendarBar(model: model, store: store, level: level, day: CalendarRoute.day(value))
            Group {
                switch level {
                case .month: CalendarMonths(model: model, store: store)
                case .year: CalendarYear(model: model, store: store)
                case .week: CalendarWeek(model: model, store: store)
                case .day: CalendarDayPage(model: model, key: CalendarRoute.day(value) ?? store.anchorDay)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .simultaneousGesture(MagnificationGesture().onEnded { scale in
            if scale > 1.2 { store.zoom(true, model) } else if scale < 0.83 { store.zoom(false, model) }
        })
        .onAppear {
            store.installKeys(model)
            store.refresh(model)
        }
        .onReceive(model.$shown) { _ in DispatchQueue.main.async { store.refresh(model) } }
        .onReceive(model.$epoch) { _ in DispatchQueue.main.async { store.refresh(model) } }
        .onReceive(model.$marks) { _ in DispatchQueue.main.async { store.refresh(model) } }
    }
}

@MainActor
struct CalendarBar: View {
    @ObservedObject var model: Model
    @ObservedObject var store: CalendarStore
    let level: CalendarLevel
    let day: String?
    @State private var jumping = false

    private var title: String {
        switch level {
        case .day: return CalendarText.full(day ?? store.anchorDay)
        case .week: return CalendarText.week(CalendarDate.weekStart(store.anchorDay))
        case .month: return CalendarText.monthTitle(String(store.anchorDay.prefix(7)))
        case .year: return String(store.anchorDay.prefix(4))
        }
    }

    private var count: Int {
        guard let index = store.index else { return 0 }
        switch level {
        case .day: return model.flat.count
        case .week: return CalendarDate.week(store.anchorDay).reduce(0) { $0 + (index.days[$1]?.items.count ?? 0) }
        case .month: return index.months[String(store.anchorDay.prefix(7))] ?? 0
        case .year: return index.years[String(store.anchorDay.prefix(4))] ?? 0
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                Button { store.step(-1, model) } label: { Image(systemName: "chevron.left").frame(width: 24, height: 20).contentShape(Rectangle()) }
                    .help(String(localized: "Previous", table: "Calendar"))
                Button { store.step(1, model) } label: { Image(systemName: "chevron.right").frame(width: 24, height: 20).contentShape(Rectangle()) }
                    .help(String(localized: "Next", table: "Calendar"))
            }
            .buttonStyle(.borderless)
            .font(.system(size: 13, weight: .semibold))
            Button(String(localized: "Today", table: "Calendar")) { store.today(model) }
                .buttonStyle(PillButtonStyle())
            Button { jumping = true } label: {
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 17, weight: .bold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Jump to a month or year", table: "Calendar"))
            .popover(isPresented: $jumping, arrowEdge: .bottom) {
                CalendarJump(model: model, store: store, level: level) { jumping = false }
            }
            if count > 0 {
                Text(CalendarText.shots(count)).font(Theme.count(12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Picker(String(localized: "Calendar", table: "Calendar"), selection: Binding(get: { level }, set: { store.setLevel($0, model) })) {
                ForEach(CalendarLevel.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(String(localized: "Zoom with ⌘= and ⌘− or pinch the trackpad", table: "Calendar"))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .glassBar()
        .padding(.horizontal, 14).padding(.bottom, 8)
    }
}

@MainActor
struct CalendarThumb: View {
    let item: Item
    let side: CGFloat
    let epoch: Int
    @State private var image: NSImage?
    @State private var shown = ""

    private var pixels: Int { Int((max(side, 16) / 32).rounded(.up) * 64) }

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill).frame(width: side, height: side)
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .task(id: "\(item.key)|\(item.mainPath)|\(item.mainAsset)|\(pixels)|\(epoch)") {
            let key = item.key
            if shown != key { image = CalendarThumbs.shared.cached(item, pixels: pixels, epoch: epoch) }
            CalendarThumbs.shared.image(for: item, pixels: pixels, epoch: epoch) { found in
                guard let found else { return }
                image = found
                shown = key
            }
        }
    }
}

@MainActor
struct CalendarDayCell: View {
    let key: String
    let day: CalendarDay?
    let side: CGFloat
    let epoch: Int
    let today: Bool
    let open: () -> Void

    var body: some View {
        let number = String(CalendarDate.dayNumber(key))
        if let day {
            ZStack {
                CalendarThumb(item: day.cover, side: side, epoch: epoch)
                LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .clear, location: 0.45)], startPoint: .top, endPoint: .bottom)
                Text(verbatim: number)
                    .font(.system(size: side >= 110 ? 15 : 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .padding(.horizontal, side >= 110 ? 9 : 6).padding(.vertical, side >= 110 ? 7 : 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if day.items.count > 1 {
                    Text(verbatim: String(day.items.count))
                        .font(Theme.count(10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .hudCapsule()
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .frame(width: side, height: side)
            .tileStyle(selected: today)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .help(CalendarText.tooltip(day))
        } else {
            Text(verbatim: number)
                .font(.system(size: side >= 110 ? 17 : 13, weight: today ? .bold : .medium, design: .rounded))
                .foregroundStyle(today ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .frame(width: side >= 110 ? 36 : 26, height: side >= 110 ? 36 : 26)
                .overlay { if today { Circle().strokeBorder(Color.accentColor, lineWidth: 2) } }
                .frame(width: side, height: side)
        }
    }
}

struct CalendarOffsets: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

@MainActor
struct CalendarMonths: View {
    @ObservedObject var model: Model
    @ObservedObject var store: CalendarStore
    @State private var settling = Date.distantFuture

    var body: some View {
        GeometryReader { outer in
            let gap: CGFloat = 6
            let side = min(220, floor((outer.size.width - 40 - 6 * gap) / 7))
            let width = 7 * side + 6 * gap
            let rows = store.index?.rows ?? []
            VStack(spacing: 4) {
                HStack(spacing: gap) {
                    ForEach(Array(CalendarText.weekdays.enumerated()), id: \.offset) { _, name in
                        Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: side)
                    }
                }
                .frame(maxWidth: .infinity)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 28) {
                            ForEach(rows) { row in
                                Group {
                                    switch row {
                                    case .month(let month):
                                        CalendarMonthBlock(model: model, store: store, index: store.index ?? CalendarIndex(), month: month, side: side, gap: gap, epoch: model.epoch)
                                    case .gap(let from, let to):
                                        Label(String(localized: "No shots from \(CalendarText.monthTitle(from)) to \(CalendarText.monthTitle(to))", table: "Calendar"), systemImage: "ellipsis")
                                            .font(.callout).foregroundStyle(.secondary)
                                            .padding(.horizontal, 14).padding(.vertical, 6)
                                            .glassCapsule()
                                            .frame(width: width)
                                    }
                                }
                                .id(row.id)
                                .background(GeometryReader { frame in
                                    Color.clear.preference(key: CalendarOffsets.self, value: [row.id: frame.frame(in: .named("calendar.months"))])
                                })
                            }
                        }
                        .frame(width: width)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                    }
                    .coordinateSpace(name: "calendar.months")
                    .onPreferenceChange(CalendarOffsets.self) { frames in track(frames, rows, height: outer.size.height) }
                    .onAppear { reveal(proxy, rows) }
                    .onChange(of: store.scrollTick) { _ in reveal(proxy, store.index?.rows ?? []) }
                }
            }
        }
    }

    private func track(_ frames: [String: CGRect], _ rows: [MonthRow], height: CGFloat) {
        guard Date() > settling, !frames.isEmpty else { return }
        var chosen: String?
        if let last = rows.last, case .month(let month) = last, let frame = frames[last.id], frame.maxY <= height + 4 {
            chosen = month
        } else {
            let line = height * 0.35
            for row in rows {
                guard case .month(let month) = row, let frame = frames[row.id] else { continue }
                if frame.minY <= line && frame.maxY > line { chosen = month }
            }
        }
        if let chosen { store.visibleMonth(chosen) }
    }

    private func reveal(_ proxy: ScrollViewProxy, _ rows: [MonthRow]) {
        let month = String(store.anchorDay.prefix(7))
        settling = Date().addingTimeInterval(0.6)
        guard let row = rows.first(where: { $0.covers(month) }) ?? (month > (rows.last?.id ?? "") ? rows.last : rows.first) else { return }
        let anchor: UnitPoint = row.id == rows.last?.id ? .bottom : .top
        DispatchQueue.main.async { proxy.scrollTo(row.id, anchor: anchor) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { proxy.scrollTo(row.id, anchor: anchor) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { proxy.scrollTo(row.id, anchor: anchor) }
    }
}

struct TripSegment: Identifiable {
    let trip: CalendarTrip
    let start: Int
    let end: Int
    let labeled: Bool
    var lane = 0
    var id: String { trip.id }
}

enum CalendarTint {
    static let palette: [Color] = [.orange, .teal, .pink, .indigo, .green, .purple, .blue, .red]
    static func color(_ trip: CalendarTrip) -> Color { palette[trip.tint % palette.count] }
}

@MainActor
struct CalendarMonthBlock: View {
    let model: Model
    let store: CalendarStore
    let index: CalendarIndex
    let month: String
    let side: CGFloat
    let gap: CGFloat
    let epoch: Int

    var body: some View {
        let lead = CalendarDate.leading(month)
        let count = CalendarDate.daysIn(month)
        let weeks = (lead + count + 6) / 7
        let today = CalendarDate.today
        VStack(alignment: .leading, spacing: gap) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(CalendarText.monthTitle(month)).font(.system(size: 22, weight: .bold))
                if let shots = index.months[month] {
                    Text(CalendarText.shots(shots)).font(Theme.count(13)).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 2).padding(.bottom, 4)
            ForEach(0..<weeks, id: \.self) { week in
                let keys: [String?] = (0..<7).map { column in
                    let number = week * 7 + column - lead + 1
                    return number >= 1 && number <= count ? String(month.prefix(7)) + String(format: "-%02d", number) : nil
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { column in
                            if let key = keys[column] {
                                CalendarDayCell(key: key, day: index.days[key], side: side, epoch: epoch, today: key == today) {
                                    store.openDay(key, model)
                                }
                            } else {
                                Color.clear.frame(width: side, height: side)
                            }
                        }
                    }
                    lanes(segments(keys))
                }
            }
        }
    }

    private func segments(_ keys: [String?]) -> [TripSegment] {
        let present = keys.enumerated().compactMap { offset, key in key.map { (offset, $0) } }
        guard let first = present.first, let last = present.last else { return [] }
        var out: [TripSegment] = []
        var lanes: [Int] = []
        for trip in index.trips where trip.to >= first.1 && trip.from <= last.1 {
            guard let start = present.first(where: { $0.1 >= trip.from })?.0, let end = present.last(where: { $0.1 <= trip.to })?.0, start <= end else { continue }
            let startKey = keys[start] ?? ""
            var segment = TripSegment(trip: trip, start: start, end: end, labeled: startKey == trip.from || startKey.hasSuffix("-01"))
            if let lane = lanes.firstIndex(where: { $0 < start }) {
                lanes[lane] = end
                segment.lane = lane
            } else {
                segment.lane = lanes.count
                lanes.append(end)
            }
            out.append(segment)
        }
        return out
    }

    @ViewBuilder
    private func lanes(_ segments: [TripSegment]) -> some View {
        if !segments.isEmpty {
            let laneCount = (segments.map { $0.lane }.max() ?? 0) + 1
            ZStack(alignment: .topLeading) {
                ForEach(segments) { segment in
                    let span = CGFloat(segment.end - segment.start + 1)
                    Capsule(style: .continuous)
                        .fill(CalendarTint.color(segment.trip).opacity(0.85))
                        .overlay(alignment: .leading) {
                            if segment.labeled {
                                Label(segment.trip.title, systemImage: "airplane")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .padding(.horizontal, 8)
                            }
                        }
                        .frame(width: span * side + (span - 1) * gap, height: 16)
                        .contentShape(Capsule(style: .continuous))
                        .onTapGesture { model.go(.tag("trip", segment.trip.id)) }
                        .help(segment.trip.title + " · " + Months.days(segment.trip.from, segment.trip.to))
                        .offset(x: CGFloat(segment.start) * (side + gap), y: CGFloat(segment.lane) * 20)
                }
            }
            .frame(width: 7 * side + 6 * gap, height: CGFloat(laneCount) * 20 - 4, alignment: .topLeading)
        }
    }
}

@MainActor
struct CalendarYear: View {
    @ObservedObject var model: Model
    @ObservedObject var store: CalendarStore

    var body: some View {
        GeometryReader { outer in
            let year = String(store.anchorDay.prefix(4))
            let gap: CGFloat = 26
            let (columns, side) = layout(outer.size, gap: gap)
            let width = side * 7 + 6 * 3
            let index = store.index ?? CalendarIndex()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: width), spacing: gap, alignment: .topLeading), count: columns), alignment: .leading, spacing: 24) {
                        ForEach(1...12, id: \.self) { m in
                            CalendarMiniMonth(model: model, store: store, index: index, month: String(year) + String(format: "-%02d", m), side: side, epoch: model.epoch)
                        }
                    }
                    if let loose = index.loose[year], !loose.isEmpty {
                        Button {
                            model.showItems(Set(loose), title: String(localized: "\(year) · without an exact date", table: "Calendar"))
                        } label: {
                            Label(String(localized: "\(loose.count) shots without an exact date", table: "Calendar"), systemImage: "calendar.badge.exclamationmark")
                        }
                        .buttonStyle(PillButtonStyle())
                        .help(String(localized: "Shots from this year whose day is not known", table: "Calendar"))
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func layout(_ size: CGSize, gap: CGFloat) -> (Int, CGFloat) {
        var best = (4, floor(((size.width - 48 - 3 * gap) / 4 - 18) / 7))
        var fitted: CGFloat = 0
        for columns in [4, 3, 6] {
            let rows = CGFloat(12 / columns)
            let byWidth = ((size.width - 48 - CGFloat(columns - 1) * gap) / CGFloat(columns) - 18) / 7
            let byHeight = ((size.height - 70 - (rows - 1) * 24) / rows - 80) / 6
            let side = floor(min(byWidth, byHeight, 64))
            if side > fitted + 2 {
                fitted = side
                if side >= 16 { best = (columns, side) }
            }
        }
        return best
    }
}

@MainActor
struct CalendarMiniMonth: View {
    let model: Model
    let store: CalendarStore
    let index: CalendarIndex
    let month: String
    let side: CGFloat
    let epoch: Int

    var body: some View {
        let lead = CalendarDate.leading(month)
        let count = CalendarDate.daysIn(month)
        let today = CalendarDate.today
        let thumbs = side >= 22
        VStack(alignment: .leading, spacing: 3) {
            Button { store.openMonth(month, model) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(CalendarText.monthName(month))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(today.hasPrefix(month) ? Color.accentColor : Color.primary)
                    if let shots = index.months[month] {
                        Text(verbatim: String(shots)).font(Theme.count(11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(CalendarText.monthTitle(month))
            .padding(.bottom, 3)
            HStack(spacing: 3) {
                ForEach(Array(CalendarText.tinyWeekdays.enumerated()), id: \.offset) { _, name in
                    Text(name).font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary).frame(width: side)
                }
            }
            ForEach(0..<6, id: \.self) { week in
                HStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { column in
                        let number = week * 7 + column - lead + 1
                        if number >= 1 && number <= count {
                            cell(String(month.prefix(7)) + String(format: "-%02d", number), number, today, thumbs)
                        } else {
                            Color.clear.frame(width: side, height: side)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ key: String, _ number: Int, _ today: String, _ thumbs: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: max(3, side / 7), style: .continuous)
        if let day = index.days[key] {
            ZStack {
                if thumbs {
                    CalendarThumb(item: day.cover, side: side, epoch: epoch)
                } else {
                    Rectangle().fill(Color.accentColor.opacity(0.25 + 0.7 * sqrt(Double(day.items.count) / Double(index.busiest))))
                }
                if side >= 30 || !thumbs {
                    Text(verbatim: String(number))
                        .font(.system(size: max(8, min(11, side * 0.32)), weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.7), radius: 1.5)
                }
            }
            .frame(width: side, height: side)
            .clipShape(shape)
            .overlay { if key == today { shape.inset(by: -2).strokeBorder(Color.accentColor, lineWidth: 2) } }
            .contentShape(shape)
            .onTapGesture { store.openDay(key, model) }
            .help(CalendarText.full(key) + " · " + CalendarText.tooltip(day))
        } else {
            Text(verbatim: String(number))
                .font(.system(size: max(8, min(12, side * 0.36)), weight: key == today ? .bold : .regular, design: .rounded))
                .foregroundStyle(key == today ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .frame(width: side, height: side)
                .overlay { if key == today { Circle().strokeBorder(Color.accentColor, lineWidth: 1.5) } }
        }
    }
}

@MainActor
struct CalendarWeek: View {
    @ObservedObject var model: Model
    @ObservedObject var store: CalendarStore

    var body: some View {
        GeometryReader { outer in
            let gap: CGFloat = 8
            let width = floor((outer.size.width - 28 - 6 * gap) / 7)
            let index = store.index ?? CalendarIndex()
            let today = CalendarDate.today
            HStack(alignment: .top, spacing: gap) {
                ForEach(CalendarDate.week(store.anchorDay), id: \.self) { key in
                    column(key, index.days[key], width: width, today: key == today)
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 12)
        }
    }

    private func column(_ key: String, _ day: CalendarDay?, width: CGFloat, today: Bool) -> some View {
        let inner = width - 12
        let place = day?.place ?? "", trip = day?.trip ?? ""
        let caption = trip.isEmpty ? place : (place.isEmpty || trip.contains(place) ? trip : place + " · " + trip)
        return VStack(spacing: 6) {
            VStack(spacing: 0) {
                Text(CalendarText.weekday(key)).font(.system(size: 11, weight: .semibold)).foregroundStyle(today ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                Text(verbatim: String(CalendarDate.dayNumber(key)))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(today ? AnyShapeStyle(Color.accentColor) : (day == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary)))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { if day != nil { store.openDay(key, model) } }
            VStack(spacing: 1) {
                Text(day.map { CalendarText.shots($0.items.count) } ?? String(localized: "No shots", table: "Calendar"))
                    .font(Theme.count(11)).foregroundStyle(.secondary)
                Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)
            .help(day.map(CalendarText.tooltip) ?? "")
            if let day {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        ForEach(day.items, id: \.key) { item in
                            CalendarThumb(item: item, side: inner, epoch: model.epoch)
                                .tileStyle(selected: false)
                                .contentShape(Rectangle())
                                .onTapGesture { store.openDay(key, model, select: item) }
                                .help(item.title)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(6)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(GlassPlate(radius: Theme.panelRadius))
    }
}

@MainActor
struct CalendarDayPage: View {
    @ObservedObject var model: Model
    let key: String

    private var chips: [(title: String, icon: String, scope: Scope)] {
        let ids = Set(model.flat.map { $0.id })
        guard !ids.isEmpty else { return [] }
        var out: [(title: String, icon: String, scope: Scope)] = []
        for (kind, icon) in [("trip", "airplane"), ("place", "mappin.and.ellipse"), ("person", "person.crop.circle"), ("pet", "pawprint")] {
            let hits = (model.tags[kind] ?? [:]).compactMap { name, members -> (String, Int)? in
                let overlap = members.intersection(ids).count
                return overlap > 0 ? (name, overlap) : nil
            }
            for (name, _) in hits.sorted(by: { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }) {
                out.append((Model.tagTitle(kind, name), icon, .tag(kind, name)))
            }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            let chips = self.chips
            if !chips.isEmpty {
                Flow(spacing: 6) {
                    ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                        Button { model.go(chip.scope) } label: { Label(chip.title, systemImage: chip.icon).lineLimit(1) }
                            .buttonStyle(PillButtonStyle())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 6)
            }
            if model.flat.isEmpty {
                Label(String(localized: "No shots on this day", table: "Calendar"), systemImage: "calendar")
                    .font(.title3).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Grid(model: model)
            }
        }
    }
}

@MainActor
struct CalendarJump: View {
    let model: Model
    @ObservedObject var store: CalendarStore
    let level: CalendarLevel
    let done: () -> Void
    @State private var year: Int

    init(model: Model, store: CalendarStore, level: CalendarLevel, done: @escaping () -> Void) {
        self.model = model
        self.store = store
        self.level = level
        self.done = done
        _year = State(initialValue: Int(store.anchorDay.prefix(4)) ?? Calendar.current.component(.year, from: Date()))
    }

    var body: some View {
        let index = store.index
        let current = Int(CalendarDate.today.prefix(4)) ?? year
        let first = index?.ordered.first.flatMap { Int($0.prefix(4)) } ?? current
        let last = max(current, index?.ordered.last.flatMap { Int($0.prefix(4)) } ?? current)
        let years = Array((min(first, year)...max(last, year)).reversed())
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button { year -= 1 } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Text(verbatim: String(year)).font(.system(size: 17, weight: .bold)).monospacedDigit()
                Button { year += 1 } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
                Spacer()
                if let shots = index?.years[String(year)] {
                    Text(CalendarText.shots(shots)).font(Theme.count(11)).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(1...12, id: \.self) { m in
                    let month = CalendarDate.month(year, m)
                    let has = index?.months[month] != nil
                    Button {
                        store.jump(month, model)
                        done()
                    } label: {
                        Text(CalendarText.shortMonths[safe: m - 1] ?? String(m))
                            .font(.system(size: 12, weight: store.anchorDay.hasPrefix(month) ? .bold : .medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                            .background(Capsule(style: .continuous).fill(store.anchorDay.hasPrefix(month) ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06)))
                            .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .opacity(has ? 1 : 0.35)
                }
            }
            Divider()
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                    ForEach(years, id: \.self) { y in
                        Button {
                            year = y
                            if level == .year {
                                store.jumpYear(String(y), model)
                                done()
                            }
                        } label: {
                            Text(verbatim: String(y))
                                .font(Theme.count(12, weight: y == year ? .bold : .regular))
                                .frame(maxWidth: .infinity).padding(.vertical, 4)
                                .background(Capsule(style: .continuous).fill(y == year ? Color.accentColor.opacity(0.22) : Color.clear))
                                .contentShape(Capsule(style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .opacity(index?.years[String(y)] != nil ? 1 : 0.35)
                    }
                }
            }
            .frame(maxHeight: 140)
        }
        .padding(14)
        .frame(width: 300)
    }
}
