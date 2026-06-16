import AppKit
import SwiftUI
import KeyboardShortcuts
import Shared

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("enterBehavior") private var enterBehaviorRaw: String = EnterBehavior.copyName.rawValue
    @AppStorage(UIScale.storageKey) private var uiScaleValue: Double = UIScale.defaultValue
    @AppStorage(ClearSearchTimeout.storageKey) private var clearSearchTimeoutSeconds: Double = ClearSearchTimeout.defaultValue
    @AppStorage("appUpdateAutoCheck") private var appUpdateAutoCheck: Bool = true
    @AppStorage("showRecentlyAdded") private var showRecentlyAdded: Bool = true
    // The OS (SMAppService) is the source of truth; seed from it and resync onAppear.
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            try LoginItem.setEnabled(newValue)
                        } catch {
                            NSLog("QuickStudy: failed to set launch-at-login to \(newValue): \(error)")
                            // Revert the toggle so the UI reflects the real state.
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
            }
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
                Picker("Clear search after:", selection: $clearSearchTimeoutSeconds) {
                    ForEach(ClearSearchTimeout.allCases) { t in
                        Text(t.label).tag(t.seconds)
                    }
                }
                .pickerStyle(.inline)
                Toggle("Show recently added cards", isOn: $showRecentlyAdded)
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
                HStack {
                    Text("Status:")
                    Spacer()
                    if model.updateAvailable {
                        Label {
                            Text("Update available" + (model.availableUpdateDisplay.map { " (Scryfall updated \($0))" } ?? ""))
                        } icon: {
                            Image(systemName: "exclamationmark.circle.fill")
                        }
                        .foregroundStyle(.tint)
                        .font(.callout)
                    } else {
                        Text("Up to date").foregroundStyle(.secondary)
                    }
                }
                refreshButtons
            }
            Section("Application") {
                HStack {
                    Text("Version:")
                    Spacer()
                    Text(model.currentAppVersion).foregroundStyle(.secondary)
                }
                Toggle("Automatically check for updates", isOn: $appUpdateAutoCheck)
                HStack {
                    Text("Update:")
                    Spacer()
                    appUpdateStatusLabel
                }
                appUpdateButton
            }
            Section("Cache") {
                HStack {
                    Text("Image cache:")
                    Spacer()
                    Text(model.imageCacheSizeFormatted).foregroundStyle(.secondary)
                }
                Button("Clear Image Cache…", role: .destructive) { confirmClearImageCache() }
                    .disabled(model.refreshState != .idle)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 520, maxWidth: .infinity,
               minHeight: 440, idealHeight: 560, maxHeight: .infinity)
        .onAppear {
            model.refreshImageCacheSize()
            // Pick up changes made in System Settings while this window was closed.
            launchAtLogin = LoginItem.isEnabled
        }
        .tint(DS.accent)
    }

    private func confirmClearImageCache() {
        let alert = NSAlert()
        alert.messageText = "Clear Image Cache?"
        alert.informativeText = "This will delete \(model.imageCacheSizeFormatted) of cached card images. The card database is preserved — you can re-download images via Refresh Now."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Clear")
        // Make "Clear" the destructive (non-default) button.
        if alert.buttons.count >= 2 {
            alert.buttons[1].hasDestructiveAction = true
        }
        let response = alert.runModal()
        // First button = Cancel (.alertFirstButtonReturn), second = Clear.
        if response == .alertSecondButtonReturn {
            model.clearImageCache()
        }
    }

    @ViewBuilder
    private var appUpdateStatusLabel: some View {
        switch model.appUpdateState {
        case .none:
            Text("Up to date").foregroundStyle(.secondary)
        case let .available(version, _):
            Label("Update available (\(version))", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.tint).font(.callout)
        case let .downloading(version):
            Text("Downloading \(version)…").foregroundStyle(.secondary)
        case let .readyToRelaunch(version):
            Label("Ready to install \(version)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.tint).font(.callout)
        case .installing:
            Text("Installing…").foregroundStyle(.secondary)
        case let .failed(message):
            Text(message).foregroundStyle(.red).font(.callout)
        }
    }

    @ViewBuilder
    private var appUpdateButton: some View {
        switch model.appUpdateState {
        case let .available(_, kind):
            Button(kind == .homebrew ? "Install Update" : "Get Update") { model.installOrRelaunch() }
        case .readyToRelaunch:
            Button("Relaunch to Update") { model.installOrRelaunch() }
        case .downloading, .installing:
            Button("Check for Updates") { model.checkForAppUpdate(force: true) }.disabled(true)
        case .none, .failed:
            Button("Check for Updates") { model.checkForAppUpdate(force: true) }
        }
    }

    @ViewBuilder
    private var refreshButtons: some View {
        switch model.refreshState {
        case .idle:
            HStack {
                Button {
                    model.startRefresh(skipImages: false)
                } label: {
                    Label("Refresh Now", systemImage: "arrow.clockwise")
                }
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
