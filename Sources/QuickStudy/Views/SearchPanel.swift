import SwiftUI
import AppKit
import Shared

struct SearchPanel: View {
    @ObservedObject var model: AppModel
    var onDismiss: () -> Void

    @FocusState private var searchFocused: Bool
    @AppStorage("enterBehavior") private var enterBehaviorRaw: String = EnterBehavior.copyName.rawValue
    @AppStorage(UIScale.storageKey) private var uiScaleValue: Double = UIScale.defaultValue

    var body: some View {
        let scale = UIScale(value: uiScaleValue)
        return VStack(spacing: 0) {
            searchField
            Divider().opacity(0.3)
            content
        }
        .frame(minWidth: scale.size(860), minHeight: scale.size(520))
        .onAppear { searchFocused = true }
        .onExitCommand(perform: onDismiss)
    }

    private var searchField: some View {
        let scale = UIScale(value: uiScaleValue)
        return HStack(spacing: scale.pad(8)) {
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
            }
            if model.results.isEmpty && model.query.isEmpty {
                placeholderHint
            } else if model.results.isEmpty {
                Text("No matches.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let scale = UIScale(value: uiScaleValue)
                HStack(spacing: 0) {
                    ResultList(model: model)
                        .frame(width: scale.size(280))
                    Divider().opacity(0.2)
                    CardPreview(card: model.selectedCard)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
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
