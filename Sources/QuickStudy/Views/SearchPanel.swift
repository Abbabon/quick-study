import SwiftUI
import AppKit
import Shared

struct SearchPanel: View {
    @ObservedObject var model: AppModel
    var onDismiss: () -> Void

    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("enterBehavior") private var enterBehaviorRaw: String = EnterBehavior.copyName.rawValue
    @AppStorage(UIScale.storageKey) private var uiScaleValue: Double = UIScale.defaultValue
    @AppStorage("showRecentlyAdded") private var showRecentlyAdded: Bool = true

    var body: some View {
        let scale = UIScale(value: uiScaleValue)
        return VStack(spacing: 0) {
            searchField
            Divider().opacity(0.3)
            HStack(spacing: 0) {
                if model.showsRecentColumn && model.recentlyAddedExpanded {
                    RecentlyAddedColumn(model: model)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Divider().opacity(0.5)
                }
                content
                if model.dbState == .ready && model.listsColumnVisible {
                    Divider().opacity(0.5)
                    ListsColumn(model: model)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            if model.dbState == .ready && !model.pinned.isEmpty {
                Divider().opacity(0.3)
                PinnedRow(model: model)
            }
        }
        .frame(minWidth: scale.size(860), minHeight: scale.size(520))
        .animation(reduceMotion ? nil : DS.Motion.resize, value: model.recentlyAddedExpanded)
        .animation(reduceMotion ? nil : DS.Motion.resize, value: model.showsRecentColumn)
        .animation(reduceMotion ? nil : DS.Motion.resize, value: model.listsColumnVisible)
        .tint(DS.accent)
        .onAppear { searchFocused = true }
        .onExitCommand(perform: onDismiss)
    }

    private var searchField: some View {
        let scale = UIScale(value: uiScaleValue)
        return HStack(spacing: scale.pad(8)) {
            if model.showsRecentColumn {
                Button {
                    withAnimation(reduceMotion ? nil : DS.Motion.resize) {
                        model.recentlyAddedExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.leading")
                        .font(scale.font(18))
                        .foregroundStyle(model.recentlyAddedExpanded ? DS.accent : Color.secondary)
                        .frame(width: scale.size(30), height: scale.size(30))
                        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
                }
                .buttonStyle(.plain)
                .help(model.recentlyAddedExpanded ? "Hide Recently Added" : "Show Recently Added")
            }
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(scale.font(18, weight: .medium))
            TextField("Search MTG cards…", text: $model.query)
                .textFieldStyle(.plain)
                .font(scale.font(22, weight: .light))
                .focused($searchFocused)
                .onChange(of: model.query) { model.runSearch() }
                .onSubmit { handleEnter() }
                .onKeyPress(.upArrow) { model.selectPrev(); return .handled }
                .onKeyPress(.downArrow) { model.selectNext(); return .handled }
            if model.dbState == .ready {
                Button {
                    withAnimation(reduceMotion ? nil : DS.Motion.resize) {
                        model.toggleListsColumn()
                    }
                } label: {
                    Image(systemName: "sidebar.trailing")
                        .font(scale.font(18))
                        .foregroundStyle(model.listsColumnVisible ? DS.accent : Color.secondary)
                        .frame(width: scale.size(30), height: scale.size(30))
                        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
                }
                .buttonStyle(.plain)
                .help(model.listsColumnVisible ? "Hide Lists" : "Show Lists")
            }
            Button {
                model.onOpenGame?()
            } label: {
                Image(systemName: "gamecontroller")
                    .font(scale.font(18))
                    .foregroundStyle(.secondary)
                    .frame(width: scale.size(30), height: scale.size(30))
                    .contentShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
            }
            .buttonStyle(.plain)
            .help("Play")
            Button {
                model.onOpenSettings?()
            } label: {
                Image(systemName: "gearshape")
                    .font(scale.font(18))
                    .foregroundStyle(.secondary)
                    .frame(width: scale.size(30), height: scale.size(30))
                    .contentShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, scale.pad(18))
        .padding(.vertical, scale.pad(14))
    }

    @ViewBuilder
    private var content: some View {
        switch model.dbState {
        case .empty:
            DownloadPromptView(model: model)
        case .unknown:
            ProgressView("Loading database…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if case .running = model.refreshState {
                refreshBanner
            } else if showAppUpdateBanner {
                appUpdateBanner
            } else if model.updateAvailable {
                updateBanner
            }
            if !model.results.isEmpty {
                let scale = UIScale(value: uiScaleValue)
                HStack(spacing: 0) {
                    ResultList(model: model)
                        .frame(width: scale.size(280))
                    Divider().opacity(0.2)
                    cardPreview
                }
            } else if model.selectedCard != nil {
                // No active search, but a pinned card was clicked — show it.
                cardPreview
            } else if model.query.isEmpty {
                placeholderHint
            } else {
                Text("No matches.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var cardPreview: some View {
        VStack(spacing: 0) {
            if let recent = model.selectedRecent {
                metaStrip(recent)
                Divider().opacity(0.5)
            }
            CardPreview(
                card: model.selectedCard,
                isPinned: model.selectedCard.map { model.isPinned($0.id) } ?? false,
                onTogglePin: { model.togglePinSelected() },
                lists: model.lists,
                onAddToList: { listID in
                    if let id = model.selectedCard?.id { model.addCard(id, toList: listID) }
                },
                onAddToNewList: {
                    if let id = model.selectedCard?.id {
                        model.addToNewList(id)
                        if !model.listsColumnVisible { model.toggleListsColumn() }
                    }
                },
                printings: model.selectedPrintings,
                onSetTap: { model.searchSet($0) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func metaStrip(_ recent: Card.Recent) -> some View {
        let scale = UIScale(value: uiScaleValue)
        let code = recent.setCode.map { " (\($0))" } ?? ""
        let set = recent.setName ?? recent.setCode ?? "—"
        return HStack(spacing: scale.pad(8)) {
            if model.isNew(recent) {
                Text("New")
                    .font(scale.font(11, weight: .semibold))
                    .foregroundStyle(DS.accent)
                    .padding(.horizontal, scale.pad(8))
                    .padding(.vertical, scale.pad(2))
                    .background(Capsule().fill(DS.selection))
            }
            Text("Added \(RelativeTime.string(for: recent.firstSeen)) · \(set)\(code)")
                .font(scale.font(11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, scale.pad(16))
        .padding(.vertical, scale.pad(8))
    }

    private var refreshBanner: some View {
        let scale = UIScale(value: uiScaleValue)
        return Group {
            if case let .running(phase, done, total) = model.refreshState {
                HStack(spacing: scale.pad(8)) {
                    ProgressView().controlSize(.small)
                    Text("\(phase) \(done)/\(total)").font(scale.font(11)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, scale.pad(18))
                .padding(.vertical, scale.pad(6))
            }
        }
    }

    private var updateBanner: some View {
        let scale = UIScale(value: uiScaleValue)
        let dateSuffix = model.availableUpdateDisplay.map { " (updated \($0))" } ?? ""
        return HStack(spacing: scale.pad(8)) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .foregroundStyle(.tint)
                .font(scale.font(13))
            Text("New cards available on Scryfall\(dateSuffix)")
                .font(scale.font(11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Update") { model.startRefresh(skipImages: false) }
                .buttonStyle(.brandProminent)
                .controlSize(.small)
            Button("Dismiss") { model.dismissUpdate() }
                .controlSize(.small)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, scale.pad(18))
        .padding(.vertical, scale.pad(6))
        .background(.tint.opacity(0.08))
    }

    private var showAppUpdateBanner: Bool {
        if case .none = model.appUpdateState { return false }
        return true
    }

    private var appUpdateBanner: some View {
        let scale = UIScale(value: uiScaleValue)
        return HStack(spacing: scale.pad(8)) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
                .font(scale.font(13))
            Text(appUpdateText)
                .font(scale.font(11))
                .foregroundStyle(.secondary)
            Spacer()
            appUpdateButtons
        }
        .padding(.horizontal, scale.pad(18))
        .padding(.vertical, scale.pad(6))
        .background(.tint.opacity(0.08))
    }

    private var appUpdateText: String {
        switch model.appUpdateState {
        case let .available(version, _): return "QuickStudy \(version) is available"
        case let .downloading(version): return "Downloading QuickStudy \(version)…"
        case let .readyToRelaunch(version): return "QuickStudy \(version) ready to install"
        case .installing: return "Installing update…"
        case let .failed(message): return "Update failed: \(message)"
        case .none: return ""
        }
    }

    @ViewBuilder
    private var appUpdateButtons: some View {
        switch model.appUpdateState {
        case .available:
            Button("Update") { model.installOrRelaunch() }
                .controlSize(.small)
            Button("Dismiss") { model.dismissAppUpdate() }
                .controlSize(.small)
                .buttonStyle(.borderless)
        case .downloading, .installing:
            ProgressView().controlSize(.small)
        case .readyToRelaunch:
            Button("Relaunch") { model.installOrRelaunch() }
                .controlSize(.small)
            Button("Later") { model.dismissAppUpdate() }
                .controlSize(.small)
                .buttonStyle(.borderless)
        case .failed:
            Button("Dismiss") { model.dismissAppUpdate() }
                .controlSize(.small)
                .buttonStyle(.borderless)
        case .none:
            EmptyView()
        }
    }

    private var placeholderHint: some View {
        let scale = UIScale(value: uiScaleValue)
        return VStack(spacing: scale.pad(8)) {
            Text("Type a card name")
                .font(scale.font(17))
                .foregroundStyle(.secondary)
            Text("\(model.totalCards) cards • ↑↓ to navigate • Esc to close")
                .font(scale.font(11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleEnter() {
        guard let card = model.selectedCard else { return }
        switch EnterBehavior(rawValue: enterBehaviorRaw) ?? .copyName {
        case .copyName:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(card.name, forType: .string)
        case .openScryfall:
            if let url = URL(string: card.scryfallURI) {
                NSWorkspace.shared.open(url)
            }
        }
        onDismiss()
    }
}

enum EnterBehavior: String, CaseIterable, Identifiable {
    case copyName, openScryfall
    var id: String { rawValue }
    var label: String {
        switch self {
        case .copyName: return "Copy card name to clipboard"
        case .openScryfall: return "Open Scryfall page in browser"
        }
    }
    /// Compact label for the segmented control in Settings.
    var shortLabel: String {
        switch self {
        case .copyName: return "Copy name"
        case .openScryfall: return "Open Scryfall"
        }
    }
}

/// Preset durations for the "clear search on reopen" behavior.
/// `seconds == 0` disables the auto-clear entirely.
enum ClearSearchTimeout: Double, CaseIterable, Identifiable {
    case never = 0
    case thirtySeconds = 30
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case oneHour = 3600

    static let storageKey = "clearSearchTimeout"
    static let defaultValue: Double = ClearSearchTimeout.oneMinute.rawValue

    var id: Double { rawValue }
    var seconds: Double { rawValue }
    var label: String {
        switch self {
        case .never: return "Never"
        case .thirtySeconds: return "30 seconds"
        case .oneMinute: return "1 minute"
        case .fiveMinutes: return "5 minutes"
        case .fifteenMinutes: return "15 minutes"
        case .oneHour: return "1 hour"
        }
    }
}
