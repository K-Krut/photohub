import AppKit
import SwiftUI

enum Chrome {
    @MainActor
    static func style(_ window: NSWindow?) {
        guard let window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
    }

    @MainActor
    static func styleSettings(_ window: NSWindow?) {
        guard let window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
    }
}

struct FloatingBars: View {
    @ObservedObject var model: Model

    var body: some View {
        let crumbs = model.viewing ? nil : model.crumbs
        let filters = model.isBrowsing && !model.viewing
        let sorting = !model.isBrowsing && model.scope != .home && model.scope != .map && model.scope != .statistics
        if crumbs != nil || filters || sorting {
            VStack(alignment: .leading, spacing: 8) {
                if let crumbs { Breadcrumbs(model: model, crumbs: crumbs) }
                if filters {
                    FilterBar(model: model)
                    if model.scope == .kind(.photosExports) { ExportBar(model: model) }
                } else if sorting {
                    CardSortBar(model: model)
                }
            }
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 6)
        }
    }
}
