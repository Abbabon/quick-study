import SwiftUI
import AppKit
import Shared

/// Collapsible left column listing the most recently ingested cards.
/// 222pt fixed width with a hairline trailing separator; body shows ~6 rows
/// and scrolls for the rest of the 30-day window.
struct RecentlyAddedColumn: View {
    @ObservedObject var model: AppModel
    @AppStorage(UIScale.storageKey) private var uiScaleValue: Double = UIScale.defaultValue

    var body: some View {
        let scale = UIScale(value: uiScaleValue)
        VStack(alignment: .leading, spacing: 0) {
            header(scale: scale)
            Divider().opacity(0.5)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: scale.pad(1)) {
                    ForEach(model.recentlyAdded) { recent in
                        RecentRow(
                            recent: recent,
                            isNew: model.isNew(recent),
                            selected: recent.id == model.selectedID
                        ) {
                            model.selectRecent(recent)
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
        HStack(spacing: scale.pad(6)) {
            Image(systemName: "clock")
                .font(scale.font(15))
                .foregroundStyle(.secondary)
            Text("Recently Added")
                .font(scale.font(13, weight: .semibold))
            if model.newCount > 0 {
                Text("\(model.newCount) New")
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
