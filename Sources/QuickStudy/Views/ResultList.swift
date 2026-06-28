import SwiftUI
import AppKit
import Shared

struct ResultList: View {
    @ObservedObject var model: AppModel
    @AppStorage(UIScale.storageKey) private var uiScaleValue: Double = UIScale.defaultValue

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.results, id: \.id) { mini in
                            Row(model: model, mini: mini, selected: mini.id == model.selectedID) {
                                model.select(mini.id, immediate: true)
                                // Clicking a row pulls focus off the search field; restore it so
                                // ↑↓ keep navigating the list after a card is picked.
                                model.focusSearchField()
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
            countFooter
        }
    }

    private var countFooter: some View {
        let scale = UIScale(value: uiScaleValue)
        let total = model.totalMatchCount
        let shown = model.results.count
        let label = total > shown
            ? "\(shown) of \(total)"
            : "\(total) result\(total == 1 ? "" : "s")"
        return VStack(spacing: 0) {
            Divider().opacity(0.2)
            Text(label)
                .font(scale.font(11))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, scale.pad(12))
                .padding(.vertical, scale.pad(6))
        }
    }

    private struct Row: View {
        // Plain reference, not @ObservedObject: the row's visible content depends only on
        // `mini`/`selected`, and the context menu (the sole model-dependent part) is rebuilt
        // each time it opens. Observing the whole model here made every keystroke — which
        // republishes `query`/`results` — re-invalidate every visible row.
        let model: AppModel
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
                RarityBadge(rarity: mini.rarity, size: scale.size(15))
            }
            .padding(.horizontal, scale.pad(10))
            .padding(.vertical, scale.pad(4))
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm)
                    .fill(selected ? DS.selectionStrong : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .contextMenu {
                ForEach(model.lists) { list in
                    Button("Add to \(list.name)") { model.addCard(mini.id, toList: list.id) }
                }
                Button("Add to new list…") {
                    model.addToNewList(mini.id)
                    if !model.listsColumnVisible { model.toggleListsColumn() }
                }
                Divider()
                Button(model.isPinned(mini.id) ? "Unpin" : "Pin") { model.togglePin(mini) }
            }
        }
    }
}
