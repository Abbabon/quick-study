import SwiftUI
import KeyboardShortcuts
import Shared

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("enterBehavior") private var enterBehaviorRaw: String = EnterBehavior.copyName.rawValue
    @AppStorage(UIScale.storageKey) private var uiScaleValue: Double = UIScale.defaultValue

    var body: some View {
        Form {
            Section("Hotkey") {
                KeyboardShortcuts.Recorder("Open search:", name: .openSearch)
            }
            Section("Behavior") {
                Picker("On Enter:", selection: $enterBehaviorRaw) {
                    ForEach(EnterBehavior.allCases) { b in
                        Text(b.label).tag(b.rawValue)
                    }
                }
                .pickerStyle(.inline)
            }
            Section("Appearance") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("UI Scale:")
                        Spacer()
                        Text("\(Int((uiScaleValue * 100).rounded()))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $uiScaleValue, in: UIScale.minValue ... UIScale.maxValue, step: 0.05)
                    Text("Applies the next time you open the search panel.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Section("Database") {
                HStack {
                    Text("Cards in DB:")
                    Spacer()
                    Text("\(model.totalCards)").foregroundStyle(.secondary)
                }
                HStack {
                    Text("Last refresh:")
                    Spacer()
                    Text(model.lastRefresh ?? "never").foregroundStyle(.secondary)
                }
                refreshButtons
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 480, minHeight: 380, idealHeight: 380)
    }

    @ViewBuilder
    private var refreshButtons: some View {
        switch model.refreshState {
        case .idle:
            HStack {
                Button("Refresh Now") { model.startRefresh(skipImages: false) }
                Button("Refresh Cards Only") { model.startRefresh(skipImages: true) }
            }
        case let .running(phase, done, total):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: total > 0 ? Double(done) / Double(total) : 0)
                Text("\(phase) — \(done)/\(total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case let .error(msg):
            VStack(alignment: .leading) {
                Text("Error: \(msg)").font(.caption).foregroundStyle(.red)
                Button("Retry") { model.startRefresh(skipImages: false) }
            }
        }
    }
}
