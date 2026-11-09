import SwiftUI
import AppKit
import EngineBindings
import Shared

/// Collapsible left column listing the most recently ingested cards.
/// 222pt fixed width with a hairline trailing separator; body shows ~6 rows
/// and scrolls for the rest of the 30-day window.
///
/// Not an observer of the model (see `ListsColumn`): `Equatable` on what it shows, so typing
/// doesn't re-render its 200 rows. `model` is only used for actions and the "new" cutoff.
struct RecentlyAddedColumn: View, Equatable {
    let model: AppModel
    let recents: [Card.Recent]
    /// When non-nil, the column lists these sets (newest first) instead of the recent cards.
    let sets: [SetRow]?
    /// The selected card's id when it is one of `recents` (else nil).
    let highlightedID: String?

    static func == (a: Self, b: Self) -> Bool {
        a.recents == b.recents && a.sets == b.sets && a.highlightedID == b.highlightedID
    }
    @AppStorage(UIScale.storageKey) private var uiScaleValue: Double = UIScale.defaultValue

    var body: some View {
        let scale = UIScale(value: uiScaleValue)
        VStack(alignment: .leading, spacing: 0) {
            header(scale: scale)
            Divider().opacity(0.5)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: scale.pad(1)) {
                    if let sets {
                        ForEach(sets, id: \.code) { s in SetListRow(info: s) { model.searchSet(s.code) } }
                    } else {
                    ForEach(recents) { recent in
                        RecentRow(
                            recent: recent,
                            isNew: model.isNew(recent),
                            selected: recent.id == highlightedID
                        ) {
                            if recent.id == highlightedID { model.goHome() } else { model.selectRecent(recent) }
                        }
                    }
                    }
                }
                .padding(.horizontal, scale.pad(6))
                .padding(.top, scale.pad(2))
                .padding(.bottom, scale.pad(6))
            }
        }
        .frame(width: scale.size(222))
    }

    private func header(scale: UIScale) -> some View {
        let newCount = recents.filter(model.isNew).count
        // The whole row is the switch: cards <-> sets by release date. With no sets data
        // (no --printings refresh yet) the toggle is a no-op and the column stays on cards.
        return Button { model.toggleRecentColumnSets() } label: {
            HStack(spacing: scale.pad(6)) {
                Image(systemName: sets == nil ? "clock" : "calendar")
                    .font(scale.font(15))
                    .foregroundStyle(.secondary)
                Text(sets == nil ? "Recently Added" : "Sets")
                    .font(scale.font(13, weight: .semibold))
                if sets != nil || newCount > 0 {
                    Text(sets != nil ? "‹ Recent" : "\(newCount) New")
                        .font(scale.font(11, weight: .semibold))
                        .foregroundStyle(DS.accent)
                        .padding(.horizontal, scale.pad(8))
                        .padding(.vertical, scale.pad(2))
                        .background(Capsule().fill(DS.selection))
                }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: scale.pad(10), leading: scale.pad(12),
                                bottom: scale.pad(6), trailing: scale.pad(8)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(sets != nil ? "Back to recently added cards" : "Browse sets by release date")
    }
}

/// One card in the Recently Added list: thumbnail, name (+ ≤7-day accent dot),
/// and a "{Set} · {relative time}" secondary line.
private struct RecentRow: View {
    let recent: Card.Recent
    let isNew: Bool
    let selected: Bool
    let onTap: () -> Void
    @AppStorage(UIScale.storageKey) private var uiScaleValue: Double = UIScale.defaultValue
    @State private var hovering = false

    var body: some View {
        let scale = UIScale(value: uiScaleValue)
        HStack(spacing: scale.pad(10)) {
            Thumbnail(id: recent.id, identity: recent.identity)
                .frame(width: scale.size(30), height: scale.size(42))
            VStack(alignment: .leading, spacing: scale.pad(2)) {
                HStack(spacing: scale.pad(4)) {
                    Text(recent.name)
                        .font(scale.font(14))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if isNew {
                        Circle()
                            .fill(DS.accent)
                            .frame(width: scale.size(6), height: scale.size(6))
                    }
                }
                secondaryLine(scale: scale)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, scale.pad(8))
        .padding(.vertical, scale.pad(4))
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.sm)
                .fill(selected ? DS.selection : (hovering ? Color.primary.opacity(0.045) : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
        .animation(DS.Motion.selectScroll, value: hovering)
    }

    private func secondaryLine(scale: UIScale) -> some View {
        (
            Text(recent.setName ?? recent.setCode ?? "—")
                .foregroundStyle(.secondary)
            + Text(" · \(RelativeTime.string(for: recent.firstSeen))")
                .foregroundStyle(.tertiary)
        )
        .font(scale.font(11))
        .lineLimit(1)
        .truncationMode(.tail)
    }
}

/// One set in the column's "Sets" view: symbol, name and release date. Click runs `set:<code>`.
private struct SetListRow: View {
    let info: SetRow
    let onTap: () -> Void
    @AppStorage(UIScale.storageKey) private var uiScaleValue: Double = UIScale.defaultValue
    @State private var hovering = false

    var body: some View {
        let scale = UIScale(value: uiScaleValue)
        HStack(spacing: scale.pad(8)) {
            SetIconView(code: info.code, urlString: info.iconSvgUri)
                .frame(width: scale.size(18), height: scale.size(18))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: scale.pad(2)) {
                Text(info.name).font(scale.font(13)).lineLimit(1).truncationMode(.tail)
                Text(info.releasedAt).font(scale.font(11)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, scale.pad(8))
        .padding(.vertical, scale.pad(4))
        .background(RoundedRectangle(cornerRadius: DS.Radius.sm)
            .fill(hovering ? Color.primary.opacity(0.045) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
        .animation(DS.Motion.selectScroll, value: hovering)
        .help("Search set:\(info.code)")
    }
}
