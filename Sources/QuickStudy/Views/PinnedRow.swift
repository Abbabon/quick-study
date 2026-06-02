import SwiftUI
import AppKit
import Shared

/// Horizontal strip of pinned cards shown at the bottom of the panel.
/// Clicking an entry previews that card; each entry has its own unpin control.
struct PinnedRow: View {
    @ObservedObject var model: AppModel
    @AppStorage(UIScale.storageKey) private var uiScaleValue: Double = UIScale.defaultValue

    var body: some View {
        let scale = UIScale(value: uiScaleValue)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: scale.pad(10)) {
                ForEach(model.pinned, id: \.id) { mini in
                    entry(mini, scale: scale)
                }
            }
            .padding(.horizontal, scale.pad(14))
            .padding(.vertical, scale.pad(8))
        }
    }

    private func entry(_ mini: Card.Mini, scale: UIScale) -> some View {
        let selected = mini.id == model.selectedID
        return VStack(spacing: scale.pad(4)) {
            Thumbnail(id: mini.id)
                .frame(width: scale.size(44), height: scale.size(62))
            Text(mini.name)
                .font(scale.font(10))
                .lineLimit(1)
                .frame(maxWidth: scale.size(64))
        }
        .padding(scale.pad(6))
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.25) : .clear)
        )
        .overlay(alignment: .topTrailing) {
            Button {
                model.unpin(mini.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(scale.font(13))
                    .foregroundStyle(.secondary)
                    .background(Circle().fill(.background))
            }
            .buttonStyle(.plain)
            .help("Unpin")
            .padding(scale.pad(2))
        }
        .contentShape(Rectangle())
        .onTapGesture { model.select(mini.id) }
    }
}
