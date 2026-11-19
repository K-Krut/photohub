import AppKit
import SwiftUI

struct Palette: Equatable, Codable {
    let rgb: [[Double]]

    var colors: [Color] { rgb.map { Color(.sRGB, red: $0[0], green: $0[1], blue: $0[2]) } }
    var primary: Color { colors[0] }

    var deep: Color {
        let (h, s, _) = Palette.hsb(rgb[0])
        let (r, g, b) = Palette.rgb(h, min(1, s * 1.1 + 0.08), 0.2)
        return Color(.sRGB, red: r, green: g, blue: b)
    }

    static func extract(_ image: CGImage) -> Palette? {
        let side = 24
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &bytes, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var points: [SIMD3<Double>] = []
        points.reserveCapacity(side * side)
        for index in stride(from: 0, to: bytes.count, by: 4) where bytes[index + 3] > 0 {
            points.append(SIMD3(Double(bytes[index]), Double(bytes[index + 1]), Double(bytes[index + 2])) / 255)
        }
        guard points.count >= 8 else { return nil }
        let sorted = points.sorted { luma($0) < luma($1) }
        let k = 4
        var centers: [SIMD3<Double>] = []
        for index in 0..<k {
            let position: Int = (2 * index + 1) * sorted.count / (2 * k)
            centers.append(sorted[min(sorted.count - 1, position)])
        }
        var counts = [Int](repeating: 0, count: k)
        for _ in 0..<8 {
            var sums = [SIMD3<Double>](repeating: .zero, count: k)
            counts = [Int](repeating: 0, count: k)
            for point in points {
                var best = 0, bestDistance = Double.infinity
                for (index, center) in centers.enumerated() {
                    let delta: SIMD3<Double> = point - center
                    let distance: Double = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z
                    if distance < bestDistance { best = index; bestDistance = distance }
                }
                sums[best] += point
                counts[best] += 1
            }
            for index in 0..<k where counts[index] > 0 { centers[index] = sums[index] / Double(counts[index]) }
        }
        let ranked = (0..<k).filter { counts[$0] > 0 }.sorted { score(centers[$0], counts[$0]) > score(centers[$1], counts[$1]) }
        var picked = ranked.prefix(3).map { boost(centers[$0]) }
        while picked.count < 3 { picked.append(picked.last ?? [0.5, 0.5, 0.5]) }
        return Palette(rgb: picked)
    }

    private static func luma(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    private static func score(_ c: SIMD3<Double>, _ count: Int) -> Double {
        let (_, s, v) = hsb([c.x, c.y, c.z])
        return Double(count) * (0.35 + s) * (0.3 + min(v, 0.85))
    }

    private static func boost(_ c: SIMD3<Double>) -> [Double] {
        let (h, s, v) = hsb([c.x, c.y, c.z])
        let (r, g, b) = rgb(h, min(1, s * 1.6 + 0.1), min(0.86, max(0.4, v * 1.05)))
        return [r, g, b]
    }

    static func hsb(_ c: [Double]) -> (Double, Double, Double) {
        let maxV = max(c[0], c[1], c[2]), minV = min(c[0], c[1], c[2]), delta = maxV - minV
        var h = 0.0
        if delta > 0 {
            if maxV == c[0] { h = (c[1] - c[2]) / delta + (c[1] < c[2] ? 6 : 0) }
            else if maxV == c[1] { h = (c[2] - c[0]) / delta + 2 }
            else { h = (c[0] - c[1]) / delta + 4 }
            h /= 6
        }
        return (h, maxV == 0 ? 0 : delta / maxV, maxV)
    }

    static func rgb(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}

final class PaletteStore {
    static let shared = PaletteStore()

    private var memory: [String: Palette] = [:]
    private var waiting: [String: [(Palette) -> Void]] = [:]
    private var saveScheduled = false
    private let queue = DispatchQueue(label: "photohub.palette", qos: .utility)
    private let file = AppPaths.support.appendingPathComponent("palettes.json")

    private init() {
        if let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode([String: Palette].self, from: data) {
            memory = stored
        }
    }

    static func key(_ item: Item) -> String { "\(item.key)|\(item.mainAsset)|\(item.mainPath)|\(item.thumbAsset)|\(item.thumbPath)" }

    func cached(_ item: Item?) -> Palette? {
        guard let item else { return nil }
        return memory[PaletteStore.key(item)]
    }

    func palette(for item: Item, side: CGFloat, completion: @escaping (Palette) -> Void) {
        let key = PaletteStore.key(item)
        if let hit = memory[key] {
            completion(hit)
            return
        }
        if waiting[key] != nil {
            waiting[key]?.append(completion)
            return
        }
        waiting[key] = [completion]
        Thumbs.shared.image(for: item, side: side) { [weak self] image in
            guard let self else { return }
            guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                self.waiting[key] = nil
                return
            }
            self.queue.async {
                let palette = Palette.extract(cg)
                DispatchQueue.main.async {
                    let callbacks = self.waiting.removeValue(forKey: key) ?? []
                    guard let palette else { return }
                    self.memory[key] = palette
                    self.scheduleSave()
                    callbacks.forEach { $0(palette) }
                }
            }
        }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            let snapshot = self.memory
            let file = self.file
            self.queue.async {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                try? data.write(to: file, options: .atomic)
            }
        }
    }
}

struct PaletteReader<Content: View>: View {
    let item: Item?
    let side: CGFloat
    @ViewBuilder let content: (Palette?) -> Content
    @State private var found: KeyedPalette?

    var body: some View {
        let key = item.map(PaletteStore.key)
        content(found?.key == key ? found?.palette : PaletteStore.shared.cached(item))
            .task(id: key) {
                guard let item, let key else { return }
                PaletteStore.shared.palette(for: item, side: side) { palette in
                    if found != KeyedPalette(key: key, palette: palette) { found = KeyedPalette(key: key, palette: palette) }
                }
            }
    }
}

struct KeyedPalette: Equatable {
    let key: String
    let palette: Palette
}

struct CollectionBanner: View {
    let item: Item
    let epoch: Int
    @State private var shown: (key: String, image: NSImage)?
    @State private var found: KeyedPalette?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let tint = found?.key == PaletteStore.key(item) ? found?.palette : PaletteStore.shared.cached(item)
        ZStack(alignment: .top) {
            if let tint {
                LinearGradient(stops: [.init(color: tint.colors[0].opacity(scheme == .dark ? 0.42 : 0.42), location: 0),
                                       .init(color: tint.colors[1].opacity(scheme == .dark ? 0.26 : 0.26), location: 0.5),
                                       .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .transition(.opacity)
            }
            if let shown {
                Image(nsImage: shown.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
                    .scaleEffect(1.25)
                    .blur(radius: 44)
                    .saturation(1.35)
                    .opacity(scheme == .dark ? 0.6 : 0.62)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.8), location: 0.4), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .id(shown.key)
                    .transition(.opacity)
            }
        }
        .frame(height: 420)
        .clipped()
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task(id: PaletteStore.key(item) + "-\(epoch)") {
            let key = PaletteStore.key(item)
            Thumbs.shared.image(for: item, side: 400) { image in
                guard let image, shown?.key != key else { return }
                withAnimation(.easeInOut(duration: 0.45)) { shown = (key, image) }
            }
            PaletteStore.shared.palette(for: item, side: 400) { palette in
                let next = KeyedPalette(key: key, palette: palette)
                if found != next { withAnimation(.easeInOut(duration: 0.45)) { found = next } }
            }
        }
    }
}
