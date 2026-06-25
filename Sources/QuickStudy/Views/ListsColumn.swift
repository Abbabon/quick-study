import SwiftUI
import AppKit
import Shared

/// Collapsible right column for managing card Lists. ~252pt fixed width with a hairline
/// leading separator (added by the caller). Mirrors `RecentlyAddedColumn`'s shape: a
/// header, a divider, then a scrolling body. Tapping a list makes it active and expands
/// its cards inline; the active list's cards can be dragged to reorder.
struct ListsColumn: View {
    @ObservedObject var model: AppModel
    @AppStorage(UIScale.storageKey) private var uiScaleValue: Double = UIScale.defaultValue

    var body: some View {
        let scale = UIScale(value: uiScaleValue)
        VStack(alignment: .leading, spacing: 0) {
            header(scale: scale)
            Divider().opacity(0.5)
            if model.lists.isEmpty {
                emptyState(scale: scale)
            } else {
                listBody(scale: scale)
            }
        }
        .frame(width: scale.size(252))
    }

    private func header(scale: UIScale) -> some View {
        HStack(spacing: scale.pad(6)) {
            Image(systemName: "list.bullet")
                .font(scale.font(15))
                .foregroundStyle(.secondary)
            Text("Lists")
                .font(scale.font(13, weight: .semibold))
            Spacer(minLength: 0)
            Button {
                model.createList()
            } label: {
                Image(systemName: "plus")
                    .font(scale.font(14, weight: .medium))
                    .foregroundStyle(DS.accent)
                    .frame(width: scale.size(24), height: scale.size(24))
                    .contentShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
            }
            .buttonStyle(.plain)
            .help("New list")
        }
        .padding(EdgeInsets(top: scale.pad(10), leading: scale.pad(12),
                            bottom: scale.pad(6), trailing: scale.pad(8)))
    }

    private func emptyState(scale: UIScale) -> some View {
        VStack(spacing: scale.pad(10)) {
            Text("No lists yet")
                .font(scale.font(13))
                .foregroundStyle(.secondary)
            Button("New List") { model.createList() }
                .controlSize(.small)
            Text("Add cards from search results or the card preview.")
                .font(scale.font(11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(scale.pad(16))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func listBody(scale: UIScale) -> some View {
        List {
            ForEach(model.lists) { list in
                ListHeaderRow(
                    model: model,
                    list: list,
                    expanded: list.id == model.activeListID,
                    scale: scale
                )
                .listRowInsets(EdgeInsets(top: scale.pad(2), leading: scale.pad(6),
                                          bottom: scale.pad(2), trailing: scale.pad(6)))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

                if list.id == model.activeListID {
                    if model.activeListCards.isEmpty {
                        Text("Empty — add cards from search.")
                            .font(scale.font(11))
                            .foregroundStyle(.tertiary)
                            .listRowInsets(EdgeInsets(top: scale.pad(2), leading: scale.pad(28),
                                                      bottom: scale.pad(6), trailing: scale.pad(6)))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(model.activeListCards, id: \.id) { mini in
                            ListCardRow(model: model, listID: list.id, mini: mini, scale: scale)
                                .listRowInsets(EdgeInsets(top: scale.pad(1), leading: scale.pad(16),
                                                          bottom: scale.pad(1), trailing: scale.pad(6)))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                        .onMove { source, dest in
                            model.moveCard(in: list.id, fromOffsets: source, toOffset: dest)
                        }
                        .onDelete { offsets in
                            for i in offsets {
                                model.removeCard(model.activeListCards[i].id, fromList: list.id)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, scale.size(1))
    }
}

/// A list's header row: disclosure chevron, name (or inline-rename field), and count.
/// Tapping toggles active/expanded; right-click offers rename/delete.
private struct ListHeaderRow: View {
    @ObservedObject var model: AppModel
    let list: CardList
    let expanded: Bool
    let scale: UIScale

    @State private var hovering = false
    @State private var draftName = ""
    @FocusState private var renameFocused: Bool

    private var isRenaming: Bool { model.renamingListID == list.id }

    var body: some View {
        HStack(spacing: scale.pad(6)) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(scale.font(10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: scale.size(12))
            if isRenaming {
                TextField("List name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(scale.font(13, weight: .medium))
                    .focused($renameFocused)
                    .onSubmit { commitRename() }
                    .onChange(of: renameFocused) { _, focused in
                        if !focused { commitRename() }
                    }
            } else {
                Text(list.name)
                    .font(scale.font(13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: scale.pad(4))
                Text("\(list.itemCount)")
                    .font(scale.font(11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, scale.pad(8))
        .padding(.vertical, scale.pad(5))
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.sm)
                .fill(expanded ? DS.selection : (hovering ? Color.primary.opacity(0.045) : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isRenaming else { return }
            model.setActiveList(expanded ? nil : list.id)
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename") { startRename() }
            Button("Delete List", role: .destructive) { model.deleteList(list.id) }
        }
        .onChange(of: model.renamingListID) { _, id in
            if id == list.id { startRename() }
        }
        .onAppear {
            if isRenaming { startRename() }
        }
    }

    private func startRename() {
        draftName = list.name
        model.setActiveList(list.id)
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename() {
        defer { if model.renamingListID == list.id { model.renamingListID = nil } }
        guard isRenaming else { return }
        model.renameList(list.id, to: draftName)
    }
}

/// One card inside an expanded list: thumbnail + name, tap to preview, remove via the
/// trailing button (on hover) or the context menu. Draggable for reorder (via `.onMove`).
private struct ListCardRow: View {
    @ObservedObject var model: AppModel
    let listID: String
    let mini: Card.Mini
    let scale: UIScale

    @State private var hovering = false

    var body: some View {
        HStack(spacing: scale.pad(8)) {
            Thumbnail(id: mini.id, identity: mini.identity)
                .frame(width: scale.size(24), height: scale.size(34))
            Text(mini.name)
                .font(scale.font(13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: scale.pad(2))
            if hovering {
                Button {
                    model.removeCard(mini.id, fromList: listID)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(scale.font(12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from list")
            }
        }
        .padding(.horizontal, scale.pad(6))
        .padding(.vertical, scale.pad(3))
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.sm)
                .fill(mini.id == model.selectedID ? DS.selection
                      : (hovering ? Color.primary.opacity(0.045) : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { model.select(mini.id) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Remove from list", role: .destructive) {
                model.removeCard(mini.id, fromList: listID)
            }
        }
    }
}
