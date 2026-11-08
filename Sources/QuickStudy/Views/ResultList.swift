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
                        // Rows are keyed by position, not card id. Typing replaces most of the
                        // results on every keystroke, and refilling the same row slots is far
                        // cheaper than building new row subgraphs (~0.35 ms each): per-keystroke
                        // render p90 12.5 ms -> 6.8 ms. Also lets scrollTo use the index directly.
                        ForEach(model.results.indices, id: \.self) { i in
                            let mini = model.results[i]
                            Row(model: model, mini: mini, selected: mini.id == model.selectedID,
                                scaleValue: uiScaleValue) {
                                model.select(mini.id, immediate: true)
                                // Clicking a row pulls focus off the search field; restore it so
                                // ↑↓ keep navigating the list after a card is picked.
                                model.focusSearchField()
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: model.selectedID) { _, id in
                    if let i = model.results.firstIndex(where: { $0.id == id }) {
                        withAnimation(DS.Motion.selectScroll) {
                            proxy.scrollTo(i, anchor: .center)
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
        /// Passed in rather than an `@AppStorage` per row (one defaults observer per row).
        let scaleValue: Double
        let onTap: () -> Void

        var body: some View {
            let scale = UIScale(value: scaleValue)
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
