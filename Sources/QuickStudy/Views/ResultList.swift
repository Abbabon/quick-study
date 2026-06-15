import SwiftUI
import AppKit
import Shared

struct ResultList: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.results, id: \.id) { mini in
                        Row(mini: mini, selected: mini.id == model.selectedID) {
                            model.select(mini.id)
                        }
                        .id(mini.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: model.selectedID) { _, id in
                if let id = id {
                    withAnimation(DS.Motion.selectScroll) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private struct Row: View {
        let mini: Card.Mini
        let selected: Bool
        let onTap: () -> Void
        @AppStorage(UIScale.storageKey) private var uiScaleValue: Double = UIScale.defaultValue

        var body: some View {
            let scale = UIScale(value: uiScaleValue)
            return HStack(spacing: scale.pad(10)) {
                Thumbnail(id: mini.id, identity: mini.identity)
                    .frame(width: scale.size(28), height: scale.size(40))
                Text(mini.name)
                    .lineLimit(1)
                    .font(scale.font(14))
                Spacer(minLength: 4)
            }
            .padding(.horizontal, scale.pad(10))
            .padding(.vertical, scale.pad(4))
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm)
                    .fill(selected ? DS.selectionStrong : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
        }
    }
}
