import SwiftUI
import AppKit
import Shared

struct SearchPanel: View {
    @ObservedObject var model: AppModel
    var onDismiss: () -> Void

    @FocusState private var searchFocused: Bool
    @AppStorage("enterBehavior") private var enterBehaviorRaw: String = EnterBehavior.copyName.rawValue

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().opacity(0.3)
            content
        }
        .frame(minWidth: 860, minHeight: 520)
        .onAppear { searchFocused = true }
        .onExitCommand(perform: onDismiss)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 18, weight: .medium))
            TextField("Search MTG cards…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .light))
                .focused($searchFocused)
                .onChange(of: model.query) { model.runSearch() }
                .onSubmit { handleEnter() }
                .onKeyPress(.upArrow) { model.selectPrev(); return .handled }
                .onKeyPress(.downArrow) { model.selectNext(); return .handled }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
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
                HStack(spacing: 0) {
                    ResultList(model: model)
                        .frame(width: 280)
                    Divider().opacity(0.2)
                    CardPreview(card: model.selectedCard)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var refreshBanner: some View {
        Group {
            if case let .running(phase, done, total) = model.refreshState {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(phase) \(done)/\(total)").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
            }
        }
    }

    private var placeholderHint: some View {
        VStack(spacing: 8) {
            Text("Type a card name").font(.title3).foregroundStyle(.secondary)
            Text("\(model.totalCards) cards • ↑↓ to navigate • Esc to close")
                .font(.caption)
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
