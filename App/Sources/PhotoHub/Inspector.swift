import SwiftUI

struct NoSelectionPanel: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text("No Selection").font(.title3).bold().foregroundStyle(.secondary)
            Text("Click a shot to see its versions, files, rating and label here.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
