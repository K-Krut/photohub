import AppKit
import SwiftUI

enum Theme {
    static let cardRadius: CGFloat = 16
    static let tileRadius: CGFloat = 8
    static let panelRadius: CGFloat = 14
    static let barRadius: CGFloat = 12
    static let sectionInset: CGFloat = 12
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.78)
    static let snapshot = ProcessInfo.processInfo.environment["PHOTOHUB_SNAPSHOT"] != nil

    static func count(_ size: CGFloat = 12, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var dark = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        update(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) { update(view) }

    private func update(_ view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = blending
        view.state = Theme.snapshot ? .active : .followsWindowActiveState
        view.appearance = dark ? NSAppearance(named: .vibrantDark) : nil
    }
}

private struct TileActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var tileActive: Bool {
        get { self[TileActiveKey.self] }
        set { self[TileActiveKey.self] = newValue }
    }
}

struct GlassStroke<S: InsettableShape>: View {
    let shape: S
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        shape.strokeBorder(
            LinearGradient(colors: scheme == .dark ? [.white.opacity(0.22), .white.opacity(0.05)] : [.white.opacity(0.9), .black.opacity(0.07)],
                           startPoint: .top, endPoint: .bottom),
            lineWidth: 0.75)
    }
}

private struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    var material: Material = .regularMaterial
    var shadow: CGFloat = 10
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(material, in: shape)
            .overlay(GlassStroke(shape: shape))
            .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.10), radius: shadow, y: shadow / 3)
    }
}

private struct HUDSurface<S: InsettableShape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        content
            .background(shape.fill(Color.white.opacity(0.07)))
            .background(VisualEffect(material: .hudWindow, blending: .withinWindow, dark: true).clipShape(shape))
            .overlay(GlassStroke(shape: shape))
            .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    func glassCard(radius: CGFloat = Theme.panelRadius) -> some View {
        modifier(GlassSurface(shape: RoundedRectangle(cornerRadius: radius, style: .continuous)))
    }

    func glassBar(radius: CGFloat = Theme.barRadius) -> some View {
        modifier(GlassSurface(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), material: .thinMaterial, shadow: 8))
    }

    func glassCapsule() -> some View {
        modifier(GlassSurface(shape: Capsule(style: .continuous), material: .thinMaterial, shadow: 6))
    }

    func hudPanel(radius: CGFloat = Theme.panelRadius) -> some View {
        modifier(HUDSurface(shape: RoundedRectangle(cornerRadius: radius, style: .continuous)))
    }

    func hudCapsule() -> some View {
        modifier(HUDSurface(shape: Capsule(style: .continuous)))
    }

    func glassSidebar() -> some View {
        background(GlassPane().ignoresSafeArea())
            .overlay(alignment: .leading) { GlassEdge().ignoresSafeArea() }
    }

    func glassSidebarColumn() -> some View {
        scrollContentBackground(.hidden)
            .background(GlassPane().ignoresSafeArea())
    }

    func glassToolbar() -> some View {
        toolbarBackground(.hidden, for: .windowToolbar)
            .overlay(alignment: .top) { ToolbarGlass() }
    }

    @ViewBuilder func unclippedScroll() -> some View {
        if #available(macOS 14.0, *) {
            scrollClipDisabled()
        } else {
            self
        }
    }

    func glassDetail() -> some View {
        background {
            ZStack {
                VisualEffect(material: .underWindowBackground)
                LinearGradient(colors: [Color.accentColor.opacity(0.07), .clear, Color.purple.opacity(0.035)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .ignoresSafeArea()
        }
    }

    func tileStyle(selected: Bool, radius: CGFloat = Theme.tileRadius) -> some View {
        modifier(TileChrome(selected: selected, radius: radius))
    }

    func selectionRing(_ selected: Bool, radius: CGFloat = Theme.tileRadius) -> some View {
        overlay {
            if selected {
                RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
                    .padding(-3)
                    .shadow(color: Color.accentColor.opacity(0.6), radius: 6)
            }
        }
        .animation(Theme.spring, value: selected)
    }

    func glassSection(_ id: String) -> some View {
        anchorPreference(key: GlassSectionKey.self, value: .bounds) { [id: [$0]] }
    }

    func glassSections(inset: CGFloat = Theme.sectionInset, radius: CGFloat = Theme.panelRadius) -> some View {
        backgroundPreferenceValue(GlassSectionKey.self) { sections in
            GeometryReader { proxy in
                ForEach(sections.keys.sorted(), id: \.self) { id in
                    if let frame = sections[id]?.map({ proxy[$0] }).reduce(nil, { (union: CGRect?, next: CGRect) in union?.union(next) ?? next }) {
                        GlassPlate(radius: radius)
                            .frame(width: proxy.size.width + inset * 2, height: frame.height + inset * 2)
                            .offset(x: -inset, y: frame.minY - inset)
                    }
                }
            }
        }
    }
}

struct TileChrome: ViewModifier {
    let selected: Bool
    let radius: CGFloat
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .environment(\.tileActive, selected || hover)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
            .selectionRing(selected, radius: radius)
            .shadow(color: .black.opacity(hover ? 0.32 : 0.0), radius: hover ? 10 : 0, y: hover ? 5 : 0)
            .scaleEffect(hover ? 1.035 : 1)
            .zIndex(hover ? 1 : 0)
            .animation(Theme.spring, value: hover)
            .onHover { hover = $0 }
    }
}

struct GlassPlate: View {
    var radius: CGFloat = Theme.panelRadius
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape.fill(Color.primary.opacity(scheme == .dark ? 0.06 : 0.035))
            .background(.thinMaterial, in: shape)
            .overlay(GlassStroke(shape: shape))
            .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0.06), radius: 6, y: 2)
    }
}

struct GlassPane: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            VisualEffect(material: .popover)
            LinearGradient(colors: scheme == .dark ? [.black.opacity(0.06), .black.opacity(0.16)] : [.white.opacity(0.18), .white.opacity(0.08)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}

struct GlassEdge: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Rectangle().fill(scheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.55))
            .frame(width: 1)
            .overlay(alignment: .leading) { Rectangle().fill(Color.black.opacity(scheme == .dark ? 0.35 : 0.06)).frame(width: 0.5) }
    }
}

struct ToolbarGlass: View {
    var body: some View {
        GeometryReader { proxy in
            let height = proxy.safeAreaInsets.top
            Rectangle().fill(.regularMaterial)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.75), location: 0.7), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(height: height + 14)
                .offset(y: -height)
                .opacity(height > 0 ? 1 : 0)
        }
        .allowsHitTesting(false)
    }
}

struct GlassSectionKey: PreferenceKey {
    static var defaultValue: [String: [Anchor<CGRect>]] = [:]

    static func reduce(value: inout [String: [Anchor<CGRect>]], nextValue: () -> [String: [Anchor<CGRect>]]) {
        value.merge(nextValue()) { $0 + $1 }
    }
}

struct GlassGap: View {
    var body: some View { Color.clear.frame(height: 14) }
}

struct ChipDivider: View {
    var body: some View {
        Capsule().fill(Color.primary.opacity(0.14)).frame(width: 1, height: 16)
    }
}

struct GlassChipMenuStyle: MenuStyle {
    func makeBody(configuration: Configuration) -> some View {
        Menu(configuration)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.leading, 10).padding(.trailing, 7).padding(.vertical, 4)
            .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
    }
}

struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.22 : 0.12), in: Capsule(style: .continuous))
            .glassCapsule()
            .contentShape(Capsule(style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.spring, value: configuration.isPressed)
    }
}

struct WrapLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        var rowStart = 0
        func closeRow() {
            for index in rowStart..<frames.count { frames[index].origin.y = y + (row - frames[index].height) / 2 }
        }
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                closeRow()
                x = 0
                y += row + lineSpacing
                row = 0
                rowStart = frames.count
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            widest = max(widest, x - spacing)
            row = max(row, size.height)
        }
        closeRow()
        return (CGSize(width: widest, height: y + row), frames)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let size = arrange(width, subviews).size
        return CGSize(width: proposal.width.map { min($0, max(size.width, 0)) } ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(bounds.width, subviews).frames
        for (view, frame) in zip(subviews, frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
}

struct PhotoCard<Cover: View>: View {
    let title: String
    let subtitle: String
    let width: CGFloat
    let height: CGFloat
    var symbol: String?
    var palette: Palette?
    @ViewBuilder let cover: () -> Cover
    @State private var hover = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        ZStack(alignment: .bottomLeading) {
            cover().frame(width: width, height: height).clipped()
            LinearGradient(stops: [.init(color: .clear, location: 0.38),
                                   .init(color: (palette?.deep ?? Color(white: 0.06)).opacity(0.45), location: 0.68),
                                   .init(color: (palette?.deep ?? Color(white: 0.06)).opacity(0.8), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                if !subtitle.isEmpty {
                    Text(subtitle).font(Theme.count(11)).opacity(0.85).lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
            .padding(.horizontal, 11).padding(.vertical, 9)
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                    .padding(6)
                    .hudCapsule()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
            }
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay(GlassStroke(shape: shape))
        .background { glow(shape) }
        .shadow(color: (palette?.deep ?? .black).opacity(scheme == .dark ? (hover ? 0.55 : 0.4) : (hover ? 0.26 : 0.14)), radius: hover ? 14 : 8, y: hover ? 8 : 4)
        .scaleEffect(hover ? 1.025 : 1)
        .animation(Theme.spring, value: hover)
        .animation(.easeOut(duration: 0.45), value: palette)
        .contentShape(shape)
        .onHover { hover = $0 }
    }

    @ViewBuilder private func glow(_ shape: RoundedRectangle) -> some View {
        if let palette {
            let strength = scheme == .dark ? (hover ? 0.95 : 0.8) : (hover ? 0.85 : 0.7)
            shape.fill(LinearGradient(colors: palette.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .padding(6)
                .shadow(color: palette.colors[0].opacity(strength), radius: hover ? 17 : 13, x: -6, y: hover ? 13 : 10)
                .shadow(color: palette.colors[2].opacity(strength * 0.85), radius: hover ? 19 : 14, x: 6, y: hover ? 15 : 12)
                .transition(.opacity)
        }
    }
}
